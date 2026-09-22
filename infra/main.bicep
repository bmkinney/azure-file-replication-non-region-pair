targetScope = 'subscription'

@description('Resource group for the replication workload.')
param resourceGroupName string = 'rg-azure-files-replication-demo'

@description('Resource group for the primary-region split-horizon private DNS zones.')
param primaryDnsResourceGroupName string = '${resourceGroupName}-primary-dns'

@description('Resource group for the secondary-region split-horizon private DNS zones.')
param secondaryDnsResourceGroupName string = '${resourceGroupName}-secondary-dns'

@description('Resource group metadata location. Keep the current value because resource group locations are immutable.')
param resourceGroupLocation string = 'centralus'

param primaryLocation string = 'southcentralus'
param secondaryLocation string = 'westus'
param environmentName string = 'demo'

@allowed([
  'none'
  'primary'
  'secondary'
])
@description('The only region with an enabled schedule. Use none while bootstrapping the image.')
param activeRegion string = 'none'

@description('Digest-pinned AzCopy image. The deployment script sets this after building the image.')
param containerImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@allowed([
  'Enabled'
  'Disabled'
])
param acrPublicNetworkAccess string = 'Enabled'

param scheduleCronExpression string = '*/10 * * * *'

param tags object = {
  Environment: environmentName
  Workload: 'azure-files-dr-replication'
  ManagedBy: 'Bicep'
}

resource workloadResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: resourceGroupLocation
  tags: tags
}

resource primaryDnsResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: primaryDnsResourceGroupName
  location: primaryLocation
  tags: union(tags, { RegionRole: 'primary-dns' })
}

resource secondaryDnsResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: secondaryDnsResourceGroupName
  location: secondaryLocation
  tags: union(tags, { RegionRole: 'secondary-dns' })
}

module foundation 'modules/foundation.bicep' = {
  name: 'storage-replication-foundation'
  scope: workloadResourceGroup
  params: {
    environmentName: environmentName
    primaryLocation: primaryLocation
    secondaryLocation: secondaryLocation
    primaryDnsResourceGroupName: primaryDnsResourceGroup.name
    secondaryDnsResourceGroupName: secondaryDnsResourceGroup.name
    activeRegion: activeRegion
    containerImage: containerImage
    acrPublicNetworkAccess: acrPublicNetworkAccess
    scheduleCronExpression: scheduleCronExpression
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
