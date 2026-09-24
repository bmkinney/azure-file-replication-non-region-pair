targetScope = 'resourceGroup'

param environmentName string
param location string
param regionCode string

@description('Optional name; empty generates the same name as earlier versions of this template.')
param name string = ''

param tags object

var token = uniqueString(subscription().id, resourceGroup().id, environmentName, location)

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: empty(name) ? 'id-replication-${regionCode}-${token}' : name
  location: location
  tags: tags
}

output id string = identity.id
output principalId string = identity.properties.principalId
output clientId string = identity.properties.clientId
