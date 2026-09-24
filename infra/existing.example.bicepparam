using './existing.bicep'

// Annotated example of an existing-resource parameter file.
// Copy it to infra/existing.bicepparam, which Git ignores, or generate that file from what already exists with
// scripts/audit-existing-resources.ps1 -ParametersOutputPath ./infra/existing.bicepparam.
// Replace every value in angle brackets, then check the file with
// pwsh ./scripts/inventory.ps1 -ParametersFile ./infra/existing.bicepparam.
// README.md, section "Customize the parameter file", explains every setting. Unset parameters use their defaults,
// which reuse every service and place everything the deployment creates in resourceGroupName.

// 1. Regions and resource groups. Choose these before the first deployment: they are part of generated resource names.
param resourceGroupName = '<replication-resource-group>'
param resourceGroupLocation = '<primary-region>'
param primaryLocation = '<primary-region>'
param secondaryLocation = '<secondary-region>'
param primaryRegionCode = 'pri'
param secondaryRegionCode = 'sec'
param environmentName = 'prod'

// Optional: one resource group per region. Secondary-region compute and new secondary-region services go here.
// param secondaryResourceGroupName = '<secondary-replication-resource-group>'
// param secondaryResourceGroupLocation = '<secondary-region>'

// Resource groups that already exist. The deployment creates every other group that it places resources in, and it
// replaces the tags of an existing group that isn't listed, for example ['<replication-resource-group>'].
param existingResourceGroups = []

// 2. Storage. existing reuses an account and SMB share; new creates a private account and share.
// Primary storage is the replication source.
param primaryStorageMode = 'existing'
param primaryStorageAccountName = '<primary-storage-account>'
param primaryStorageResourceGroupName = '<primary-storage-resource-group>'
param primaryFileShareName = '<primary-file-share>'

// Secondary storage is the replication destination. Replication copies into it and never deletes extra files.
param secondaryStorageMode = 'existing'
param secondaryStorageAccountName = '<secondary-storage-account>'
param secondaryStorageResourceGroupName = '<secondary-storage-resource-group>'
param secondaryFileShareName = '<secondary-file-share>'
// To create the destination instead, set secondaryStorageMode = 'new'. The other secondary storage values then
// become optional: an empty account name is generated, an empty resource group is the secondary region's group,
// and an empty share name is replication. Choose the SKU and the quota of new shares with:
// param secondaryStorageSkuName = 'Standard_LRS'
// param newFileShareQuotaGiB = 1024

// 3. Job networks. existing reuses a VNet and its empty subnet delegated to Microsoft.App/environments (/27 or larger);
// newSubnet adds a delegated job subnet to the VNet; new creates a dedicated VNet with its own private DNS zones.
param primaryNetworkMode = 'existing'
param primaryVnetName = '<primary-vnet>'
param primaryVnetResourceGroupName = '<primary-network-resource-group>'
param primaryInfrastructureSubnetName = '<primary-container-apps-subnet>'
// newSubnet keeps the VNet values, makes the subnet name optional (default snet-replication-jobs), and needs a free prefix:
// param primaryInfrastructureSubnetPrefix = '<free-prefix-inside-the-vnet>'
// new makes the VNet values optional and uses:
// param primaryVnetAddressPrefix = '10.10.0.0/16'
// param primaryDnsResourceGroupName = '<primary-dns-resource-group>'

param secondaryNetworkMode = 'existing'
param secondaryVnetName = '<secondary-vnet>'
param secondaryVnetResourceGroupName = '<secondary-network-resource-group>'
param secondaryInfrastructureSubnetName = '<secondary-container-apps-subnet>'
// param secondaryInfrastructureSubnetPrefix = '<free-prefix-inside-the-vnet>'
// param secondaryVnetAddressPrefix = '10.20.0.0/16'
// param secondaryDnsResourceGroupName = '<secondary-dns-resource-group>'

// 4. Private endpoints and DNS. Each job VNet needs private access to both storage accounts, and to the registry
// unless the jobs reach it publicly (registryPrivateEndpointsEnabled = false in section 5).
// The deployment creates the endpoints for every new service and in every new VNet. For an existing VNet, list the
// existing services that still need an endpoint there: 'primaryStorage', 'secondaryStorage', or 'registry'.
// When the deployment creates any endpoint in an existing VNet, set that VNet's endpoint subnet and, unless Azure
// Policy creates the records, the resource IDs of the private DNS zones linked to it.
// param primaryEndpointsToCreate = ['secondaryStorage']
// param primaryPrivateEndpointSubnetName = '<primary-endpoint-subnet>'
// param primaryFileDnsZoneId = '<privatelink.file zone resource ID>'
// param primaryRegistryDnsZoneId = '<privatelink.azurecr.io zone resource ID>'
// param secondaryEndpointsToCreate = ['primaryStorage']
// param secondaryPrivateEndpointSubnetName = '<secondary-endpoint-subnet>'
// param secondaryFileDnsZoneId = '<privatelink.file zone resource ID>'
// param secondaryRegistryDnsZoneId = '<privatelink.azurecr.io zone resource ID>'
// Optional: a resource group for the endpoints that the deployment creates in each VNet.
// param primaryEndpointResourceGroupName = '<primary-endpoint-resource-group>'
// param secondaryEndpointResourceGroupName = '<secondary-endpoint-resource-group>'
// Reference only: existing endpoints that the replication layout relies on. The template records them in its outputs.
// param existingPrivateEndpointIds = ['<private-endpoint-resource-id>']

// 5. Registry. existing reuses a registry; new creates a Premium registry with a replica in the secondary region.
param registryMode = 'existing'
param registryName = '<registry-name>'
param registryResourceGroupName = '<registry-resource-group>'
// For a Basic or Standard registry that the jobs reach through its public endpoint:
// param registryPrivateEndpointsEnabled = false

// scripts/deploy.ps1 builds and pins the AzCopy image. For a direct deployment, set an image that is in the registry:
// param containerImage = '<registry-name>.azurecr.io/azure-files-dr-azcopy@sha256:<digest>'

// 6. Optional names for the other resources that the deployment creates; omitted names are generated. Valid keys:
// primaryIdentity, secondaryIdentity, primaryLogWorkspace, secondaryLogWorkspace, primaryEnvironment,
// secondaryEnvironment, primaryJob, secondaryJob, primaryVnetPrimaryStorageEndpoint, primaryVnetSecondaryStorageEndpoint,
// primaryVnetRegistryEndpoint, secondaryVnetPrimaryStorageEndpoint, secondaryVnetSecondaryStorageEndpoint,
// secondaryVnetRegistryEndpoint, actionGroup, primaryFailureAlert, secondaryFailureAlert, primaryFreshnessAlert, and
// secondaryFreshnessAlert.
// param resourceNames = {
//   primaryJob: '<primary-job-name>'
//   secondaryJob: '<secondary-job-name>'
// }

// 7. Schedule and alerts. Keep activeRegion = 'none' until the jobs pass validation, then set 'primary'.
param activeRegion = 'none'
param scheduleCronExpression = '*/10 * * * *'
param alertEmailAddresses = [
  '<operations-email-address>'
]
param replicationLagThresholdMinutes = 30
param monitoringEnabled = true