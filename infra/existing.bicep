targetScope = 'subscription'

@description('Resource group for the replication compute resources and for any service this deployment creates.')
param resourceGroupName string

@description('Azure region used for resource group metadata.')
param resourceGroupLocation string

param primaryLocation string
param secondaryLocation string

@minLength(2)
@maxLength(8)
@description('Short code used in primary-region resource names, for example eus2.')
param primaryRegionCode string

@minLength(2)
@maxLength(8)
@description('Short code used in secondary-region resource names, for example wus2.')
param secondaryRegionCode string

param environmentName string = 'prod'

// Each service is either reused (existing) or created by this deployment (new). The defaults reuse every service.

@allowed([
  'existing'
  'new'
])
@description('existing reuses primaryStorageAccountName and primaryFileShareName. new creates a private storage account and SMB share in resourceGroupName.')
param primaryStorageMode string = 'existing'

@description('Existing account to reuse, or an optional name for a new account. A new account gets a generated name when this is empty.')
param primaryStorageAccountName string = ''

@description('Resource group of an existing primary storage account. Not used for a new account.')
param primaryStorageResourceGroupName string = ''

@description('Existing SMB share to replicate from, or the name of a new share. A new share is named replication when this is empty.')
param primaryFileShareName string = ''

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_GZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
@description('SKU of a new primary storage account. Premium SKUs create a FileStorage account.')
param primaryStorageSkuName string = 'Standard_LRS'

@allowed([
  'existing'
  'new'
])
@description('existing reuses secondaryStorageAccountName and secondaryFileShareName. new creates a private storage account and SMB share in resourceGroupName.')
param secondaryStorageMode string = 'existing'

@description('Existing account to reuse, or an optional name for a new account. A new account gets a generated name when this is empty.')
param secondaryStorageAccountName string = ''

@description('Resource group of an existing secondary storage account. Not used for a new account.')
param secondaryStorageResourceGroupName string = ''

@description('Existing SMB share to replicate to, or the name of a new share. A new share is named replication when this is empty.')
param secondaryFileShareName string = ''

@allowed([
  'Standard_LRS'
  'Standard_ZRS'
  'Standard_GRS'
  'Standard_GZRS'
  'Premium_LRS'
  'Premium_ZRS'
])
@description('SKU of a new secondary storage account. Premium SKUs create a FileStorage account.')
param secondaryStorageSkuName string = 'Standard_LRS'

@minValue(100)
@maxValue(102400)
@description('Quota in GiB of each file share this deployment creates.')
param newFileShareQuotaGiB int = 1024

@allowed([
  'existing'
  'newSubnet'
  'new'
])
@description('existing reuses primaryVnetName and its delegated primaryInfrastructureSubnetName. newSubnet adds a delegated subnet to that VNet. new creates a dedicated VNet with its own private DNS zones.')
param primaryNetworkMode string = 'existing'

@description('Existing VNet to reuse or extend, or an optional name for a new VNet.')
param primaryVnetName string = ''

@description('Resource group of an existing primary VNet. Not used for a new VNet.')
param primaryVnetResourceGroupName string = ''

@description('Existing empty subnet delegated to Microsoft.App/environments, or the name of the subnet to create.')
param primaryInfrastructureSubnetName string = ''

@description('Address prefix of the subnet created in newSubnet mode: /27 or larger, inside the VNet, and not used by another subnet.')
param primaryInfrastructureSubnetPrefix string = ''

@description('Address space of a new primary VNet, /22 or larger. Its first /23 hosts the job and its third /24 hosts the private endpoints.')
param primaryVnetAddressPrefix string = '10.10.0.0/16'

@description('Resource group for the private DNS zones of a new primary VNet.')
param primaryDnsResourceGroupName string = '${resourceGroupName}-${primaryRegionCode}-dns'

@allowed([
  'primaryStorage'
  'secondaryStorage'
  'registry'
])
@description('Existing services that need a new private endpoint in the existing primary VNet. New services and new VNets get their endpoints automatically.')
param primaryEndpointsToCreate array = []

@description('Existing subnet of the primary VNet for the private endpoints this deployment creates there. Not used for a new VNet.')
param primaryPrivateEndpointSubnetName string = ''

@description('privatelink.file zone that holds records for file endpoints created in the existing primary VNet. Leave empty when policy or another process creates the records.')
param primaryFileDnsZoneId string = ''

@description('privatelink.azurecr.io zone that holds records for a registry endpoint created in the existing primary VNet. Leave empty when policy or another process creates the records.')
param primaryRegistryDnsZoneId string = ''

@allowed([
  'existing'
  'newSubnet'
  'new'
])
@description('existing reuses secondaryVnetName and its delegated secondaryInfrastructureSubnetName. newSubnet adds a delegated subnet to that VNet. new creates a dedicated VNet with its own private DNS zones.')
param secondaryNetworkMode string = 'existing'

@description('Existing VNet to reuse or extend, or an optional name for a new VNet.')
param secondaryVnetName string = ''

@description('Resource group of an existing secondary VNet. Not used for a new VNet.')
param secondaryVnetResourceGroupName string = ''

@description('Existing empty subnet delegated to Microsoft.App/environments, or the name of the subnet to create.')
param secondaryInfrastructureSubnetName string = ''

@description('Address prefix of the subnet created in newSubnet mode: /27 or larger, inside the VNet, and not used by another subnet.')
param secondaryInfrastructureSubnetPrefix string = ''

@description('Address space of a new secondary VNet, /22 or larger. Its first /23 hosts the job and its third /24 hosts the private endpoints.')
param secondaryVnetAddressPrefix string = '10.20.0.0/16'

@description('Resource group for the private DNS zones of a new secondary VNet.')
param secondaryDnsResourceGroupName string = '${resourceGroupName}-${secondaryRegionCode}-dns'

@allowed([
  'primaryStorage'
  'secondaryStorage'
  'registry'
])
@description('Existing services that need a new private endpoint in the existing secondary VNet. New services and new VNets get their endpoints automatically.')
param secondaryEndpointsToCreate array = []

@description('Existing subnet of the secondary VNet for the private endpoints this deployment creates there. Not used for a new VNet.')
param secondaryPrivateEndpointSubnetName string = ''

@description('privatelink.file zone that holds records for file endpoints created in the existing secondary VNet. Leave empty when policy or another process creates the records.')
param secondaryFileDnsZoneId string = ''

@description('privatelink.azurecr.io zone that holds records for a registry endpoint created in the existing secondary VNet. Leave empty when policy or another process creates the records.')
param secondaryRegistryDnsZoneId string = ''

@allowed([
  'existing'
  'new'
])
@description('existing reuses registryName. new creates a Premium registry in primaryLocation with a replica in secondaryLocation.')
param registryMode string = 'existing'

@description('Existing registry to reuse, or an optional name for a new registry.')
param registryName string = ''

@description('Resource group of an existing registry. Not used for a new registry.')
param registryResourceGroupName string = ''

@description('Creates registry private endpoints where the job VNets need them. Set to false for a Basic or Standard registry that the jobs reach through its public endpoint.')
param registryPrivateEndpointsEnabled bool = true

@allowed([
  'Enabled'
  'Disabled'
])
@description('Public network access of a new registry. scripts/deploy.ps1 enables it only while it builds the image.')
param acrPublicNetworkAccess string = 'Disabled'

@description('Resource IDs of existing private endpoints used for replication. They are recorded in deployment outputs for reference; the template does not validate or modify them.')
param existingPrivateEndpointIds array = []

@allowed(['none', 'primary', 'secondary'])
param activeRegion string = 'none'

param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
param scheduleCronExpression string = '*/10 * * * *'

@minLength(1)
@description('Email addresses that receive Azure Monitor replication alerts.')
param alertEmailAddresses array

@allowed([
  20
  30
  60
])
@description('Minutes without a successful active-direction replication before an alert is raised.')
param replicationLagThresholdMinutes int = 30

@description('Creates and enables Azure Monitor alerting resources when true.')
param monitoringEnabled bool = true

param tags object = {
  Environment: environmentName
  Workload: 'azure-files-dr-replication'
  ManagedBy: 'Bicep'
}

var primaryNetworkIsNew = primaryNetworkMode == 'new'
var secondaryNetworkIsNew = secondaryNetworkMode == 'new'

// Endpoints are created for every new service and in every new VNet; endpoints between existing resources must exist or be listed.
var primaryEndpoints = {
  primaryStorage: primaryNetworkIsNew || primaryStorageMode == 'new' || contains(primaryEndpointsToCreate, 'primaryStorage')
  secondaryStorage: primaryNetworkIsNew || secondaryStorageMode == 'new' || contains(primaryEndpointsToCreate, 'secondaryStorage')
  registry: registryPrivateEndpointsEnabled && (primaryNetworkIsNew || registryMode == 'new' || contains(primaryEndpointsToCreate, 'registry'))
}
var secondaryEndpoints = {
  primaryStorage: secondaryNetworkIsNew || primaryStorageMode == 'new' || contains(secondaryEndpointsToCreate, 'primaryStorage')
  secondaryStorage: secondaryNetworkIsNew || secondaryStorageMode == 'new' || contains(secondaryEndpointsToCreate, 'secondaryStorage')
  registry: registryPrivateEndpointsEnabled && (secondaryNetworkIsNew || registryMode == 'new' || contains(secondaryEndpointsToCreate, 'registry'))
}
var primaryCreatesEndpointsInExistingVnet = !primaryNetworkIsNew && (primaryEndpoints.primaryStorage || primaryEndpoints.secondaryStorage || primaryEndpoints.registry)
var secondaryCreatesEndpointsInExistingVnet = !secondaryNetworkIsNew && (secondaryEndpoints.primaryStorage || secondaryEndpoints.secondaryStorage || secondaryEndpoints.registry)

// Missing inputs stop the deployment during validation, before any resource changes.
var inputErrors = filter([
  primaryStorageMode == 'existing' && (empty(primaryStorageAccountName) || empty(primaryStorageResourceGroupName) || empty(primaryFileShareName)) ? 'primaryStorageMode is existing, so set primaryStorageAccountName, primaryStorageResourceGroupName, and primaryFileShareName.' : ''
  secondaryStorageMode == 'existing' && (empty(secondaryStorageAccountName) || empty(secondaryStorageResourceGroupName) || empty(secondaryFileShareName)) ? 'secondaryStorageMode is existing, so set secondaryStorageAccountName, secondaryStorageResourceGroupName, and secondaryFileShareName.' : ''
  !primaryNetworkIsNew && (empty(primaryVnetName) || empty(primaryVnetResourceGroupName)) ? 'primaryNetworkMode is ${primaryNetworkMode}, so set primaryVnetName and primaryVnetResourceGroupName.' : ''
  !secondaryNetworkIsNew && (empty(secondaryVnetName) || empty(secondaryVnetResourceGroupName)) ? 'secondaryNetworkMode is ${secondaryNetworkMode}, so set secondaryVnetName and secondaryVnetResourceGroupName.' : ''
  primaryNetworkMode == 'existing' && empty(primaryInfrastructureSubnetName) ? 'primaryNetworkMode is existing, so set primaryInfrastructureSubnetName.' : ''
  secondaryNetworkMode == 'existing' && empty(secondaryInfrastructureSubnetName) ? 'secondaryNetworkMode is existing, so set secondaryInfrastructureSubnetName.' : ''
  primaryNetworkMode == 'newSubnet' && empty(primaryInfrastructureSubnetPrefix) ? 'primaryNetworkMode is newSubnet, so set primaryInfrastructureSubnetPrefix.' : ''
  secondaryNetworkMode == 'newSubnet' && empty(secondaryInfrastructureSubnetPrefix) ? 'secondaryNetworkMode is newSubnet, so set secondaryInfrastructureSubnetPrefix.' : ''
  primaryCreatesEndpointsInExistingVnet && empty(primaryPrivateEndpointSubnetName) ? 'This deployment creates private endpoints in the existing primary VNet, so set primaryPrivateEndpointSubnetName.' : ''
  secondaryCreatesEndpointsInExistingVnet && empty(secondaryPrivateEndpointSubnetName) ? 'This deployment creates private endpoints in the existing secondary VNet, so set secondaryPrivateEndpointSubnetName.' : ''
  registryMode == 'existing' && (empty(registryName) || empty(registryResourceGroupName)) ? 'registryMode is existing, so set registryName and registryResourceGroupName.' : ''
  registryMode == 'new' && !registryPrivateEndpointsEnabled ? 'A new registry denies public network access, so registryPrivateEndpointsEnabled must be true.' : ''
], inputError => !empty(inputError))
var validatedTags = empty(inputErrors) ? tags : fail(join(inputErrors, ' '))

var newPrimaryToken = uniqueString(subscription().id, resourceGroupName, environmentName, primaryLocation)
var newSecondaryToken = uniqueString(subscription().id, resourceGroupName, environmentName, secondaryLocation)
var newRegistryToken = uniqueString(subscription().id, resourceGroupName, environmentName)

var primaryStorageName = primaryStorageMode == 'new' && empty(primaryStorageAccountName) ? 'stfile${newPrimaryToken}' : primaryStorageAccountName
var primaryStorageGroup = primaryStorageMode == 'new' ? resourceGroupName : primaryStorageResourceGroupName
var primaryShareName = empty(primaryFileShareName) ? 'replication' : primaryFileShareName
var secondaryStorageName = secondaryStorageMode == 'new' && empty(secondaryStorageAccountName) ? 'stfile${newSecondaryToken}' : secondaryStorageAccountName
var secondaryStorageGroup = secondaryStorageMode == 'new' ? resourceGroupName : secondaryStorageResourceGroupName
var secondaryShareName = empty(secondaryFileShareName) ? 'replication' : secondaryFileShareName

var registryResolvedName = registryMode == 'new' && empty(registryName) ? 'acr${newRegistryToken}' : registryName
var registryGroup = registryMode == 'new' ? resourceGroupName : registryResourceGroupName

// Empty values only occur when validation fails; the fallbacks keep resource IDs well formed until it does.
var primaryVnetResolvedName = primaryNetworkIsNew && empty(primaryVnetName) ? 'vnet-replication-${primaryRegionCode}' : primaryVnetName
var primaryVnetGroup = primaryNetworkIsNew ? resourceGroupName : primaryVnetResourceGroupName
var primaryJobSubnetName = !empty(primaryInfrastructureSubnetName) ? primaryInfrastructureSubnetName : (primaryNetworkIsNew ? 'jobs' : 'snet-replication-jobs')
var primaryVnetId = resourceId(subscription().subscriptionId, empty(primaryVnetGroup) ? resourceGroupName : primaryVnetGroup, 'Microsoft.Network/virtualNetworks', empty(primaryVnetResolvedName) ? 'unset' : primaryVnetResolvedName)
var secondaryVnetResolvedName = secondaryNetworkIsNew && empty(secondaryVnetName) ? 'vnet-replication-${secondaryRegionCode}' : secondaryVnetName
var secondaryVnetGroup = secondaryNetworkIsNew ? resourceGroupName : secondaryVnetResourceGroupName
var secondaryJobSubnetName = !empty(secondaryInfrastructureSubnetName) ? secondaryInfrastructureSubnetName : (secondaryNetworkIsNew ? 'jobs' : 'snet-replication-jobs')
var secondaryVnetId = resourceId(subscription().subscriptionId, empty(secondaryVnetGroup) ? resourceGroupName : secondaryVnetGroup, 'Microsoft.Network/virtualNetworks', empty(secondaryVnetResolvedName) ? 'unset' : secondaryVnetResolvedName)

resource workloadResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: resourceGroupLocation
  tags: validatedTags
}

resource primaryDnsResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = if (primaryNetworkIsNew) {
  name: primaryDnsResourceGroupName
  location: primaryLocation
  tags: union(tags, { RegionRole: 'primary-dns' })
}

resource secondaryDnsResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = if (secondaryNetworkIsNew) {
  name: secondaryDnsResourceGroupName
  location: secondaryLocation
  tags: union(tags, { RegionRole: 'secondary-dns' })
}

module newPrimaryStorage 'modules/new-file-storage.bicep' = if (primaryStorageMode == 'new') {
  name: 'replication-new-primary-storage'
  scope: workloadResourceGroup
  params: {
    name: primaryStorageName
    location: primaryLocation
    skuName: primaryStorageSkuName
    shareName: primaryShareName
    shareQuotaGiB: newFileShareQuotaGiB
    tags: union(tags, { RegionRole: 'primary', DataRole: 'files' })
  }
}

module newSecondaryStorage 'modules/new-file-storage.bicep' = if (secondaryStorageMode == 'new') {
  name: 'replication-new-secondary-storage'
  scope: workloadResourceGroup
  params: {
    name: secondaryStorageName
    location: secondaryLocation
    skuName: secondaryStorageSkuName
    shareName: secondaryShareName
    shareQuotaGiB: newFileShareQuotaGiB
    tags: union(tags, { RegionRole: 'secondary', DataRole: 'files' })
  }
}

module newRegistry 'modules/new-registry.bicep' = if (registryMode == 'new') {
  name: 'replication-new-registry'
  scope: workloadResourceGroup
  params: {
    name: registryResolvedName
    location: primaryLocation
    replicaLocation: secondaryLocation
    publicNetworkAccess: acrPublicNetworkAccess
    tags: tags
  }
}

module newPrimaryNetwork 'modules/new-network.bicep' = if (primaryNetworkIsNew) {
  name: 'replication-new-primary-network'
  scope: workloadResourceGroup
  params: {
    name: primaryVnetResolvedName
    location: primaryLocation
    addressPrefix: primaryVnetAddressPrefix
    jobSubnetName: primaryJobSubnetName
    tags: union(tags, { RegionRole: 'primary' })
  }
}

module newSecondaryNetwork 'modules/new-network.bicep' = if (secondaryNetworkIsNew) {
  name: 'replication-new-secondary-network'
  scope: workloadResourceGroup
  params: {
    name: secondaryVnetResolvedName
    location: secondaryLocation
    addressPrefix: secondaryVnetAddressPrefix
    jobSubnetName: secondaryJobSubnetName
    tags: union(tags, { RegionRole: 'secondary' })
  }
}

module newPrimarySubnet 'modules/new-subnet.bicep' = if (primaryNetworkMode == 'newSubnet') {
  name: 'replication-new-primary-subnet'
  scope: resourceGroup(empty(primaryVnetResourceGroupName) ? resourceGroupName : primaryVnetResourceGroupName)
  params: {
    vnetName: primaryVnetName
    subnetName: primaryJobSubnetName
    addressPrefix: primaryInfrastructureSubnetPrefix
  }
}

module newSecondarySubnet 'modules/new-subnet.bicep' = if (secondaryNetworkMode == 'newSubnet') {
  name: 'replication-new-secondary-subnet'
  scope: resourceGroup(empty(secondaryVnetResourceGroupName) ? resourceGroupName : secondaryVnetResourceGroupName)
  params: {
    vnetName: secondaryVnetName
    subnetName: secondaryJobSubnetName
    addressPrefix: secondaryInfrastructureSubnetPrefix
  }
}

// A new VNet gets its own split-horizon zones, so its records can't redirect other workloads.
module primaryDns 'modules/regional-dns.bicep' = if (primaryNetworkIsNew) {
  name: 'replication-primary-private-dns'
  scope: primaryDnsResourceGroup
  params: {
    virtualNetworkId: newPrimaryNetwork!.outputs.id
    linkToken: newPrimaryToken
    tags: union(tags, { RegionRole: 'primary' })
  }
}

module secondaryDns 'modules/regional-dns.bicep' = if (secondaryNetworkIsNew) {
  name: 'replication-secondary-private-dns'
  scope: secondaryDnsResourceGroup
  params: {
    virtualNetworkId: newSecondaryNetwork!.outputs.id
    linkToken: newSecondaryToken
    tags: union(tags, { RegionRole: 'secondary' })
  }
}

var primaryStorageId = primaryStorageMode == 'new' ? newPrimaryStorage!.outputs.id : resourceId(subscription().subscriptionId, empty(primaryStorageGroup) ? resourceGroupName : primaryStorageGroup, 'Microsoft.Storage/storageAccounts', empty(primaryStorageName) ? 'unset' : primaryStorageName)
var secondaryStorageId = secondaryStorageMode == 'new' ? newSecondaryStorage!.outputs.id : resourceId(subscription().subscriptionId, empty(secondaryStorageGroup) ? resourceGroupName : secondaryStorageGroup, 'Microsoft.Storage/storageAccounts', empty(secondaryStorageName) ? 'unset' : secondaryStorageName)
var registryId = registryMode == 'new' ? newRegistry!.outputs.id : resourceId(subscription().subscriptionId, empty(registryGroup) ? resourceGroupName : registryGroup, 'Microsoft.ContainerRegistry/registries', empty(registryResolvedName) ? 'unset' : registryResolvedName)

var primaryInfrastructureSubnetId = primaryNetworkIsNew ? newPrimaryNetwork!.outputs.jobSubnetId : (primaryNetworkMode == 'newSubnet' ? newPrimarySubnet!.outputs.id : '${primaryVnetId}/subnets/${primaryJobSubnetName}')
var secondaryInfrastructureSubnetId = secondaryNetworkIsNew ? newSecondaryNetwork!.outputs.jobSubnetId : (secondaryNetworkMode == 'newSubnet' ? newSecondarySubnet!.outputs.id : '${secondaryVnetId}/subnets/${secondaryJobSubnetName}')
var primaryEndpointSubnetId = primaryNetworkIsNew ? newPrimaryNetwork!.outputs.endpointSubnetId : '${primaryVnetId}/subnets/${primaryPrivateEndpointSubnetName}'
var secondaryEndpointSubnetId = secondaryNetworkIsNew ? newSecondaryNetwork!.outputs.endpointSubnetId : '${secondaryVnetId}/subnets/${secondaryPrivateEndpointSubnetName}'
var primaryFileZoneId = primaryNetworkIsNew ? primaryDns!.outputs.fileZoneId : primaryFileDnsZoneId
var primaryRegistryZoneId = primaryNetworkIsNew ? primaryDns!.outputs.acrZoneId : primaryRegistryDnsZoneId
var secondaryFileZoneId = secondaryNetworkIsNew ? secondaryDns!.outputs.fileZoneId : secondaryFileDnsZoneId
var secondaryRegistryZoneId = secondaryNetworkIsNew ? secondaryDns!.outputs.acrZoneId : secondaryRegistryDnsZoneId

module primaryVnetPrimaryFileEndpoint 'modules/storage-private-endpoint.bicep' = if (primaryEndpoints.primaryStorage) {
  name: 'replication-${primaryRegionCode}-primary-file-pe'
  scope: workloadResourceGroup
  params: {
    name: 'pe-${primaryRegionCode}-primary-file'
    location: primaryLocation
    subnetId: primaryEndpointSubnetId
    storageAccountId: primaryStorageId
    groupId: 'file'
    privateDnsZoneId: primaryFileZoneId
    tags: tags
  }
}

module primaryVnetSecondaryFileEndpoint 'modules/storage-private-endpoint.bicep' = if (primaryEndpoints.secondaryStorage) {
  name: 'replication-${primaryRegionCode}-secondary-file-pe'
  scope: workloadResourceGroup
  params: {
    name: 'pe-${primaryRegionCode}-secondary-file'
    location: primaryLocation
    subnetId: primaryEndpointSubnetId
    storageAccountId: secondaryStorageId
    groupId: 'file'
    privateDnsZoneId: primaryFileZoneId
    tags: tags
  }
}

module primaryVnetRegistryEndpoint 'modules/storage-private-endpoint.bicep' = if (primaryEndpoints.registry) {
  name: 'replication-${primaryRegionCode}-registry-pe'
  scope: workloadResourceGroup
  params: {
    name: 'pe-${primaryRegionCode}-registry'
    location: primaryLocation
    subnetId: primaryEndpointSubnetId
    storageAccountId: registryId
    groupId: 'registry'
    privateDnsZoneId: primaryRegistryZoneId
    tags: tags
  }
}

module secondaryVnetPrimaryFileEndpoint 'modules/storage-private-endpoint.bicep' = if (secondaryEndpoints.primaryStorage) {
  name: 'replication-${secondaryRegionCode}-primary-file-pe'
  scope: workloadResourceGroup
  params: {
    name: 'pe-${secondaryRegionCode}-primary-file'
    location: secondaryLocation
    subnetId: secondaryEndpointSubnetId
    storageAccountId: primaryStorageId
    groupId: 'file'
    privateDnsZoneId: secondaryFileZoneId
    tags: tags
  }
}

module secondaryVnetSecondaryFileEndpoint 'modules/storage-private-endpoint.bicep' = if (secondaryEndpoints.secondaryStorage) {
  name: 'replication-${secondaryRegionCode}-secondary-file-pe'
  scope: workloadResourceGroup
  params: {
    name: 'pe-${secondaryRegionCode}-secondary-file'
    location: secondaryLocation
    subnetId: secondaryEndpointSubnetId
    storageAccountId: secondaryStorageId
    groupId: 'file'
    privateDnsZoneId: secondaryFileZoneId
    tags: tags
  }
}

module secondaryVnetRegistryEndpoint 'modules/storage-private-endpoint.bicep' = if (secondaryEndpoints.registry) {
  name: 'replication-${secondaryRegionCode}-registry-pe'
  scope: workloadResourceGroup
  params: {
    name: 'pe-${secondaryRegionCode}-registry'
    location: secondaryLocation
    subnetId: secondaryEndpointSubnetId
    storageAccountId: registryId
    groupId: 'registry'
    privateDnsZoneId: secondaryRegistryZoneId
    tags: tags
  }
}

module foundation 'modules/existing-foundation.bicep' = {
  name: 'existing-storage-replication-foundation'
  scope: workloadResourceGroup
  params: {
    environmentName: environmentName
    primaryLocation: primaryLocation
    secondaryLocation: secondaryLocation
    primaryRegionCode: primaryRegionCode
    secondaryRegionCode: secondaryRegionCode
    primaryStorageAccountName: primaryStorageMode == 'new' ? newPrimaryStorage!.outputs.name : primaryStorageName
    primaryStorageResourceGroupName: primaryStorageGroup
    primaryFileShareName: primaryShareName
    secondaryStorageAccountName: secondaryStorageMode == 'new' ? newSecondaryStorage!.outputs.name : secondaryStorageName
    secondaryStorageResourceGroupName: secondaryStorageGroup
    secondaryFileShareName: secondaryShareName
    primaryInfrastructureSubnetId: primaryInfrastructureSubnetId
    secondaryInfrastructureSubnetId: secondaryInfrastructureSubnetId
    registryName: registryMode == 'new' ? newRegistry!.outputs.name : registryResolvedName
    registryResourceGroupName: registryGroup
    existingPrivateEndpointIds: existingPrivateEndpointIds
    activeRegion: activeRegion
    containerImage: containerImage
    scheduleCronExpression: scheduleCronExpression
    tags: tags
  }
  // The jobs must not run before the endpoints they copy through exist.
  dependsOn: [
    primaryVnetPrimaryFileEndpoint
    primaryVnetSecondaryFileEndpoint
    primaryVnetRegistryEndpoint
    secondaryVnetPrimaryFileEndpoint
    secondaryVnetSecondaryFileEndpoint
    secondaryVnetRegistryEndpoint
  ]
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'existing-storage-replication-monitoring'
  scope: workloadResourceGroup
  params: {
    environmentName: environmentName
    primaryLocation: primaryLocation
    secondaryLocation: secondaryLocation
    activeRegion: activeRegion
    primaryJobId: foundation.outputs.primaryJobId
    primaryJobName: foundation.outputs.primaryJobName
    secondaryJobId: foundation.outputs.secondaryJobId
    secondaryJobName: foundation.outputs.secondaryJobName
    primaryLogWorkspaceId: foundation.outputs.primaryLogWorkspaceId
    secondaryLogWorkspaceId: foundation.outputs.secondaryLogWorkspaceId
    alertEmailAddresses: alertEmailAddresses
    replicationLagThresholdMinutes: replicationLagThresholdMinutes
    monitoringEnabled: monitoringEnabled
    tags: tags
  }
}

output resourceGroupName string = workloadResourceGroup.name
output primaryJobName string = foundation.outputs.primaryJobName
output secondaryJobName string = foundation.outputs.secondaryJobName
output registryName string = foundation.outputs.registryName
output primaryFileStorageAccountName string = foundation.outputs.primaryFileStorageAccountName
output secondaryFileStorageAccountName string = foundation.outputs.secondaryFileStorageAccountName
output primaryFileShareName string = foundation.outputs.primaryFileShareName
output secondaryFileShareName string = foundation.outputs.secondaryFileShareName
output primaryLogWorkspaceName string = foundation.outputs.primaryLogWorkspaceName
output secondaryLogWorkspaceName string = foundation.outputs.secondaryLogWorkspaceName
output monitoringActionGroupId string = monitoring.outputs.actionGroupId
output primaryFailureAlertId string = monitoring.outputs.primaryFailureAlertId
output secondaryFailureAlertId string = monitoring.outputs.secondaryFailureAlertId
output primaryFreshnessAlertId string = monitoring.outputs.primaryFreshnessAlertId
output secondaryFreshnessAlertId string = monitoring.outputs.secondaryFreshnessAlertId
