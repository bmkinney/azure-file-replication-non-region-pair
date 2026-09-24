using './existing.bicep'

// Copy this file to existing.bicepparam and replace every placeholder, or generate it with
// scripts/audit-existing-resources.ps1 -ParametersOutputPath ./infra/existing.bicepparam.
param resourceGroupName = '<replication-resource-group>'
param resourceGroupLocation = '<primary-region>'
param primaryLocation = '<primary-region>'
param secondaryLocation = '<secondary-region>'
param primaryRegionCode = 'pri'
param secondaryRegionCode = 'sec'
param environmentName = 'prod'

// Each service is reused (existing, the default) or created by the deployment (new).
// A new service needs no names: the deployment creates it in resourceGroupName with its endpoints and DNS records.
param primaryStorageMode = 'existing'
param primaryStorageAccountName = '<primary-storage-account>'
param primaryStorageResourceGroupName = '<primary-storage-resource-group>'
param primaryFileShareName = '<primary-file-share>'
param secondaryStorageMode = 'existing'
param secondaryStorageAccountName = '<secondary-storage-account>'
param secondaryStorageResourceGroupName = '<secondary-storage-resource-group>'
param secondaryFileShareName = '<secondary-file-share>'
// For a new account: param secondaryStorageMode = 'new', optionally with secondaryStorageSkuName and secondaryFileShareName.

// Network modes: existing reuses a VNet and its empty delegated subnet; newSubnet adds a delegated subnet to the VNet
// (set primaryInfrastructureSubnetPrefix); new creates a dedicated VNet (primaryVnetAddressPrefix) with its own DNS zones.
param primaryNetworkMode = 'existing'
param primaryVnetName = '<primary-vnet>'
param primaryVnetResourceGroupName = '<primary-network-resource-group>'
param primaryInfrastructureSubnetName = '<primary-container-apps-subnet>'
param secondaryNetworkMode = 'existing'
param secondaryVnetName = '<secondary-vnet>'
param secondaryVnetResourceGroupName = '<secondary-network-resource-group>'
param secondaryInfrastructureSubnetName = '<secondary-container-apps-subnet>'

// The deployment creates private endpoints for new services and in new VNets. In an existing VNet it also creates
// the endpoints listed in primaryEndpointsToCreate or secondaryEndpointsToCreate ('primaryStorage', 'secondaryStorage',
// 'registry'). Endpoints created in an existing VNet need its endpoint subnet and, unless policy creates the records,
// the resource IDs of the private DNS zones linked to it:
// param primaryPrivateEndpointSubnetName = '<primary-endpoint-subnet>'
// param primaryFileDnsZoneId = '<privatelink.file zone resource ID>'
// param primaryRegistryDnsZoneId = '<privatelink.azurecr.io zone resource ID>'

param registryMode = 'existing'
param registryName = '<existing-premium-acr>'
param registryResourceGroupName = '<acr-resource-group>'
// For a Basic or Standard registry that the jobs reach publicly: param registryPrivateEndpointsEnabled = false

// Reference only: list the existing private endpoints your replication network layout uses.
// This example shows the local-endpoint layout; the template does not validate these IDs.
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
param alertEmailAddresses = [
  '<operations-email-address>'
]
param replicationLagThresholdMinutes = 30
param monitoringEnabled = true