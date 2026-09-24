targetScope = 'resourceGroup'

param name string
param location string
param replicaLocation string

@allowed([
  'Enabled'
  'Disabled'
])
@description('Enable only while scripts/deploy.ps1 builds the AzCopy image.')
param publicNetworkAccess string

param tags object

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: name
  location: location
  tags: tags
  sku: { name: 'Premium' }
  properties: {
    adminUserEnabled: false
    dataEndpointEnabled: true
    publicNetworkAccess: publicNetworkAccess
  }
}

resource replica 'Microsoft.ContainerRegistry/registries/replications@2025-04-01' = {
  parent: registry
  name: replicaLocation
  location: replicaLocation
  tags: tags
  properties: {}
}

// Consumers of these outputs wait for the whole module, including the replica, so their private endpoints include its data endpoint.
output id string = registry.id
output name string = registry.name
output loginServer string = registry.properties.loginServer
