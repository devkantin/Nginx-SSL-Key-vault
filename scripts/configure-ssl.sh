#!/usr/bin/env bash
# Runs on the VM via az vm run-command.
# Pulls the SSL certificate from Azure Key Vault using the VM's managed identity,
# converts it from PFX to PEM, and applies the Nginx HTTPS configuration.

set -euo pipefail

KV_NAME="${1:?KV_NAME argument is required}"
CERT_NAME="${2:-nginx-ssl-cert}"

echo "[1/5] Obtaining managed identity token for Key Vault..."
TOKEN=$(curl -fsSL \
  "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://vault.azure.net" \
  -H "Metadata: true" | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "ERROR: Failed to obtain managed identity token" >&2
  exit 1
fi
echo "       Token obtained."

echo "[2/5] Fetching certificate secret from Key Vault: $KV_NAME/$CERT_NAME..."
RESPONSE=$(curl -fsSL \
  "https://${KV_NAME}.vault.azure.net/secrets/${CERT_NAME}?api-version=7.4" \
  -H "Authorization: Bearer $TOKEN")

SECRET_VALUE=$(echo "$RESPONSE" | jq -r '.value // empty')
if [ -z "$SECRET_VALUE" ]; then
  echo "ERROR: Certificate secret not found or access denied." >&2
  echo "       Response: $RESPONSE" >&2
  exit 1
fi
echo "       Certificate secret retrieved."

echo "[3/5] Converting PFX to PEM..."
mkdir -p /etc/ssl/nginx
echo "$SECRET_VALUE" | base64 -d > /tmp/nginx-cert.pfx

openssl pkcs12 -in /tmp/nginx-cert.pfx -nokeys -clcerts \
  -out /etc/ssl/nginx/cert.pem -passin pass: 2>/dev/null

openssl pkcs12 -in /tmp/nginx-cert.pfx -nocerts -nodes \
  -out /etc/ssl/nginx/key.pem  -passin pass: 2>/dev/null

chmod 644 /etc/ssl/nginx/cert.pem
chmod 600 /etc/ssl/nginx/key.pem
rm -f /tmp/nginx-cert.pfx
echo "       PEM files written to /etc/ssl/nginx/"

echo "[4/5] Writing Nginx SSL configuration..."
cat > /etc/nginx/sites-available/default << 'NGINXCONF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_certificate     /etc/ssl/nginx/cert.pem;
    ssl_certificate_key /etc/ssl/nginx/key.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains" always;
    add_header X-Content-Type-Options    nosniff always;
    add_header X-Frame-Options           DENY    always;

    root  /var/www/html;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    location /health {
        return 200 'OK';
        add_header Content-Type text/plain;
    }
}
NGINXCONF

echo "[5/5] Validating and reloading Nginx..."
nginx -t
systemctl reload nginx
echo "SSL configuration complete."
