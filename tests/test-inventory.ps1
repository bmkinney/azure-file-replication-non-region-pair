$ErrorActionPreference = 'Stop'

# Runs scripts/inventory.ps1 against canned Azure CLI responses; no Azure calls are made.

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$inventoryScript = Join-Path $repositoryRoot 'scripts/inventory.ps1'
$realAz = (Get-Command az -CommandType Application | Select-Object -First 1).Source
$subscription = '/subscriptions/00000000-0000-0000-0000-000000000000'
$fakeAzRules = @()

function az {
    $joined = $args -join ' '
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

function Invoke-Inventory([string]$ParametersFile) {
    $reportPath = Join-Path ([IO.Path]::GetTempPath()) "inventory-report-$([guid]::NewGuid().ToString('N')).json"
    try {
        & $inventoryScript -ParametersFile $ParametersFile -OutputPath $reportPath 6> $null
        return Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
    } finally {
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    }
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
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Inventory script checks passed.'
