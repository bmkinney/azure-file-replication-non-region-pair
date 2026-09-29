targetScope = 'resourceGroup'

param environmentName string
param location string
param regionCode string

@description('Optional name; empty generates the same name as earlier versions of this template.')
param name string = ''

@description('Resource ID of an existing user-assigned identity to reuse. Empty creates the identity.')
param existingIdentityId string = ''

param tags object

var token = uniqueString(subscription().id, resourceGroup().id, environmentName, location)
var reuseIdentity = !empty(existingIdentityId)
// The parent template validates the ID; the fallback keeps the reference well formed until it does.
var existingIdentitySegments = split(length(split(existingIdentityId, '/')) == 9 ? existingIdentityId : '/subscriptions/${subscription().subscriptionId}/resourceGroups/unset/providers/Microsoft.ManagedIdentity/userAssignedIdentities/unset', '/')

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = if (!reuseIdentity) {
  name: empty(name) ? 'id-replication-${regionCode}-${token}' : name
  location: location
  tags: tags
}

resource existingIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' existing = if (reuseIdentity) {
  name: existingIdentitySegments[8]
  scope: resourceGroup(existingIdentitySegments[2], existingIdentitySegments[4])
}

output id string = reuseIdentity ? existingIdentity!.id : identity!.id
output name string = reuseIdentity ? existingIdentity!.name : identity!.name
output principalId string = reuseIdentity ? existingIdentity!.properties.principalId : identity!.properties.principalId
output clientId string = reuseIdentity ? existingIdentity!.properties.clientId : identity!.properties.clientId
