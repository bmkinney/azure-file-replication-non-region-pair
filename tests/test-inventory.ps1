$ErrorActionPreference = 'Stop'

# Runs scripts/inventory.ps1 against canned Azure CLI responses; no Azure calls are made.

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$inventoryScript = Join-Path $repositoryRoot 'scripts/inventory.ps1'
$realAz = (Get-Command az -CommandType Application | Select-Object -First 1).Source
$subscription = '/subscriptions/00000000-0000-0000-0000-000000000000'
$fakeAzRules = @()
$global:InventoryAzCalls = [System.Collections.Generic.List[string]]::new()

function az {
    $joined = $args -join ' '
    $global:InventoryAzCalls.Add($joined)
    if ($args[0] -eq 'bicep') {
        & $realAz @args
        return
    }
    foreach ($rule in $fakeAzRules) {
        if ($joined -like $rule.Pattern) {
            $global:LASTEXITCODE = 0
            return (ConvertTo-Json -InputObject $rule.Response -Depth 20 -Compress)
        }
    }
    $global:LASTEXITCODE = 3
    Write-Error "ERROR: (ResourceNotFound) No test fixture for: $joined" -ErrorAction Continue
}

function New-Rule([string]$Pattern, $Response) {
    [pscustomobject]@{ Pattern = $Pattern; Response = $Response }
}

function Invoke-Inventory([string]$ParametersFile, [string[]]$ParameterOverrides = @()) {
    $reportPath = Join-Path ([IO.Path]::GetTempPath()) "inventory-report-$([guid]::NewGuid().ToString('N')).json"
    $global:InventoryAzCalls.Clear()
    try {
        & $inventoryScript -ParametersFile $ParametersFile -OutputPath $reportPath -ParameterOverrides $ParameterOverrides 6> $null
        return Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
    } finally {
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    }
}

function Get-WhatIfCall {
    return @($global:InventoryAzCalls | Where-Object { $_ -like 'deployment sub what-if*' }) | Select-Object -First 1
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "inventory check failed: $Message"
    }
}

function Get-Status($Report, [string]$ItemPattern) {
    return @($Report.Prerequisites | Where-Object { $_.Item -like $ItemPattern } | ForEach-Object { $_.Status })
}

$commonRules = @(
    (New-Rule 'account show*' @{ id = '00000000-0000-0000-0000-000000000000'; name = 'Test subscription'; tenantId = '11111111-1111-1111-1111-111111111111' }),
    (New-Rule 'cloud show*' @{ suffixes = @{ storageEndpoint = 'core.windows.net' } }),
    (New-Rule 'provider show --namespace*' @{
        registrationState = 'Registered'
        resourceTypes     = @(@{ resourceType = 'managedEnvironments'; locations = @('South Central US', 'West US', 'West US 2', 'North Central US') })
    })
)

# Greenfield: every resource is new.
$fakeAzRules = $commonRules + @(
    (New-Rule 'rest --method get --url *Microsoft.Storage/skus*' @{ value = @(
        @{ name = 'Standard_ZRS'; kind = 'StorageV2'; locations = @('southcentralus'); restrictions = @() },
        @{ name = 'Standard_LRS'; kind = 'StorageV2'; locations = @('westus'); restrictions = @() }
    ) }),
    (New-Rule 'deployment sub what-if*' @{ status = 'Succeeded'; changes = @(
        @{ changeType = 'Create'; resourceId = "$subscription/resourceGroups/rg-azure-files-replication-demo" },
        @{ changeType = 'Create'; resourceId = "$subscription/resourceGroups/rg-azure-files-replication-demo/providers/Microsoft.App/jobs/job-sync-primary" },
        @{ changeType = 'Create'; resourceId = "$subscription/resourceGroups/rg-azure-files-replication-demo/providers/Microsoft.Storage/storageAccounts/stfileprimary/providers/Microsoft.Authorization/roleAssignments/role-1" }
    ) })
)
$report = Invoke-Inventory (Join-Path $repositoryRoot 'infra/main.bicepparam')
Assert-True ($report.Profile -like 'greenfield*') 'main.bicepparam must be detected as the greenfield profile'
Assert-True ($report.Summary.ResourcesToProvision -eq 3) "greenfield resources to provision were $($report.Summary.ResourcesToProvision)"
Assert-True ((Get-Status $report 'Standard_ZRS in southcentralus') -contains 'Ready') 'ZRS availability was not reported as ready'
Assert-True ((Get-Status $report 'alertEmailAddresses') -contains 'Warning') 'the example alert address was not flagged'
$roleAssignment = @($report.Resources | Where-Object Type -eq 'Microsoft.Authorization/roleAssignments')
Assert-True ($roleAssignment.Count -eq 1 -and $roleAssignment[0].Name -eq 'role-1 on stfileprimary') 'role assignment scope was not described'
Assert-True ((Get-WhatIfCall) -notlike '*--parameters activeRegion*') 'what-if must not add parameters when no overrides are given'

# Overrides reach what-if as extra --parameters values; names the template doesn't declare are dropped.
$report = Invoke-Inventory (Join-Path $repositoryRoot 'infra/main.bicepparam') @('activeRegion=primary', 'acrPublicNetworkAccess=Disabled', 'notDeclared=1')
$whatIfCall = Get-WhatIfCall
Assert-True ($whatIfCall -like '*--parameters activeRegion=primary acrPublicNetworkAccess=Disabled --result-format*') "what-if did not receive the overrides: $whatIfCall"
Assert-True ($whatIfCall -notlike '*notDeclared*') 'an undeclared override was passed to what-if'
Assert-True ((@($report.ParameterOverrides) -join ',') -eq 'activeRegion=primary,acrPublicNetworkAccess=Disabled') "report overrides were $(@($report.ParameterOverrides) -join ',')"
$invalidOverrideRejected = $false
try {
    Invoke-Inventory (Join-Path $repositoryRoot 'infra/main.bicepparam') @('activeRegion') | Out-Null
} catch {
    $invalidOverrideRejected = $_.Exception.Message -match 'name=value'
}
Assert-True $invalidOverrideRejected 'an override without a value was accepted'

# Existing resources: copy the templates so the test parameter file can reference them.
$workRoot = Join-Path ([IO.Path]::GetTempPath()) "inventory-test-$([guid]::NewGuid().ToString('N'))"
Copy-Item -Path (Join-Path $repositoryRoot 'infra') -Destination $workRoot -Recurse
$parametersFile = Join-Path $workRoot 'existing.test.bicepparam'
$digest = 'a' * 64
@"
using './existing.bicep'

param resourceGroupName = 'rg-replication-test'
param resourceGroupLocation = 'westus2'
param primaryLocation = 'westus2'
param secondaryLocation = 'northcentralus'
param primaryRegionCode = 'pri'
param secondaryRegionCode = 'sec'
param primaryStorageAccountName = 'stprimarytest'
param primaryStorageResourceGroupName = 'rg-storage-primary'
param primaryFileShareName = 'share'
param secondaryStorageAccountName = 'stsecondarytest'
param secondaryStorageResourceGroupName = 'rg-storage-secondary'
param secondaryFileShareName = 'share'
param primaryVnetName = 'vnet-primary'
param primaryVnetResourceGroupName = 'rg-network-primary'
param primaryInfrastructureSubnetName = 'snet-jobs'
param secondaryVnetName = 'vnet-secondary'
param secondaryVnetResourceGroupName = 'rg-network-secondary'
param secondaryInfrastructureSubnetName = 'snet-jobs'
param registryName = 'acrtest'
param registryResourceGroupName = 'rg-registry'
param existingPrivateEndpointIds = ['$subscription/resourceGroups/rg-network-primary/providers/Microsoft.Network/privateEndpoints/pe-primary-file-a']
param containerImage = 'acrtest.azurecr.io/azure-files-dr-azcopy@sha256:$digest'
param alertEmailAddresses = ['alerts@replication.test']
"@ | Set-Content -LiteralPath $parametersFile -Encoding utf8

function Get-ExistingRules([string[]]$PrimaryEndpoints, [string[]]$SecondaryEndpoints) {
    $vnetPrimary = "$subscription/resourceGroups/rg-network-primary/providers/Microsoft.Network/virtualNetworks/vnet-primary"
    $vnetSecondary = "$subscription/resourceGroups/rg-network-secondary/providers/Microsoft.Network/virtualNetworks/vnet-secondary"
    $endpoints = @{
        'pe-primary-file-a'   = @{ Vnet = $vnetPrimary; Group = 'file'; Ip = '10.1.2.4' }
        'pe-secondary-file-a' = @{ Vnet = $vnetPrimary; Group = 'file'; Ip = '10.1.2.5' }
        'pe-acr-a'            = @{ Vnet = $vnetPrimary; Group = 'registry'; Ip = '10.1.2.6' }
        'pe-secondary-file-b' = @{ Vnet = $vnetSecondary; Group = 'file'; Ip = '10.2.2.4' }
        'pe-primary-file-b'   = @{ Vnet = $vnetSecondary; Group = 'file'; Ip = '10.2.2.5' }
        'pe-acr-b'            = @{ Vnet = $vnetSecondary; Group = 'registry'; Ip = '10.2.2.6' }
    }
    function Get-Connections([string[]]$Names) {
        @($Names | ForEach-Object { @{ privateEndpoint = @{ id = "$subscription/resourceGroups/rg-network/providers/Microsoft.Network/privateEndpoints/$_" }; privateLinkServiceConnectionState = @{ status = 'Approved' } } })
    }

    $rules = @(
        (New-Rule 'storage account show --name stprimarytest*' @{ location = 'westus2'; kind = 'StorageV2'; sku = @{ name = 'Standard_ZRS' }; publicNetworkAccess = 'Disabled'; privateEndpointConnections = (Get-Connections $PrimaryEndpoints) }),
        (New-Rule 'storage account show --name stsecondarytest*' @{ location = 'northcentralus'; kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }; publicNetworkAccess = 'Disabled'; privateEndpointConnections = (Get-Connections $SecondaryEndpoints) }),
        (New-Rule 'storage share-rm show --resource-group rg-storage-primary*' @{ enabledProtocols = 'SMB'; shareQuota = 100; shareUsageBytes = 1073741824 }),
        (New-Rule 'storage share-rm show --resource-group rg-storage-secondary*' @{ enabledProtocols = 'SMB'; shareQuota = 100; shareUsageBytes = 0 }),
        (New-Rule 'network vnet show --resource-group rg-network-primary*' @{ id = $vnetPrimary; location = 'westus2'; dhcpOptions = @{ dnsServers = @() }; virtualNetworkPeerings = @() }),
        (New-Rule 'network vnet show --resource-group rg-network-secondary*' @{ id = $vnetSecondary; location = 'northcentralus'; dhcpOptions = @{ dnsServers = @() }; virtualNetworkPeerings = @() }),
        (New-Rule 'network vnet subnet show*' @{ addressPrefix = '10.0.0.0/23'; delegations = @(@{ serviceName = 'Microsoft.App/environments' }); serviceAssociationLinks = @() }),
        (New-Rule 'acr show --name acrtest*' @{ loginServer = 'acrtest.azurecr.io'; sku = @{ name = 'Premium' }; publicNetworkAccess = 'Disabled'; privateEndpointConnections = (Get-Connections @('pe-acr-a', 'pe-acr-b')) }),
        (New-Rule 'acr manifest show-metadata*' @{ digest = "sha256:$digest" }),
        (New-Rule 'network private-dns zone list*' @(
            @{ name = 'privatelink.file.core.windows.net'; resourceGroup = 'rg-dns-primary' },
            @{ name = 'privatelink.file.core.windows.net'; resourceGroup = 'rg-dns-secondary' }
        )),
        (New-Rule 'network private-dns link vnet list --resource-group rg-dns-primary *' @(@{ virtualNetwork = @{ id = $vnetPrimary } })),
        (New-Rule 'network private-dns link vnet list --resource-group rg-dns-secondary *' @(@{ virtualNetwork = @{ id = $vnetSecondary } })),
        (New-Rule 'network private-dns record-set a show --resource-group rg-dns-primary * --name stprimarytest*' @{ aRecords = @(@{ ipv4Address = '10.1.2.4' }) }),
        (New-Rule 'network private-dns record-set a show --resource-group rg-dns-primary * --name stsecondarytest*' @{ aRecords = @(@{ ipv4Address = '10.1.2.5' }) }),
        (New-Rule 'network private-dns record-set a show --resource-group rg-dns-secondary * --name stsecondarytest*' @{ aRecords = @(@{ ipv4Address = '10.2.2.4' }) }),
        (New-Rule 'network private-dns record-set a show --resource-group rg-dns-secondary * --name stprimarytest*' @{ aRecords = @(@{ ipv4Address = '10.2.2.5' }) }),
        (New-Rule 'deployment sub what-if*' @{ status = 'Succeeded'; changes = @(
            @{ changeType = 'Create'; resourceId = "$subscription/resourceGroups/rg-replication-test/providers/Microsoft.App/jobs/job-sync-pri" },
            @{ changeType = 'NoChange'; resourceId = "$subscription/resourceGroups/rg-replication-test" }
        ) })
    )
    foreach ($name in $endpoints.Keys) {
        $endpoint = $endpoints[$name]
        $rules += New-Rule "network private-endpoint show --ids */$name *" @{
            subnet                       = @{ id = "$($endpoint.Vnet)/subnets/snet-endpoints" }
            privateLinkServiceConnections = @(@{ groupIds = @($endpoint.Group) })
            networkInterfaces            = @(@{ id = "$subscription/resourceGroups/rg-network/providers/Microsoft.Network/networkInterfaces/nic-$name" })
        }
        $rules += New-Rule "network nic show --ids */nic-$name *" @{ ipConfigurations = @(@{ privateIPAddress = $endpoint.Ip }) }
    }
    return $rules
}

try {
    $fakeAzRules = $commonRules + (Get-ExistingRules -PrimaryEndpoints @('pe-primary-file-a', 'pe-primary-file-b') -SecondaryEndpoints @('pe-secondary-file-a', 'pe-secondary-file-b'))
    $report = Invoke-Inventory $parametersFile
    Assert-True ($report.Profile -like 'existing*') 'the test parameter file must be detected as the existing-resource profile'
    Assert-True ((Get-Status $report 'primary job copy path*') -contains 'Ready') 'the local-endpoint layout was not accepted for the primary job'
    Assert-True ((Get-Status $report 'secondary job copy path*') -contains 'Ready') 'the local-endpoint layout was not accepted for the secondary job'
    Assert-True (@(Get-Status $report '*DNS for file endpoints*' | Where-Object { $_ -ne 'Ready' }).Count -eq 0) 'DNS records that match local endpoints were not accepted'
    Assert-True ((Get-Status $report 'containerImage') -contains 'Ready') 'the digest-pinned image was not accepted'
    Assert-True ($report.Summary.PrerequisitesActionRequired -eq 0) "unexpected action items: $(@($report.Prerequisites | Where-Object Status -eq 'Action required' | ForEach-Object Item) -join '; ')"
    Assert-True ($report.Summary.ResourcesToProvision -eq 1 -and $report.Summary.ResourcesExisting -eq 1) 'what-if results were not classified'

    $fakeAzRules = $commonRules + (Get-ExistingRules -PrimaryEndpoints @('pe-primary-file-a') -SecondaryEndpoints @('pe-secondary-file-b'))
    $report = Invoke-Inventory $parametersFile
    Assert-True ((Get-Status $report 'primary job copy path*') -contains 'Action required') 'a hub-only primary copy path was accepted'
    Assert-True ((Get-Status $report 'secondary job copy path*') -contains 'Action required') 'a hub-only secondary copy path was accepted'

    # Workload profiles environments accept an existing delegated subnet down to /27.
    $subnetRules = @(
        (New-Rule 'network vnet subnet show --resource-group rg-network-primary *' @{ addressPrefix = '10.1.4.0/26'; delegations = @(@{ serviceName = 'Microsoft.App/environments' }); serviceAssociationLinks = @() }),
        (New-Rule 'network vnet subnet show --resource-group rg-network-secondary *' @{ addressPrefix = '10.2.4.0/28'; delegations = @(@{ serviceName = 'Microsoft.App/environments' }); serviceAssociationLinks = @() })
    )
    $fakeAzRules = $commonRules + $subnetRules + (Get-ExistingRules -PrimaryEndpoints @('pe-primary-file-a', 'pe-primary-file-b') -SecondaryEndpoints @('pe-secondary-file-a', 'pe-secondary-file-b'))
    $report = Invoke-Inventory $parametersFile
    Assert-True ((Get-Status $report 'primary Container Apps subnet snet-jobs') -contains 'Ready') 'a delegated /26 subnet was not accepted'
    Assert-True ((Get-Status $report 'secondary Container Apps subnet snet-jobs') -contains 'Action required') 'a delegated /28 subnet was accepted'

    # Reuse or create: a new secondary account, VNet, and registry, plus a new job subnet in the existing primary VNet.
    $hybridParametersFile = Join-Path $workRoot 'hybrid.test.bicepparam'
    $vnetPrimary = "$subscription/resourceGroups/rg-network-primary/providers/Microsoft.Network/virtualNetworks/vnet-primary"
    function Set-HybridParameters([string]$SubnetPrefix) {
        @"
using './existing.bicep'

param resourceGroupName = 'rg-replication-test'
param resourceGroupLocation = 'westus2'
param primaryLocation = 'westus2'
param secondaryLocation = 'northcentralus'
param primaryRegionCode = 'pri'
param secondaryRegionCode = 'sec'
param primaryStorageAccountName = 'stprimarytest'
param primaryStorageResourceGroupName = 'rg-storage-primary'
param primaryFileShareName = 'share'
param secondaryStorageMode = 'new'
param secondaryStorageAccountName = 'stnewsecondary'
param primaryNetworkMode = 'newSubnet'
param primaryVnetName = 'vnet-primary'
param primaryVnetResourceGroupName = 'rg-network-primary'
param primaryInfrastructureSubnetPrefix = '$SubnetPrefix'
param primaryPrivateEndpointSubnetName = 'snet-endpoints'
param primaryFileDnsZoneId = '$subscription/resourceGroups/rg-dns-primary/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net'
param secondaryNetworkMode = 'new'
param registryMode = 'new'
param alertEmailAddresses = ['alerts@replication.test']
"@ | Set-Content -LiteralPath $hybridParametersFile -Encoding utf8
    }
    function Get-HybridRules([bool]$NameAvailable) {
        @(
            (New-Rule 'network vnet show --resource-group rg-network-primary*' @{
                id = $vnetPrimary; location = 'westus2'; dhcpOptions = @{ dnsServers = @() }; virtualNetworkPeerings = @()
                addressSpace = @{ addressPrefixes = @('10.1.0.0/16') }
                subnets = @(@{ name = 'snet-jobs-in-use'; addressPrefix = '10.1.0.0/23' }, @{ name = 'snet-endpoints'; addressPrefix = '10.1.2.0/24'; delegations = @() })
            }),
            (New-Rule 'storage account check-name --name stnewsecondary*' @{ nameAvailable = $NameAvailable; message = 'The storage account named stnewsecondary is already taken.' }),
            (New-Rule 'rest --method get --url *Microsoft.Storage/skus*' @{ value = @(@{ name = 'Standard_LRS'; kind = 'StorageV2'; locations = @('northcentralus'); restrictions = @() }) }),
            (New-Rule 'network vnet list*' @(@{ name = 'vnet-primary'; addressSpace = @{ addressPrefixes = @('10.1.0.0/16') } })),
            (New-Rule "network private-dns link vnet list --subscription 00000000-0000-0000-0000-000000000000 --resource-group rg-dns-primary --zone-name privatelink.file.core.windows.net *" @(@{ virtualNetwork = @{ id = $vnetPrimary } }))
        )
    }

    Set-HybridParameters '10.1.4.0/23'
    $fakeAzRules = $commonRules + (Get-HybridRules $true) + (Get-ExistingRules -PrimaryEndpoints @('pe-primary-file-a', 'pe-primary-file-b') -SecondaryEndpoints @())
    $report = Invoke-Inventory $hybridParametersFile
    Assert-True ((Get-Status $report 'secondary account stnewsecondary') -contains 'To be created') 'a new storage account was not reported as to be created'
    Assert-True ((Get-Status $report 'Standard_LRS in northcentralus') -contains 'Ready') 'the new account SKU was not checked'
    Assert-True ((Get-Status $report 'primary Container Apps subnet snet-replication-jobs (new)') -contains 'To be created') 'a free subnet prefix was not accepted'
    Assert-True ((Get-Status $report 'primary endpoint subnet snet-endpoints') -contains 'To be created') 'the endpoint subnet for new endpoints was not checked'
    Assert-True ((Get-Status $report 'primary file DNS zone for new endpoints') -contains 'Ready') 'a linked DNS zone for new endpoints was not accepted'
    Assert-True ((Get-Status $report 'primary registry DNS zone for new endpoints') -contains 'Warning') 'a missing registry DNS zone was not flagged'
    Assert-True ((Get-Status $report 'secondary VNet vnet-replication-sec (new)') -contains 'To be created') 'a new VNet was not reported as to be created'
    Assert-True ((Get-Status $report 'Registry (new)') -contains 'To be created') 'a new registry was not reported as to be created'
    Assert-True ((Get-Status $report 'primary job copy path*') -contains 'Ready') 'an existing source endpoint plus a created destination endpoint was not accepted'
    Assert-True ((Get-Status $report 'secondary job copy path*') -contains 'Ready') 'endpoints created in a new VNet were not accepted'
    Assert-True ((Get-Status $report '*job registry path') -notcontains 'Action required') 'endpoints created for a new registry were not accepted'
    Assert-True ($report.Summary.PrerequisitesActionRequired -eq 0) "unexpected hybrid action items: $(@($report.Prerequisites | Where-Object Status -eq 'Action required' | ForEach-Object Item) -join '; ')"

    Set-HybridParameters '10.1.2.0/25'
    $fakeAzRules = $commonRules + (Get-HybridRules $false) + (Get-ExistingRules -PrimaryEndpoints @('pe-primary-file-a', 'pe-primary-file-b') -SecondaryEndpoints @())
    $report = Invoke-Inventory $hybridParametersFile
    Assert-True ((Get-Status $report 'primary Container Apps subnet snet-replication-jobs (new)') -contains 'Action required') 'an overlapping subnet prefix was accepted'
    Assert-True ((Get-Status $report 'secondary account stnewsecondary') -contains 'Action required') 'an unavailable storage account name was accepted'

    # Resource group layout: new services in their own groups, listed existing groups, and custom names.
    $layoutParametersFile = Join-Path $workRoot 'layout.test.bicepparam'
    @"
using './existing.bicep'

param resourceGroupName = 'rg-replication-test'
param resourceGroupLocation = 'westus2'
param secondaryResourceGroupName = 'rg-replication-sec'
param existingResourceGroups = ['rg-shared', 'rg-missing']
param primaryLocation = 'westus2'
param secondaryLocation = 'northcentralus'
param primaryRegionCode = 'pri'
param secondaryRegionCode = 'PRI'
param primaryStorageMode = 'new'
param primaryStorageAccountName = 'stnewprimary'
param primaryStorageResourceGroupName = 'rg-shared'
param secondaryStorageMode = 'new'
param secondaryStorageResourceGroupName = 'rg-missing'
param primaryNetworkMode = 'new'
param primaryDnsResourceGroupName = 'rg-dns'
param secondaryNetworkMode = 'new'
param secondaryDnsResourceGroupName = 'RG-DNS'
param registryMode = 'new'
param registryResourceGroupName = 'rg-foreign'
param resourceNames = {
  primaryJob: 'Job--Invalid'
  secondaryJob: 'job-sync-secondary'
}
param alertEmailAddresses = ['alerts@replication.test']
"@ | Set-Content -LiteralPath $layoutParametersFile -Encoding utf8
    $fakeAzRules = $commonRules + @(
        (New-Rule 'group show --name rg-shared *' @{ name = 'rg-shared'; tags = @{} }),
        (New-Rule 'group show --name rg-foreign *' @{ name = 'rg-foreign'; tags = @{ Owner = 'another-team' } }),
        (New-Rule 'group show --name rg-dns *' @{ name = 'rg-dns' }),
        (New-Rule 'group show --name rg-replication-test *' @{ name = 'rg-replication-test'; tags = @{ Workload = 'azure-files-dr-replication' } }),
        (New-Rule 'network private-dns zone list --resource-group rg-dns *' @(@{ name = 'privatelink.blob.core.windows.net'; tags = @{} })),
        (New-Rule 'storage account show --name stnewprimary --resource-group rg-shared *' @{ name = 'stnewprimary' }),
        (New-Rule 'rest --method get --url *Microsoft.Storage/skus*' @{ value = @(@{ name = 'Standard_LRS'; kind = 'StorageV2'; locations = @('westus2', 'northcentralus'); restrictions = @() }) })
    )
    $report = Invoke-Inventory $layoutParametersFile
    Assert-True ((Get-Status $report 'Resource group rg-shared') -contains 'Ready') 'a listed existing resource group was not accepted'
    Assert-True ((Get-Status $report 'Resource group rg-missing') -contains 'Action required') 'a listed resource group that does not exist was accepted'
    Assert-True ((Get-Status $report 'Resource group rg-foreign') -contains 'Warning') 'an unlisted existing resource group was not flagged'
    Assert-True ((Get-Status $report 'Resource group rg-replication-test') -contains 'Ready') 'a resource group created by an earlier deployment was not accepted'
    Assert-True ((Get-Status $report 'Resource group rg-replication-sec') -contains 'To be created') 'a new secondary resource group was not reported as to be created'
    Assert-True (@(Get-Status $report 'Resource group *').Count -eq 6) "resource groups were not deduplicated: $(@($report.Prerequisites | Where-Object Item -like 'Resource group *' | ForEach-Object Item) -join '; ')"
    Assert-True ((Get-Status $report 'DNS resource group rg-dns') -contains 'Action required') 'a shared DNS resource group for two new VNets was accepted'
    Assert-True ((Get-Status $report 'primary DNS resource group rg-dns') -contains 'Warning') 'foreign private DNS zones in the DNS resource group were not flagged'
    Assert-True ((Get-Status $report 'Region codes') -contains 'Action required') 'identical region codes were accepted'
    Assert-True ((Get-Status $report "resourceNames.primaryJob 'Job--Invalid'") -contains 'Action required') 'an invalid custom job name was accepted'
    Assert-True (@(Get-Status $report 'resourceNames.secondaryJob*').Count -eq 0) 'a valid custom job name was flagged'
    Assert-True ((Get-Status $report 'primary account stnewprimary') -contains 'Ready') 'a new account was not looked up in its own resource group'
    $secondaryAccount = @($report.Prerequisites | Where-Object Item -eq 'secondary account (new)')
    Assert-True ($secondaryAccount.Count -eq 1 -and $secondaryAccount[0].Status -eq 'To be created' -and $secondaryAccount[0].Detail -like '* in rg-missing.') 'a new account without a name was not placed in its resource group'
    Assert-True ((Get-Status $report 'Registry (new)') -contains 'To be created') 'a new registry in a custom resource group was not reported as to be created'

    # A placeholder that an override replaces no longer blocks lookups and what-if.
    $placeholderFile = Join-Path $workRoot 'existing.placeholder.bicepparam'
    (Get-Content -LiteralPath $parametersFile -Raw) -replace "param containerImage = '[^']+'", "param containerImage = '<existing-acr-login-server>/<repository>@sha256:<digest>'" | Set-Content -LiteralPath $placeholderFile -Encoding utf8
    $fakeAzRules = $commonRules + (Get-ExistingRules -PrimaryEndpoints @('pe-primary-file-a', 'pe-primary-file-b') -SecondaryEndpoints @('pe-secondary-file-a', 'pe-secondary-file-b'))
    $report = Invoke-Inventory $placeholderFile
    Assert-True ((Get-Status $report 'existing.placeholder.bicepparam') -contains 'Action required') 'the placeholder image was not flagged without an override'
    $report = Invoke-Inventory $placeholderFile @("containerImage=acrtest.azurecr.io/azure-files-dr-azcopy@sha256:$digest", 'activeRegion=primary', 'acrPublicNetworkAccess=Disabled')
    Assert-True ((Get-Status $report 'existing.placeholder.bicepparam') -contains 'Ready') 'an overridden placeholder was still reported'
    Assert-True ((Get-Status $report 'containerImage') -contains 'Ready') 'the override image was not checked'
    $whatIfCall = Get-WhatIfCall
    Assert-True ($whatIfCall -like "*--parameters containerImage=acrtest.azurecr.io/azure-files-dr-azcopy@sha256:$digest activeRegion=primary acrPublicNetworkAccess=Disabled --result-format*") "what-if did not receive the existing-profile overrides: $whatIfCall"
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Inventory script checks passed.'
