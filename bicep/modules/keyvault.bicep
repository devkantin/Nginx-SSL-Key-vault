param name string
param location string
param tags object

@description('Object ID of the deployment principal — granted full certificate + secret access')
param deploymentPrincipalId string

resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: false
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false
    accessPolicies: [
      {
        tenantId: subscription().tenantId
        objectId: deploymentPrincipalId
        permissions: {
          certificates: ['all']
          secrets: ['all']
          keys: ['all']
        }
      }
    ]
  }
}

output id string = kv.id
output name string = kv.name
output uri string = kv.properties.vaultUri
