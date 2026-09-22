targetScope = 'resourceGroup'

param environmentName string
param primaryLocation string
param secondaryLocation string
param primaryRegionCode string
param secondaryRegionCode string
param primaryStorageAccountName string
param primaryStorageResourceGroupName string
param primaryFileShareName string
param secondaryStorageAccountName string
param secondaryStorageResourceGroupName string
param secondaryFileShareName string
param primaryVnetName string
param primaryVnetResourceGroupName string
param primaryInfrastructureSubnetName string
param secondaryVnetName string
param secondaryVnetResourceGroupName string
param secondaryInfrastructureSubnetName string
param registryName string
param registryResourceGroupName string
param existingPrivateEndpointIds array
param activeRegion string
param containerImage string
param scheduleCronExpression string
param tags object

var primaryToken = uniqueString(subscription().id, resourceGroup().id, environmentName, primaryLocation)
var secondaryToken = uniqueString(subscription().id, resourceGroup().id, environmentName, secondaryLocation)
var primaryIdentityName = 'id-replication-${primaryRegionCode}-${primaryToken}'
var secondaryIdentityName = 'id-replication-${secondaryRegionCode}-${secondaryToken}'
var sourceFileUrl = 'https://${primaryStorageAccountName}.file.${environment().suffixes.storage}/${primaryFileShareName}'
var destinationFileUrl = 'https://${secondaryStorageAccountName}.file.${environment().suffixes.storage}/${secondaryFileShareName}'

resource primaryStorage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: primaryStorageAccountName
  scope: resourceGroup(primaryStorageResourceGroupName)
}

resource secondaryStorage 'Microsoft.Storage/storageAccounts@2025-01-01' existing = {
  name: secondaryStorageAccountName
  scope: resourceGroup(secondaryStorageResourceGroupName)
}

resource primaryVnet 'Microsoft.Network/virtualNetworks@2024-10-01' existing = {
  name: primaryVnetName
  scope: resourceGroup(primaryVnetResourceGroupName)
}

resource primaryInfrastructureSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-10-01' existing = {
  parent: primaryVnet
  name: primaryInfrastructureSubnetName
}

resource secondaryVnet 'Microsoft.Network/virtualNetworks@2024-10-01' existing = {
  name: secondaryVnetName
  scope: resourceGroup(secondaryVnetResourceGroupName)
}

resource secondaryInfrastructureSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-10-01' existing = {
  parent: secondaryVnet
  name: secondaryInfrastructureSubnetName
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = {
  name: registryName
  scope: resourceGroup(registryResourceGroupName)
}

resource primaryIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: primaryIdentityName
  location: primaryLocation
  tags: tags
}

resource secondaryIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: secondaryIdentityName
  location: secondaryLocation
  tags: tags
}

module primaryStorageRbac 'existing-storage-rbac.bicep' = {
  name: 'primary-storage-rbac'
  scope: resourceGroup(primaryStorageResourceGroupName)
  params: {
    storageAccountName: primaryStorageAccountName
    principalIds: [primaryIdentity.properties.principalId, secondaryIdentity.properties.principalId]
  }
}

module secondaryStorageRbac 'existing-storage-rbac.bicep' = {
  name: 'secondary-storage-rbac'
  scope: resourceGroup(secondaryStorageResourceGroupName)
  params: {
    storageAccountName: secondaryStorageAccountName
    principalIds: [primaryIdentity.properties.principalId, secondaryIdentity.properties.principalId]
  }
}

module registryRbac 'existing-acr-rbac.bicep' = {
  name: 'registry-rbac'
  scope: resourceGroup(registryResourceGroupName)
  params: {
    registryName: registryName
    principalIds: [primaryIdentity.properties.principalId, secondaryIdentity.properties.principalId]
  }
}

resource primaryLog 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: 'log-replication-${primaryRegionCode}-${primaryToken}'
  location: primaryLocation
  tags: tags
  properties: {
    retentionInDays: 30
    sku: { name: 'PerGB2018' }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource secondaryLog 'Microsoft.OperationalInsights/workspaces@2025-02-01' = {
  name: 'log-replication-${secondaryRegionCode}-${secondaryToken}'
  location: secondaryLocation
  tags: tags
  properties: {
    retentionInDays: 30
    sku: { name: 'PerGB2018' }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource primaryEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: 'cae-replication-${primaryRegionCode}-${primaryToken}'
  location: primaryLocation
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: primaryLog.properties.customerId
        sharedKey: primaryLog.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: primaryInfrastructureSubnet.id
      internal: true
    }
    zoneRedundant: false
  }
}

resource secondaryEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: 'cae-replication-${secondaryRegionCode}-${secondaryToken}'
  location: secondaryLocation
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: secondaryLog.properties.customerId
        sharedKey: secondaryLog.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: secondaryInfrastructureSubnet.id
      internal: true
    }
    zoneRedundant: false
  }
}

var primaryRegistry = [{
  server: registry.properties.loginServer
  identity: primaryIdentity.id
}]
var secondaryRegistry = [{
  server: registry.properties.loginServer
  identity: secondaryIdentity.id
}]
var primaryJobConfiguration = activeRegion == 'primary' ? {
  triggerType: 'Schedule'
  replicaRetryLimit: 2
  replicaTimeout: 3600
  scheduleTriggerConfig: {
    cronExpression: scheduleCronExpression
    parallelism: 1
    replicaCompletionCount: 1
  }
  registries: primaryRegistry
} : {
  triggerType: 'Manual'
  replicaRetryLimit: 2
  replicaTimeout: 3600
  manualTriggerConfig: {
    parallelism: 1
    replicaCompletionCount: 1
  }
  registries: primaryRegistry
}
var secondaryJobConfiguration = activeRegion == 'secondary' ? {
  triggerType: 'Schedule'
  replicaRetryLimit: 2
  replicaTimeout: 3600
  scheduleTriggerConfig: {
    cronExpression: scheduleCronExpression
    parallelism: 1
    replicaCompletionCount: 1
  }
  registries: secondaryRegistry
} : {
  triggerType: 'Manual'
  replicaRetryLimit: 2
  replicaTimeout: 3600
  manualTriggerConfig: {
    parallelism: 1
    replicaCompletionCount: 1
  }
  registries: secondaryRegistry
}

resource primaryJob 'Microsoft.App/jobs@2025-01-01' = {
  name: 'job-sync-${primaryRegionCode}-${primaryToken}'
  location: primaryLocation
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${primaryIdentity.id}': {} }
  }
  properties: {
    environmentId: primaryEnvironment.id
    configuration: primaryJobConfiguration
    template: {
      containers: [{
        name: 'azcopy'
        image: containerImage
        env: [
          { name: 'SOURCE_FILE_URL', value: sourceFileUrl }
          { name: 'DESTINATION_FILE_URL', value: destinationFileUrl }
          { name: 'AZCOPY_MSI_CLIENT_ID', value: primaryIdentity.properties.clientId }
          { name: 'DELETE_DESTINATION', value: 'false' }
        ]
        resources: { cpu: json('1.0'), memory: '2Gi' }
      }]
    }
  }
  dependsOn: [
    primaryStorageRbac
    secondaryStorageRbac
    registryRbac
  ]
}

resource secondaryJob 'Microsoft.App/jobs@2025-01-01' = {
  name: 'job-sync-${secondaryRegionCode}-${secondaryToken}'
  location: secondaryLocation
  tags: tags
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${secondaryIdentity.id}': {} }
  }
  properties: {
    environmentId: secondaryEnvironment.id
    configuration: secondaryJobConfiguration
    template: {
      containers: [{
        name: 'azcopy'
        image: containerImage
        env: [
          { name: 'SOURCE_FILE_URL', value: destinationFileUrl }
          { name: 'DESTINATION_FILE_URL', value: sourceFileUrl }
          { name: 'AZCOPY_MSI_CLIENT_ID', value: secondaryIdentity.properties.clientId }
          { name: 'DELETE_DESTINATION', value: 'false' }
        ]
        resources: { cpu: json('1.0'), memory: '2Gi' }
      }]
    }
  }
  dependsOn: [
    primaryStorageRbac
    secondaryStorageRbac
    registryRbac
  ]
}

output primaryJobName string = primaryJob.name
output secondaryJobName string = secondaryJob.name
output registryName string = registry.name
output primaryFileStorageAccountName string = primaryStorage.name
output secondaryFileStorageAccountName string = secondaryStorage.name
output primaryFileShareName string = primaryFileShareName
output secondaryFileShareName string = secondaryFileShareName
output referencedPrivateEndpointIds array = existingPrivateEndpointIds
