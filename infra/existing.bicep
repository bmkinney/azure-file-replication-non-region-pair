targetScope = 'subscription'

@description('Resource group for primary-region replication compute and monitoring, and the default for any service this deployment creates.')
param resourceGroupName string

@description('Metadata region of resourceGroupName when the deployment creates it.')
param resourceGroupLocation string

param primaryLocation string
param secondaryLocation string

@description('Resource group for secondary-region replication compute, and the default for secondary-region services this deployment creates.')
param secondaryResourceGroupName string = resourceGroupName

@description('Metadata region of secondaryResourceGroupName when the deployment creates it.')
param secondaryResourceGroupLocation string = secondaryLocation

@description('Resource groups that already exist. The deployment creates every other resource group it places resources in, and never modifies the groups listed here.')
param existingResourceGroups array = []

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
// For a new service, the name and resource group parameters are optional and name and place the new resource.

@allowed([
  'existing'
  'new'
])
@description('existing reuses primaryStorageAccountName and primaryFileShareName. new creates a private storage account and SMB share.')
param primaryStorageMode string = 'existing'

@description('Existing account to reuse, or an optional name for a new account. A new account gets a generated name when this is empty.')
param primaryStorageAccountName string = ''

@description('Resource group of an existing account, or of a new one. A new account goes in resourceGroupName when this is empty.')
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
@description('existing reuses secondaryStorageAccountName and secondaryFileShareName. new creates a private storage account and SMB share.')
param secondaryStorageMode string = 'existing'

@description('Existing account to reuse, or an optional name for a new account. A new account gets a generated name when this is empty.')
param secondaryStorageAccountName string = ''

@description('Resource group of an existing account, or of a new one. A new account goes in secondaryResourceGroupName when this is empty.')
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

@description('Resource group of an existing VNet, or of a new one. A new VNet goes in resourceGroupName when this is empty.')
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

@description('Existing subnet of the primary VNet for the private endpoints this deployment creates there, or the name of the endpoint subnet in a new VNet (default endpoints).')
param primaryPrivateEndpointSubnetName string = ''

@description('Resource group for the private endpoints this deployment creates in the primary VNet. Defaults to the VNet resource group for a new VNet, and to resourceGroupName otherwise.')
param primaryEndpointResourceGroupName string = ''

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

@description('Resource group of an existing VNet, or of a new one. A new VNet goes in secondaryResourceGroupName when this is empty.')
param secondaryVnetResourceGroupName string = ''

@description('Existing empty subnet delegated to Microsoft.App/environments, or the name of the subnet to create.')
param secondaryInfrastructureSubnetName string = ''

@description('Address prefix of the subnet created in newSubnet mode: /27 or larger, inside the VNet, and not used by another subnet.')
param secondaryInfrastructureSubnetPrefix string = ''

@description('Address space of a new secondary VNet, /22 or larger. Its first /23 hosts the job and its third /24 hosts the private endpoints.')
param secondaryVnetAddressPrefix string = '10.20.0.0/16'

@description('Resource group for the private DNS zones of a new secondary VNet. It must differ from primaryDnsResourceGroupName when both VNets are new.')
param secondaryDnsResourceGroupName string = '${secondaryResourceGroupName}-${secondaryRegionCode}-dns'

@allowed([
  'primaryStorage'
  'secondaryStorage'
  'registry'
])
@description('Existing services that need a new private endpoint in the existing secondary VNet. New services and new VNets get their endpoints automatically.')
param secondaryEndpointsToCreate array = []

@description('Existing subnet of the secondary VNet for the private endpoints this deployment creates there, or the name of the endpoint subnet in a new VNet (default endpoints).')
param secondaryPrivateEndpointSubnetName string = ''

@description('Resource group for the private endpoints this deployment creates in the secondary VNet. Defaults to the VNet resource group for a new VNet, and to secondaryResourceGroupName otherwise.')
param secondaryEndpointResourceGroupName string = ''

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

@description('Resource group of an existing registry, or of a new one. A new registry goes in resourceGroupName when this is empty.')
param registryResourceGroupName string = ''

@description('Creates registry private endpoints where the job VNets need them. Set to false for a Basic or Standard registry that the jobs reach through its public endpoint.')
param registryPrivateEndpointsEnabled bool = true

@allowed([
  'Enabled'
  'Disabled'
])
@description('Public network access of a new registry. scripts/deploy.ps1 enables it only while it builds the image.')
param acrPublicNetworkAccess string = 'Disabled'

@sealed()
type resourceNamesType = {
  primaryIdentity: string?
  secondaryIdentity: string?
  primaryLogWorkspace: string?
  secondaryLogWorkspace: string?
  primaryEnvironment: string?
  secondaryEnvironment: string?
  primaryJob: string?
  secondaryJob: string?
  primaryVnetPrimaryStorageEndpoint: string?
  primaryVnetSecondaryStorageEndpoint: string?
  primaryVnetRegistryEndpoint: string?
  secondaryVnetPrimaryStorageEndpoint: string?
  secondaryVnetSecondaryStorageEndpoint: string?
  secondaryVnetRegistryEndpoint: string?
  actionGroup: string?
  primaryFailureAlert: string?
  secondaryFailureAlert: string?
  primaryFreshnessAlert: string?
  secondaryFreshnessAlert: string?
}

@description('Optional names for the other resources this deployment creates. Omitted names are generated.')
param resourceNames resourceNamesType = {}

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
var primaryCreatesEndpoints = primaryEndpoints.primaryStorage || primaryEndpoints.secondaryStorage || primaryEndpoints.registry
var secondaryCreatesEndpoints = secondaryEndpoints.primaryStorage || secondaryEndpoints.secondaryStorage || secondaryEndpoints.registry

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
  !primaryNetworkIsNew && primaryCreatesEndpoints && empty(primaryPrivateEndpointSubnetName) ? 'This deployment creates private endpoints in the existing primary VNet, so set primaryPrivateEndpointSubnetName.' : ''
  !secondaryNetworkIsNew && secondaryCreatesEndpoints && empty(secondaryPrivateEndpointSubnetName) ? 'This deployment creates private endpoints in the existing secondary VNet, so set secondaryPrivateEndpointSubnetName.' : ''
  registryMode == 'existing' && (empty(registryName) || empty(registryResourceGroupName)) ? 'registryMode is existing, so set registryName and registryResourceGroupName.' : ''
  registryMode == 'new' && !registryPrivateEndpointsEnabled ? 'A new registry denies public network access, so registryPrivateEndpointsEnabled must be true.' : ''
  primaryNetworkIsNew && secondaryNetworkIsNew && toLower(primaryDnsResourceGroupName) == toLower(secondaryDnsResourceGroupName) ? 'Both VNets are new and their private DNS zones have the same names, so primaryDnsResourceGroupName and secondaryDnsResourceGroupName must differ.' : ''
  toLower(primaryRegionCode) == toLower(secondaryRegionCode) ? 'primaryRegionCode and secondaryRegionCode must differ because they distinguish the regional resource names.' : ''
], inputError => !empty(inputError))
var validatedTags = empty(inputErrors) ? tags : fail(join(inputErrors, ' '))

var newPrimaryToken = uniqueString(subscription().id, resourceGroupName, environmentName, primaryLocation)
var newSecondaryToken = uniqueString(subscription().id, resourceGroupName, environmentName, secondaryLocation)
var newRegistryToken = uniqueString(subscription().id, resourceGroupName, environmentName)

// Empty values only occur when validation fails; the fallbacks keep resource IDs well formed until it does.
var primaryStorageName = primaryStorageMode == 'new' && empty(primaryStorageAccountName) ? 'stfile${newPrimaryToken}' : primaryStorageAccountName
var primaryStorageGroup = primaryStorageMode == 'new' && empty(primaryStorageResourceGroupName) ? resourceGroupName : primaryStorageResourceGroupName
var primaryShareName = empty(primaryFileShareName) ? 'replication' : primaryFileShareName
var secondaryStorageName = secondaryStorageMode == 'new' && empty(secondaryStorageAccountName) ? 'stfile${newSecondaryToken}' : secondaryStorageAccountName
var secondaryStorageGroup = secondaryStorageMode == 'new' && empty(secondaryStorageResourceGroupName) ? secondaryResourceGroupName : secondaryStorageResourceGroupName
var secondaryShareName = empty(secondaryFileShareName) ? 'replication' : secondaryFileShareName

var registryResolvedName = registryMode == 'new' && empty(registryName) ? 'acr${newRegistryToken}' : registryName
var registryGroup = registryMode == 'new' && empty(registryResourceGroupName) ? resourceGroupName : registryResourceGroupName

var primaryVnetResolvedName = primaryNetworkIsNew && empty(primaryVnetName) ? 'vnet-replication-${primaryRegionCode}' : primaryVnetName
var primaryVnetGroup = primaryNetworkIsNew && empty(primaryVnetResourceGroupName) ? resourceGroupName : primaryVnetResourceGroupName
var primaryJobSubnetName = !empty(primaryInfrastructureSubnetName) ? primaryInfrastructureSubnetName : (primaryNetworkIsNew ? 'jobs' : 'snet-replication-jobs')
var primaryEndpointSubnetName = empty(primaryPrivateEndpointSubnetName) ? 'endpoints' : primaryPrivateEndpointSubnetName
var primaryEndpointGroup = !empty(primaryEndpointResourceGroupName) ? primaryEndpointResourceGroupName : (primaryNetworkIsNew ? primaryVnetGroup : resourceGroupName)
var primaryVnetId = resourceId(subscription().subscriptionId, empty(primaryVnetGroup) ? resourceGroupName : primaryVnetGroup, 'Microsoft.Network/virtualNetworks', empty(primaryVnetResolvedName) ? 'unset' : primaryVnetResolvedName)
var secondaryVnetResolvedName = secondaryNetworkIsNew && empty(secondaryVnetName) ? 'vnet-replication-${secondaryRegionCode}' : secondaryVnetName
var secondaryVnetGroup = secondaryNetworkIsNew && empty(secondaryVnetResourceGroupName) ? secondaryResourceGroupName : secondaryVnetResourceGroupName
var secondaryJobSubnetName = !empty(secondaryInfrastructureSubnetName) ? secondaryInfrastructureSubnetName : (secondaryNetworkIsNew ? 'jobs' : 'snet-replication-jobs')
var secondaryEndpointSubnetName = empty(secondaryPrivateEndpointSubnetName) ? 'endpoints' : secondaryPrivateEndpointSubnetName
var secondaryEndpointGroup = !empty(secondaryEndpointResourceGroupName) ? secondaryEndpointResourceGroupName : (secondaryNetworkIsNew ? secondaryVnetGroup : secondaryResourceGroupName)
var secondaryVnetId = resourceId(subscription().subscriptionId, empty(secondaryVnetGroup) ? resourceGroupName : secondaryVnetGroup, 'Microsoft.Network/virtualNetworks', empty(secondaryVnetResolvedName) ? 'unset' : secondaryVnetResolvedName)

// Every resource group that receives resources, from lowest to highest priority for its metadata region and tags.
var groupPlan = [
  { name: primaryDnsResourceGroupName, location: primaryLocation, used: primaryNetworkIsNew, tags: { RegionRole: 'primary-dns' } }
  { name: secondaryDnsResourceGroupName, location: secondaryLocation, used: secondaryNetworkIsNew, tags: { RegionRole: 'secondary-dns' } }
  { name: primaryEndpointGroup, location: primaryLocation, used: primaryCreatesEndpoints, tags: {} }
  { name: secondaryEndpointGroup, location: secondaryLocation, used: secondaryCreatesEndpoints, tags: {} }
  { name: registryGroup, location: primaryLocation, used: registryMode == 'new', tags: {} }
  { name: primaryVnetGroup, location: primaryLocation, used: primaryNetworkIsNew, tags: {} }
  { name: secondaryVnetGroup, location: secondaryLocation, used: secondaryNetworkIsNew, tags: {} }
  { name: primaryStorageGroup, location: primaryLocation, used: primaryStorageMode == 'new', tags: {} }
  { name: secondaryStorageGroup, location: secondaryLocation, used: secondaryStorageMode == 'new', tags: {} }
  { name: secondaryResourceGroupName, location: secondaryResourceGroupLocation, used: true, tags: {} }
  { name: resourceGroupName, location: resourceGroupLocation, used: true, tags: {} }
]
var existingGroupKeys = map(existingResourceGroups, groupName => toLower(groupName))
var groupsToCreate = reduce(filter(groupPlan, group => group.used && !empty(group.name) && !contains(existingGroupKeys, toLower(group.name))), {}, (planned, group) => union(planned, { '${toLower(group.name)}': group }))

resource createdResourceGroups 'Microsoft.Resources/resourceGroups@2024-11-01' = [for group in items(groupsToCreate): {
  name: group.value.name
  location: group.value.location
  tags: union(validatedTags, group.value.tags)
}]

module newPrimaryStorage 'modules/new-file-storage.bicep' = if (primaryStorageMode == 'new') {
  name: 'replication-new-primary-storage'
  scope: resourceGroup(empty(primaryStorageGroup) ? resourceGroupName : primaryStorageGroup)
  params: {
    name: primaryStorageName
    location: primaryLocation
    skuName: primaryStorageSkuName
    shareName: primaryShareName
    shareQuotaGiB: newFileShareQuotaGiB
    tags: union(tags, { RegionRole: 'primary', DataRole: 'files' })
  }
  dependsOn: [createdResourceGroups]
}

module newSecondaryStorage 'modules/new-file-storage.bicep' = if (secondaryStorageMode == 'new') {
  name: 'replication-new-secondary-storage'
  scope: resourceGroup(empty(secondaryStorageGroup) ? resourceGroupName : secondaryStorageGroup)
  params: {
    name: secondaryStorageName
    location: secondaryLocation
    skuName: secondaryStorageSkuName
    shareName: secondaryShareName
    shareQuotaGiB: newFileShareQuotaGiB
    tags: union(tags, { RegionRole: 'secondary', DataRole: 'files' })
  }
  dependsOn: [createdResourceGroups]
}

module newRegistry 'modules/new-registry.bicep' = if (registryMode == 'new') {
  name: 'replication-new-registry'
  scope: resourceGroup(empty(registryGroup) ? resourceGroupName : registryGroup)
  params: {
    name: registryResolvedName
    location: primaryLocation
    replicaLocation: secondaryLocation
    publicNetworkAccess: acrPublicNetworkAccess
    tags: tags
  }
  dependsOn: [createdResourceGroups]
}

resource existingRegistry 'Microsoft.ContainerRegistry/registries@2025-04-01' existing = if (registryMode == 'existing') {
  name: empty(registryResolvedName) ? 'unset' : registryResolvedName
  scope: resourceGroup(empty(registryGroup) ? resourceGroupName : registryGroup)
}

module newPrimaryNetwork 'modules/new-network.bicep' = if (primaryNetworkIsNew) {
  name: 'replication-new-primary-network'
  scope: resourceGroup(empty(primaryVnetGroup) ? resourceGroupName : primaryVnetGroup)
  params: {
    name: primaryVnetResolvedName
    location: primaryLocation
    addressPrefix: primaryVnetAddressPrefix
    jobSubnetName: primaryJobSubnetName
    endpointSubnetName: primaryEndpointSubnetName
    tags: union(tags, { RegionRole: 'primary' })
  }
  dependsOn: [createdResourceGroups]
}

module newSecondaryNetwork 'modules/new-network.bicep' = if (secondaryNetworkIsNew) {
  name: 'replication-new-secondary-network'
  scope: resourceGroup(empty(secondaryVnetGroup) ? resourceGroupName : secondaryVnetGroup)
  params: {
    name: secondaryVnetResolvedName
    location: secondaryLocation
    addressPrefix: secondaryVnetAddressPrefix
    jobSubnetName: secondaryJobSubnetName
    endpointSubnetName: secondaryEndpointSubnetName
    tags: union(tags, { RegionRole: 'secondary' })
  }
  dependsOn: [createdResourceGroups]
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
  scope: resourceGroup(empty(primaryDnsResourceGroupName) ? resourceGroupName : primaryDnsResourceGroupName)
  params: {
    virtualNetworkId: newPrimaryNetwork!.outputs.id
    linkToken: newPrimaryToken
    tags: union(tags, { RegionRole: 'primary' })
  }
  dependsOn: [createdResourceGroups]
}

module secondaryDns 'modules/regional-dns.bicep' = if (secondaryNetworkIsNew) {
  name: 'replication-secondary-private-dns'
  scope: resourceGroup(empty(secondaryDnsResourceGroupName) ? resourceGroupName : secondaryDnsResourceGroupName)
  params: {
    virtualNetworkId: newSecondaryNetwork!.outputs.id
    linkToken: newSecondaryToken
    tags: union(tags, { RegionRole: 'secondary' })
  }
  dependsOn: [createdResourceGroups]
}

var primaryStorageId = primaryStorageMode == 'new' ? newPrimaryStorage!.outputs.id : resourceId(subscription().subscriptionId, empty(primaryStorageGroup) ? resourceGroupName : primaryStorageGroup, 'Microsoft.Storage/storageAccounts', empty(primaryStorageName) ? 'unset' : primaryStorageName)
var secondaryStorageId = secondaryStorageMode == 'new' ? newSecondaryStorage!.outputs.id : resourceId(subscription().subscriptionId, empty(secondaryStorageGroup) ? resourceGroupName : secondaryStorageGroup, 'Microsoft.Storage/storageAccounts', empty(secondaryStorageName) ? 'unset' : secondaryStorageName)
var registryId = registryMode == 'new' ? newRegistry!.outputs.id : existingRegistry!.id
var registryLoginServer = registryMode == 'new' ? newRegistry!.outputs.loginServer : existingRegistry!.properties.loginServer

var primaryInfrastructureSubnetId = primaryNetworkIsNew ? newPrimaryNetwork!.outputs.jobSubnetId : (primaryNetworkMode == 'newSubnet' ? newPrimarySubnet!.outputs.id : '${primaryVnetId}/subnets/${primaryJobSubnetName}')
var secondaryInfrastructureSubnetId = secondaryNetworkIsNew ? newSecondaryNetwork!.outputs.jobSubnetId : (secondaryNetworkMode == 'newSubnet' ? newSecondarySubnet!.outputs.id : '${secondaryVnetId}/subnets/${secondaryJobSubnetName}')
var primaryEndpointSubnetId = primaryNetworkIsNew ? newPrimaryNetwork!.outputs.endpointSubnetId : '${primaryVnetId}/subnets/${primaryPrivateEndpointSubnetName}'
var secondaryEndpointSubnetId = secondaryNetworkIsNew ? newSecondaryNetwork!.outputs.endpointSubnetId : '${secondaryVnetId}/subnets/${secondaryPrivateEndpointSubnetName}'
var primaryFileZoneId = primaryNetworkIsNew ? primaryDns!.outputs.fileZoneId : primaryFileDnsZoneId
var primaryRegistryZoneId = primaryNetworkIsNew ? primaryDns!.outputs.acrZoneId : primaryRegistryDnsZoneId
var secondaryFileZoneId = secondaryNetworkIsNew ? secondaryDns!.outputs.fileZoneId : secondaryFileDnsZoneId
var secondaryRegistryZoneId = secondaryNetworkIsNew ? secondaryDns!.outputs.acrZoneId : secondaryRegistryDnsZoneId
// An empty or omitted endpoint name keeps the generated name.
var endpointNames = {
  primaryVnetPrimaryStorage: resourceNames.?primaryVnetPrimaryStorageEndpoint ?? ''
  primaryVnetSecondaryStorage: resourceNames.?primaryVnetSecondaryStorageEndpoint ?? ''
  primaryVnetRegistry: resourceNames.?primaryVnetRegistryEndpoint ?? ''
  secondaryVnetPrimaryStorage: resourceNames.?secondaryVnetPrimaryStorageEndpoint ?? ''
  secondaryVnetSecondaryStorage: resourceNames.?secondaryVnetSecondaryStorageEndpoint ?? ''
  secondaryVnetRegistry: resourceNames.?secondaryVnetRegistryEndpoint ?? ''
}

module primaryVnetPrimaryFileEndpoint 'modules/storage-private-endpoint.bicep' = if (primaryEndpoints.primaryStorage) {
  name: 'replication-${primaryRegionCode}-primary-file-pe'
  scope: resourceGroup(empty(primaryEndpointGroup) ? resourceGroupName : primaryEndpointGroup)
  params: {
    name: empty(endpointNames.primaryVnetPrimaryStorage) ? 'pe-${primaryRegionCode}-primary-file' : endpointNames.primaryVnetPrimaryStorage
    location: primaryLocation
    subnetId: primaryEndpointSubnetId
    storageAccountId: primaryStorageId
    groupId: 'file'
    privateDnsZoneId: primaryFileZoneId
    tags: tags
  }
  dependsOn: [createdResourceGroups]
}

module primaryVnetSecondaryFileEndpoint 'modules/storage-private-endpoint.bicep' = if (primaryEndpoints.secondaryStorage) {
  name: 'replication-${primaryRegionCode}-secondary-file-pe'
  scope: resourceGroup(empty(primaryEndpointGroup) ? resourceGroupName : primaryEndpointGroup)
  params: {
    name: empty(endpointNames.primaryVnetSecondaryStorage) ? 'pe-${primaryRegionCode}-secondary-file' : endpointNames.primaryVnetSecondaryStorage
    location: primaryLocation
    subnetId: primaryEndpointSubnetId
    storageAccountId: secondaryStorageId
    groupId: 'file'
    privateDnsZoneId: primaryFileZoneId
    tags: tags
  }
  dependsOn: [createdResourceGroups]
}

module primaryVnetRegistryEndpoint 'modules/storage-private-endpoint.bicep' = if (primaryEndpoints.registry) {
  name: 'replication-${primaryRegionCode}-registry-pe'
  scope: resourceGroup(empty(primaryEndpointGroup) ? resourceGroupName : primaryEndpointGroup)
  params: {
    name: empty(endpointNames.primaryVnetRegistry) ? 'pe-${primaryRegionCode}-registry' : endpointNames.primaryVnetRegistry
    location: primaryLocation
    subnetId: primaryEndpointSubnetId
    storageAccountId: registryId
    groupId: 'registry'
    privateDnsZoneId: primaryRegistryZoneId
    tags: tags
  }
  dependsOn: [createdResourceGroups]
}

module secondaryVnetPrimaryFileEndpoint 'modules/storage-private-endpoint.bicep' = if (secondaryEndpoints.primaryStorage) {
  name: 'replication-${secondaryRegionCode}-primary-file-pe'
  scope: resourceGroup(empty(secondaryEndpointGroup) ? resourceGroupName : secondaryEndpointGroup)
  params: {
    name: empty(endpointNames.secondaryVnetPrimaryStorage) ? 'pe-${secondaryRegionCode}-primary-file' : endpointNames.secondaryVnetPrimaryStorage
    location: secondaryLocation
    subnetId: secondaryEndpointSubnetId
    storageAccountId: primaryStorageId
    groupId: 'file'
    privateDnsZoneId: secondaryFileZoneId
    tags: tags
  }
  dependsOn: [createdResourceGroups]
}

module secondaryVnetSecondaryFileEndpoint 'modules/storage-private-endpoint.bicep' = if (secondaryEndpoints.secondaryStorage) {
  name: 'replication-${secondaryRegionCode}-secondary-file-pe'
  scope: resourceGroup(empty(secondaryEndpointGroup) ? resourceGroupName : secondaryEndpointGroup)
  params: {
    name: empty(endpointNames.secondaryVnetSecondaryStorage) ? 'pe-${secondaryRegionCode}-secondary-file' : endpointNames.secondaryVnetSecondaryStorage
    location: secondaryLocation
    subnetId: secondaryEndpointSubnetId
    storageAccountId: secondaryStorageId
    groupId: 'file'
    privateDnsZoneId: secondaryFileZoneId
    tags: tags
  }
  dependsOn: [createdResourceGroups]
}

module secondaryVnetRegistryEndpoint 'modules/storage-private-endpoint.bicep' = if (secondaryEndpoints.registry) {
  name: 'replication-${secondaryRegionCode}-registry-pe'
  scope: resourceGroup(empty(secondaryEndpointGroup) ? resourceGroupName : secondaryEndpointGroup)
  params: {
    name: empty(endpointNames.secondaryVnetRegistry) ? 'pe-${secondaryRegionCode}-registry' : endpointNames.secondaryVnetRegistry
    location: secondaryLocation
    subnetId: secondaryEndpointSubnetId
    storageAccountId: registryId
    groupId: 'registry'
    privateDnsZoneId: secondaryRegistryZoneId
    tags: tags
  }
  dependsOn: [createdResourceGroups]
}

module primaryIdentity 'modules/replication-identity.bicep' = {
  name: 'replication-${primaryRegionCode}-identity'
  scope: resourceGroup(resourceGroupName)
  params: {
    environmentName: environmentName
    location: primaryLocation
    regionCode: primaryRegionCode
    name: resourceNames.?primaryIdentity ?? ''
    tags: validatedTags
  }
  dependsOn: [createdResourceGroups]
}

module secondaryIdentity 'modules/replication-identity.bicep' = {
  name: 'replication-${secondaryRegionCode}-identity'
  scope: resourceGroup(secondaryResourceGroupName)
  params: {
    environmentName: environmentName
    location: secondaryLocation
    regionCode: secondaryRegionCode
    name: resourceNames.?secondaryIdentity ?? ''
    tags: validatedTags
  }
  dependsOn: [createdResourceGroups]
}

// Both identities need both accounts because either region can become the replication source.
module primaryStorageRbac 'modules/existing-storage-rbac.bicep' = {
  name: 'replication-primary-storage-rbac'
  scope: resourceGroup(empty(primaryStorageGroup) ? resourceGroupName : primaryStorageGroup)
  params: {
    storageAccountName: primaryStorageMode == 'new' ? newPrimaryStorage!.outputs.name : primaryStorageName
    principalIds: [primaryIdentity.outputs.principalId, secondaryIdentity.outputs.principalId]
  }
}

module secondaryStorageRbac 'modules/existing-storage-rbac.bicep' = {
  name: 'replication-secondary-storage-rbac'
  scope: resourceGroup(empty(secondaryStorageGroup) ? resourceGroupName : secondaryStorageGroup)
  params: {
    storageAccountName: secondaryStorageMode == 'new' ? newSecondaryStorage!.outputs.name : secondaryStorageName
    principalIds: [primaryIdentity.outputs.principalId, secondaryIdentity.outputs.principalId]
  }
}

module registryRbac 'modules/existing-acr-rbac.bicep' = {
  name: 'replication-registry-rbac'
  scope: resourceGroup(empty(registryGroup) ? resourceGroupName : registryGroup)
  params: {
    registryName: registryMode == 'new' ? newRegistry!.outputs.name : registryResolvedName
    principalIds: [primaryIdentity.outputs.principalId, secondaryIdentity.outputs.principalId]
  }
}

var primaryFileUrl = 'https://${primaryStorageName}.file.${environment().suffixes.storage}/${primaryShareName}'
var secondaryFileUrl = 'https://${secondaryStorageName}.file.${environment().suffixes.storage}/${secondaryShareName}'

// The jobs must not start before their role assignments and the endpoints they copy through exist.
module primaryRegion 'modules/replication-region.bicep' = {
  name: 'replication-${primaryRegionCode}-compute'
  scope: resourceGroup(resourceGroupName)
  params: {
    environmentName: environmentName
    location: primaryLocation
    regionCode: primaryRegionCode
    logWorkspaceName: resourceNames.?primaryLogWorkspace ?? ''
    managedEnvironmentName: resourceNames.?primaryEnvironment ?? ''
    jobName: resourceNames.?primaryJob ?? ''
    infrastructureSubnetId: primaryInfrastructureSubnetId
    identityId: primaryIdentity.outputs.id
    identityClientId: primaryIdentity.outputs.clientId
    registryLoginServer: registryLoginServer
    sourceFileUrl: primaryFileUrl
    destinationFileUrl: secondaryFileUrl
    scheduled: activeRegion == 'primary'
    scheduleCronExpression: scheduleCronExpression
    containerImage: containerImage
    tags: validatedTags
  }
  dependsOn: [
    primaryStorageRbac
    secondaryStorageRbac
    registryRbac
    primaryVnetPrimaryFileEndpoint
    primaryVnetSecondaryFileEndpoint
    primaryVnetRegistryEndpoint
  ]
}

module secondaryRegion 'modules/replication-region.bicep' = {
  name: 'replication-${secondaryRegionCode}-compute'
  scope: resourceGroup(secondaryResourceGroupName)
  params: {
    environmentName: environmentName
    location: secondaryLocation
    regionCode: secondaryRegionCode
    logWorkspaceName: resourceNames.?secondaryLogWorkspace ?? ''
    managedEnvironmentName: resourceNames.?secondaryEnvironment ?? ''
    jobName: resourceNames.?secondaryJob ?? ''
    infrastructureSubnetId: secondaryInfrastructureSubnetId
    identityId: secondaryIdentity.outputs.id
    identityClientId: secondaryIdentity.outputs.clientId
    registryLoginServer: registryLoginServer
    sourceFileUrl: secondaryFileUrl
    destinationFileUrl: primaryFileUrl
    scheduled: activeRegion == 'secondary'
    scheduleCronExpression: scheduleCronExpression
    containerImage: containerImage
    tags: validatedTags
  }
  dependsOn: [
    primaryStorageRbac
    secondaryStorageRbac
    registryRbac
    secondaryVnetPrimaryFileEndpoint
    secondaryVnetSecondaryFileEndpoint
    secondaryVnetRegistryEndpoint
  ]
}

module monitoring 'modules/monitoring.bicep' = {
  name: 'existing-storage-replication-monitoring'
  scope: resourceGroup(resourceGroupName)
  params: {
    environmentName: environmentName
    primaryLocation: primaryLocation
    secondaryLocation: secondaryLocation
    activeRegion: activeRegion
    primaryJobId: primaryRegion.outputs.jobId
    primaryJobName: primaryRegion.outputs.jobName
    secondaryJobId: secondaryRegion.outputs.jobId
    secondaryJobName: secondaryRegion.outputs.jobName
    primaryLogWorkspaceId: primaryRegion.outputs.logWorkspaceId
    secondaryLogWorkspaceId: secondaryRegion.outputs.logWorkspaceId
    alertEmailAddresses: alertEmailAddresses
    replicationLagThresholdMinutes: replicationLagThresholdMinutes
    monitoringEnabled: monitoringEnabled
    tags: tags
    actionGroupName: resourceNames.?actionGroup ?? ''
    primaryFailureAlertName: resourceNames.?primaryFailureAlert ?? ''
    secondaryFailureAlertName: resourceNames.?secondaryFailureAlert ?? ''
    primaryFreshnessAlertName: resourceNames.?primaryFreshnessAlert ?? ''
    secondaryFreshnessAlertName: resourceNames.?secondaryFreshnessAlert ?? ''
  }
  dependsOn: [createdResourceGroups]
}

output resourceGroupName string = resourceGroupName
output secondaryResourceGroupName string = secondaryResourceGroupName
output primaryJobName string = primaryRegion.outputs.jobName
output secondaryJobName string = secondaryRegion.outputs.jobName
output registryName string = registryResolvedName
output primaryFileStorageAccountName string = primaryStorageName
output secondaryFileStorageAccountName string = secondaryStorageName
output primaryFileShareName string = primaryShareName
output secondaryFileShareName string = secondaryShareName
output primaryLogWorkspaceName string = primaryRegion.outputs.logWorkspaceName
output secondaryLogWorkspaceName string = secondaryRegion.outputs.logWorkspaceName
output referencedPrivateEndpointIds array = existingPrivateEndpointIds
output monitoringActionGroupId string = monitoring.outputs.actionGroupId
output primaryFailureAlertId string = monitoring.outputs.primaryFailureAlertId
output secondaryFailureAlertId string = monitoring.outputs.secondaryFailureAlertId
output primaryFreshnessAlertId string = monitoring.outputs.primaryFreshnessAlertId
output secondaryFreshnessAlertId string = monitoring.outputs.secondaryFreshnessAlertId
