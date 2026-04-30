param name string
param location string
param tags object
param dnsLabel string

resource pip 'Microsoft.Network/publicIPAddresses@2023-09-01' = {
  name: name
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    dnsSettings: {
      domainNameLabel: dnsLabel
    }
  }
}

output id string = pip.id
output ipAddress string = pip.properties.ipAddress
output fqdn string = pip.properties.dnsSettings.fqdn
