targetScope = 'subscription'

@description('Resource group where replication compute resources will be created.')
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

@minLength(6)
@description('Resource IDs for the existing file and ACR private endpoints. They are validated as deployment inputs but never modified.')
param existingPrivateEndpointIds array

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

resource workloadResourceGroup 'Microsoft.Resources/resourceGroups@2024-11-01' = {
  name: resourceGroupName
  location: resourceGroupLocation
  tags: tags
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
    primaryStorageAccountName: primaryStorageAccountName
    primaryStorageResourceGroupName: primaryStorageResourceGroupName
    primaryFileShareName: primaryFileShareName
    secondaryStorageAccountName: secondaryStorageAccountName
    secondaryStorageResourceGroupName: secondaryStorageResourceGroupName
    secondaryFileShareName: secondaryFileShareName
    primaryVnetName: primaryVnetName
    primaryVnetResourceGroupName: primaryVnetResourceGroupName
    primaryInfrastructureSubnetName: primaryInfrastructureSubnetName
    secondaryVnetName: secondaryVnetName
    secondaryVnetResourceGroupName: secondaryVnetResourceGroupName
    secondaryInfrastructureSubnetName: secondaryInfrastructureSubnetName
    registryName: registryName
    registryResourceGroupName: registryResourceGroupName
    existingPrivateEndpointIds: existingPrivateEndpointIds
    activeRegion: activeRegion
    containerImage: containerImage
    scheduleCronExpression: scheduleCronExpression
    tags: tags
  }
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
