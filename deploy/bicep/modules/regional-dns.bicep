targetScope = 'resourceGroup'

param virtualNetworkId string
param linkToken string
param tags object

var zones = [
  'privatelink.file.${environment().suffixes.storage}'
  'privatelink.blob.${environment().suffixes.storage}'
  'privatelink${environment().suffixes.acrLoginServer}'
]

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zoneName in zones: {
  name: zoneName
  location: 'global'
  tags: tags
}]

resource virtualNetworkLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zoneName, index) in zones: {
  parent: privateDnsZones[index]
  name: 'link-${linkToken}'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetworkId
    }
  }
}]

output fileZoneId string = privateDnsZones[0].id
output blobZoneId string = privateDnsZones[1].id
output acrZoneId string = privateDnsZones[2].id
