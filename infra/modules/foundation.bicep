targetScope = 'resourceGroup'

param environmentName string
param primaryLocation string
param secondaryLocation string
param primaryDnsResourceGroupName string
param secondaryDnsResourceGroupName string
param activeRegion string
param containerImage string
param acrPublicNetworkAccess string
param scheduleCronExpression string
param tags object

var primaryToken = uniqueString(subscription().id, resourceGroup().id, environmentName, primaryLocation)
var secondaryToken = uniqueString(subscription().id, resourceGroup().id, environmentName, secondaryLocation)
var registryToken = uniqueString(subscription().id, resourceGroup().id, environmentName, primaryLocation)
var primaryVnetName = 'vnet-${environmentName}-primary'
var secondaryVnetName = 'vnet-${environmentName}-secondary'
var primaryFileStorageName = 'stfile${primaryToken}'
var secondaryFileStorageName = 'stfile${secondaryToken}'
var primaryBlobStorageName = 'stblob${primaryToken}'
var secondaryBlobStorageName = 'stblob${secondaryToken}'
var primaryFileShareName = 'files-primary'
var secondaryFileShareName = 'files-secondary'
var blobContainerName = 'replication'
var registryName = 'acr${registryToken}'
var primaryIdentityName = 'id-replication-primary-${primaryToken}'
var secondaryIdentityName = 'id-replication-secondary-${secondaryToken}'
var fileDataRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '69566ab7-960f-475b-8e7c-b3118f30c6bd')
var acrPullRoleDefinitionId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var sourceFileUrl = 'https://${primaryFileStorageName}.file.${environment().suffixes.storage}/${primaryFileShareName}'
var destinationFileUrl = 'https://${secondaryFileStorageName}.file.${environment().suffixes.storage}/${secondaryFileShareName}'

resource primaryVnet 'Microsoft.Network/virtualNetworks@2024-10-01' = {
  name: primaryVnetName
  location: primaryLocation
  tags: union(tags, { RegionRole: 'primary' })
  properties: {
    addressSpace: { addressPrefixes: ['10.10.0.0/16'] }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.10.0.0/23'
          delegations: [
            {
              name: 'container-apps'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: 'storage'
        properties: {
          addressPrefix: '10.10.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource secondaryVnet 'Microsoft.Network/virtualNetworks@2024-10-01' = {
  name: secondaryVnetName
  location: secondaryLocation
  tags: union(tags, { RegionRole: 'secondary' })
  properties: {
    addressSpace: { addressPrefixes: ['10.20.0.0/16'] }
    subnets: [
      {
        name: 'default'
        properties: {
          addressPrefix: '10.20.0.0/23'
          delegations: [
            {
              name: 'container-apps'
              properties: { serviceName: 'Microsoft.App/environments' }
            }
          ]
        }
      }
      {
        name: 'storage'
        properties: {
          addressPrefix: '10.20.2.0/24'
          privateEndpointNetworkPolicies: 'Disabled'
        }
      }
    ]
  }
}

resource primaryDefaultSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-10-01' existing = {
  parent: primaryVnet
  name: 'default'
}

resource primaryStorageSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-10-01' existing = {
  parent: primaryVnet
  name: 'storage'
}

resource secondaryDefaultSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-10-01' existing = {
  parent: secondaryVnet
  name: 'default'
}

resource secondaryStorageSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-10-01' existing = {
  parent: secondaryVnet
  name: 'storage'
}

module primaryDns 'regional-dns.bicep' = {
  name: 'primary-regional-private-dns'
  scope: resourceGroup(primaryDnsResourceGroupName)
  params: {
    virtualNetworkId: primaryVnet.id
    linkToken: primaryToken
    tags: union(tags, { RegionRole: 'primary' })
  }
}

module secondaryDns 'regional-dns.bicep' = {
  name: 'secondary-regional-private-dns'
  scope: resourceGroup(secondaryDnsResourceGroupName)
  params: {
    virtualNetworkId: secondaryVnet.id
    linkToken: secondaryToken
    tags: union(tags, { RegionRole: 'secondary' })
  }
}

resource primaryFileStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: primaryFileStorageName
  location: primaryLocation
  tags: union(tags, {
    RegionRole: 'primary'
    DataRole: 'files'
  })
  sku: { name: 'Standard_ZRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
  }
}

resource secondaryFileStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: secondaryFileStorageName
  location: secondaryLocation
  tags: union(tags, {
    RegionRole: 'secondary'
    DataRole: 'files'
  })
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
  }
}

resource primaryFileService 'Microsoft.Storage/storageAccounts/fileServices@2025-01-01' = {
  parent: primaryFileStorage
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    protocolSettings: { smb: { versions: 'SMB3.0;SMB3.1.1' } }
  }
}

resource secondaryFileService 'Microsoft.Storage/storageAccounts/fileServices@2025-01-01' = {
  parent: secondaryFileStorage
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    protocolSettings: { smb: { versions: 'SMB3.0;SMB3.1.1' } }
  }
}

resource primaryShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-01-01' = {
  parent: primaryFileService
  name: primaryFileShareName
  properties: {
    accessTier: 'TransactionOptimized'
    enabledProtocols: 'SMB'
    shareQuota: 1024
  }
}

resource secondaryShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2025-01-01' = {
  parent: secondaryFileService
  name: secondaryFileShareName
  properties: {
    accessTier: 'TransactionOptimized'
    enabledProtocols: 'SMB'
    shareQuota: 1024
  }
}

resource primaryBlobStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: primaryBlobStorageName
  location: primaryLocation
  tags: union(tags, {
    RegionRole: 'primary'
    DataRole: 'blob'
  })
  sku: { name: 'Standard_ZRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
    isHnsEnabled: false
  }
}

resource secondaryBlobStorage 'Microsoft.Storage/storageAccounts@2025-01-01' = {
  name: secondaryBlobStorageName
  location: secondaryLocation
  tags: union(tags, {
    RegionRole: 'secondary'
    DataRole: 'blob'
  })
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    defaultToOAuthAuthentication: true
    minimumTlsVersion: 'TLS1_2'
    publicNetworkAccess: 'Disabled'
    supportsHttpsTrafficOnly: true
    isHnsEnabled: false
  }
}

resource primaryBlobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: primaryBlobStorage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    isVersioningEnabled: true
  }
}

resource secondaryBlobService 'Microsoft.Storage/storageAccounts/blobServices@2025-01-01' = {
  parent: secondaryBlobStorage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 14
    }
    isVersioningEnabled: true
  }
}

resource primaryContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: primaryBlobService
  name: blobContainerName
  properties: { publicAccess: 'None' }
}

resource secondaryContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2025-01-01' = {
  parent: secondaryBlobService
  name: blobContainerName
  properties: { publicAccess: 'None' }
}

resource registry 'Microsoft.ContainerRegistry/registries@2025-04-01' = {
  name: registryName
  location: primaryLocation
  tags: tags
  sku: { name: 'Premium' }
  properties: {
    adminUserEnabled: false
    dataEndpointEnabled: true
    publicNetworkAccess: acrPublicNetworkAccess
    zoneRedundancy: 'Enabled'
  }
}

resource registryReplication 'Microsoft.ContainerRegistry/registries/replications@2025-04-01' = {
  parent: registry
  name: secondaryLocation
  location: secondaryLocation
  tags: tags
  properties: { zoneRedundancy: 'Disabled' }
}

module primaryPrimaryFilePe 'storage-private-endpoint.bicep' = {
  name: 'primary-primary-file-pe'
  params: {
    name: 'pe-primary-primary-file'
    location: primaryLocation
    subnetId: primaryStorageSubnet.id
    storageAccountId: primaryFileStorage.id
    groupId: 'file'
    privateDnsZoneId: primaryDns.outputs.fileZoneId
    tags: tags
  }
}
module primarySecondaryFilePe 'storage-private-endpoint.bicep' = {
  name: 'primary-secondary-file-pe'
  params: {
    name: 'pe-primary-secondary-file'
    location: primaryLocation
    subnetId: primaryStorageSubnet.id
    storageAccountId: secondaryFileStorage.id
    groupId: 'file'
    privateDnsZoneId: primaryDns.outputs.fileZoneId
    tags: tags
  }
}
module secondaryPrimaryFilePe 'storage-private-endpoint.bicep' = {
  name: 'secondary-primary-file-pe'
  params: {
    name: 'pe-secondary-primary-file'
    location: secondaryLocation
    subnetId: secondaryStorageSubnet.id
    storageAccountId: primaryFileStorage.id
    groupId: 'file'
    privateDnsZoneId: secondaryDns.outputs.fileZoneId
    tags: tags
  }
}
module secondarySecondaryFilePe 'storage-private-endpoint.bicep' = {
  name: 'secondary-secondary-file-pe'
  params: {
    name: 'pe-secondary-secondary-file'
    location: secondaryLocation
    subnetId: secondaryStorageSubnet.id
    storageAccountId: secondaryFileStorage.id
    groupId: 'file'
    privateDnsZoneId: secondaryDns.outputs.fileZoneId
    tags: tags
  }
}
module primaryBlobPe 'storage-private-endpoint.bicep' = {
  name: 'primary-blob-pe'
  params: {
    name: 'pe-primary-blob'
    location: primaryLocation
    subnetId: primaryStorageSubnet.id
    storageAccountId: primaryBlobStorage.id
    groupId: 'blob'
    privateDnsZoneId: primaryDns.outputs.blobZoneId
    tags: tags
  }
}
module secondaryBlobPe 'storage-private-endpoint.bicep' = {
  name: 'secondary-blob-pe'
  params: {
    name: 'pe-secondary-blob'
    location: secondaryLocation
    subnetId: secondaryStorageSubnet.id
    storageAccountId: secondaryBlobStorage.id
    groupId: 'blob'
    privateDnsZoneId: secondaryDns.outputs.blobZoneId
    tags: tags
  }
}
module primaryAcrPe 'storage-private-endpoint.bicep' = {
  name: 'primary-acr-pe'
  params: {
    name: 'pe-primary-acr'
    location: primaryLocation
    subnetId: primaryStorageSubnet.id
    storageAccountId: registry.id
    groupId: 'registry'
    privateDnsZoneId: primaryDns.outputs.acrZoneId
    tags: tags
  }
}
module secondaryAcrPe 'storage-private-endpoint.bicep' = {
  name: 'secondary-acr-pe'
  params: {
    name: 'pe-secondary-acr'
    location: secondaryLocation
    subnetId: secondaryStorageSubnet.id
    storageAccountId: registry.id
    groupId: 'registry'
    privateDnsZoneId: secondaryDns.outputs.acrZoneId
    tags: tags
  }
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

resource primaryIdentityPrimaryFileRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(primaryFileStorage.id, primaryIdentity.id, fileDataRoleDefinitionId)
  scope: primaryFileStorage
  properties: {
    principalId: primaryIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: fileDataRoleDefinitionId
  }
}

resource primaryIdentitySecondaryFileRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(secondaryFileStorage.id, primaryIdentity.id, fileDataRoleDefinitionId)
  scope: secondaryFileStorage
  properties: {
    principalId: primaryIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: fileDataRoleDefinitionId
  }
}

resource secondaryIdentityPrimaryFileRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(primaryFileStorage.id, secondaryIdentity.id, fileDataRoleDefinitionId)
  scope: primaryFileStorage
  properties: {
    principalId: secondaryIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: fileDataRoleDefinitionId
  }
}

resource secondaryIdentitySecondaryFileRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(secondaryFileStorage.id, secondaryIdentity.id, fileDataRoleDefinitionId)
  scope: secondaryFileStorage
  properties: {
    principalId: secondaryIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: fileDataRoleDefinitionId
  }
}

resource primaryAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, primaryIdentity.id, acrPullRoleDefinitionId)
  scope: registry
  properties: {
    principalId: primaryIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

resource secondaryAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(registry.id, secondaryIdentity.id, acrPullRoleDefinitionId)
  scope: registry
  properties: {
    principalId: secondaryIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleDefinitionId
  }
}

resource primaryLog 'Microsoft.OperationalInsights/workspaces@2025-04-01' = {
  name: 'log-replication-primary-${primaryToken}'
  location: primaryLocation
  tags: tags
  properties: {
    retentionInDays: 30
    sku: { name: 'PerGB2018' }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}
resource secondaryLog 'Microsoft.OperationalInsights/workspaces@2025-04-01' = {
  name: 'log-replication-secondary-${secondaryToken}'
  location: secondaryLocation
  tags: tags
  properties: {
    retentionInDays: 30
    sku: { name: 'PerGB2018' }
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource primaryEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: 'cae-replication-primary-${primaryToken}'
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
      infrastructureSubnetId: primaryDefaultSubnet.id
      internal: true
    }
    zoneRedundant: false
  }
}
resource secondaryEnvironment 'Microsoft.App/managedEnvironments@2025-01-01' = {
  name: 'cae-replication-secondary-${secondaryToken}'
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
      infrastructureSubnetId: secondaryDefaultSubnet.id
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
  name: 'job-sync-primary-${primaryToken}'
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
        resources: {
          cpu: json('1.0')
          memory: '2Gi'
        }
      }]
    }
  }
  dependsOn: [
    primaryAcrPe
    primaryPrimaryFilePe
    primarySecondaryFilePe
    primaryIdentityPrimaryFileRole
    primaryIdentitySecondaryFileRole
    primaryAcrPull
  ]
}

resource secondaryJob 'Microsoft.App/jobs@2025-01-01' = {
  name: 'job-sync-secondary-${secondaryToken}'
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
        resources: {
          cpu: json('1.0')
          memory: '2Gi'
        }
      }]
    }
  }
  dependsOn: [
    secondaryAcrPe
    secondaryPrimaryFilePe
    secondarySecondaryFilePe
    secondaryIdentityPrimaryFileRole
    secondaryIdentitySecondaryFileRole
    secondaryAcrPull
  ]
}

output primaryJobName string = primaryJob.name
output secondaryJobName string = secondaryJob.name
output primaryJobId string = primaryJob.id
output secondaryJobId string = secondaryJob.id
output primaryLogWorkspaceId string = primaryLog.id
output primaryLogWorkspaceName string = primaryLog.name
output secondaryLogWorkspaceId string = secondaryLog.id
output secondaryLogWorkspaceName string = secondaryLog.name
output registryName string = registry.name
output primaryFileStorageAccountName string = primaryFileStorage.name
output secondaryFileStorageAccountName string = secondaryFileStorage.name
output primaryFileShareName string = primaryShare.name
output secondaryFileShareName string = secondaryShare.name
