targetScope = 'resourceGroup'

param name string
param location string
param subnetId string
param storageAccountId string
param groupId string
param privateDnsZoneId string
param tags object

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-10-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${name}-connection'
        properties: {
          privateLinkServiceId: storageAccountId
          groupIds: [groupId]
          privateLinkServiceConnectionState: {
            status: 'Approved'
            description: 'Approved by Bicep deployment'
          }
        }
      }
    ]
  }
}

resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-10-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: groupId
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

output id string = privateEndpoint.id
