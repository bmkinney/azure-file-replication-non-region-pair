using './existing.bicep'

// Copy this file to existing.bicepparam and replace every placeholder.
param resourceGroupName = '<replication-resource-group>'
param resourceGroupLocation = '<primary-region>'
param primaryLocation = '<primary-region>'
param secondaryLocation = '<secondary-region>'
param primaryRegionCode = 'pri'
param secondaryRegionCode = 'sec'
param environmentName = 'prod'

param primaryStorageAccountName = '<primary-storage-account>'
param primaryStorageResourceGroupName = '<primary-storage-resource-group>'
param primaryFileShareName = '<primary-file-share>'
param secondaryStorageAccountName = '<secondary-storage-account>'
param secondaryStorageResourceGroupName = '<secondary-storage-resource-group>'
param secondaryFileShareName = '<secondary-file-share>'

param primaryVnetName = '<primary-vnet>'
param primaryVnetResourceGroupName = '<primary-network-resource-group>'
param primaryInfrastructureSubnetName = '<primary-container-apps-subnet>'
param secondaryVnetName = '<secondary-vnet>'
param secondaryVnetResourceGroupName = '<secondary-network-resource-group>'
param secondaryInfrastructureSubnetName = '<secondary-container-apps-subnet>'

param registryName = '<existing-premium-acr>'
param registryResourceGroupName = '<acr-resource-group>'

param existingPrivateEndpointIds = [
  '<primary-vnet-to-primary-file-endpoint-id>'
  '<primary-vnet-to-secondary-file-endpoint-id>'
  '<secondary-vnet-to-primary-file-endpoint-id>'
  '<secondary-vnet-to-secondary-file-endpoint-id>'
  '<primary-vnet-to-acr-endpoint-id>'
  '<secondary-vnet-to-acr-endpoint-id>'
]

param activeRegion = 'none'
// For a direct Bicep deployment, set this to an image already present in registryName.
// Example: myregistry.azurecr.io/azure-files-dr@sha256:<64-hex-digest>
param containerImage = '<existing-acr-login-server>/<repository>@sha256:<digest>'
param scheduleCronExpression = '*/10 * * * *'
