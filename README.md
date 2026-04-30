# Nginx SSL — Azure Key Vault

Deploy an Ubuntu VM running Nginx with an SSL certificate sourced from **Azure Key Vault**, fully automated via a GitHub Actions CI/CD pipeline.

---

## Architecture

```
Internet
   │
   │ HTTP :80 → 301 redirect
   │ HTTPS :443
   ▼
┌──────────────────────────┐
│  Public IP (Standard,    │  ← Static IP + DNS label
│  Static)                 │
└────────────┬─────────────┘
             │
      NSG (allow 80, 443)
             │
             ▼
┌──────────────────────────┐
│  Ubuntu 22.04 LTS VM     │
│  Nginx + TLS 1.2/1.3     │  ← System-assigned Managed Identity
│  HSTS, security headers  │
└────────────┬─────────────┘
             │ Managed Identity (get secret)
             ▼
┌──────────────────────────┐
│  Azure Key Vault         │  ← Self-signed cert (auto-renews 30d before expiry)
│  nginx-ssl-cert (PFX)    │
└──────────────────────────┘
```

**How SSL works:**
1. Key Vault generates and stores a self-signed RSA 2048 certificate (PFX format)
2. The VM's managed identity has `get` permission on Key Vault secrets
3. `configure-ssl.sh` runs on the VM, retrieves the PFX via managed identity token, converts to PEM, and configures Nginx
4. Nginx serves HTTPS with TLS 1.2/1.3 only, HSTS, and security headers

---

## Repository Structure

```
├── bicep/
│   ├── main.bicep                  # Orchestrator — wires all modules + KV access policy
│   ├── modules/
│   │   ├── nsg.bicep               # NSG: allow 80, 443 inbound; SSH VNet-only
│   │   ├── network.bicep           # VNet + subnet
│   │   ├── publicip.bicep          # Standard static public IP with DNS label
│   │   ├── keyvault.bicep          # Key Vault with access policies
│   │   └── vm.bicep                # Ubuntu 22.04 Gen2 VM with managed identity + cloud-init
│   └── parameters/
│       ├── dev.bicepparam          # Dev: Standard_B2s
│       └── prod.bicepparam         # Prod: Standard_B2ms
├── scripts/
│   ├── cloud-init.yml              # Installs Nginx, jq, openssl on first boot
│   ├── configure-ssl.sh            # Pulls cert from KV, converts PFX→PEM, configures Nginx
│   └── cert-policy.json            # Key Vault certificate policy (self-signed, 12 months)
├── tests/
│   ├── infrastructure.tests.ps1   # Pester 5: VM, KV, NSG, PIP, RG validation
│   └── nginx.tests.sh             # curl + openssl: HTTP redirect, HTTPS, TLS, headers
└── .github/workflows/
    ├── validate.yml                # PR: Bicep lint + ShellCheck + Checkov + What-If
    └── deploy.yml                  # Push/manual: deploy → cert → configure → test
```

---

## CI/CD Pipeline

### `validate.yml` — runs on every Pull Request

```
PR opened
   ├─► Bicep Lint          az bicep lint
   ├─► ShellCheck          lint scripts/ and tests/
   ├─► Security Scan       Checkov → GitHub Security tab
   └─► What-If Preview     az deployment group what-if → PR comment
```

### `deploy.yml` — runs on push to `main` or manual trigger

```
Push to main
   │
   ├─[1]─► Deploy Bicep     VNet, NSG, PIP, Key Vault, VM
   ├─[2]─► Create Cert      az keyvault certificate create (idempotent)
   ├─[3]─► Wait cloud-init  polls VM until cloud-init status = done
   ├─[4]─► Configure SSL    az vm run-command → configure-ssl.sh
   ├─[5]─► Pester Tests     infrastructure validation (VM, KV, NSG, PIP)
   ├─[6]─► Nginx Tests      HTTP redirect, HTTPS, TLS 1.0/1.1 rejected,
   │                         security headers, /health endpoint
   └─[7]─► Artifacts        test-results XML uploaded
```

---

## Test Coverage

### Infrastructure Tests (Pester)
| Area | Tests |
|---|---|
| Resource Group | exists, tags |
| VM | exists, Ubuntu 22.04, managed identity, running state, SSH-only auth, boot diagnostics |
| Public IP | Standard SKU, static, IP assigned, FQDN present |
| NSG | HTTPS/HTTP rules allow, SSH restricted to VNet |
| Key Vault | soft delete, cert exists, cert enabled, cert not expired, VM identity has get permission |

### Nginx / SSL Tests (bash + curl + openssl)
| Test | What it checks |
|---|---|
| Port 80 connectivity | Returns 301 redirect |
| HTTP → HTTPS redirect | Redirect URL starts with `https://` |
| HTTPS response | Returns 200 OK |
| Redirect chain | HTTP → HTTPS → 200 end-to-end |
| SSL handshake | `openssl s_client` connects successfully |
| TLS version | TLSv1.2 or TLSv1.3 only |
| Certificate expiry | `notAfter` date is present |
| Certificate subject | Subject is readable |
| TLS 1.0 disabled | Handshake fails with `-tls1` |
| TLS 1.1 disabled | Handshake fails with `-tls1_1` |
| HSTS header | `Strict-Transport-Security` present |
| X-Content-Type-Options | Header present |
| X-Frame-Options | Header present |
| `/health` endpoint | Returns `OK` |
| `/` endpoint | Returns HTML content |

---

## Prerequisites

| Tool | Version |
|---|---|
| Azure CLI | ≥ 2.55 |
| Bicep CLI | ≥ 0.24 (`az bicep install`) |
| PowerShell | ≥ 7.3 |
| Pester | ≥ 5.5 |
| Az PowerShell | ≥ 11.0 |

---

## GitHub Setup

### 1. Create GitHub Environments

Go to **Settings → Environments** and create:
- `dev` — no protection rules (auto-deploys on push to `main`)
- `prod` — add required reviewers

### 2. Required Secrets

Add to each environment under **Settings → Environments → Secrets**:

| Secret | Environment | Description | Where to find |
|---|---|---|---|
| `AZURE_TENANT_ID` | dev + prod | Azure AD Tenant ID | Azure Portal → Azure AD → Overview |
| `AZURE_CLIENT_ID` | dev | OIDC App Registration Client ID (dev SP) | App Registrations → Overview |
| `AZURE_SUBSCRIPTION_ID` | dev | Dev subscription ID | Azure Portal → Subscriptions |
| `AZURE_CLIENT_ID_PROD` | prod | OIDC App Registration Client ID (prod SP) | App Registrations → Overview |
| `AZURE_SUBSCRIPTION_ID_PROD` | prod | Prod subscription ID | Azure Portal → Subscriptions |
| `NGINX_SSH_PUBLIC_KEY` | dev | SSH public key for VM access | `cat ~/.ssh/id_rsa.pub` |
| `NGINX_SSH_PUBLIC_KEY_PROD` | prod | SSH public key for prod VM | `cat ~/.ssh/id_rsa.pub` |

### 3. Configure OIDC Federated Credentials

```bash
# Create app registration for dev
APP_ID=$(az ad app create --display-name "sp-nginx-dev-github" --query appId -o tsv)
az ad sp create --id $APP_ID

# Contributor role on subscription
az role assignment create \
  --assignee $APP_ID \
  --role Contributor \
  --scope /subscriptions/<your-dev-subscription-id>

# Federated credential for GitHub Actions
az ad app federated-credential create \
  --id $APP_ID \
  --parameters '{
    "name": "github-nginx-dev",
    "issuer": "https://token.actions.githubusercontent.com",
    "subject": "repo:devkantin/Nginx-SSL-Key-vault:environment:dev",
    "audiences": ["api://AzureADTokenExchange"]
  }'
```

Repeat for prod using `environment:prod` as the subject.

### 4. Set secrets via GitHub CLI

```bash
gh auth login

# Dev secrets
gh secret set AZURE_TENANT_ID            --env dev  --repo devkantin/Nginx-SSL-Key-vault
gh secret set AZURE_CLIENT_ID            --env dev  --repo devkantin/Nginx-SSL-Key-vault
gh secret set AZURE_SUBSCRIPTION_ID      --env dev  --repo devkantin/Nginx-SSL-Key-vault
gh secret set NGINX_SSH_PUBLIC_KEY       --env dev  --repo devkantin/Nginx-SSL-Key-vault

# Prod secrets
gh secret set AZURE_CLIENT_ID_PROD       --env prod --repo devkantin/Nginx-SSL-Key-vault
gh secret set AZURE_SUBSCRIPTION_ID_PROD --env prod --repo devkantin/Nginx-SSL-Key-vault
gh secret set NGINX_SSH_PUBLIC_KEY_PROD  --env prod --repo devkantin/Nginx-SSL-Key-vault
```

---

## Running Tests Locally

```powershell
# Infrastructure tests
Connect-AzAccount
$c = New-PesterContainer -Path 'tests/infrastructure.tests.ps1' -Data @{
    ResourceGroupName = 'rg-nginx-dev'
    SubscriptionId    = '<your-sub-id>'
    VmName            = 'nginx-vm-dev'
    KvName            = '<your-kv-name>'
}
Invoke-Pester -Container $c -Output Detailed
```

```bash
# Nginx + SSL tests
chmod +x tests/nginx.tests.sh
./tests/nginx.tests.sh <public-ip>
```

---

## NSG Rules

| Rule | Port | Source | Purpose |
|---|---|---|---|
| allow-https-inbound | 443 | Any | HTTPS traffic |
| allow-http-inbound | 80 | Any | HTTP (redirects to HTTPS) |
| allow-ssh-vnet-only | 22 | VirtualNetwork | SSH — use Bastion or VPN |
