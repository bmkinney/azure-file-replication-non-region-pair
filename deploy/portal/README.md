# Deploy Azure Files replication from the Azure portal

Build the same greenfield topology as the Bicep deployment, but by hand in the Azure portal. The order matters because private networking, identity, the image, jobs, and monitoring depend on earlier resources.

## Contents

- [Before you begin](#before-you-begin)
- [1. Sign in and register providers](#1-sign-in-and-register-providers)
- [2. Create resource groups](#2-create-resource-groups)
- [3. Create regional virtual networks](#3-create-regional-virtual-networks)
- [4. Create split-horizon private DNS](#4-create-split-horizon-private-dns)
- [5. Create storage accounts and shares](#5-create-storage-accounts-and-shares)
- [6. Create the container registry](#6-create-the-container-registry)
- [7. Create private endpoints](#7-create-private-endpoints)
- [8. Create managed identities and grant roles](#8-create-managed-identities-and-grant-roles)
- [9. Build and pin the image](#9-build-and-pin-the-image)
- [10. Create Log Analytics workspaces](#10-create-log-analytics-workspaces)
- [11. Create Container Apps environments](#11-create-container-apps-environments)
- [12. Create Container Apps jobs](#12-create-container-apps-jobs)
- [13. Create monitoring and alerts](#13-create-monitoring-and-alerts)
- [14. Validate and enable the schedule](#14-validate-and-enable-the-schedule)
- [15. Switch direction or fail over](#15-switch-direction-or-fail-over)
- [16. Clean up](#16-clean-up)
- [Reuse existing services](#reuse-existing-services)
- [Next steps](#next-steps)

## Before you begin

This guide creates the greenfield topology in [Architecture](../../README.md#architecture): two regional VNets, split-horizon Private DNS, private endpoints for both Azure Files accounts in both VNets, optional blob accounts, a Premium Azure Container Registry with a secondary replica, two user-assigned managed identities, two Log Analytics workspaces, two internal Container Apps environments, two Container Apps jobs, and Azure Monitor alerts. Read [Prerequisites](../../README.md#prerequisites) first.

You need subscription **Owner**, or **Contributor** plus **Role Based Access Control Administrator**, because the job identities need role assignments. An administrator can grant them separately; see [RBAC requirements](../../README.md#rbac-requirements).

Run Azure CLI examples from **PowerShell 7**. Bash users can adapt variable and loop syntax.

### Azure CLI variables

```powershell
$tenantId = '<tenant-id>'
$subscriptionId = '<subscription-id>'
$environment = 'prod'
$suffix = '<unique-lowercase-alnum>' # Keep storage account names <= 24 chars.
$primaryLocation = 'southcentralus'
$secondaryLocation = 'westus'
$resourceGroupLocation = 'centralus'
$alertEmail = '<alert-email>'
$scheduleCron = '*/10 * * * *'
$lagMinutes = 30
$workloadRg = "rg-azure-files-replication-$suffix"
$primaryDnsRg = "$workloadRg-primary-dns"
$secondaryDnsRg = "$workloadRg-secondary-dns"
$primaryVnet = "vnet-$environment-primary"
$secondaryVnet = "vnet-$environment-secondary"
$primaryFileStorage = "stfile${suffix}p"
$secondaryFileStorage = "stfile${suffix}s"
$primaryBlobStorage = "stblob${suffix}p"
$secondaryBlobStorage = "stblob${suffix}s"
$primaryShare = 'files-primary'
$secondaryShare = 'files-secondary'
$registry = "acr$suffix"
$primaryIdentity = "id-replication-primary-$suffix"
$secondaryIdentity = "id-replication-secondary-$suffix"
$primaryLog = "log-replication-primary-$suffix"
$secondaryLog = "log-replication-secondary-$suffix"
$primaryEnv = "cae-replication-primary-$suffix"
$secondaryEnv = "cae-replication-secondary-$suffix"
$primaryJob = "job-sync-primary-$suffix"
$secondaryJob = "job-sync-secondary-$suffix"
$actionGroup = "ag-replication-$suffix"
$imageRepository = 'azure-files-dr-azcopy'
$imageTag = '10.30.1'
$tags = @("Workload=azure-files-dr-replication","Environment=$environment",'ManagedBy=Portal')
$providers = 'Microsoft.App','Microsoft.ContainerRegistry','Microsoft.Insights','Microsoft.ManagedIdentity','Microsoft.Network','Microsoft.OperationalInsights','Microsoft.Storage'
$zones = 'privatelink.file.core.windows.net','privatelink.blob.core.windows.net','privatelink.azurecr.io'
```

### Azure PowerShell variables

Use PowerShell 7 with `Az.Accounts`, `Az.Resources`, `Az.Network`, `Az.PrivateDns`, `Az.Storage`, `Az.ContainerRegistry`, `Az.ManagedServiceIdentity`, `Az.OperationalInsights`, `Az.App`, and `Az.Monitor`.

```powershell
$tenantId = '<tenant-id>'
$subscriptionId = '<subscription-id>'
$environment = 'prod'
$suffix = '<unique-lowercase-alnum>'
$primaryLocation = 'southcentralus'
$secondaryLocation = 'westus'
$resourceGroupLocation = 'centralus'
$alertEmail = '<alert-email>'
$scheduleCron = '*/10 * * * *'
$lagMinutes = 30
$workloadRg = "rg-azure-files-replication-$suffix"
$primaryDnsRg = "$workloadRg-primary-dns"
$secondaryDnsRg = "$workloadRg-secondary-dns"
$primaryVnet = "vnet-$environment-primary"
$secondaryVnet = "vnet-$environment-secondary"
$primaryFileStorage = "stfile${suffix}p"
$secondaryFileStorage = "stfile${suffix}s"
$primaryBlobStorage = "stblob${suffix}p"
$secondaryBlobStorage = "stblob${suffix}s"
$primaryShare = 'files-primary'
$secondaryShare = 'files-secondary'
$registry = "acr$suffix"
$primaryIdentity = "id-replication-primary-$suffix"
$secondaryIdentity = "id-replication-secondary-$suffix"
$primaryLog = "log-replication-primary-$suffix"
$secondaryLog = "log-replication-secondary-$suffix"
$primaryEnv = "cae-replication-primary-$suffix"
$secondaryEnv = "cae-replication-secondary-$suffix"
$primaryJob = "job-sync-primary-$suffix"
$secondaryJob = "job-sync-secondary-$suffix"
$actionGroup = "ag-replication-$suffix"
$imageRepository = 'azure-files-dr-azcopy'
$imageTag = '10.30.1'
$tags = @{ Workload = 'azure-files-dr-replication'; Environment = $environment; ManagedBy = 'Portal' }
$providers = 'Microsoft.App','Microsoft.ContainerRegistry','Microsoft.Insights','Microsoft.ManagedIdentity','Microsoft.Network','Microsoft.OperationalInsights','Microsoft.Storage'
$zones = 'privatelink.file.core.windows.net','privatelink.blob.core.windows.net','privatelink.azurecr.io'
```

### Naming

| Resource | Name |
| --- | --- |
| Workload resource group | `rg-azure-files-replication-$suffix` |
| DNS resource groups | `$workloadRg-primary-dns`, `$workloadRg-secondary-dns` |
| VNets | `vnet-$environment-primary`, `vnet-$environment-secondary` |
| File accounts | `stfile${suffix}p`, `stfile${suffix}s` |
| Blob accounts | `stblob${suffix}p`, `stblob${suffix}s` |
| Shares | `files-primary`, `files-secondary` |
| Registry | `acr$suffix` |
| Identities | `id-replication-primary-$suffix`, `id-replication-secondary-$suffix` |
| Workspaces | `log-replication-primary-$suffix`, `log-replication-secondary-$suffix` |
| Environments | `cae-replication-primary-$suffix`, `cae-replication-secondary-$suffix` |
| Jobs | `job-sync-primary-$suffix`, `job-sync-secondary-$suffix` |

Apply tags `Workload=azure-files-dr-replication`, `Environment=<environment>`, and `ManagedBy=Portal` to every resource. The scripts discover jobs by `Workload=azure-files-dr-replication`.

## 1. Sign in and register providers

In the portal, switch to the target tenant and subscription. Open **Subscriptions** > your subscription > **Resource providers**. Register `Microsoft.App`, `Microsoft.ContainerRegistry`, `Microsoft.Insights`, `Microsoft.ManagedIdentity`, `Microsoft.Network`, `Microsoft.OperationalInsights`, and `Microsoft.Storage`. Wait for **Registered**. Install the Azure CLI `containerapp` and `scheduled-query` extensions if you use CLI snippets.

<details>
<summary>Azure CLI</summary>

```powershell
az login --tenant $tenantId
az account set --subscription $subscriptionId
az account show --output table
foreach ($provider in $providers) { az provider register --namespace $provider --wait }
az extension add --name containerapp --upgrade
az extension add --name scheduled-query --upgrade
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
Connect-AzAccount -Tenant $tenantId
Set-AzContext -Subscription $subscriptionId
foreach ($provider in $providers) {
  Register-AzResourceProvider -ProviderNamespace $provider | Out-Null
  do { Start-Sleep -Seconds 10; $state = (Get-AzResourceProvider -ProviderNamespace $provider).RegistrationState } until ($state -eq 'Registered')
}
```

</details>

## 2. Create resource groups

In **Resource groups**, create the workload group in the metadata location, plus one DNS group per region. Add the common tags.

<details>
<summary>Azure CLI</summary>

```powershell
az group create --name $workloadRg --location $resourceGroupLocation --tags $tags
az group create --name $primaryDnsRg --location $primaryLocation --tags $tags RegionRole=primary-dns
az group create --name $secondaryDnsRg --location $secondaryLocation --tags $tags RegionRole=secondary-dns
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
New-AzResourceGroup -Name $workloadRg -Location $resourceGroupLocation -Tag $tags
New-AzResourceGroup -Name $primaryDnsRg -Location $primaryLocation -Tag ($tags + @{ RegionRole = 'primary-dns' })
New-AzResourceGroup -Name $secondaryDnsRg -Location $secondaryLocation -Tag ($tags + @{ RegionRole = 'secondary-dns' })
```

</details>

## 3. Create regional virtual networks

Create two VNets in the workload group. Add `default` subnets delegated to `Microsoft.App/environments` and `storage` subnets with private endpoint network policies disabled.

| VNet | Address space | `default` subnet | `storage` subnet |
| --- | --- | --- | --- |
| Primary | `10.10.0.0/16` | `10.10.0.0/23` | `10.10.2.0/24` |
| Secondary | `10.20.0.0/16` | `10.20.0.0/23` | `10.20.2.0/24` |

In the portal, open **Virtual networks** > **Create**. Add the subnets on **IP addresses**, then open each subnet to set delegation and private endpoint policies.

<details>
<summary>Azure CLI</summary>

```powershell
az network vnet create -g $workloadRg -n $primaryVnet -l $primaryLocation --address-prefixes 10.10.0.0/16 --subnet-name default --subnet-prefixes 10.10.0.0/23 --tags $tags RegionRole=primary
az network vnet subnet update -g $workloadRg --vnet-name $primaryVnet -n default --delegations Microsoft.App/environments
az network vnet subnet create -g $workloadRg --vnet-name $primaryVnet -n storage --address-prefixes 10.10.2.0/24 --private-endpoint-network-policies Disabled
az network vnet create -g $workloadRg -n $secondaryVnet -l $secondaryLocation --address-prefixes 10.20.0.0/16 --subnet-name default --subnet-prefixes 10.20.0.0/23 --tags $tags RegionRole=secondary
az network vnet subnet update -g $workloadRg --vnet-name $secondaryVnet -n default --delegations Microsoft.App/environments
az network vnet subnet create -g $workloadRg --vnet-name $secondaryVnet -n storage --address-prefixes 10.20.2.0/24 --private-endpoint-network-policies Disabled
$primaryVnetId = az network vnet show -g $workloadRg -n $primaryVnet --query id -o tsv
$secondaryVnetId = az network vnet show -g $workloadRg -n $secondaryVnet --query id -o tsv
$primaryDefaultSubnetId = az network vnet subnet show -g $workloadRg --vnet-name $primaryVnet -n default --query id -o tsv
$primaryStorageSubnetId = az network vnet subnet show -g $workloadRg --vnet-name $primaryVnet -n storage --query id -o tsv
$secondaryDefaultSubnetId = az network vnet subnet show -g $workloadRg --vnet-name $secondaryVnet -n default --query id -o tsv
$secondaryStorageSubnetId = az network vnet subnet show -g $workloadRg --vnet-name $secondaryVnet -n storage --query id -o tsv
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
$delegation = New-AzDelegation -Name container-apps -ServiceName Microsoft.App/environments
$primarySubnets = @(New-AzVirtualNetworkSubnetConfig -Name default -AddressPrefix 10.10.0.0/23 -Delegation $delegation; New-AzVirtualNetworkSubnetConfig -Name storage -AddressPrefix 10.10.2.0/24 -PrivateEndpointNetworkPoliciesFlag Disabled)
$secondarySubnets = @(New-AzVirtualNetworkSubnetConfig -Name default -AddressPrefix 10.20.0.0/23 -Delegation $delegation; New-AzVirtualNetworkSubnetConfig -Name storage -AddressPrefix 10.20.2.0/24 -PrivateEndpointNetworkPoliciesFlag Disabled)
$primaryVnetObject = New-AzVirtualNetwork -ResourceGroupName $workloadRg -Name $primaryVnet -Location $primaryLocation -AddressPrefix 10.10.0.0/16 -Subnet $primarySubnets -Tag ($tags + @{ RegionRole = 'primary' })
$secondaryVnetObject = New-AzVirtualNetwork -ResourceGroupName $workloadRg -Name $secondaryVnet -Location $secondaryLocation -AddressPrefix 10.20.0.0/16 -Subnet $secondarySubnets -Tag ($tags + @{ RegionRole = 'secondary' })
$primaryVnetId = $primaryVnetObject.Id; $secondaryVnetId = $secondaryVnetObject.Id
$primaryDefaultSubnetId = ($primaryVnetObject.Subnets | Where-Object Name -eq default).Id
$primaryStorageSubnetId = ($primaryVnetObject.Subnets | Where-Object Name -eq storage).Id
$secondaryDefaultSubnetId = ($secondaryVnetObject.Subnets | Where-Object Name -eq default).Id
$secondaryStorageSubnetId = ($secondaryVnetObject.Subnets | Where-Object Name -eq storage).Id
```

</details>

## 4. Create split-horizon private DNS

Create `privatelink.file.core.windows.net`, `privatelink.blob.core.windows.net`, and `privatelink.azurecr.io` in each regional DNS group. Link each zone only to the same-region VNet. The VNets are intentionally not peered; each VNet resolves both file accounts to local private endpoints.

<details>
<summary>Azure CLI</summary>

```powershell
foreach ($zone in $zones) {
  az network private-dns zone create -g $primaryDnsRg -n $zone --tags $tags RegionRole=primary
  az network private-dns link vnet create -g $primaryDnsRg -z $zone -n "link-$suffix-primary" --virtual-network $primaryVnetId --registration-enabled false --tags $tags
  az network private-dns zone create -g $secondaryDnsRg -n $zone --tags $tags RegionRole=secondary
  az network private-dns link vnet create -g $secondaryDnsRg -z $zone -n "link-$suffix-secondary" --virtual-network $secondaryVnetId --registration-enabled false --tags $tags
}
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
foreach ($zone in $zones) {
  New-AzPrivateDnsZone -ResourceGroupName $primaryDnsRg -Name $zone -Tag ($tags + @{ RegionRole = 'primary' })
  New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $primaryDnsRg -ZoneName $zone -Name "link-$suffix-primary" -VirtualNetworkId $primaryVnetId -EnableRegistration:$false -Tag $tags
  New-AzPrivateDnsZone -ResourceGroupName $secondaryDnsRg -Name $zone -Tag ($tags + @{ RegionRole = 'secondary' })
  New-AzPrivateDnsVirtualNetworkLink -ResourceGroupName $secondaryDnsRg -ZoneName $zone -Name "link-$suffix-secondary" -VirtualNetworkId $secondaryVnetId -EnableRegistration:$false -Tag $tags
}
```

</details>

## 5. Create storage accounts and shares

Create file accounts with public access disabled, shared key disabled, default Microsoft Entra authorization enabled, TLS 1.2, HTTPS only, soft delete 14 days, and SMB `3.0;3.1.1`. Use `Standard_ZRS` for primary and `Standard_LRS` for secondary. Create 1024 GiB SMB shares with transaction optimized tier through the management plane (`share-rm`/`New-AzRmStorageShare`), because keys and public access are disabled. Optionally create blob accounts for application use.

In the portal, use **Storage accounts** > **Create**. After creation, configure **Configuration**, **Networking**, **Data protection**, **File shares**, and **File service** settings.

<details>
<summary>Azure CLI</summary>

```powershell
az storage account create -g $workloadRg -n $primaryFileStorage -l $primaryLocation --sku Standard_ZRS --kind StorageV2 --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false --public-network-access Disabled --default-action Deny --tags $tags RegionRole=primary DataRole=files
az storage account create -g $workloadRg -n $secondaryFileStorage -l $secondaryLocation --sku Standard_LRS --kind StorageV2 --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false --public-network-access Disabled --default-action Deny --tags $tags RegionRole=secondary DataRole=files
$primaryFileAccountId = az storage account show -g $workloadRg -n $primaryFileStorage --query id -o tsv
$secondaryFileAccountId = az storage account show -g $workloadRg -n $secondaryFileStorage --query id -o tsv
az resource update --ids $primaryFileAccountId --set properties.defaultToOAuthAuthentication=true
az resource update --ids $secondaryFileAccountId --set properties.defaultToOAuthAuthentication=true
foreach ($account in $primaryFileStorage,$secondaryFileStorage) { az storage account file-service-properties update -g $workloadRg --account-name $account --enable-delete-retention true --delete-retention-days 14 --versions 'SMB3.0;SMB3.1.1' }
az storage share-rm create -g $workloadRg --storage-account $primaryFileStorage -n $primaryShare --quota 1024 --access-tier TransactionOptimized --enabled-protocols SMB
az storage share-rm create -g $workloadRg --storage-account $secondaryFileStorage -n $secondaryShare --quota 1024 --access-tier TransactionOptimized --enabled-protocols SMB
az storage account create -g $workloadRg -n $primaryBlobStorage -l $primaryLocation --sku Standard_ZRS --kind StorageV2 --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false --public-network-access Disabled --default-action Deny --tags $tags RegionRole=primary DataRole=blob
az storage account create -g $workloadRg -n $secondaryBlobStorage -l $secondaryLocation --sku Standard_LRS --kind StorageV2 --https-only true --min-tls-version TLS1_2 --allow-blob-public-access false --allow-shared-key-access false --public-network-access Disabled --default-action Deny --tags $tags RegionRole=secondary DataRole=blob
$primaryBlobAccountId = az storage account show -g $workloadRg -n $primaryBlobStorage --query id -o tsv
$secondaryBlobAccountId = az storage account show -g $workloadRg -n $secondaryBlobStorage --query id -o tsv
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
$networkRuleSet = @{ defaultAction = 'Deny'; bypass = 'AzureServices'; ipRules = @(); virtualNetworkRules = @() }
$primaryFileAccount = New-AzStorageAccount -ResourceGroupName $workloadRg -Name $primaryFileStorage -Location $primaryLocation -SkuName Standard_ZRS -Kind StorageV2 -EnableHttpsTrafficOnly $true -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false -PublicNetworkAccess Disabled -NetworkRuleSet $networkRuleSet -Tag ($tags + @{ RegionRole = 'primary'; DataRole = 'files' })
$secondaryFileAccount = New-AzStorageAccount -ResourceGroupName $workloadRg -Name $secondaryFileStorage -Location $secondaryLocation -SkuName Standard_LRS -Kind StorageV2 -EnableHttpsTrafficOnly $true -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false -PublicNetworkAccess Disabled -NetworkRuleSet $networkRuleSet -Tag ($tags + @{ RegionRole = 'secondary'; DataRole = 'files' })
foreach ($account in $primaryFileAccount,$secondaryFileAccount) {
  Invoke-AzRestMethod -Method PATCH -Uri "https://management.azure.com$($account.Id)?api-version=2025-01-01" -Payload '{"properties":{"defaultToOAuthAuthentication":true}}'
  Update-AzStorageFileServiceProperty -ResourceGroupName $workloadRg -StorageAccountName $account.StorageAccountName -EnableShareDeleteRetentionPolicy $true -ShareRetentionDays 14
  Invoke-AzRestMethod -Method PATCH -Uri "https://management.azure.com$($account.Id)/fileServices/default?api-version=2025-01-01" -Payload '{"properties":{"protocolSettings":{"smb":{"versions":"SMB3.0;SMB3.1.1"}}}}'
}
New-AzRmStorageShare -ResourceGroupName $workloadRg -StorageAccountName $primaryFileStorage -Name $primaryShare -QuotaGiB 1024 -AccessTier TransactionOptimized -EnabledProtocol SMB
New-AzRmStorageShare -ResourceGroupName $workloadRg -StorageAccountName $secondaryFileStorage -Name $secondaryShare -QuotaGiB 1024 -AccessTier TransactionOptimized -EnabledProtocol SMB
$primaryBlobAccount = New-AzStorageAccount -ResourceGroupName $workloadRg -Name $primaryBlobStorage -Location $primaryLocation -SkuName Standard_ZRS -Kind StorageV2 -EnableHttpsTrafficOnly $true -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false -PublicNetworkAccess Disabled -NetworkRuleSet $networkRuleSet -Tag ($tags + @{ RegionRole = 'primary'; DataRole = 'blob' })
$secondaryBlobAccount = New-AzStorageAccount -ResourceGroupName $workloadRg -Name $secondaryBlobStorage -Location $secondaryLocation -SkuName Standard_LRS -Kind StorageV2 -EnableHttpsTrafficOnly $true -MinimumTlsVersion TLS1_2 -AllowBlobPublicAccess $false -AllowSharedKeyAccess $false -PublicNetworkAccess Disabled -NetworkRuleSet $networkRuleSet -Tag ($tags + @{ RegionRole = 'secondary'; DataRole = 'blob' })
$primaryFileAccountId = $primaryFileAccount.Id; $secondaryFileAccountId = $secondaryFileAccount.Id
$primaryBlobAccountId = $primaryBlobAccount.Id; $secondaryBlobAccountId = $secondaryBlobAccount.Id
```

</details>

## 6. Create the container registry

Create a Premium registry in the primary region. Enable zone redundancy and dedicated data endpoint, keep admin disabled, add a secondary replica, and leave public access enabled only until the build completes.

<details>
<summary>Azure CLI</summary>

```powershell
az acr create -g $workloadRg -n $registry -l $primaryLocation --sku Premium --zone-redundancy Enabled --data-endpoint-enabled true --admin-enabled false --public-network-enabled true --tags $tags
az acr replication create -g $workloadRg --registry $registry --location $secondaryLocation --zone-redundancy Disabled
$registryId = az acr show -g $workloadRg -n $registry --query id -o tsv
$registryServer = az acr show -g $workloadRg -n $registry --query loginServer -o tsv
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
$registryObject = New-AzContainerRegistry -ResourceGroupName $workloadRg -Name $registry -Location $primaryLocation -Sku Premium -ZoneRedundancy Enabled -DataEndpointEnabled -PublicNetworkAccess Enabled -Tag $tags
New-AzContainerRegistryReplication -ResourceGroupName $workloadRg -RegistryName $registry -Name $secondaryLocation -Location $secondaryLocation -ZoneRedundancy Disabled
$registryId = $registryObject.Id
$registryServer = $registryObject.LoginServer
```

</details>

## 7. Create private endpoints

Create eight private endpoints with DNS zone groups: primary VNet to primary file, secondary file, primary blob, and ACR; secondary VNet to primary file, secondary file, secondary blob, and ACR.

| Endpoint | Region | Target | Group ID | DNS zone |
| --- | --- | --- | --- | --- |
| `pe-primary-primary-file` | Primary | Primary file account | `file` | Primary file |
| `pe-primary-secondary-file` | Primary | Secondary file account | `file` | Primary file |
| `pe-secondary-primary-file` | Secondary | Primary file account | `file` | Secondary file |
| `pe-secondary-secondary-file` | Secondary | Secondary file account | `file` | Secondary file |
| `pe-primary-blob` | Primary | Primary blob account | `blob` | Primary blob |
| `pe-secondary-blob` | Secondary | Secondary blob account | `blob` | Secondary blob |
| `pe-primary-acr` | Primary | Registry | `registry` | Primary ACR |
| `pe-secondary-acr` | Secondary | Registry | `registry` | Secondary ACR |

<details>
<summary>Azure CLI</summary>

```powershell
$primaryFileZoneId = az network private-dns zone show -g $primaryDnsRg -n privatelink.file.core.windows.net --query id -o tsv
$primaryBlobZoneId = az network private-dns zone show -g $primaryDnsRg -n privatelink.blob.core.windows.net --query id -o tsv
$primaryAcrZoneId = az network private-dns zone show -g $primaryDnsRg -n privatelink.azurecr.io --query id -o tsv
$secondaryFileZoneId = az network private-dns zone show -g $secondaryDnsRg -n privatelink.file.core.windows.net --query id -o tsv
$secondaryBlobZoneId = az network private-dns zone show -g $secondaryDnsRg -n privatelink.blob.core.windows.net --query id -o tsv
$secondaryAcrZoneId = az network private-dns zone show -g $secondaryDnsRg -n privatelink.azurecr.io --query id -o tsv
$endpoints = @(
  @{N='pe-primary-primary-file';L=$primaryLocation;S=$primaryStorageSubnetId;T=$primaryFileAccountId;G='file';Z=$primaryFileZoneId}, @{N='pe-primary-secondary-file';L=$primaryLocation;S=$primaryStorageSubnetId;T=$secondaryFileAccountId;G='file';Z=$primaryFileZoneId}, @{N='pe-secondary-primary-file';L=$secondaryLocation;S=$secondaryStorageSubnetId;T=$primaryFileAccountId;G='file';Z=$secondaryFileZoneId}, @{N='pe-secondary-secondary-file';L=$secondaryLocation;S=$secondaryStorageSubnetId;T=$secondaryFileAccountId;G='file';Z=$secondaryFileZoneId}, @{N='pe-primary-blob';L=$primaryLocation;S=$primaryStorageSubnetId;T=$primaryBlobAccountId;G='blob';Z=$primaryBlobZoneId}, @{N='pe-secondary-blob';L=$secondaryLocation;S=$secondaryStorageSubnetId;T=$secondaryBlobAccountId;G='blob';Z=$secondaryBlobZoneId}, @{N='pe-primary-acr';L=$primaryLocation;S=$primaryStorageSubnetId;T=$registryId;G='registry';Z=$primaryAcrZoneId}, @{N='pe-secondary-acr';L=$secondaryLocation;S=$secondaryStorageSubnetId;T=$registryId;G='registry';Z=$secondaryAcrZoneId}
)
foreach ($pe in $endpoints) {
  az network private-endpoint create -g $workloadRg -n $pe.N -l $pe.L --subnet $pe.S --private-connection-resource-id $pe.T --group-id $pe.G --connection-name "$($pe.N)-connection" --tags $tags
  az network private-endpoint dns-zone-group create -g $workloadRg --endpoint-name $pe.N -n default --private-dns-zone $pe.Z --zone-name $pe.G
}
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
$primaryFileZoneId = (Get-AzPrivateDnsZone -ResourceGroupName $primaryDnsRg -Name privatelink.file.core.windows.net).ResourceId
$primaryBlobZoneId = (Get-AzPrivateDnsZone -ResourceGroupName $primaryDnsRg -Name privatelink.blob.core.windows.net).ResourceId
$primaryAcrZoneId = (Get-AzPrivateDnsZone -ResourceGroupName $primaryDnsRg -Name privatelink.azurecr.io).ResourceId
$secondaryFileZoneId = (Get-AzPrivateDnsZone -ResourceGroupName $secondaryDnsRg -Name privatelink.file.core.windows.net).ResourceId
$secondaryBlobZoneId = (Get-AzPrivateDnsZone -ResourceGroupName $secondaryDnsRg -Name privatelink.blob.core.windows.net).ResourceId
$secondaryAcrZoneId = (Get-AzPrivateDnsZone -ResourceGroupName $secondaryDnsRg -Name privatelink.azurecr.io).ResourceId
$endpoints = @(
  @{N='pe-primary-primary-file';L=$primaryLocation;S=$primaryStorageSubnetId;T=$primaryFileAccountId;G='file';Z=$primaryFileZoneId}, @{N='pe-primary-secondary-file';L=$primaryLocation;S=$primaryStorageSubnetId;T=$secondaryFileAccountId;G='file';Z=$primaryFileZoneId}, @{N='pe-secondary-primary-file';L=$secondaryLocation;S=$secondaryStorageSubnetId;T=$primaryFileAccountId;G='file';Z=$secondaryFileZoneId}, @{N='pe-secondary-secondary-file';L=$secondaryLocation;S=$secondaryStorageSubnetId;T=$secondaryFileAccountId;G='file';Z=$secondaryFileZoneId}, @{N='pe-primary-blob';L=$primaryLocation;S=$primaryStorageSubnetId;T=$primaryBlobAccountId;G='blob';Z=$primaryBlobZoneId}, @{N='pe-secondary-blob';L=$secondaryLocation;S=$secondaryStorageSubnetId;T=$secondaryBlobAccountId;G='blob';Z=$secondaryBlobZoneId}, @{N='pe-primary-acr';L=$primaryLocation;S=$primaryStorageSubnetId;T=$registryId;G='registry';Z=$primaryAcrZoneId}, @{N='pe-secondary-acr';L=$secondaryLocation;S=$secondaryStorageSubnetId;T=$registryId;G='registry';Z=$secondaryAcrZoneId}
)
foreach ($pe in $endpoints) {
  $subnet = [Microsoft.Azure.Commands.Network.Models.PSSubnet]@{ Id = $pe.S }
  $connection = New-AzPrivateLinkServiceConnection -Name "$($pe.N)-connection" -PrivateLinkServiceId $pe.T -GroupId $pe.G
  New-AzPrivateEndpoint -ResourceGroupName $workloadRg -Name $pe.N -Location $pe.L -Subnet $subnet -PrivateLinkServiceConnection $connection -Tag $tags | Out-Null
  $zoneConfig = New-AzPrivateDnsZoneConfig -Name $pe.G -PrivateDnsZoneId $pe.Z
  New-AzPrivateDnsZoneGroup -ResourceGroupName $workloadRg -PrivateEndpointName $pe.N -Name default -PrivateDnsZoneConfig $zoneConfig | Out-Null
}
```

</details>

## 8. Create managed identities and grant roles

Create one UAMI per region. Assign **Storage File Data Privileged Contributor** on both file accounts to both identities, and **AcrPull** on the registry to both identities. Wait several minutes for propagation. An administrator can perform this step; see [RBAC requirements](../../README.md#rbac-requirements).

<details>
<summary>Azure CLI</summary>

```powershell
az identity create -g $workloadRg -n $primaryIdentity -l $primaryLocation --tags $tags
az identity create -g $workloadRg -n $secondaryIdentity -l $secondaryLocation --tags $tags
$primaryIdentityId = az identity show -g $workloadRg -n $primaryIdentity --query id -o tsv
$secondaryIdentityId = az identity show -g $workloadRg -n $secondaryIdentity --query id -o tsv
$primaryClientId = az identity show -g $workloadRg -n $primaryIdentity --query clientId -o tsv
$secondaryClientId = az identity show -g $workloadRg -n $secondaryIdentity --query clientId -o tsv
$primaryPrincipalId = az identity show -g $workloadRg -n $primaryIdentity --query principalId -o tsv
$secondaryPrincipalId = az identity show -g $workloadRg -n $secondaryIdentity --query principalId -o tsv
foreach ($principalId in $primaryPrincipalId,$secondaryPrincipalId) { foreach ($scope in $primaryFileAccountId,$secondaryFileAccountId) { az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role 'Storage File Data Privileged Contributor' --scope $scope }; az role assignment create --assignee-object-id $principalId --assignee-principal-type ServicePrincipal --role AcrPull --scope $registryId }
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
$primaryIdentityObject = New-AzUserAssignedIdentity -ResourceGroupName $workloadRg -Name $primaryIdentity -Location $primaryLocation -Tag $tags
$secondaryIdentityObject = New-AzUserAssignedIdentity -ResourceGroupName $workloadRg -Name $secondaryIdentity -Location $secondaryLocation -Tag $tags
$primaryIdentityId = $primaryIdentityObject.Id; $secondaryIdentityId = $secondaryIdentityObject.Id
$primaryClientId = $primaryIdentityObject.ClientId; $secondaryClientId = $secondaryIdentityObject.ClientId
foreach ($principalId in $primaryIdentityObject.PrincipalId,$secondaryIdentityObject.PrincipalId) { foreach ($scope in $primaryFileAccount.Id,$secondaryFileAccount.Id) { New-AzRoleAssignment -ObjectId $principalId -ObjectType ServicePrincipal -RoleDefinitionName 'Storage File Data Privileged Contributor' -Scope $scope }; New-AzRoleAssignment -ObjectId $principalId -ObjectType ServicePrincipal -RoleDefinitionName AcrPull -Scope $registryId }
```

</details>

## 9. Build and pin the image

Build `src\azcopy-job`, read the digest, and use only the digest-pinned image. Disable registry public access after the build. Azure PowerShell has no ACR quick-build cmdlet, so use `az acr build` or an ACR Task.

<details>
<summary>Azure CLI</summary>

```powershell
az acr build --registry $registry --image "$imageRepository`:$imageTag" src\azcopy-job
$digest = az acr manifest show-metadata "$registry.azurecr.io/$imageRepository`:$imageTag" --query digest -o tsv
$image = "$registry.azurecr.io/$imageRepository@$digest"
az acr update -g $workloadRg -n $registry --public-network-enabled false
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
az acr build --registry $registry --image "$imageRepository`:$imageTag" src\azcopy-job
$digest = az acr manifest show-metadata "$registry.azurecr.io/$imageRepository`:$imageTag" --query digest -o tsv
$image = "$registry.azurecr.io/$imageRepository@$digest"
Update-AzContainerRegistry -ResourceGroupName $workloadRg -Name $registry -PublicNetworkAccess Disabled
```

</details>

## 10. Create Log Analytics workspaces

Create one workspace per region with SKU `PerGB2018` and 30-day retention.

<details>
<summary>Azure CLI</summary>

```powershell
az monitor log-analytics workspace create -g $workloadRg -n $primaryLog -l $primaryLocation --sku PerGB2018 --retention-time 30 --tags $tags
az monitor log-analytics workspace create -g $workloadRg -n $secondaryLog -l $secondaryLocation --sku PerGB2018 --retention-time 30 --tags $tags
$primaryWorkspaceId = az monitor log-analytics workspace show -g $workloadRg -n $primaryLog --query id -o tsv
$secondaryWorkspaceId = az monitor log-analytics workspace show -g $workloadRg -n $secondaryLog --query id -o tsv
$primaryWorkspaceCustomerId = az monitor log-analytics workspace show -g $workloadRg -n $primaryLog --query customerId -o tsv
$secondaryWorkspaceCustomerId = az monitor log-analytics workspace show -g $workloadRg -n $secondaryLog --query customerId -o tsv
$primaryWorkspaceKey = az monitor log-analytics workspace get-shared-keys -g $workloadRg -n $primaryLog --query primarySharedKey -o tsv
$secondaryWorkspaceKey = az monitor log-analytics workspace get-shared-keys -g $workloadRg -n $secondaryLog --query primarySharedKey -o tsv
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
$primaryWorkspace = New-AzOperationalInsightsWorkspace -ResourceGroupName $workloadRg -Name $primaryLog -Location $primaryLocation -Sku PerGB2018 -RetentionInDays 30 -Tag $tags
$secondaryWorkspace = New-AzOperationalInsightsWorkspace -ResourceGroupName $workloadRg -Name $secondaryLog -Location $secondaryLocation -Sku PerGB2018 -RetentionInDays 30 -Tag $tags
$primaryWorkspaceId = $primaryWorkspace.ResourceId; $secondaryWorkspaceId = $secondaryWorkspace.ResourceId
$primaryWorkspaceCustomerId = $primaryWorkspace.CustomerId; $secondaryWorkspaceCustomerId = $secondaryWorkspace.CustomerId
$primaryWorkspaceKey = (Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $workloadRg -Name $primaryLog).PrimarySharedKey
$secondaryWorkspaceKey = (Get-AzOperationalInsightsWorkspaceSharedKey -ResourceGroupName $workloadRg -Name $secondaryLog).PrimarySharedKey
```

</details>

## 11. Create Container Apps environments

Create workload profiles environments with the **Consumption** profile. Use the regional `default` subnet, internal-only networking, and the regional Log Analytics workspace.

<details>
<summary>Azure CLI</summary>

```powershell
az containerapp env create -g $workloadRg -n $primaryEnv -l $primaryLocation --enable-workload-profiles true --infrastructure-subnet-resource-id $primaryDefaultSubnetId --internal-only true --logs-workspace-id $primaryWorkspaceCustomerId --logs-workspace-key $primaryWorkspaceKey --tags $tags
az containerapp env create -g $workloadRg -n $secondaryEnv -l $secondaryLocation --enable-workload-profiles true --infrastructure-subnet-resource-id $secondaryDefaultSubnetId --internal-only true --logs-workspace-id $secondaryWorkspaceCustomerId --logs-workspace-key $secondaryWorkspaceKey --tags $tags
$primaryEnvId = az containerapp env show -g $workloadRg -n $primaryEnv --query id -o tsv
$secondaryEnvId = az containerapp env show -g $workloadRg -n $secondaryEnv --query id -o tsv
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
$consumption = New-AzContainerAppWorkloadProfileObject -Name Consumption -Type Consumption
$primaryEnvObject = New-AzContainerAppManagedEnv -ResourceGroupName $workloadRg -Name $primaryEnv -Location $primaryLocation -WorkloadProfile $consumption -VnetConfigurationInfrastructureSubnetId $primaryDefaultSubnetId -VnetConfigurationInternal -AppLogConfigurationDestination log-analytics -LogAnalyticConfigurationCustomerId $primaryWorkspaceCustomerId -LogAnalyticConfigurationSharedKey $primaryWorkspaceKey -Tag $tags
$secondaryEnvObject = New-AzContainerAppManagedEnv -ResourceGroupName $workloadRg -Name $secondaryEnv -Location $secondaryLocation -WorkloadProfile $consumption -VnetConfigurationInfrastructureSubnetId $secondaryDefaultSubnetId -VnetConfigurationInternal -AppLogConfigurationDestination log-analytics -LogAnalyticConfigurationCustomerId $secondaryWorkspaceCustomerId -LogAnalyticConfigurationSharedKey $secondaryWorkspaceKey -Tag $tags
$primaryEnvId = $primaryEnvObject.Id; $secondaryEnvId = $secondaryEnvObject.Id
```

</details>

## 12. Create Container Apps jobs

Create both jobs as **Manual** with parallelism 1, completions 1, retry 2, timeout 3600, UAMI, registry pull by identity, image digest, 1 CPU, 2 GiB memory, and `DELETE_DESTINATION=false`. Primary source is `https://<primary>.file.core.windows.net/files-primary`; secondary source reverses the direction. `run-sync.sh` supports `DRY_RUN=true` and writes `AZURE_FILES_REPLICATION_SUCCEEDED` for successful real syncs.

<details>
<summary>Azure CLI</summary>

```powershell
$primarySource = "https://$primaryFileStorage.file.core.windows.net/$primaryShare"
$primaryDestination = "https://$secondaryFileStorage.file.core.windows.net/$secondaryShare"
$secondarySource = $primaryDestination; $secondaryDestination = $primarySource
az containerapp job create -g $workloadRg -n $primaryJob -l $primaryLocation --environment $primaryEnvId --trigger-type Manual --replica-timeout 3600 --replica-retry-limit 2 --parallelism 1 --replica-completion-count 1 --image $image --cpu 1.0 --memory 2Gi --workload-profile-name Consumption --mi-user-assigned $primaryIdentityId --registry-server $registryServer --registry-identity $primaryIdentityId --env-vars SOURCE_FILE_URL=$primarySource DESTINATION_FILE_URL=$primaryDestination AZCOPY_MSI_CLIENT_ID=$primaryClientId DELETE_DESTINATION=false --tags $tags
az containerapp job create -g $workloadRg -n $secondaryJob -l $secondaryLocation --environment $secondaryEnvId --trigger-type Manual --replica-timeout 3600 --replica-retry-limit 2 --parallelism 1 --replica-completion-count 1 --image $image --cpu 1.0 --memory 2Gi --workload-profile-name Consumption --mi-user-assigned $secondaryIdentityId --registry-server $registryServer --registry-identity $secondaryIdentityId --env-vars SOURCE_FILE_URL=$secondarySource DESTINATION_FILE_URL=$secondaryDestination AZCOPY_MSI_CLIENT_ID=$secondaryClientId DELETE_DESTINATION=false --tags $tags
$primaryJobId = az containerapp job show -g $workloadRg -n $primaryJob --query id -o tsv
$secondaryJobId = az containerapp job show -g $workloadRg -n $secondaryJob --query id -o tsv
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
$primarySource = "https://$primaryFileStorage.file.core.windows.net/$primaryShare"; $primaryDestination = "https://$secondaryFileStorage.file.core.windows.net/$secondaryShare"
$secondarySource = $primaryDestination; $secondaryDestination = $primarySource
$primaryEnvVars = @(New-AzContainerAppEnvironmentVarObject -Name SOURCE_FILE_URL -Value $primarySource; New-AzContainerAppEnvironmentVarObject -Name DESTINATION_FILE_URL -Value $primaryDestination; New-AzContainerAppEnvironmentVarObject -Name AZCOPY_MSI_CLIENT_ID -Value $primaryClientId; New-AzContainerAppEnvironmentVarObject -Name DELETE_DESTINATION -Value false)
$secondaryEnvVars = @(New-AzContainerAppEnvironmentVarObject -Name SOURCE_FILE_URL -Value $secondarySource; New-AzContainerAppEnvironmentVarObject -Name DESTINATION_FILE_URL -Value $secondaryDestination; New-AzContainerAppEnvironmentVarObject -Name AZCOPY_MSI_CLIENT_ID -Value $secondaryClientId; New-AzContainerAppEnvironmentVarObject -Name DELETE_DESTINATION -Value false)
$primaryContainer = New-AzContainerAppTemplateObject -Name azcopy -Image $image -Env $primaryEnvVars -ResourceCpu 1.0 -ResourceMemory 2Gi
$secondaryContainer = New-AzContainerAppTemplateObject -Name azcopy -Image $image -Env $secondaryEnvVars -ResourceCpu 1.0 -ResourceMemory 2Gi
$primaryRegistry = New-AzContainerAppRegistryCredentialObject -Server $registryServer -Identity $primaryIdentityId
$secondaryRegistry = New-AzContainerAppRegistryCredentialObject -Server $registryServer -Identity $secondaryIdentityId
$primaryJobObject = New-AzContainerAppJob -ResourceGroupName $workloadRg -Name $primaryJob -Location $primaryLocation -EnvironmentId $primaryEnvId -WorkloadProfileName Consumption -ConfigurationTriggerType Manual -ConfigurationReplicaTimeout 3600 -ConfigurationReplicaRetryLimit 2 -ManualTriggerConfigParallelism 1 -ManualTriggerConfigReplicaCompletionCount 1 -UserAssignedIdentity $primaryIdentityId -ConfigurationRegistry $primaryRegistry -TemplateContainer $primaryContainer -Tag $tags
$secondaryJobObject = New-AzContainerAppJob -ResourceGroupName $workloadRg -Name $secondaryJob -Location $secondaryLocation -EnvironmentId $secondaryEnvId -WorkloadProfileName Consumption -ConfigurationTriggerType Manual -ConfigurationReplicaTimeout 3600 -ConfigurationReplicaRetryLimit 2 -ManualTriggerConfigParallelism 1 -ManualTriggerConfigReplicaCompletionCount 1 -UserAssignedIdentity $secondaryIdentityId -ConfigurationRegistry $secondaryRegistry -TemplateContainer $secondaryContainer -Tag $tags
$primaryJobId = $primaryJobObject.Id; $secondaryJobId = $secondaryJobObject.Id
```

</details>

## 13. Create monitoring and alerts

Create an action group with short name `file-repl`, email receivers, and common alert schema. Create per-job metric alerts on `Microsoft.App/jobs` metric `Executions`, aggregation **Total**, dimension `state = Failed`, threshold `> 0`, severity 1, frequency 1 minute, window 5 minutes.

Create a freshness log search alert for each job with this KQL, without the grace lines used by the Bicep template. Replace `<job-name>` with that alert's job, so that each alert counts only its own job's successes, even in a shared workspace:

```kusto
ContainerAppConsoleLogs_CL
| where TimeGenerated >= ago(30m)
| where ContainerJobName_s == "<job-name>"
| where Log_s contains "AZURE_FILES_REPLICATION_SUCCEEDED"
| summarize SuccessCount = count()
```

Keep both freshness alerts disabled until the first successful run. Then enable only the active region's rule; keep the standby rule disabled.

<details>
<summary>Azure CLI</summary>

```powershell
$actionGroupId = az monitor action-group create -g $workloadRg -n $actionGroup --short-name file-repl --action email ops $alertEmail usecommonalertschema --tags $tags --query id -o tsv
az monitor metrics alert create -g $workloadRg -n "alert-replication-failed-primary-$suffix" --scopes $primaryJobId --severity 1 --evaluation-frequency 1m --window-size 5m --auto-mitigate true --target-resource-type Microsoft.App/jobs --target-resource-region $primaryLocation --condition "total Executions > 0 where state includes Failed" --action $actionGroupId --tags $tags
az monitor metrics alert create -g $workloadRg -n "alert-replication-failed-secondary-$suffix" --scopes $secondaryJobId --severity 1 --evaluation-frequency 1m --window-size 5m --auto-mitigate true --target-resource-type Microsoft.App/jobs --target-resource-region $secondaryLocation --condition "total Executions > 0 where state includes Failed" --action $actionGroupId --tags $tags
$freshnessQueries = @{}; foreach ($job in $primaryJob, $secondaryJob) { $freshnessQueries[$job] = "ContainerAppConsoleLogs_CL | where TimeGenerated >= ago($($lagMinutes)m) | where ContainerJobName_s == '$job' | where Log_s contains 'AZURE_FILES_REPLICATION_SUCCEEDED' | summarize SuccessCount = count()" }
$freshnessCondition = "max 'SuccessCount' from 'Freshness' < 1 at least 1 violations out of 1 aggregated points"
az monitor scheduled-query create -g $workloadRg -n "alert-replication-stale-primary-$suffix" -l $primaryLocation --scopes $primaryWorkspaceId --severity 2 --evaluation-frequency 10m --window-size "$($lagMinutes)m" --auto-mitigate true --skip-query-validation true --disabled true --action-groups $actionGroupId --condition $freshnessCondition --condition-query Freshness="$($freshnessQueries[$primaryJob])" --tags $tags
az monitor scheduled-query create -g $workloadRg -n "alert-replication-stale-secondary-$suffix" -l $secondaryLocation --scopes $secondaryWorkspaceId --severity 2 --evaluation-frequency 10m --window-size "$($lagMinutes)m" --auto-mitigate true --skip-query-validation true --disabled true --action-groups $actionGroupId --condition $freshnessCondition --condition-query Freshness="$($freshnessQueries[$secondaryJob])" --tags $tags
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
$emailReceiver = New-AzActionGroupEmailReceiverObject -Name ops -EmailAddress $alertEmail -UseCommonAlertSchema $true
$actionGroupObject = New-AzActionGroup -ResourceGroupName $workloadRg -Name $actionGroup -Location Global -GroupShortName file-repl -EmailReceiver $emailReceiver -Enabled -Tag $tags
$actionGroupId = $actionGroupObject.Id
$failedDimension = New-AzMetricAlertRuleV2DimensionSelection -DimensionName state -ValuesToInclude Failed
$failedCriteria = New-AzMetricAlertRuleV2Criteria -MetricNamespace Microsoft.App/jobs -MetricName Executions -TimeAggregation Total -Operator GreaterThan -Threshold 0 -DimensionSelection $failedDimension -SkipMetricValidation:$false
Add-AzMetricAlertRuleV2 -ResourceGroupName $workloadRg -Name "alert-replication-failed-primary-$suffix" -TargetResourceId $primaryJobId -TargetResourceType Microsoft.App/jobs -TargetResourceRegion $primaryLocation -WindowSize ([TimeSpan]::FromMinutes(5)) -Frequency ([TimeSpan]::FromMinutes(1)) -Severity 1 -Condition $failedCriteria -ActionGroupId $actionGroupId -AutoMitigate $true
Add-AzMetricAlertRuleV2 -ResourceGroupName $workloadRg -Name "alert-replication-failed-secondary-$suffix" -TargetResourceId $secondaryJobId -TargetResourceType Microsoft.App/jobs -TargetResourceRegion $secondaryLocation -WindowSize ([TimeSpan]::FromMinutes(5)) -Frequency ([TimeSpan]::FromMinutes(1)) -Severity 1 -Condition $failedCriteria -ActionGroupId $actionGroupId -AutoMitigate $true
$freshnessQueries = @{}; foreach ($job in $primaryJob, $secondaryJob) { $freshnessQueries[$job] = "ContainerAppConsoleLogs_CL | where TimeGenerated >= ago($($lagMinutes)m) | where ContainerJobName_s == '$job' | where Log_s contains 'AZURE_FILES_REPLICATION_SUCCEEDED' | summarize SuccessCount = count()" }
$freshnessConditions = @{}; foreach ($job in $primaryJob, $secondaryJob) { $freshnessConditions[$job] = New-AzScheduledQueryRuleConditionObject -Query $freshnessQueries[$job] -TimeAggregation Maximum -MetricMeasureColumn SuccessCount -Operator LessThan -Threshold 1 -FailingPeriodNumberOfEvaluationPeriod 1 -FailingPeriodMinFailingPeriodsToAlert 1 }
New-AzScheduledQueryRule -ResourceGroupName $workloadRg -Name "alert-replication-stale-primary-$suffix" -Location $primaryLocation -Scope $primaryWorkspaceId -Severity 2 -WindowSize ([TimeSpan]::FromMinutes($lagMinutes)) -EvaluationFrequency ([TimeSpan]::FromMinutes(10)) -CriterionAllOf $freshnessConditions[$primaryJob] -ActionGroupResourceId $actionGroupId -SkipQueryValidation -Enabled:$false -Tag $tags
New-AzScheduledQueryRule -ResourceGroupName $workloadRg -Name "alert-replication-stale-secondary-$suffix" -Location $secondaryLocation -Scope $secondaryWorkspaceId -Severity 2 -WindowSize ([TimeSpan]::FromMinutes($lagMinutes)) -EvaluationFrequency ([TimeSpan]::FromMinutes(10)) -CriterionAllOf $freshnessConditions[$secondaryJob] -ActionGroupResourceId $actionGroupId -SkipQueryValidation -Enabled:$false -Tag $tags
```

</details>

## 14. Validate and enable the schedule

Start the primary job manually. Use `DRY_RUN=true` for a non-writing validation if you start with an override; otherwise run the primary job and confirm `AZURE_FILES_REPLICATION_SUCCEEDED` in logs. Then switch the primary job to `Schedule` with cron `*/10 * * * *` and enable only the primary freshness rule.

<details>
<summary>Azure CLI</summary>

```powershell
az containerapp job start -g $workloadRg -n $primaryJob
az containerapp job execution list -g $workloadRg -n $primaryJob --output table
az containerapp job logs show -g $workloadRg -n $primaryJob --container azcopy --follow
az monitor log-analytics query --workspace $primaryWorkspaceCustomerId --analytics-query "ContainerAppConsoleLogs_CL | where ContainerJobName_s == '$primaryJob' and Log_s has 'AZURE_FILES_REPLICATION' | project TimeGenerated, Log_s | order by TimeGenerated desc | take 10" --output table
az containerapp job update -g $workloadRg -n $primaryJob --trigger-type Schedule --cron-expression $scheduleCron --replica-timeout 3600 --replica-retry-limit 2 --parallelism 1 --replica-completion-count 1
az monitor scheduled-query update -g $workloadRg -n "alert-replication-stale-primary-$suffix" --disabled false
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
Start-AzContainerAppJob -ResourceGroupName $workloadRg -Name $primaryJob
Update-AzContainerAppJob -ResourceGroupName $workloadRg -Name $primaryJob -ConfigurationTriggerType Schedule -ScheduleTriggerConfigCronExpression $scheduleCron -ScheduleTriggerConfigParallelism 1 -ScheduleTriggerConfigReplicaCompletionCount 1 -ConfigurationReplicaTimeout 3600 -ConfigurationReplicaRetryLimit 2
New-AzScheduledQueryRule -ResourceGroupName $workloadRg -Name "alert-replication-stale-primary-$suffix" -Location $primaryLocation -Scope $primaryWorkspaceId -Severity 2 -WindowSize ([TimeSpan]::FromMinutes($lagMinutes)) -EvaluationFrequency ([TimeSpan]::FromMinutes(10)) -CriterionAllOf $freshnessConditions[$primaryJob] -ActionGroupResourceId $actionGroupId -SkipQueryValidation -Enabled -Tag $tags
```

</details>

## 15. Switch direction or fail over

Fence writes first. Confirm neither job has a running execution. Change primary to `Manual`, secondary to `Schedule`, disable the primary freshness alert, and enable the secondary freshness alert. Failback reverses those changes. `scripts/switch-direction.ps1` redeploys templates, so portal-built environments use these manual steps. Read [Switch direction](../../README.md#switch-direction).

<details>
<summary>Azure CLI</summary>

```powershell
az containerapp job execution list -g $workloadRg -n $primaryJob --query "[?properties.status=='Running']" --output table
az containerapp job execution list -g $workloadRg -n $secondaryJob --query "[?properties.status=='Running']" --output table
az containerapp job update -g $workloadRg -n $primaryJob --trigger-type Manual --replica-timeout 3600 --replica-retry-limit 2 --parallelism 1 --replica-completion-count 1
az containerapp job update -g $workloadRg -n $secondaryJob --trigger-type Schedule --cron-expression $scheduleCron --replica-timeout 3600 --replica-retry-limit 2 --parallelism 1 --replica-completion-count 1
az monitor scheduled-query update -g $workloadRg -n "alert-replication-stale-primary-$suffix" --disabled true
az monitor scheduled-query update -g $workloadRg -n "alert-replication-stale-secondary-$suffix" --disabled false
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
Update-AzContainerAppJob -ResourceGroupName $workloadRg -Name $primaryJob -ConfigurationTriggerType Manual -ManualTriggerConfigParallelism 1 -ManualTriggerConfigReplicaCompletionCount 1 -ConfigurationReplicaTimeout 3600 -ConfigurationReplicaRetryLimit 2
Update-AzContainerAppJob -ResourceGroupName $workloadRg -Name $secondaryJob -ConfigurationTriggerType Schedule -ScheduleTriggerConfigCronExpression $scheduleCron -ScheduleTriggerConfigParallelism 1 -ScheduleTriggerConfigReplicaCompletionCount 1 -ConfigurationReplicaTimeout 3600 -ConfigurationReplicaRetryLimit 2
New-AzScheduledQueryRule -ResourceGroupName $workloadRg -Name "alert-replication-stale-primary-$suffix" -Location $primaryLocation -Scope $primaryWorkspaceId -Severity 2 -WindowSize ([TimeSpan]::FromMinutes($lagMinutes)) -EvaluationFrequency ([TimeSpan]::FromMinutes(10)) -CriterionAllOf $freshnessConditions[$primaryJob] -ActionGroupResourceId $actionGroupId -SkipQueryValidation -Enabled:$false -Tag $tags
New-AzScheduledQueryRule -ResourceGroupName $workloadRg -Name "alert-replication-stale-secondary-$suffix" -Location $secondaryLocation -Scope $secondaryWorkspaceId -Severity 2 -WindowSize ([TimeSpan]::FromMinutes($lagMinutes)) -EvaluationFrequency ([TimeSpan]::FromMinutes(10)) -CriterionAllOf $freshnessConditions[$secondaryJob] -ActionGroupResourceId $actionGroupId -SkipQueryValidation -Enabled -Tag $tags
```

</details>

## 16. Clean up

Deleting the resource groups deletes private endpoints, jobs, identities, registry, workspaces, DNS zones, storage accounts, shares, and data. Back up required data first. In the portal, open each resource group and select **Delete resource group**.

<details>
<summary>Azure CLI</summary>

```powershell
# Delete the primary DNS, secondary DNS, and workload resource groups after backing up data.
# Example: az group delete --name <resource-group-name> --yes
```

</details>

<details>
<summary>Azure PowerShell</summary>

```powershell
# Delete the primary DNS, secondary DNS, and workload resource groups after backing up data.
# Example: use Remove-AzResourceGroup with -Name <resource-group-name> and -Force.
```

</details>

## Reuse existing services

Skip only the steps your existing services already satisfy.

| Existing service | Skip | Still verify |
| --- | --- | --- |
| Storage and shares | Step 5 account/share creation | Accounts and shares exist; identities can access data; both job VNets resolve and reach both accounts privately. |
| VNets and subnets | Step 3 VNet creation | The job subnet is empty, delegated to `Microsoft.App/environments`, and at least `/27`; private endpoint subnet policies are disabled. |
| DNS zones | Step 4 zone creation | Each job VNet links to the correct zone set. |
| Private endpoints | Step 7 rows already present | Each job VNet has endpoints for both file accounts and, when needed, the registry. |
| Registry | Step 6 registry creation | The digest-pinned image exists and both identities can pull it. |

Server-side copy requires each job VNet to have private endpoints for **both** storage accounts with DNS resolving to them, or the two storage-account VNets must be directly peered. Hub or Virtual WAN transit fails with `403 CannotVerifyCopySource`; see [Network requirements for server-side copy](../../README.md#network-requirements-for-server-side-copy).

A VNet can link only one private DNS zone of a given name. Do not add a second endpoint record into a shared central `privatelink.file.core.windows.net` zone for the same account, because other workloads can resolve to the wrong endpoint. For automated, audited existing-resource deployment, use [deploy/bicep](../bicep/README.md).

## Next steps

- [Verify a deployment](../../README.md#verify-a-deployment)
- [Monitoring and alerts](../../README.md#monitoring-and-alerts)
- [Troubleshooting](../../README.md#troubleshooting)
- [Terraform deployment](../terraform/README.md)
- [Bicep deployment](../bicep/README.md)

