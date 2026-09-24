$ErrorActionPreference = 'Stop'

# Runs scripts/audit-existing-resources.ps1 against canned Azure CLI responses; no Azure calls are made.

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$auditScript = Join-Path $repositoryRoot 'scripts/audit-existing-resources.ps1'
$realAz = (Get-Command az -CommandType Application | Select-Object -First 1).Source
$subscription = '/subscriptions/00000000-0000-0000-0000-000000000000'
$azCalls = [System.Collections.Generic.List[string]]::new()

function az {
    $joined = $args -join ' '
    $azCalls.Add($joined)
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

function Get-Id([string]$Group, [string]$Type, [string]$Name) {
    return "$subscription/resourceGroups/$Group/providers/$Type/$Name"
}

function New-Endpoint([string]$Name, [string]$Location, [string]$VnetId, [string]$TargetId, [string]$GroupId, [string]$Status) {
    @{
        id                                  = Get-Id 'rg-network' 'Microsoft.Network/privateEndpoints' $Name
        name                                = $Name
        resourceGroup                       = 'rg-network'
        location                            = $Location
        subnet                              = @{ id = "$VnetId/subnets/snet-endpoints" }
        privateLinkServiceConnections       = @(@{ privateLinkServiceId = $TargetId; groupIds = @($GroupId); privateLinkServiceConnectionState = @{ status = $Status } })
        manualPrivateLinkServiceConnections = @()
        networkInterfaces                   = @(@{ id = Get-Id 'rg-network' 'Microsoft.Network/networkInterfaces' "nic-$Name" })
    }
}

function New-NicRule([string]$EndpointName, [object[]]$IpConfigurations) {
    New-Rule "network nic show --ids */nic-$EndpointName *" @{ ipConfigurations = $IpConfigurations }
}

function Invoke-Audit([string[]]$Groups) {
    $reportPath = Join-Path ([IO.Path]::GetTempPath()) "audit-report-$([guid]::NewGuid().ToString('N')).json"
    $azCalls.Clear()
    try {
        if ($Groups) {
            & $auditScript -ResourceGroupName $Groups -OutputPath $reportPath 6> $null
        } else {
            & $auditScript -OutputPath $reportPath 6> $null
        }
        return Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json -Depth 20
    } finally {
        Remove-Item -LiteralPath $reportPath -Force -ErrorAction SilentlyContinue
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "audit check failed: $Message"
    }
}

function Get-Row($Report, [string]$Service, [string]$Name) {
    return @($Report.Services | Where-Object { $_.Service -eq $Service -and $_.Name -eq $Name }) | Select-Object -First 1
}

function Assert-Status($Report, [string]$Service, [string]$Name, [string]$Expected) {
    $row = Get-Row $Report $Service $Name
    Assert-True ($null -ne $row) "$Service $Name was not reported"
    Assert-True ($row.Status -eq $Expected) "$Service $Name was '$($row.Status)', expected '$Expected': $($row.Detail)"
    return $row
}

$vnetPrimaryId = Get-Id 'rg-network' 'Microsoft.Network/virtualNetworks' 'vnet-primary'
$vnetSecondaryId = Get-Id 'rg-network' 'Microsoft.Network/virtualNetworks' 'vnet-secondary'
$storagePrimaryId = Get-Id 'rg-storage' 'Microsoft.Storage/storageAccounts' 'stprimary'
$storageSecondaryId = Get-Id 'rg-storage' 'Microsoft.Storage/storageAccounts' 'stsecondary'
$registryId = Get-Id 'rg-registry' 'Microsoft.ContainerRegistry/registries' 'acrshared'

$fakeAzRules = @(
    (New-Rule 'account show*' @{ id = '00000000-0000-0000-0000-000000000000'; name = 'Test subscription'; tenantId = '11111111-1111-1111-1111-111111111111' }),
    (New-Rule 'cloud show*' @{ suffixes = @{ storageEndpoint = 'core.windows.net'; acrLoginServerEndpoint = '.azurecr.io' }; endpoints = @{ resourceManager = 'https://management.azure.com/' } }),
    (New-Rule 'group list*' @(@{ name = 'rg-storage' }, @{ name = 'rg-network' }, @{ name = 'rg-dns' }, @{ name = 'rg-registry' }, @{ name = 'rg-other' })),
    (New-Rule 'storage account list*' @(
        @{ id = $storagePrimaryId; name = 'stprimary'; resourceGroup = 'rg-storage'; location = 'westus2'; kind = 'StorageV2'; sku = @{ name = 'Standard_ZRS' }; publicNetworkAccess = 'Disabled' },
        @{ id = $storageSecondaryId; name = 'stsecondary'; resourceGroup = 'rg-storage'; location = 'northcentralus'; kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }; publicNetworkAccess = 'Disabled' },
        @{ id = (Get-Id 'rg-storage' 'Microsoft.Storage/storageAccounts' 'stnfs'); name = 'stnfs'; resourceGroup = 'rg-storage'; location = 'westus2'; kind = 'FileStorage'; sku = @{ name = 'Premium_LRS' }; publicNetworkAccess = 'Enabled' },
        @{ id = (Get-Id 'rg-storage' 'Microsoft.Storage/storageAccounts' 'stblob'); name = 'stblob'; resourceGroup = 'rg-storage'; location = 'westus2'; kind = 'BlobStorage'; sku = @{ name = 'Standard_LRS' }; publicNetworkAccess = 'Enabled' },
        @{ id = (Get-Id 'rg-other' 'Microsoft.Storage/storageAccounts' 'stother'); name = 'stother'; resourceGroup = 'rg-other'; location = 'westus2'; kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }; publicNetworkAccess = 'Enabled' }
    )),
    (New-Rule 'storage share-rm list *--storage-account stprimary *' @(@{ name = 'share'; enabledProtocols = 'SMB'; shareQuota = 100; accessTier = 'TransactionOptimized' })),
    (New-Rule 'storage share-rm list *--storage-account stsecondary *' @(@{ name = 'share'; enabledProtocols = 'SMB'; shareQuota = 100; accessTier = 'TransactionOptimized' })),
    (New-Rule 'storage share-rm list *--storage-account stnfs *' @(@{ name = 'nfsshare'; enabledProtocols = 'NFS'; shareQuota = 100; accessTier = 'Premium' })),
    (New-Rule 'storage share-rm list *--storage-account stother *' @(@{ name = 'data'; enabledProtocols = 'SMB'; shareQuota = 50; accessTier = 'Hot' })),
    (New-Rule 'network vnet list*' @(
        @{
            id = $vnetPrimaryId; name = 'vnet-primary'; resourceGroup = 'rg-network'; location = 'westus2'
            addressSpace = @{ addressPrefixes = @('10.1.0.0/16') }; dhcpOptions = @{ dnsServers = @() }; virtualNetworkPeerings = @()
            subnets = @(
                @{ id = "$vnetPrimaryId/subnets/snet-jobs"; name = 'snet-jobs'; addressPrefix = '10.1.0.0/23'; delegations = @(@{ serviceName = 'Microsoft.App/environments' }) },
                @{ id = "$vnetPrimaryId/subnets/snet-endpoints"; name = 'snet-endpoints'; addressPrefix = '10.1.2.0/24'; privateEndpoints = @(@{ id = 'endpoint' }); ipConfigurations = @(@{ id = 'ip' }) },
                @{ id = "$vnetPrimaryId/subnets/snet-spare"; name = 'snet-spare'; addressPrefix = '10.1.3.0/26' },
                @{ id = "$vnetPrimaryId/subnets/GatewaySubnet"; name = 'GatewaySubnet'; addressPrefix = '10.1.255.0/27' }
            )
        },
        @{
            id = $vnetSecondaryId; name = 'vnet-secondary'; resourceGroup = 'rg-network'; location = 'northcentralus'
            addressSpace = @{ addressPrefixes = @('10.2.0.0/16') }; dhcpOptions = @{ dnsServers = @('10.0.0.4') }
            virtualNetworkPeerings = @(@{ peeringState = 'Connected'; remoteVirtualNetwork = @{ id = $vnetPrimaryId } })
            subnets = @(
                @{ id = "$vnetSecondaryId/subnets/snet-used"; name = 'snet-used'; addressPrefix = '10.2.0.0/23'; delegations = @(@{ serviceName = 'Microsoft.App/environments' }); serviceAssociationLinks = @(@{ linkedResourceType = 'Microsoft.App/environments' }) },
                @{ id = "$vnetSecondaryId/subnets/snet-tiny"; name = 'snet-tiny'; addressPrefix = '10.2.2.0/28'; delegations = @(@{ serviceName = 'Microsoft.App/environments' }) },
                @{ id = "$vnetSecondaryId/subnets/snet-endpoints"; name = 'snet-endpoints'; addressPrefix = '10.2.3.0/24'; privateEndpoints = @(@{ id = 'endpoint' }) }
            )
        }
    )),
    (New-Rule 'network private-endpoint list*' @(
        (New-Endpoint 'pe-primary-file' 'westus2' $vnetPrimaryId $storagePrimaryId 'file' 'Approved'),
        (New-Endpoint 'pe-secondary-file-in-primary' 'westus2' $vnetPrimaryId $storageSecondaryId 'file' 'Approved'),
        (New-Endpoint 'pe-registry-primary' 'westus2' $vnetPrimaryId $registryId 'registry' 'Approved'),
        (New-Endpoint 'pe-secondary-file' 'northcentralus' $vnetSecondaryId $storageSecondaryId 'file' 'Pending'),
        (New-Endpoint 'pe-blob' 'westus2' $vnetPrimaryId $storagePrimaryId 'blob' 'Approved')
    )),
    (New-NicRule 'pe-primary-file' @(@{ privateIPAddress = '10.1.2.4'; privateLinkConnectionProperties = @{ requiredMemberName = 'file' } })),
    (New-NicRule 'pe-secondary-file-in-primary' @(@{ privateIPAddress = '10.1.2.5'; privateLinkConnectionProperties = @{ requiredMemberName = 'file' } })),
    (New-NicRule 'pe-registry-primary' @(
        @{ privateIPAddress = '10.1.2.6'; privateLinkConnectionProperties = @{ requiredMemberName = 'registry' } },
        @{ privateIPAddress = '10.1.2.7'; privateLinkConnectionProperties = @{ requiredMemberName = 'registry_data_westus2' } }
    )),
    (New-NicRule 'pe-secondary-file' @(@{ privateIPAddress = '10.2.3.4'; privateLinkConnectionProperties = @{ requiredMemberName = 'file' } })),
    (New-Rule 'network private-dns zone list*' @(
        @{ id = (Get-Id 'rg-dns' 'Microsoft.Network/privateDnsZones' 'privatelink.file.core.windows.net'); name = 'privatelink.file.core.windows.net'; resourceGroup = 'rg-dns'; numberOfRecordSets = 3 },
        @{ id = (Get-Id 'rg-dns' 'Microsoft.Network/privateDnsZones' 'privatelink.azurecr.io'); name = 'privatelink.azurecr.io'; resourceGroup = 'rg-dns'; numberOfRecordSets = 1 },
        @{ id = (Get-Id 'rg-dns' 'Microsoft.Network/privateDnsZones' 'privatelink.blob.core.windows.net'); name = 'privatelink.blob.core.windows.net'; resourceGroup = 'rg-dns'; numberOfRecordSets = 2 }
    )),
    (New-Rule 'network private-dns link vnet list --resource-group rg-dns --zone-name privatelink.file.core.windows.net *' @(@{ virtualNetwork = @{ id = $vnetPrimaryId } })),
    (New-Rule 'network private-dns link vnet list --resource-group rg-dns --zone-name privatelink.azurecr.io *' @()),
    (New-Rule 'network private-dns record-set a list --resource-group rg-dns --zone-name privatelink.file.core.windows.net *' @(
        @{ name = 'stprimary'; aRecords = @(@{ ipv4Address = '10.1.2.4' }) },
        @{ name = 'stsecondary'; aRecords = @(@{ ipv4Address = '10.9.9.9' }) }
    )),
    (New-Rule 'acr list*' @(
        @{ id = $registryId; name = 'acrshared'; resourceGroup = 'rg-registry'; location = 'westus2'; sku = @{ name = 'Premium' }; publicNetworkAccess = 'Disabled'; roleAssignmentMode = 'LegacyRegistryPermissions' },
        @{ id = (Get-Id 'rg-registry' 'Microsoft.ContainerRegistry/registries' 'acrabac'); name = 'acrabac'; resourceGroup = 'rg-registry'; location = 'westus2'; sku = @{ name = 'Premium' }; publicNetworkAccess = 'Enabled'; roleAssignmentMode = 'AbacRepositoryPermissions' },
        @{ id = (Get-Id 'rg-registry' 'Microsoft.ContainerRegistry/registries' 'acrbasic'); name = 'acrbasic'; resourceGroup = 'rg-registry'; location = 'westus2'; sku = @{ name = 'Basic' }; publicNetworkAccess = 'Enabled'; roleAssignmentMode = 'LegacyRegistryPermissions' }
    )),
    (New-Rule 'acr replication list --registry acrshared *' @(@{ location = 'westus2' }, @{ location = 'northcentralus' })),
    (New-Rule 'acr replication list --registry acrabac *' @(@{ location = 'westus2' })),
    (New-Rule 'rest --method get --url *Microsoft.App/managedEnvironments*' @{ value = @(@{ name = 'cae-existing'; properties = @{ vnetConfiguration = @{ infrastructureSubnetId = "$vnetSecondaryId/subnets/snet-used" } } }) })
)

# Audit selected resource groups, including one that doesn't exist.
$report = Invoke-Audit @('rg-storage,rg-network', 'rg-dns', 'RG-REGISTRY', 'rg-missing')
Assert-True (@($report.ResourceGroups).Count -eq 4) "audited resource groups were $(@($report.ResourceGroups) -join ', ')"
$null = Assert-Status $report 'Resource group' 'rg-missing' 'Not verified'

$null = Assert-Status $report 'Storage account' 'stprimary' 'Reusable'
$null = Assert-Status $report 'Storage account' 'stnfs' 'Needs changes'
$null = Assert-Status $report 'Storage account' 'stblob' 'Not suitable'
$null = Assert-Status $report 'File share' 'stprimary/share' 'Reusable'
$null = Assert-Status $report 'File share' 'stnfs/nfsshare' 'Not suitable'
Assert-True ($null -eq (Get-Row $report 'Storage account' 'stother')) 'a storage account outside the audited resource groups was reported'

$null = Assert-Status $report 'Container Apps subnet' 'vnet-primary/snet-jobs' 'Reusable'
$spare = Assert-Status $report 'Container Apps subnet' 'vnet-primary/snet-spare' 'Needs changes'
Assert-True ($spare.Detail -like '*Delegate it to Microsoft.App/environments*' -and $spare.Detail -notlike '*/23*') "a /26 candidate subnet wasn't reported as needing only the delegation: $($spare.Detail)"
$used = Assert-Status $report 'Container Apps subnet' 'vnet-secondary/snet-used' 'Not suitable'
Assert-True ($used.Detail -like '*cae-existing*') 'the environment using a subnet was not named'
$null = Assert-Status $report 'Container Apps subnet' 'vnet-secondary/snet-tiny' 'Not suitable'
foreach ($subnet in 'vnet-primary/snet-endpoints', 'vnet-primary/GatewaySubnet', 'vnet-secondary/snet-endpoints') {
    Assert-True ($null -eq (Get-Row $report 'Container Apps subnet' $subnet)) "$subnet is not a Container Apps candidate"
}
$null = Assert-Status $report 'Virtual network' 'vnet-primary' 'Reusable'
$null = Assert-Status $report 'Virtual network' 'vnet-secondary' 'Needs changes'

$null = Assert-Status $report 'Private endpoint' 'pe-primary-file' 'Reusable'
$null = Assert-Status $report 'Private endpoint' 'pe-secondary-file' 'Needs changes'
Assert-True ($null -eq (Get-Row $report 'Private endpoint' 'pe-blob')) 'a blob endpoint was reported'
$null = Assert-Status $report 'Private DNS zone' 'privatelink.file.core.windows.net' 'Reusable'
$null = Assert-Status $report 'Private DNS zone' 'privatelink.azurecr.io' 'Needs changes'
Assert-True ($null -eq (Get-Row $report 'Private DNS zone' 'privatelink.blob.core.windows.net')) 'the blob zone was reported'

$null = Assert-Status $report 'Container registry' 'acrshared' 'Reusable'
$null = Assert-Status $report 'Container registry' 'acrabac' 'Needs changes'
$basic = Assert-Status $report 'Container registry' 'acrbasic' 'Reusable'
Assert-True ($basic.Detail -like '*public endpoint*') 'a Basic registry was not described as public-only'

$primaryNetwork = @($report.Networks | Where-Object VirtualNetwork -eq 'vnet-primary') | Select-Object -First 1
Assert-True ($primaryNetwork.JobSubnet -eq 'snet-jobs') "vnet-primary job subnet was '$($primaryNetwork.JobSubnet)'"
Assert-True ($primaryNetwork.FileEndpoints -like '*stprimary*' -and $primaryNetwork.FileEndpoints -like '*stsecondary*') "vnet-primary file endpoints were '$($primaryNetwork.FileEndpoints)'"
Assert-True ($primaryNetwork.FileDns -like '*stprimary resolves*') "stprimary DNS was not accepted: $($primaryNetwork.FileDns)"
Assert-True ($primaryNetwork.FileDns -like '*stsecondary resolves to 10.9.9.9, not to its endpoint*') "a mismatched DNS record was accepted: $($primaryNetwork.FileDns)"
Assert-True ($primaryNetwork.RegistryEndpoints -eq 'acrshared') "vnet-primary registry endpoints were '$($primaryNetwork.RegistryEndpoints)'"

$secondaryNetwork = @($report.Networks | Where-Object VirtualNetwork -eq 'vnet-secondary') | Select-Object -First 1
Assert-True ($secondaryNetwork.JobSubnet -eq 'none') "vnet-secondary job subnet was '$($secondaryNetwork.JobSubnet)'"
Assert-True ($secondaryNetwork.FileEndpoints -like '*stprimary (peered)*') "peered endpoints were not reported: $($secondaryNetwork.FileEndpoints)"
Assert-True ($secondaryNetwork.FileDns -like '*not verified (custom DNS)*') "custom DNS was not flagged: $($secondaryNetwork.FileDns)"
Assert-True ($secondaryNetwork.RegistryEndpoints -eq 'acrshared (peered)') "vnet-secondary registry endpoints were '$($secondaryNetwork.RegistryEndpoints)'"

$readOnlyPrefixes = 'account show', 'cloud show', 'group list', 'storage account list', 'storage share-rm list', 'network vnet list', 'network private-endpoint list',
    'network private-dns zone list', 'network private-dns link vnet list', 'network private-dns record-set a list', 'network nic show', 'acr list', 'acr replication list', 'rest --method get'
$unexpected = @($azCalls | Where-Object { $call = $_; -not ($readOnlyPrefixes | Where-Object { $call.StartsWith($_) }) })
Assert-True ($unexpected.Count -eq 0) "non-read-only Azure CLI calls: $($unexpected -join '; ')"

# Without resource groups, the whole subscription is audited.
$report = Invoke-Audit
Assert-True (@($report.ResourceGroups).Count -eq 5) 'the whole subscription was not audited by default'
$null = Assert-Status $report 'Storage account' 'stother' 'Reusable'

# Parameter file generation: reuse what fits, create what's missing or requested, and ask when the choice is ambiguous.
$generatedRoot = Join-Path ([IO.Path]::GetTempPath()) "audit-generated-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $generatedRoot | Out-Null
$scopedGroups = @('rg-storage', 'rg-network', 'rg-dns', 'rg-registry')

function Invoke-Generation([string]$Name, [hashtable]$Arguments) {
    $path = Join-Path $generatedRoot $Name
    & $auditScript -ResourceGroupName $scopedGroups -PrimaryLocation westus2 -SecondaryLocation northcentralus -ParametersOutputPath $path @Arguments 6> $null 3> $null
    Assert-True (Test-Path -LiteralPath $path) "$Name was not written"
    & $realAz bicep build-params --file $path --stdout *> $null
    Assert-True ($LASTEXITCODE -eq 0) "$Name does not compile against infra/existing.bicep"
    return Get-Content -LiteralPath $path -Raw
}

function Assert-Contains([string]$Text, [string[]]$Expected, [string]$Context) {
    foreach ($line in $Expected) {
        Assert-True ($Text.Contains($line)) "$Context is missing: $line"
    }
}

try {
    $generated = Invoke-Generation 'reuse.bicepparam' @{ New = @('registry'); AlertEmailAddress = @('ops@replication.test') }
    Assert-Contains $generated @(
        "param primaryStorageMode = 'existing'", "param primaryStorageAccountName = 'stprimary'", "param primaryStorageResourceGroupName = 'rg-storage'", "param primaryFileShareName = 'share'",
        "param secondaryStorageMode = 'existing'", "param secondaryStorageAccountName = 'stsecondary'",
        "param primaryNetworkMode = 'existing'", "param primaryVnetName = 'vnet-primary'", "param primaryInfrastructureSubnetName = 'snet-jobs'",
        "param primaryPrivateEndpointSubnetName = 'snet-endpoints'", "param primaryRegistryDnsZoneId = ''",
        "param secondaryNetworkMode = 'new'", "param secondaryVnetAddressPrefix = '10.20.0.0/16'",
        "param registryMode = 'new'", "/privateEndpoints/pe-primary-file'", "/privateEndpoints/pe-secondary-file-in-primary'", "'ops@replication.test'"
    ) 'the reuse parameter file'
    Assert-True (-not $generated.Contains('primaryEndpointsToCreate')) 'endpoints that already exist were requested again'
    Assert-True (-not ($generated -match '<[^>]+>')) 'the reuse parameter file has unexpected placeholders'
    Assert-Contains $generated @(
        "param registryName = ''", "param registryResourceGroupName = ''",
        "param secondaryVnetName = ''", "param secondaryVnetResourceGroupName = ''", "param secondaryPrivateEndpointSubnetName = ''",
        "param secondaryDnsResourceGroupName = 'rg-azure-files-replication-sec-dns'",
        '// param resourceNames = {', "//   primaryJob: ''", "//   secondaryFreshnessAlert: ''",
        'param existingResourceGroups = []'
    ) 'the reuse parameter file'
    Assert-True (-not $generated.Contains('param secondaryResourceGroupName')) 'a single resource group layout wrote a secondary resource group'

    $generated = Invoke-Generation 'create.bicepparam' @{ New = @('primaryNetwork,secondaryStorage'); ReplicationResourceGroupName = 'rg-network'; SecondaryResourceGroupName = 'rg-replication-sec' }
    Assert-Contains $generated @(
        "param primaryNetworkMode = 'new'", "param primaryVnetAddressPrefix = '10.10.0.0/16'",
        "param secondaryStorageMode = 'new'", "param secondaryFileShareName = 'share'", "param secondaryStorageSkuName = 'Standard_LRS'",
        "param registryMode = 'existing'", "param registryName = 'acrshared'", "'<operations-email-address>'",
        "param resourceGroupName = 'rg-network'", "param secondaryResourceGroupName = 'rg-replication-sec'", "param secondaryResourceGroupLocation = 'northcentralus'",
        "param secondaryStorageAccountName = ''", "param secondaryStorageResourceGroupName = ''",
        "param primaryDnsResourceGroupName = 'rg-network-pri-dns'",
        "param existingResourceGroups = [`n  'rg-network'`n]"
    ) 'the create parameter file'

    # A second SMB account in the primary region makes the source ambiguous.
    $fakeAzRules = @(
        (New-Rule 'storage account list*' @(
            @{ id = $storagePrimaryId; name = 'stprimary'; resourceGroup = 'rg-storage'; location = 'westus2'; kind = 'StorageV2'; sku = @{ name = 'Standard_ZRS' }; publicNetworkAccess = 'Disabled' },
            @{ id = (Get-Id 'rg-storage' 'Microsoft.Storage/storageAccounts' 'stprimary2'); name = 'stprimary2'; resourceGroup = 'rg-storage'; location = 'westus2'; kind = 'StorageV2'; sku = @{ name = 'Standard_LRS' }; publicNetworkAccess = 'Enabled' }
        )),
        (New-Rule 'storage share-rm list *--storage-account stprimary2 *' @(@{ name = 'archive'; enabledProtocols = 'SMB'; shareQuota = 100; accessTier = 'Hot' }))
    ) + $fakeAzRules
    $generated = Invoke-Generation 'ambiguous.bicepparam' @{ AlertEmailAddress = @('ops@replication.test') }
    Assert-True ($generated -match "param primaryStorageAccountName = '<choose an account: stprimary \| stprimary2>'") 'an ambiguous source account was not left for the user to choose'
    Assert-True ($generated.Contains("param secondaryStorageMode = 'new'")) 'with no secondary candidate left, the destination account was not created'
    Assert-True ($generated.Contains("param primaryFileDnsZoneId = '$subscription/resourceGroups/rg-dns/providers/Microsoft.Network/privateDnsZones/privatelink.file.core.windows.net'")) 'the linked file zone was not used for the new account endpoint'

    $failure = $null
    try {
        & $auditScript -New 'firewall' -PrimaryLocation westus2 -SecondaryLocation northcentralus -ParametersOutputPath (Join-Path $generatedRoot 'bad.bicepparam') 6> $null
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True ($failure -like "*Unknown -New service 'firewall'*") "an unknown -New service was accepted: $failure"

    $failure = $null
    try {
        & $auditScript -ResourceGroupName $scopedGroups -PrimaryLocation westus2 -SecondaryLocation northcentralus -ParametersOutputPath (Join-Path $generatedRoot 'reuse.bicepparam') 6> $null
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True ($failure -like '*already exists*-Force*') "an existing parameter file was overwritten without -Force: $failure"
} finally {
    Remove-Item -LiteralPath $generatedRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Audit script checks passed.'
