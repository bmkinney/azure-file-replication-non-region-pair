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

module monitoring 'modules/monitoring.bicep' = {
  name: 'storage-replication-monitoring'
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
