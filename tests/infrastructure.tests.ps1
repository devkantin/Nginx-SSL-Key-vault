param(
    [Parameter(Mandatory)] [string] $ResourceGroupName,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $VmName,
    [Parameter(Mandatory)] [string] $KvName
)

BeforeAll {
    Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
    $script:rg  = Get-AzResourceGroup -Name $ResourceGroupName -ErrorAction SilentlyContinue
    $script:vm  = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -ErrorAction SilentlyContinue
    $script:kv  = Get-AzKeyVault -ResourceGroupName $ResourceGroupName -VaultName $KvName -ErrorAction SilentlyContinue
    $script:pip = Get-AzPublicIpAddress -ResourceGroupName $ResourceGroupName |
                  Where-Object { $_.Name -like 'pip-nginx-*' }
    $script:nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $ResourceGroupName |
                  Where-Object { $_.Name -like 'nsg-nginx-*' }
}

# ─── Resource Group ───────────────────────────────────────────────────────────
Describe 'Resource Group' {
    It 'should exist' {
        $script:rg | Should -Not -BeNullOrEmpty
    }
    It 'should have required tags' {
        $script:rg.Tags['project']   | Should -Be 'nginx-ssl'
        $script:rg.Tags['managedBy'] | Should -Be 'bicep'
    }
}

# ─── Virtual Machine ──────────────────────────────────────────────────────────
Describe 'Virtual Machine' {
    It 'should exist' {
        $script:vm | Should -Not -BeNullOrEmpty
    }

    It 'should run Ubuntu 22.04 LTS Gen2' {
        $script:vm.StorageProfile.ImageReference.Offer | Should -BeLike '*ubuntu*'
        $script:vm.StorageProfile.ImageReference.Sku   | Should -BeLike '22_04*'
    }

    It 'should have system-assigned managed identity' {
        $script:vm.Identity.Type        | Should -Be 'SystemAssigned'
        $script:vm.Identity.PrincipalId | Should -Not -BeNullOrEmpty
    }

    It 'should be in running state' {
        $status = (Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VmName -Status).Statuses |
                  Where-Object { $_.Code -like 'PowerState/*' }
        $status.Code | Should -Be 'PowerState/running'
    }

    It 'should have password authentication disabled' {
        $script:vm.OSProfile.LinuxConfiguration.DisablePasswordAuthentication | Should -Be $true
    }

    It 'should have boot diagnostics enabled' {
        $script:vm.DiagnosticsProfile.BootDiagnostics.Enabled | Should -Be $true
    }

    It 'should have an SSH public key configured' {
        $script:vm.OSProfile.LinuxConfiguration.Ssh.PublicKeys.Count | Should -BeGreaterThan 0
    }
}

# ─── Public IP ────────────────────────────────────────────────────────────────
Describe 'Public IP' {
    It 'should exist' {
        $script:pip | Should -Not -BeNullOrEmpty
    }

    It 'should be Standard SKU' {
        $script:pip.Sku.Name | Should -Be 'Standard'
    }

    It 'should be statically allocated' {
        $script:pip.PublicIpAllocationMethod | Should -Be 'Static'
    }

    It 'should have an assigned IP address' {
        $script:pip.IpAddress | Should -Match '^\d+\.\d+\.\d+\.\d+$'
    }

    It 'should have a DNS label (FQDN)' {
        $script:pip.DnsSettings.Fqdn | Should -Not -BeNullOrEmpty
    }
}

# ─── NSG ──────────────────────────────────────────────────────────────────────
Describe 'Network Security Group' {
    It 'should exist' {
        $script:nsg | Should -Not -BeNullOrEmpty
    }

    It 'should allow HTTPS (443) from any source' {
        $rule = $script:nsg.SecurityRules | Where-Object { $_.Name -eq 'allow-https-inbound' }
        $rule              | Should -Not -BeNullOrEmpty
        $rule.Access       | Should -Be 'Allow'
        $rule.Direction    | Should -Be 'Inbound'
        $rule.DestinationPortRange | Should -Be '443'
    }

    It 'should allow HTTP (80) from any source' {
        $rule = $script:nsg.SecurityRules | Where-Object { $_.Name -eq 'allow-http-inbound' }
        $rule              | Should -Not -BeNullOrEmpty
        $rule.Access       | Should -Be 'Allow'
        $rule.DestinationPortRange | Should -Be '80'
    }

    It 'should restrict SSH to VNet only' {
        $rule = $script:nsg.SecurityRules | Where-Object { $_.Name -eq 'allow-ssh-vnet-only' }
        $rule                      | Should -Not -BeNullOrEmpty
        $rule.SourceAddressPrefix  | Should -Be 'VirtualNetwork'
        $rule.DestinationPortRange | Should -Be '22'
    }
}

# ─── Key Vault ────────────────────────────────────────────────────────────────
Describe 'Key Vault' {
    It 'should exist' {
        $script:kv | Should -Not -BeNullOrEmpty
    }

    It 'should have soft delete enabled' {
        $script:kv.EnableSoftDelete | Should -Be $true
    }

    It 'should not be enabled for public template deployment' {
        $script:kv.EnabledForTemplateDeployment | Should -Not -Be $true
    }

    It 'SSL certificate should exist' {
        $cert = Get-AzKeyVaultCertificate -VaultName $KvName -Name 'nginx-ssl-cert' -ErrorAction SilentlyContinue
        $cert | Should -Not -BeNullOrEmpty
    }

    It 'SSL certificate should be enabled' {
        $cert = Get-AzKeyVaultCertificate -VaultName $KvName -Name 'nginx-ssl-cert' -ErrorAction SilentlyContinue
        $cert.Enabled | Should -Be $true
    }

    It 'SSL certificate should not be expired' {
        $cert = Get-AzKeyVaultCertificate -VaultName $KvName -Name 'nginx-ssl-cert' -ErrorAction SilentlyContinue
        $cert.Expires | Should -BeGreaterThan (Get-Date)
    }

    It 'VM managed identity should have secret get permission' {
        $vmPrincipalId = $script:vm.Identity.PrincipalId
        $policy = $script:kv.AccessPolicies | Where-Object { $_.ObjectId -eq $vmPrincipalId }
        $policy                           | Should -Not -BeNullOrEmpty
        $policy.PermissionsToSecrets      | Should -Contain 'get'
    }
}
