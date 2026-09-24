[CmdletBinding()]
param(
    # One or more resource groups to audit. Comma-separated values are accepted. Omit to audit every resource group in the current subscription.
    [string[]]$ResourceGroupName,
    [string]$OutputPath,

    # Writes an existing-resource parameter file from the audit. Requires -PrimaryLocation and -SecondaryLocation.
    [string]$ParametersOutputPath,
    [string]$PrimaryLocation,
    [string]$SecondaryLocation,

    # Services to create instead of reuse: primaryStorage, secondaryStorage, primaryNetwork, secondaryNetwork, registry.
    [string[]]$New,

    [string]$ReplicationResourceGroupName = 'rg-azure-files-replication',
    # Resource group for secondary-region compute; defaults to -ReplicationResourceGroupName.
    [string]$SecondaryResourceGroupName,
    [string]$PrimaryRegionCode = 'pri',
    [string]$SecondaryRegionCode = 'sec',
    [string[]]$AlertEmailAddress,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read-only audit: every Azure CLI call below is a show, list, or REST GET operation. Only -ParametersOutputPath and -OutputPath write local files.

$newServices = @($New | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$newServiceNames = 'primaryStorage', 'secondaryStorage', 'primaryNetwork', 'secondaryNetwork', 'registry'
foreach ($service in $newServices) {
    if ($newServiceNames -notcontains $service) {
        throw "Unknown -New service '$service'. Use one or more of: $($newServiceNames -join ', ')."
    }
}
if ($ParametersOutputPath) {
    if (-not $PrimaryLocation -or -not $SecondaryLocation) {
        throw '-ParametersOutputPath requires -PrimaryLocation and -SecondaryLocation to assign services to the replication roles.'
    }
    if ((Test-Path -LiteralPath $ParametersOutputPath) -and -not $Force) {
        throw "'$ParametersOutputPath' already exists. Pass -Force to replace it."
    }
}

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $errorPath = [IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments --only-show-errors --output json 2> $errorPath
        $exitCode = $LASTEXITCODE
        $errorText = [IO.File]::ReadAllText($errorPath).Trim()
    } finally {
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }

    $text = ($output -join [Environment]::NewLine).Trim()
    $firstError = @($errorText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    [pscustomobject]@{
        Succeeded = $exitCode -eq 0
        Value     = if ($exitCode -eq 0 -and $text) { $text | ConvertFrom-Json -Depth 100 } else { $null }
        Error     = if ($exitCode -ne 0) { if ($firstError) { $firstError[0].Trim() } else { "Azure CLI exited with code $exitCode." } } else { $null }
    }
}

function Get-Property {
    param($Object, [Parameter(Mandatory)][string]$Path)

    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) {
            return $null
        }
        $property = $current.PSObject.Properties[$segment]
        if (-not $property) {
            return $null
        }
        $current = $property.Value
    }
    return $current
}

function ConvertTo-Key([string]$Value) {
    if (-not $Value) {
        return ''
    }
    return ($Value -replace '\s', '').ToLowerInvariant()
}

function Get-ResourceName([string]$ResourceId) {
    if (-not $ResourceId) {
        return ''
    }
    return ($ResourceId.TrimEnd('/') -split '/')[-1]
}

function Get-ResourceGroupName([string]$ResourceId) {
    if ($ResourceId -match '(?i)/resourceGroups/([^/]+)') {
        return $Matches[1]
    }
    return ''
}

$services = [System.Collections.Generic.List[object]]::new()
$networks = [System.Collections.Generic.List[object]]::new()
$storageCandidates = [System.Collections.Generic.List[object]]::new()
$vnetCandidates = [System.Collections.Generic.List[object]]::new()
$registryCandidates = [System.Collections.Generic.List[object]]::new()

function Add-Service {
    param(
        [Parameter(Mandatory)][string]$Service,
        [Parameter(Mandatory)][string]$Name,
        [string]$ResourceGroup = '',
        [string]$Location = '',
        [Parameter(Mandatory)][ValidateSet('Reusable', 'Needs changes', 'Not suitable', 'Not verified')][string]$Status,
        [string]$Detail = ''
    )
    $services.Add([pscustomobject]@{ Service = $Service; Status = $Status; Name = $Name; ResourceGroup = $ResourceGroup; Location = $Location; Detail = $Detail })
}

function Get-List([string]$Service, [string[]]$Arguments) {
    $result = Invoke-Az -Arguments $Arguments
    if (-not $result.Succeeded) {
        Add-Service -Service $Service -Name '(all)' -Status 'Not verified' -Detail "Could not list resources: $($result.Error)"
        return
    }
    $result.Value | Where-Object { $null -ne $_ }
}

$account = Invoke-Az -Arguments @('account', 'show')
if (-not $account.Succeeded) {
    throw "Sign in with az login before running the audit. $($account.Error)"
}
$subscriptionId = $account.Value.id

$cloud = (Invoke-Az -Arguments @('cloud', 'show')).Value
$storageSuffix = Get-Property $cloud 'suffixes.storageEndpoint'
if (-not $storageSuffix) {
    $storageSuffix = 'core.windows.net'
}
$registrySuffix = Get-Property $cloud 'suffixes.acrLoginServerEndpoint'
if (-not $registrySuffix) {
    $registrySuffix = '.azurecr.io'
}
$resourceManager = ([string](Get-Property $cloud 'endpoints.resourceManager')).TrimEnd('/')
if (-not $resourceManager) {
    $resourceManager = 'https://management.azure.com'
}
$fileZoneKey = ConvertTo-Key "privatelink.file.$storageSuffix"
$registryZoneKey = ConvertTo-Key "privatelink$registrySuffix"

$groupList = Invoke-Az -Arguments @('group', 'list')
if (-not $groupList.Succeeded) {
    throw "Could not list resource groups. $($groupList.Error)"
}
$groupsByKey = @{}
foreach ($group in @($groupList.Value | Where-Object { $_ })) {
    $groupsByKey[(ConvertTo-Key $group.name)] = $group.name
}

$scopeKeys = @{}
$missingGroups = [System.Collections.Generic.List[string]]::new()
$requestedGroups = @($ResourceGroupName | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($requestedGroups.Count -gt 0) {
    foreach ($name in $requestedGroups) {
        $key = ConvertTo-Key $name
        if ($groupsByKey.ContainsKey($key)) {
            $scopeKeys[$key] = $groupsByKey[$key]
        } elseif (-not $missingGroups.Contains($name)) {
            $missingGroups.Add($name)
            Add-Service -Service 'Resource group' -Name $name -Status 'Not verified' -Detail 'Not found in this subscription, or you lack read access.'
        }
    }
} else {
    foreach ($key in $groupsByKey.Keys) {
        $scopeKeys[$key] = $groupsByKey[$key]
    }
}

function Test-InScope([string]$ResourceGroup) {
    return $scopeKeys.ContainsKey((ConvertTo-Key $ResourceGroup))
}

# Lists are subscription-wide so that endpoints, peerings, and DNS zones in other resource groups still inform the assessment.
Write-Host "Auditing $($scopeKeys.Count) resource group(s) in subscription $($account.Value.name)..."
$storageAccounts = @(Get-List 'Storage account' @('storage', 'account', 'list'))
$virtualNetworks = @(Get-List 'Virtual network' @('network', 'vnet', 'list'))
$privateEndpoints = @(Get-List 'Private endpoint' @('network', 'private-endpoint', 'list'))
$privateDnsZones = @(Get-List 'Private DNS zone' @('network', 'private-dns', 'zone', 'list'))
$registries = @(Get-List 'Container registry' @('acr', 'list'))

# Environment names make in-use subnets easier to identify; the lookup is optional.
$environmentsBySubnet = @{}
$environmentList = Invoke-Az -Arguments @('rest', '--method', 'get', '--url', "$resourceManager/subscriptions/$subscriptionId/providers/Microsoft.App/managedEnvironments?api-version=2025-01-01")
if ($environmentList.Succeeded) {
    foreach ($environment in @(Get-Property $environmentList.Value 'value' | Where-Object { $_ })) {
        $subnetId = Get-Property $environment 'properties.vnetConfiguration.infrastructureSubnetId'
        if ($subnetId) {
            $environmentsBySubnet[(ConvertTo-Key $subnetId)] = $environment.name
        }
    }
}

$vnetsByKey = @{}
foreach ($vnet in $virtualNetworks) {
    $vnetsByKey[(ConvertTo-Key $vnet.id)] = $vnet
}

function Get-VnetLabel([string]$VnetKey) {
    if ($vnetsByKey.ContainsKey($VnetKey)) {
        return $vnetsByKey[$VnetKey].name
    }
    return Get-ResourceName $VnetKey
}

function Get-PeerKeys($Vnet) {
    return @(Get-Property $Vnet 'virtualNetworkPeerings' | Where-Object { $_ -and (Get-Property $_ 'peeringState') -eq 'Connected' } |
        ForEach-Object { ConvertTo-Key (Get-Property $_ 'remoteVirtualNetwork.id') } | Where-Object { $_ })
}

$scopeVnetKeys = @{}
foreach ($vnet in $virtualNetworks | Where-Object { Test-InScope $_.resourceGroup }) {
    $scopeVnetKeys[(ConvertTo-Key $vnet.id)] = $true
    foreach ($peerKey in Get-PeerKeys $vnet) {
        $scopeVnetKeys[$peerKey] = $true
    }
}

# Only Azure Files and registry endpoints matter for replication.
$endpointRecords = [System.Collections.Generic.List[object]]::new()
foreach ($endpoint in $privateEndpoints) {
    $subnetId = [string](Get-Property $endpoint 'subnet.id')
    $connections = @(@(Get-Property $endpoint 'privateLinkServiceConnections') + @(Get-Property $endpoint 'manualPrivateLinkServiceConnections') | Where-Object { $_ })
    foreach ($connection in $connections) {
        $groupIds = @(Get-Property $connection 'groupIds')
        $group = $null
        if ($groupIds -contains 'file') {
            $group = 'file'
        } elseif ($groupIds -contains 'registry') {
            $group = 'registry'
        }
        if (-not $group) {
            continue
        }
        $targetId = [string](Get-Property $connection 'privateLinkServiceId')
        $endpointRecords.Add([pscustomobject]@{
            Id            = $endpoint.id
            Name          = $endpoint.name
            ResourceGroup = $endpoint.resourceGroup
            Location      = $endpoint.location
            Group         = $group
            TargetKey     = ConvertTo-Key $targetId
            TargetName    = Get-ResourceName $targetId
            TargetGroup   = Get-ResourceGroupName $targetId
            Status        = [string](Get-Property $connection 'privateLinkServiceConnectionState.status')
            SubnetName    = Get-ResourceName $subnetId
            VnetKey       = ConvertTo-Key ($subnetId -replace '(?i)/subnets/[^/]+$', '')
            NicIds        = @(Get-Property $endpoint 'networkInterfaces' | ForEach-Object { Get-Property $_ 'id' } | Where-Object { $_ })
            Ips           = @()
            IpsVerified   = $false
        })
    }
}

foreach ($record in $endpointRecords) {
    $relevant = (Test-InScope $record.ResourceGroup) -or (Test-InScope $record.TargetGroup) -or $scopeVnetKeys.ContainsKey($record.VnetKey)
    if (-not $relevant) {
        continue
    }
    $verified = $record.NicIds.Count -gt 0
    $ips = foreach ($nicId in $record.NicIds) {
        $nic = Invoke-Az -Arguments @('network', 'nic', 'show', '--ids', $nicId)
        if (-not $nic.Succeeded) {
            $verified = $false
            continue
        }
        foreach ($ipConfiguration in @(Get-Property $nic.Value 'ipConfigurations' | Where-Object { $_ })) {
            $member = [string](Get-Property $ipConfiguration 'privateLinkConnectionProperties.requiredMemberName')
            if ($record.Group -eq 'file' -and $member -and $member -ne 'file') {
                continue
            }
            Get-Property $ipConfiguration 'privateIPAddress'
        }
    }
    $record.Ips = @($ips | Where-Object { $_ })
    $record.IpsVerified = $verified
}

$zoneRecords = [System.Collections.Generic.List[object]]::new()
foreach ($zone in $privateDnsZones) {
    $zoneKey = ConvertTo-Key $zone.name
    $isFileZone = $zoneKey -eq $fileZoneKey
    if (-not $isFileZone -and $zoneKey -ne $registryZoneKey) {
        continue
    }
    $links = Invoke-Az -Arguments @('network', 'private-dns', 'link', 'vnet', 'list', '--resource-group', $zone.resourceGroup, '--zone-name', $zone.name)
    $records = @{}
    $recordsVerified = $false
    if ($isFileZone) {
        $recordSets = Invoke-Az -Arguments @('network', 'private-dns', 'record-set', 'a', 'list', '--resource-group', $zone.resourceGroup, '--zone-name', $zone.name)
        if ($recordSets.Succeeded) {
            $recordsVerified = $true
            foreach ($recordSet in @($recordSets.Value | Where-Object { $_ })) {
                $records[(ConvertTo-Key $recordSet.name)] = @(Get-Property $recordSet 'aRecords' | ForEach-Object { Get-Property $_ 'ipv4Address' } | Where-Object { $_ })
            }
        }
    }
    $zoneRecords.Add([pscustomobject]@{
        Id              = Get-Property $zone 'id'
        Name            = $zone.name
        ResourceGroup   = $zone.resourceGroup
        IsFileZone      = $isFileZone
        LinksVerified   = $links.Succeeded
        LinksError      = $links.Error
        LinkedVnetKeys  = @(if ($links.Succeeded) { $links.Value | Where-Object { $_ } | ForEach-Object { ConvertTo-Key (Get-Property $_ 'virtualNetwork.id') } | Where-Object { $_ } })
        Records         = $records
        RecordsVerified = $recordsVerified
        RecordSetCount  = Get-Property $zone 'numberOfRecordSets'
    })
}

function Get-FileDnsState([string]$VnetKey, [string]$AccountName, [object[]]$Endpoints, [bool]$CustomDns) {
    if ($CustomDns) {
        return 'not verified (custom DNS)'
    }
    $zone = @($zoneRecords | Where-Object { $_.IsFileZone -and $_.LinkedVnetKeys -contains $VnetKey }) | Select-Object -First 1
    if (-not $zone) {
        if (@($zoneRecords | Where-Object { $_.IsFileZone -and -not $_.LinksVerified }).Count -gt 0) {
            return 'not verified'
        }
        return 'no linked zone'
    }
    if (-not $zone.RecordsVerified -or @($Endpoints | Where-Object { -not $_.IpsVerified }).Count -gt 0) {
        return 'not verified'
    }
    $key = ConvertTo-Key $AccountName
    if (-not $zone.Records.ContainsKey($key)) {
        return "no record in $($zone.ResourceGroup)"
    }
    $recordIps = @($zone.Records[$key])
    $expectedIps = @($Endpoints | ForEach-Object { $_.Ips })
    if (@($recordIps | Where-Object { $expectedIps -contains $_ }).Count -gt 0) {
        return 'resolves'
    }
    return "resolves to $($recordIps -join ', '), not to its endpoint"
}

$specialSubnets = 'GatewaySubnet', 'AzureFirewallSubnet', 'AzureFirewallManagementSubnet', 'AzureBastionSubnet', 'RouteServerSubnet'

# Returns an assessment only for subnets that could host a replication job's Container Apps environment.
function Get-SubnetAssessment($Subnet) {
    $name = [string]$Subnet.name
    if ($specialSubnets -contains $name) {
        return $null
    }
    $prefix = @(@(Get-Property $Subnet 'addressPrefix') + @(Get-Property $Subnet 'addressPrefixes') | Where-Object { $_ }) | Select-Object -First 1
    $prefixLength = if ($prefix -match '/(\d+)$') { [int]$Matches[1] } else { $null }
    $delegations = @(Get-Property $Subnet 'delegations' | ForEach-Object { Get-Property $_ 'serviceName' } | Where-Object { $_ })
    $isAppDelegated = $delegations -contains 'Microsoft.App/environments'
    if ($delegations.Count -gt 0 -and -not $isAppDelegated) {
        return $null
    }
    $links = @(Get-Property $Subnet 'serviceAssociationLinks' | Where-Object { $_ })
    $ipConfigurations = @(Get-Property $Subnet 'ipConfigurations' | Where-Object { $_ })
    $subnetEndpoints = @(Get-Property $Subnet 'privateEndpoints' | Where-Object { $_ })
    $inUse = $links.Count -gt 0 -or $ipConfigurations.Count -gt 0 -or $subnetEndpoints.Count -gt 0
    if (-not $isAppDelegated -and ($inUse -or ($null -ne $prefixLength -and $prefixLength -gt 27))) {
        return $null
    }

    $controls = @()
    $securityGroup = Get-Property $Subnet 'networkSecurityGroup.id'
    if ($securityGroup) {
        $controls += "NSG $(Get-ResourceName $securityGroup)"
    }
    $routeTable = Get-Property $Subnet 'routeTable.id'
    if ($routeTable) {
        $controls += "route table $(Get-ResourceName $routeTable)"
    }
    $detail = "prefix=$prefix"
    if ($controls) {
        $detail += ", $($controls -join ', ') (allow HTTPS to the storage and registry endpoints)"
    }
    $sizeNote = if ($null -ne $prefixLength -and $prefixLength -gt 23) { ' It is smaller than the documented /23.' } else { '' }

    if ($inUse) {
        $environmentName = $environmentsBySubnet[(ConvertTo-Key $Subnet.id)]
        $user = if ($environmentName) { "Container Apps environment $environmentName" } else { 'existing resources' }
        return [pscustomobject]@{ Name = $name; Status = 'Not suitable'; Detail = "$detail. Already used by $user; each replication environment needs its own empty subnet." }
    }
    if ($null -ne $prefixLength -and $prefixLength -gt 27) {
        return [pscustomobject]@{ Name = $name; Status = 'Not suitable'; Detail = "$detail. Workload profiles environments need at least a /27 subnet." }
    }
    if (-not $isAppDelegated) {
        return [pscustomobject]@{ Name = $name; Status = 'Needs changes'; Detail = "$detail, empty. Delegate it to Microsoft.App/environments to host a replication job.$sizeNote" }
    }
    return [pscustomobject]@{ Name = $name; Status = 'Reusable'; Detail = "$detail, delegated to Microsoft.App/environments, empty.$sizeNote" }
}

$supportedKinds = 'StorageV2', 'FileStorage', 'Storage'
foreach ($storage in $storageAccounts | Where-Object { Test-InScope $_.resourceGroup }) {
    $kind = [string](Get-Property $storage 'kind')
    $publicAccess = [string](Get-Property $storage 'publicNetworkAccess')
    $detail = "kind=$kind, sku=$(Get-Property $storage 'sku.name'), publicNetworkAccess=$publicAccess"
    $serviceArguments = @{ Service = 'Storage account'; Name = $storage.name; ResourceGroup = $storage.resourceGroup; Location = $storage.location }
    if ($supportedKinds -notcontains $kind) {
        Add-Service @serviceArguments -Status 'Not suitable' -Detail "$detail. This account kind doesn't support Azure file shares."
        continue
    }

    $storageKey = ConvertTo-Key $storage.id
    $fileEndpoints = @($endpointRecords | Where-Object { $_.Group -eq 'file' -and $_.TargetKey -eq $storageKey })
    $approvedVnets = @($fileEndpoints | Where-Object { $_.Status -eq 'Approved' } | ForEach-Object { Get-VnetLabel $_.VnetKey } | Select-Object -Unique)
    $otherEndpoints = @($fileEndpoints | Where-Object { $_.Status -ne 'Approved' } | ForEach-Object { "$(Get-VnetLabel $_.VnetKey) ($($_.Status))" })
    $endpointText = if ($approvedVnets) { "file endpoints in $($approvedVnets -join ', ')" } else { 'no approved file endpoints' }
    if ($otherEndpoints) {
        $endpointText += "; not approved: $($otherEndpoints -join ', ')"
    }

    $shareResult = Invoke-Az -Arguments @('storage', 'share-rm', 'list', '--resource-group', $storage.resourceGroup, '--storage-account', $storage.name)
    if (-not $shareResult.Succeeded) {
        Add-Service @serviceArguments -Status 'Not verified' -Detail "$detail, $endpointText. Could not list file shares: $($shareResult.Error)"
        continue
    }
    $shares = @($shareResult.Value | Where-Object { $_ })
    $smbCount = 0
    $smbShareNames = [System.Collections.Generic.List[string]]::new()
    foreach ($share in $shares) {
        $protocol = [string](Get-Property $share 'enabledProtocols')
        if (-not $protocol) {
            $protocol = 'SMB'
        }
        $shareDetail = "protocol=$protocol, quota=$(Get-Property $share 'shareQuota') GiB, tier=$(Get-Property $share 'accessTier')"
        $shareArguments = @{ Service = 'File share'; Name = "$($storage.name)/$($share.name)"; ResourceGroup = $storage.resourceGroup; Location = $storage.location }
        if ($protocol -eq 'NFS') {
            Add-Service @shareArguments -Status 'Not suitable' -Detail "$shareDetail. NFS shares aren't supported; the replication job copies SMB shares."
        } else {
            $smbCount++
            $smbShareNames.Add($share.name)
            Add-Service @shareArguments -Status 'Reusable' -Detail $shareDetail
        }
    }
    if ($smbCount -gt 0) {
        $storageCandidates.Add([pscustomobject]@{ Name = $storage.name; ResourceGroup = $storage.resourceGroup; Location = $storage.location; Key = $storageKey; Shares = @($smbShareNames) })
    }

    $shareText = "SMB shares=$smbCount"
    if ($shares.Count -gt $smbCount) {
        $shareText += ", NFS shares=$($shares.Count - $smbCount)"
    }
    $detail = "$detail, $shareText, $endpointText"
    if ($smbCount -eq 0) {
        Add-Service @serviceArguments -Status 'Needs changes' -Detail "$detail. Create an SMB file share to replicate."
    } elseif ($publicAccess -eq 'Disabled' -and $approvedVnets.Count -eq 0) {
        Add-Service @serviceArguments -Status 'Needs changes' -Detail "$detail. Public access is disabled, so add approved file private endpoints in the job VNets."
    } elseif ($kind -eq 'Storage') {
        Add-Service @serviceArguments -Status 'Reusable' -Detail "$detail. General-purpose v1 account; consider upgrading it to StorageV2."
    } else {
        Add-Service @serviceArguments -Status 'Reusable' -Detail $detail
    }
}

foreach ($vnet in $virtualNetworks | Where-Object { Test-InScope $_.resourceGroup }) {
    $vnetKey = ConvertTo-Key $vnet.id
    $dnsServers = @(Get-Property $vnet 'dhcpOptions.dnsServers' | Where-Object { $_ })
    $peerKeys = @(Get-PeerKeys $vnet)
    $candidates = @(foreach ($subnet in @(Get-Property $vnet 'subnets' | Where-Object { $_ })) {
        $assessment = Get-SubnetAssessment $subnet
        if ($assessment) {
            Add-Service -Service 'Container Apps subnet' -Name "$($vnet.name)/$($assessment.Name)" -ResourceGroup $vnet.resourceGroup -Location $vnet.location -Status $assessment.Status -Detail $assessment.Detail
            $assessment
        }
    })
    $readySubnets = @($candidates | Where-Object { $_.Status -eq 'Reusable' } | ForEach-Object { $_.Name })
    $delegateSubnets = @($candidates | Where-Object { $_.Status -eq 'Needs changes' } | ForEach-Object { $_.Name })
    $jobSubnet = if ($readySubnets) { $readySubnets -join ', ' } elseif ($delegateSubnets) { "delegate $($delegateSubnets -join ', ')" } else { 'none' }
    $peerNames = @($peerKeys | ForEach-Object { Get-VnetLabel $_ })
    $vnetCandidates.Add([pscustomobject]@{
        Name            = $vnet.name
        ResourceGroup   = $vnet.resourceGroup
        Location        = $vnet.location
        Key             = $vnetKey
        ReadySubnets    = $readySubnets
        EndpointSubnets = @(Get-Property $vnet 'subnets' | Where-Object { $_ -and @(Get-Property $_ 'privateEndpoints' | Where-Object { $_ }).Count -gt 0 } | ForEach-Object { $_.name })
        CustomDns       = $dnsServers.Count -gt 0
        PeerKeys        = $peerKeys
    })

    $dnsText = if ($dnsServers) { "custom DNS $($dnsServers -join ', ')" } else { 'Azure-provided DNS' }
    $vnetDetail = "address space $(@(Get-Property $vnet 'addressSpace.addressPrefixes') -join ', '), $dnsText, job subnet: $jobSubnet"
    if ($peerNames) {
        $vnetDetail += ", peered with $($peerNames -join ', ')"
    }
    $vnetArguments = @{ Service = 'Virtual network'; Name = $vnet.name; ResourceGroup = $vnet.resourceGroup; Location = $vnet.location }
    if ($readySubnets) {
        Add-Service @vnetArguments -Status 'Reusable' -Detail $vnetDetail
    } else {
        Add-Service @vnetArguments -Status 'Needs changes' -Detail "$vnetDetail. Add an empty subnet delegated to Microsoft.App/environments to host a replication job here."
    }

    # Server-side copy needs file endpoints for both accounts in the job VNet, or in a directly peered VNet.
    $reachable = @($endpointRecords | Where-Object { $_.Group -eq 'file' -and $_.Status -eq 'Approved' -and ($_.VnetKey -eq $vnetKey -or $peerKeys -contains $_.VnetKey) })
    $fileParts = @()
    $dnsParts = @()
    foreach ($accountGroup in $reachable | Group-Object TargetKey) {
        $accountEndpoints = @($accountGroup.Group)
        $accountName = $accountEndpoints[0].TargetName
        $isLocal = @($accountEndpoints | Where-Object { $_.VnetKey -eq $vnetKey }).Count -gt 0
        $fileParts += $(if ($isLocal) { $accountName } else { "$accountName (peered)" })
        $dnsParts += "$accountName $(Get-FileDnsState -VnetKey $vnetKey -AccountName $accountName -Endpoints $accountEndpoints -CustomDns ($dnsServers.Count -gt 0))"
    }
    $registryParts = @($endpointRecords | Where-Object { $_.Group -eq 'registry' -and $_.Status -eq 'Approved' -and ($_.VnetKey -eq $vnetKey -or $peerKeys -contains $_.VnetKey) } |
        ForEach-Object { if ($_.VnetKey -eq $vnetKey) { $_.TargetName } else { "$($_.TargetName) (peered)" } } | Select-Object -Unique)

    $networks.Add([pscustomobject]@{
        VirtualNetwork    = $vnet.name
        ResourceGroup     = $vnet.resourceGroup
        Location          = $vnet.location
        JobSubnet         = $jobSubnet
        FileEndpoints     = if ($fileParts) { $fileParts -join ', ' } else { 'none' }
        FileDns           = if ($dnsParts) { $dnsParts -join '; ' } else { '-' }
        RegistryEndpoints = if ($registryParts) { $registryParts -join ', ' } else { 'none' }
        PeeredWith        = if ($peerNames) { $peerNames -join ', ' } else { '-' }
    })
}

foreach ($record in $endpointRecords | Where-Object { Test-InScope $_.ResourceGroup }) {
    $ipText = if ($record.Ips) { ", IP $($record.Ips -join ', ')" } elseif (-not $record.IpsVerified) { ', IP not verified' } else { '' }
    $detail = "$($record.Group) endpoint for $($record.TargetName) in $(Get-VnetLabel $record.VnetKey)/$($record.SubnetName)$ipText"
    $endpointArguments = @{ Service = 'Private endpoint'; Name = $record.Name; ResourceGroup = $record.ResourceGroup; Location = $record.Location }
    switch ($record.Status) {
        'Approved' { Add-Service @endpointArguments -Status 'Reusable' -Detail $detail }
        'Pending' { Add-Service @endpointArguments -Status 'Needs changes' -Detail "$detail. Approve the pending connection." }
        default { Add-Service @endpointArguments -Status 'Not suitable' -Detail "$detail. The connection state is $($record.Status); create a new endpoint." }
    }
}

foreach ($zone in $zoneRecords | Where-Object { Test-InScope $_.ResourceGroup }) {
    $zoneArguments = @{ Service = 'Private DNS zone'; Name = $zone.Name; ResourceGroup = $zone.ResourceGroup; Location = 'global' }
    if (-not $zone.LinksVerified) {
        Add-Service @zoneArguments -Status 'Not verified' -Detail "Could not list virtual network links: $($zone.LinksError)"
        continue
    }
    $linkedNames = @($zone.LinkedVnetKeys | ForEach-Object { Get-VnetLabel $_ })
    $detail = "record sets=$($zone.RecordSetCount), linked to $(if ($linkedNames) { $linkedNames -join ', ' } else { 'no virtual networks' })"
    if ($linkedNames.Count -eq 0) {
        Add-Service @zoneArguments -Status 'Needs changes' -Detail "$detail. Link the zone to the job VNets."
    } elseif ($zone.IsFileZone -and $linkedNames.Count -gt 1) {
        Add-Service @zoneArguments -Status 'Reusable' -Detail "$detail. The zone is shared, so a new file endpoint record changes name resolution in every linked VNet."
    } else {
        Add-Service @zoneArguments -Status 'Reusable' -Detail $detail
    }
}

foreach ($registry in $registries | Where-Object { Test-InScope $_.resourceGroup }) {
    $sku = [string](Get-Property $registry 'sku.name')
    $publicAccess = [string](Get-Property $registry 'publicNetworkAccess')
    $registryKey = ConvertTo-Key $registry.id
    $approvedVnets = @($endpointRecords | Where-Object { $_.Group -eq 'registry' -and $_.Status -eq 'Approved' -and $_.TargetKey -eq $registryKey } | ForEach-Object { Get-VnetLabel $_.VnetKey } | Select-Object -Unique)
    $detail = "sku=$sku, publicNetworkAccess=$publicAccess"
    if ($sku -eq 'Premium') {
        $replications = Invoke-Az -Arguments @('acr', 'replication', 'list', '--registry', $registry.name, '--resource-group', $registry.resourceGroup)
        if ($replications.Succeeded) {
            $detail += ", replicas in $(@($replications.Value | Where-Object { $_ } | ForEach-Object { Get-Property $_ 'location' }) -join ', ')"
        } else {
            $detail += ', replicas not verified'
        }
    }
    if ($approvedVnets) {
        $detail += ", private endpoints in $($approvedVnets -join ', ')"
    } else {
        $detail += ', no approved private endpoints'
    }
    $registryArguments = @{ Service = 'Container registry'; Name = $registry.name; ResourceGroup = $registry.resourceGroup; Location = $registry.location }
    $isAbac = (Get-Property $registry 'roleAssignmentMode') -match '(?i)abac'
    # The deployment can create missing endpoints, so any registry the jobs can pull from with AcrPull is a candidate.
    if (-not $isAbac) {
        $registryCandidates.Add([pscustomobject]@{ Name = $registry.name; ResourceGroup = $registry.resourceGroup; Key = $registryKey; Sku = $sku; PublicAccess = $publicAccess })
    }
    if ($isAbac) {
        Add-Service @registryArguments -Status 'Needs changes' -Detail "$detail. ABAC repository permissions are enabled, so AcrPull isn't honored; assign Container Registry Repository Reader to both job identities."
    } elseif ($publicAccess -eq 'Disabled' -and $approvedVnets.Count -eq 0) {
        Add-Service @registryArguments -Status 'Needs changes' -Detail "$detail. Public access is disabled, so add private endpoints in the job VNets."
    } elseif ($sku -ne 'Premium') {
        Add-Service @registryArguments -Status 'Reusable' -Detail "$detail. Jobs reach it only through its public endpoint; private endpoints require Premium."
    } else {
        Add-Service @registryArguments -Status 'Reusable' -Detail $detail
    }
}

$serviceOrder = @{ 'Resource group' = 0; 'Storage account' = 1; 'File share' = 2; 'Virtual network' = 3; 'Container Apps subnet' = 4; 'Private endpoint' = 5; 'Private DNS zone' = 6; 'Container registry' = 7 }
$sortedServices = @($services | Sort-Object @{ Expression = { $serviceOrder[$_.Service] } }, Name)
$sortedNetworks = @($networks | Sort-Object Location, VirtualNetwork)
$auditedGroups = @($scopeKeys.Values | Sort-Object)

Write-Host ''
Write-Host 'Azure Files replication reuse audit' -ForegroundColor Cyan
Write-Host "Subscription    : $($account.Value.name) ($subscriptionId)"
Write-Host "Tenant          : $($account.Value.tenantId)"
Write-Host "Resource groups : $(if ($requestedGroups.Count -gt 0) { $auditedGroups -join ', ' } else { "all $($auditedGroups.Count) in the subscription" })"

Write-Host ''
Write-Host 'Services' -ForegroundColor Cyan
if ($sortedServices.Count -gt 0) {
    $sortedServices | Format-Table -Property Status, Service, Name, ResourceGroup, Location, Detail -AutoSize -Wrap | Out-String -Width 240 | Write-Host
} else {
    Write-Host 'No storage, network, endpoint, DNS, or registry resources were found in the audited resource groups.'
    Write-Host ''
}

Write-Host 'Replication network readiness' -ForegroundColor Cyan
if ($sortedNetworks.Count -gt 0) {
    $sortedNetworks | Format-Table -Property VirtualNetwork, Location, JobSubnet, FileEndpoints, FileDns, RegistryEndpoints -AutoSize -Wrap | Out-String -Width 240 | Write-Host
} else {
    Write-Host 'No virtual networks were found in the audited resource groups.'
    Write-Host ''
}

$summary = [ordered]@{
    Reusable     = @($services | Where-Object Status -eq 'Reusable').Count
    NeedsChanges = @($services | Where-Object Status -eq 'Needs changes').Count
    NotSuitable  = @($services | Where-Object Status -eq 'Not suitable').Count
    NotVerified  = @($services | Where-Object Status -eq 'Not verified').Count
}
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ("Services: {0} reusable, {1} need changes, {2} not suitable, {3} not verified." -f $summary.Reusable, $summary.NeedsChanges, $summary.NotSuitable, $summary.NotVerified)
Write-Host 'Choose two VNets in different regions whose readiness rows show a job subnet, file endpoints that resolve for both storage accounts, and a registry endpoint.'
Write-Host 'Record them in infra/existing.bicepparam, then validate the configuration with: pwsh ./scripts/inventory.ps1 -ParametersFile ./infra/existing.bicepparam'
Write-Host 'Endpoints and private DNS zones in other subscriptions are not audited.'

if ($OutputPath) {
    [pscustomobject]@{
        GeneratedAt           = (Get-Date).ToUniversalTime().ToString('o')
        SubscriptionId        = $subscriptionId
        TenantId              = $account.Value.tenantId
        ResourceGroups        = $auditedGroups
        MissingResourceGroups = @($missingGroups)
        Summary               = $summary
        Services              = $sortedServices
        Networks              = $sortedNetworks
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Host "Report written to $OutputPath"
}

if ($ParametersOutputPath) {
    function ConvertTo-BicepString([string]$Value) {
        return "'" + ($Value -replace '\\', '\\' -replace "'", "\'") + "'"
    }

    function ConvertTo-CidrRange([string]$Cidr) {
        if ($Cidr -notmatch '^(\d{1,3}(?:\.\d{1,3}){3})/(\d{1,2})$') {
            return $null
        }
        $length = [int]$Matches[2]
        $address = $null
        if ($length -gt 32 -or -not [System.Net.IPAddress]::TryParse($Matches[1], [ref]$address)) {
            return $null
        }
        $bytes = $address.GetAddressBytes()
        $value = ([double]$bytes[0] * 16777216) + ([double]$bytes[1] * 65536) + ([double]$bytes[2] * 256) + [double]$bytes[3]
        $size = [math]::Pow(2, 32 - $length)
        $start = [math]::Floor($value / $size) * $size
        return [pscustomobject]@{ Start = $start; End = $start + $size - 1 }
    }

    $placeholderCount = 0
    function New-Placeholder([string]$Text) {
        $script:placeholderCount++
        return "<$Text>"
    }

    function Test-Reachable($VnetCandidate, [string]$TargetKey, [string]$Group) {
        return @($endpointRecords | Where-Object {
            $_.Group -eq $Group -and $_.Status -eq 'Approved' -and $_.TargetKey -eq $TargetKey -and ($_.VnetKey -eq $VnetCandidate.Key -or $VnetCandidate.PeerKeys -contains $_.VnetKey)
        }).Count -gt 0
    }

    $locationKeys = @{ primary = ConvertTo-Key $PrimaryLocation; secondary = ConvertTo-Key $SecondaryLocation }

    # Storage: reuse the single SMB-capable account in each region, create one when there is none, and ask when there are several.
    $storageChoice = @{}
    foreach ($role in 'primary', 'secondary') {
        $taken = if ($role -eq 'secondary' -and $storageChoice['primary'].Candidate) { $storageChoice['primary'].Candidate.Key } else { '' }
        $inRegion = @($storageCandidates | Where-Object { (ConvertTo-Key $_.Location) -eq $locationKeys[$role] -and $_.Key -ne $taken })
        $selection = @{ Mode = 'existing'; Candidate = $null; Account = ''; Group = ''; Share = ''; Note = '' }
        if ($newServices -contains "${role}Storage") {
            $selection.Mode = 'new'
            $selection.Note = 'Created by the deployment, as requested with -New.'
        } elseif ($inRegion.Count -eq 0) {
            $selection.Mode = 'new'
            $selection.Note = "Created by the deployment: the audited resource groups have no storage account with an SMB share in $($locationKeys[$role])."
        } elseif ($inRegion.Count -eq 1) {
            $candidate = $inRegion[0]
            $selection.Candidate = $candidate
            $selection.Account = $candidate.Name
            $selection.Group = $candidate.ResourceGroup
            $selection.Share = if ($candidate.Shares.Count -eq 1) { $candidate.Shares[0] } else { New-Placeholder "choose a share: $($candidate.Shares -join ' | ')" }
            $selection.Note = "Reuses the only account with an SMB share in $($locationKeys[$role])."
        } else {
            $selection.Account = New-Placeholder "choose an account: $(@($inRegion | ForEach-Object { $_.Name }) -join ' | ')"
            $selection.Group = New-Placeholder 'resource group of the chosen account'
            $selection.Share = New-Placeholder 'SMB share of the chosen account'
            $selection.Note = "Several accounts qualify: $(@($inRegion | ForEach-Object { "$($_.Name) in $($_.ResourceGroup) with shares $($_.Shares -join ', ')" }) -join '; ')."
        }
        $storageChoice[$role] = $selection
    }

    # Registry: prefer a single Premium registry, which supports private endpoints.
    $registryChoice = @{ Mode = 'existing'; Candidate = $null; Name = ''; Group = ''; EndpointsEnabled = $true; Note = '' }
    $premiumRegistries = @($registryCandidates | Where-Object { $_.Sku -eq 'Premium' })
    if ($newServices -contains 'registry') {
        $registryChoice.Mode = 'new'
        $registryChoice.Note = 'Created by the deployment, as requested with -New.'
    } elseif ($premiumRegistries.Count -eq 1 -or ($premiumRegistries.Count -eq 0 -and $registryCandidates.Count -eq 1)) {
        $candidate = if ($premiumRegistries.Count -eq 1) { $premiumRegistries[0] } else { $registryCandidates[0] }
        $registryChoice.Candidate = $candidate
        $registryChoice.Name = $candidate.Name
        $registryChoice.Group = $candidate.ResourceGroup
        if ($candidate.Sku -eq 'Premium') {
            $registryChoice.Note = 'Reuses the only Premium registry.'
        } else {
            $registryChoice.EndpointsEnabled = $false
            $registryChoice.Note = "Reuses the only registry. $($candidate.Sku) doesn't support private endpoints, so the jobs pull through its public endpoint."
        }
    } elseif ($registryCandidates.Count -gt 1) {
        $pool = if ($premiumRegistries.Count -gt 1) { $premiumRegistries } else { $registryCandidates }
        $registryChoice.Name = New-Placeholder "choose a registry: $(@($pool | ForEach-Object { $_.Name }) -join ' | ')"
        $registryChoice.Group = New-Placeholder 'resource group of the chosen registry'
        $registryChoice.Note = "Several registries qualify: $(@($pool | ForEach-Object { "$($_.Name) ($($_.Sku)) in $($_.ResourceGroup)" }) -join '; ')."
    } else {
        $registryChoice.Mode = 'new'
        $registryChoice.Note = 'Created by the deployment: the audited resource groups have no registry that the jobs can pull from with AcrPull.'
    }

    # Networks: reuse a VNet with an empty delegated subnet, preferring the one that already reaches the chosen services.
    $networkChoice = @{}
    foreach ($role in 'primary', 'secondary') {
        $selection = @{ Mode = 'existing'; Candidate = $null; Name = ''; Group = ''; Subnet = ''; EndpointsToCreate = @(); EndpointSubnet = $null; FileZoneId = $null; RegistryZoneId = $null; AddressPrefix = ''; Note = '' }
        $inRegion = @($vnetCandidates | Where-Object { (ConvertTo-Key $_.Location) -eq $locationKeys[$role] -and $_.ReadySubnets.Count -gt 0 })
        if ($newServices -contains "${role}Network") {
            $selection.Mode = 'new'
            $selection.Note = 'Created by the deployment, with its own private DNS zones, as requested with -New.'
        } elseif ($inRegion.Count -eq 0) {
            $selection.Mode = 'new'
            $selection.Note = "Created by the deployment: no audited VNet in $($locationKeys[$role]) has an empty subnet delegated to Microsoft.App/environments. To extend an existing VNet instead, set ${role}NetworkMode to newSubnet with a free ${role}InfrastructureSubnetPrefix."
        } else {
            $scored = @(foreach ($candidate in $inRegion) {
                $score = 0
                foreach ($storageRole in 'primary', 'secondary') {
                    if ($storageChoice[$storageRole].Candidate -and (Test-Reachable $candidate $storageChoice[$storageRole].Candidate.Key 'file')) {
                        $score++
                    }
                }
                if ($registryChoice.Candidate -and (Test-Reachable $candidate $registryChoice.Candidate.Key 'registry')) {
                    $score++
                }
                [pscustomobject]@{ Candidate = $candidate; Score = $score }
            })
            $bestScore = ($scored | Measure-Object -Property Score -Maximum).Maximum
            $top = @($scored | Where-Object { $_.Score -eq $bestScore })
            if ($top.Count -eq 1) {
                $candidate = $top[0].Candidate
                $selection.Candidate = $candidate
                $selection.Name = $candidate.Name
                $selection.Group = $candidate.ResourceGroup
                $selection.Subnet = $candidate.ReadySubnets[0]
                $others = @($inRegion | Where-Object { $_.Key -ne $candidate.Key } | ForEach-Object { $_.Name })
                $selection.Note = "Reuses $($candidate.Name) and its empty delegated subnet $($candidate.ReadySubnets[0])$(if ($others) { ". Other candidates: $($others -join ', ')" })."
            } else {
                $selection.Name = New-Placeholder "choose a VNet: $(@($top | ForEach-Object { $_.Candidate.Name }) -join ' | ')"
                $selection.Group = New-Placeholder 'resource group of the chosen VNet'
                $selection.Subnet = New-Placeholder 'empty delegated subnet of the chosen VNet'
                $selection.Note = "Several VNets qualify equally: $(@($top | ForEach-Object { "$($_.Candidate.Name) in $($_.Candidate.ResourceGroup) with subnets $($_.Candidate.ReadySubnets -join ', ')" }) -join '; '). Endpoint settings depend on your choice."
            }
        }
        $networkChoice[$role] = $selection
    }

    $usedRanges = @($virtualNetworks | ForEach-Object { @(Get-Property $_ 'addressSpace.addressPrefixes') } | ForEach-Object { ConvertTo-CidrRange $_ } | Where-Object { $_ })
    function Get-FreeAddressPrefix([string]$Preferred) {
        foreach ($prefix in @($Preferred) + @(1..25 | ForEach-Object { "10.$($_ * 10).0.0/16" })) {
            $range = ConvertTo-CidrRange $prefix
            if (@($script:usedRanges | Where-Object { $_.Start -le $range.End -and $range.Start -le $_.End }).Count -eq 0) {
                $script:usedRanges += $range
                return $prefix
            }
        }
        return $Preferred
    }

    $newTargetsNeedEndpoints = $storageChoice['primary'].Mode -eq 'new' -or $storageChoice['secondary'].Mode -eq 'new' -or $registryChoice.Mode -eq 'new'
    foreach ($role in 'primary', 'secondary') {
        $selection = $networkChoice[$role]
        if ($selection.Mode -eq 'new') {
            $selection.AddressPrefix = Get-FreeAddressPrefix $(if ($role -eq 'primary') { '10.10.0.0/16' } else { '10.20.0.0/16' })
            continue
        }
        if (-not $selection.Candidate) {
            continue
        }
        $candidate = $selection.Candidate
        $toCreate = @()
        foreach ($storageRole in 'primary', 'secondary') {
            $storage = $storageChoice[$storageRole]
            if ($storage.Candidate -and -not (Test-Reachable $candidate $storage.Candidate.Key 'file')) {
                $toCreate += "${storageRole}Storage"
            }
        }
        if ($registryChoice.Candidate -and $registryChoice.EndpointsEnabled -and -not (Test-Reachable $candidate $registryChoice.Candidate.Key 'registry')) {
            $toCreate += 'registry'
        }
        $selection.EndpointsToCreate = $toCreate
        if ($toCreate.Count -gt 0 -or $newTargetsNeedEndpoints) {
            $selection.EndpointSubnet = if ($candidate.EndpointSubnets.Count -eq 1) { $candidate.EndpointSubnets[0] } elseif ($candidate.EndpointSubnets.Count -gt 1) { New-Placeholder "choose an endpoint subnet: $($candidate.EndpointSubnets -join ' | ')" } else { New-Placeholder "subnet of $($candidate.Name) for new private endpoints" }
            $needsFileZone = $toCreate -contains 'primaryStorage' -or $toCreate -contains 'secondaryStorage' -or $storageChoice['primary'].Mode -eq 'new' -or $storageChoice['secondary'].Mode -eq 'new'
            $needsRegistryZone = $toCreate -contains 'registry' -or $registryChoice.Mode -eq 'new'
            if ($needsFileZone) {
                $zone = @($zoneRecords | Where-Object { $_.IsFileZone -and $_.LinkedVnetKeys -contains $candidate.Key }) | Select-Object -First 1
                $selection.FileZoneId = if ($zone -and $zone.Id) { [string]$zone.Id } else { '' }
            }
            if ($needsRegistryZone) {
                $zone = @($zoneRecords | Where-Object { -not $_.IsFileZone -and $_.LinkedVnetKeys -contains $candidate.Key }) | Select-Object -First 1
                $selection.RegistryZoneId = if ($zone -and $zone.Id) { [string]$zone.Id } else { '' }
            }
        }
    }

    # Endpoints between existing services that the chosen VNets already use, recorded for reference.
    $referencedEndpoints = @(foreach ($role in 'primary', 'secondary') {
        $candidate = $networkChoice[$role].Candidate
        if (-not $candidate) {
            continue
        }
        foreach ($target in @(@{ Choice = $storageChoice['primary'].Candidate; Group = 'file' }, @{ Choice = $storageChoice['secondary'].Candidate; Group = 'file' }, @{ Choice = $registryChoice.Candidate; Group = 'registry' })) {
            if (-not $target.Choice) {
                continue
            }
            $endpointRecords | Where-Object {
                $_.Group -eq $target.Group -and $_.Status -eq 'Approved' -and $_.TargetKey -eq $target.Choice.Key -and ($_.VnetKey -eq $candidate.Key -or $candidate.PeerKeys -contains $_.VnetKey)
            } | ForEach-Object { $_.Id }
        }
    }) | Select-Object -Unique

    $lines = [System.Collections.Generic.List[string]]::new()
    function Add-Param([string]$Name, $Value) {
        if ($Value -is [bool]) {
            $lines.Add("param $Name = $($Value.ToString().ToLowerInvariant())")
        } elseif ($Value -is [int]) {
            $lines.Add("param $Name = $Value")
        } elseif ($Value -is [array]) {
            if ($Value.Count -eq 0) {
                $lines.Add("param $Name = []")
            } else {
                $lines.Add("param $Name = [")
                foreach ($item in $Value) {
                    $lines.Add("  $(ConvertTo-BicepString $item)")
                }
                $lines.Add(']')
            }
        } else {
            $lines.Add("param $Name = $(ConvertTo-BicepString ([string]$Value))")
        }
    }

    $outputFullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ParametersOutputPath)
    $templatePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\infra\existing.bicep'))
    $usingPath = [IO.Path]::GetRelativePath((Split-Path -Parent $outputFullPath), $templatePath) -replace '\\', '/'
    if (-not $usingPath.StartsWith('.')) {
        $usingPath = "./$usingPath"
    }
    $scopeText = if ($requestedGroups.Count -gt 0) { "resource groups $($auditedGroups -join ', ')" } else { 'every resource group in the subscription' }

    $lines.Add("using '$usingPath'")
    $lines.Add('')
    $lines.Add("// Generated by scripts/audit-existing-resources.ps1 on $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')) from $scopeText.")
    $lines.Add("// Services set to 'existing' are reused as they are; services set to 'new' are created by the deployment.")
    $lines.Add('// Replace every value in angle brackets, review each value, then validate the file with scripts/inventory.ps1.')
    $lines.Add('')
    Add-Param 'resourceGroupName' $ReplicationResourceGroupName
    Add-Param 'resourceGroupLocation' $locationKeys['primary']
    Add-Param 'primaryLocation' $locationKeys['primary']
    Add-Param 'secondaryLocation' $locationKeys['secondary']
    Add-Param 'primaryRegionCode' $PrimaryRegionCode
    Add-Param 'secondaryRegionCode' $SecondaryRegionCode
    Add-Param 'environmentName' 'prod'
    $secondaryGroup = if ($SecondaryResourceGroupName) { $SecondaryResourceGroupName } else { $ReplicationResourceGroupName }
    $regionGroups = @{ primary = $ReplicationResourceGroupName; secondary = $secondaryGroup }
    $regionCodes = @{ primary = $PrimaryRegionCode; secondary = $SecondaryRegionCode }
    if ((ConvertTo-Key $secondaryGroup) -ne (ConvertTo-Key $ReplicationResourceGroupName)) {
        $lines.Add('// Secondary-region compute, and new secondary-region services by default, go in their own resource group.')
        Add-Param 'secondaryResourceGroupName' $secondaryGroup
        Add-Param 'secondaryResourceGroupLocation' $locationKeys['secondary']
    }

    foreach ($role in 'primary', 'secondary') {
        $storage = $storageChoice[$role]
        $lines.Add('')
        $lines.Add("// $(if ($role -eq 'primary') { 'Primary storage, the replication source' } else { 'Secondary storage, the replication destination' }): $($storage.Note)")
        Add-Param "${role}StorageMode" $storage.Mode
        if ($storage.Mode -eq 'existing') {
            if ($role -eq 'secondary') {
                $lines.Add('// Review: replication copies into this share and never deletes extra files.')
            }
            Add-Param "${role}StorageAccountName" $storage.Account
            Add-Param "${role}StorageResourceGroupName" $storage.Group
            Add-Param "${role}FileShareName" $storage.Share
        } else {
            $lines.Add("// Optional: name the new account and share, and choose its resource group. Empty values generate a name and use $($regionGroups[$role]).")
            Add-Param "${role}StorageAccountName" ''
            Add-Param "${role}StorageResourceGroupName" ''
            $primaryShare = $storageChoice['primary'].Share
            $shareValue = if ($role -eq 'secondary' -and $storageChoice['primary'].Mode -eq 'existing' -and $primaryShare -and $primaryShare -notmatch '^<') { $primaryShare } else { '' }
            Add-Param "${role}FileShareName" $shareValue
            Add-Param "${role}StorageSkuName" 'Standard_LRS'
        }
    }

    foreach ($role in 'primary', 'secondary') {
        $network = $networkChoice[$role]
        $lines.Add('')
        $lines.Add("// $(if ($role -eq 'primary') { 'Primary' } else { 'Secondary' }) network: $($network.Note)")
        Add-Param "${role}NetworkMode" $network.Mode
        if ($network.Mode -eq 'new') {
            $lines.Add("// Optional: name the new VNet and its job and endpoint subnets, and choose its resource group. Empty values generate names and use $($regionGroups[$role]).")
            Add-Param "${role}VnetName" ''
            Add-Param "${role}VnetResourceGroupName" ''
            Add-Param "${role}InfrastructureSubnetName" ''
            Add-Param "${role}PrivateEndpointSubnetName" ''
            Add-Param "${role}VnetAddressPrefix" $network.AddressPrefix
            $lines.Add('// Each new VNet keeps its private DNS zones in a resource group of its own, because the zone names are the same in both regions.')
            Add-Param "${role}DnsResourceGroupName" "$($regionGroups[$role])-$($regionCodes[$role])-dns"
            continue
        }
        Add-Param "${role}VnetName" $network.Name
        Add-Param "${role}VnetResourceGroupName" $network.Group
        Add-Param "${role}InfrastructureSubnetName" $network.Subnet
        if ($network.EndpointsToCreate.Count -gt 0) {
            $lines.Add("// These existing services have no approved endpoint in this VNet or a directly peered VNet, so the deployment creates one.")
            Add-Param "${role}EndpointsToCreate" @($network.EndpointsToCreate)
        }
        if ($null -ne $network.EndpointSubnet) {
            Add-Param "${role}PrivateEndpointSubnetName" $network.EndpointSubnet
        }
        if ($null -ne $network.FileZoneId) {
            if (-not $network.FileZoneId) {
                $lines.Add("// No privatelink.file zone linked to this VNet was found in this subscription. Set a zone ID, or leave it empty if policy creates the records.")
            }
            Add-Param "${role}FileDnsZoneId" $network.FileZoneId
        }
        if ($null -ne $network.RegistryZoneId) {
            if (-not $network.RegistryZoneId) {
                $lines.Add("// No privatelink.azurecr.io zone linked to this VNet was found in this subscription. Set a zone ID, or leave it empty if policy creates the records.")
            }
            Add-Param "${role}RegistryDnsZoneId" $network.RegistryZoneId
        }
    }

    $lines.Add('')
    $lines.Add("// Registry: $($registryChoice.Note)")
    Add-Param 'registryMode' $registryChoice.Mode
    if ($registryChoice.Mode -eq 'existing') {
        Add-Param 'registryName' $registryChoice.Name
        Add-Param 'registryResourceGroupName' $registryChoice.Group
        if (-not $registryChoice.EndpointsEnabled) {
            Add-Param 'registryPrivateEndpointsEnabled' $false
        }
    } else {
        $lines.Add("// Optional: name the new registry and choose its resource group. Empty values generate a name and use $ReplicationResourceGroupName.")
        Add-Param 'registryName' ''
        Add-Param 'registryResourceGroupName' ''
    }

    $lines.Add('')
    $lines.Add('// Optional names for the other resources the deployment creates. Uncomment and set the names you need; empty or omitted names are generated.')
    $lines.Add('// param resourceNames = {')
    foreach ($key in 'primaryIdentity', 'secondaryIdentity', 'primaryLogWorkspace', 'secondaryLogWorkspace', 'primaryEnvironment', 'secondaryEnvironment', 'primaryJob', 'secondaryJob',
        'primaryVnetPrimaryStorageEndpoint', 'primaryVnetSecondaryStorageEndpoint', 'primaryVnetRegistryEndpoint', 'secondaryVnetPrimaryStorageEndpoint', 'secondaryVnetSecondaryStorageEndpoint', 'secondaryVnetRegistryEndpoint',
        'actionGroup', 'primaryFailureAlert', 'secondaryFailureAlert', 'primaryFreshnessAlert', 'secondaryFreshnessAlert') {
        $lines.Add("//   ${key}: ''")
    }
    $lines.Add('// }')

    # The deployment creates every resource group it uses except the listed ones, so list the ones that already exist.
    $targetGroups = @{}
    function Add-TargetGroup([string]$Name) {
        if ($Name) {
            $script:targetGroups[(ConvertTo-Key $Name)] = $Name
        }
    }
    Add-TargetGroup $ReplicationResourceGroupName
    Add-TargetGroup $secondaryGroup
    foreach ($role in 'primary', 'secondary') {
        if ($storageChoice[$role].Mode -eq 'new') {
            Add-TargetGroup $regionGroups[$role]
        }
        if ($networkChoice[$role].Mode -eq 'new') {
            Add-TargetGroup $regionGroups[$role]
            Add-TargetGroup "$($regionGroups[$role])-$($regionCodes[$role])-dns"
        } elseif ($null -ne $networkChoice[$role].EndpointSubnet) {
            Add-TargetGroup $regionGroups[$role]
        }
    }
    $existingTargets = @($targetGroups.Keys | Sort-Object | Where-Object { $groupsByKey.ContainsKey($_) } | ForEach-Object { $groupsByKey[$_] })
    $lines.Add('')
    $lines.Add('// Resource groups that already exist. The deployment creates the other groups it uses, and leaves these unchanged.')
    Add-Param 'existingResourceGroups' $existingTargets

    $lines.Add('')
    $lines.Add('// Existing endpoints this configuration uses; the template records them for reference only.')
    Add-Param 'existingPrivateEndpointIds' @($referencedEndpoints)
    $lines.Add('')
    Add-Param 'activeRegion' 'none'
    $lines.Add('// scripts/deploy.ps1 builds and pins the AzCopy image. For a direct deployment, set containerImage to a digest-pinned image.')
    Add-Param 'scheduleCronExpression' '*/10 * * * *'
    $alertAddresses = @($AlertEmailAddress | Where-Object { $_ } | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($alertAddresses.Count -eq 0) {
        $alertAddresses = @(New-Placeholder 'operations-email-address')
    }
    Add-Param 'alertEmailAddresses' $alertAddresses
    Add-Param 'replicationLagThresholdMinutes' 30
    Add-Param 'monitoringEnabled' $true

    $outputDirectory = Split-Path -Parent $outputFullPath
    if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory)) {
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
    }
    [IO.File]::WriteAllText($outputFullPath, (($lines -join "`n") + "`n"))

    $modes = @($storageChoice['primary'].Mode, $storageChoice['secondary'].Mode, $networkChoice['primary'].Mode, $networkChoice['secondary'].Mode, $registryChoice.Mode)
    Write-Host ''
    Write-Host 'Parameter file' -ForegroundColor Cyan
    Write-Host "Written to ${outputFullPath}: $(@($modes | Where-Object { $_ -eq 'existing' }).Count) services reused, $(@($modes | Where-Object { $_ -ne 'existing' }).Count) created by the deployment, $placeholderCount placeholder(s) to replace."
    $compiled = Invoke-Az -Arguments @('bicep', 'build-params', '--file', $outputFullPath, '--stdout')
    if (-not $compiled.Succeeded) {
        Write-Warning "The parameter file doesn't compile against existing.bicep: $($compiled.Error)"
    }
    Write-Host "Keep it out of source control; infra/existing.bicepparam and infra/*.local.bicepparam are git-ignored. Next: pwsh ./scripts/inventory.ps1 -ParametersFile $ParametersOutputPath"
}