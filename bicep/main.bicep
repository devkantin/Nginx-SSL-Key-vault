targetScope = 'resourceGroup'

@description('Deployment environment')
@allowed(['dev', 'prod'])
param environment string

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('VM admin username')
param adminUsername string

@description('SSH public key for VM access')
param sshPublicKey string

@description('VM size')
param vmSize string = 'Standard_B2s'

@description('Object ID of the deployment service principal — needs KV certificate permissions')
param deploymentPrincipalId string

var prefix = 'nginx-${environment}'
var certName = 'nginx-ssl-cert'
var kvName = take('kv-${prefix}-${uniqueString(resourceGroup().id)}', 24)
var tags = {
  environment: environment
  project: 'nginx-ssl'
  managedBy: 'bicep'
}

module nsg 'modules/nsg.bicep' = {
  name: 'nsg-${uniqueString(deployment().name)}'
  params: {
    name: 'nsg-${prefix}'
    location: location
    tags: tags
  }
}

module network 'modules/network.bicep' = {
  name: 'network-${uniqueString(deployment().name)}'
  params: {
    vnetName: 'vnet-${prefix}'
    location: location
    tags: tags
    nsgId: nsg.outputs.id
  }
}

module publicIp 'modules/publicip.bicep' = {
  name: 'pip-${uniqueString(deployment().name)}'
  params: {
    name: 'pip-${prefix}'
    location: location
    tags: tags
    dnsLabel: toLower('${replace(prefix, '-', '')}${uniqueString(resourceGroup().id)}')
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'kv-${uniqueString(deployment().name)}'
  params: {
    name: kvName
    location: location
    tags: tags
    deploymentPrincipalId: deploymentPrincipalId
  }
}

module vm 'modules/vm.bicep' = {
  name: 'vm-${uniqueString(deployment().name)}'
  params: {
    vmName: 'nginx-vm-${environment}'
    location: location
    tags: tags
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    vmSize: vmSize
    subnetId: network.outputs.subnetId
    publicIpId: publicIp.outputs.id
  }
}

// Grant VM managed identity read access to Key Vault secrets
resource kvVmAccessPolicy 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  name: '${kvName}/add'
  properties: {
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: vm.outputs.principalId
        permissions: {
          secrets: ['get']
        }
      }
    ]
  }
}

output publicIpAddress string = publicIp.outputs.ipAddress
output fqdn string = publicIp.outputs.fqdn
output keyVaultName string = kvName
output vmName string = vm.outputs.vmName
output certificateName string = certName
