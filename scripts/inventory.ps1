[CmdletBinding()]
param(
    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\infra\main.bicepparam'),
    [string]$Location,
    [switch]$SkipWhatIf,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Read-only inventory: every Azure CLI call below is a show, list, build, or what-if operation.

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
        NotFound  = $exitCode -ne 0 -and $errorText -match '(?i)not ?found|could not be found|does not exist'
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

$prerequisites = [System.Collections.Generic.List[object]]::new()
$resources = [System.Collections.Generic.List[object]]::new()

function Add-Prerequisite {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Item,
        [Parameter(Mandatory)][ValidateSet('Ready', 'Action required', 'Warning', 'Not verified')][string]$Status,
        [string]$Detail = ''
    )
    $prerequisites.Add([pscustomobject]@{ Area = $Area; Item = $Item; Status = $Status; Detail = $Detail })
}

function Add-LookupFailure {
    param([string]$Area, [string]$Item, $Result, [string]$MissingDetail)

    if ($Result.NotFound) {
        Add-Prerequisite -Area $Area -Item $Item -Status 'Action required' -Detail $MissingDetail
    } else {
        Add-Prerequisite -Area $Area -Item $Item -Status 'Not verified' -Detail $Result.Error
    }
}

function Get-ResourceDescriptor([string]$ResourceId) {
    $relative = $ResourceId -replace '^/subscriptions/[^/]+', ''
    $resourceGroup = if ($relative -match '^/resourceGroups/([^/]+)') { $Matches[1] } else { '' }
    $providerIndex = $relative.LastIndexOf('/providers/', [StringComparison]::OrdinalIgnoreCase)
    if ($providerIndex -lt 0) {
        return [pscustomobject]@{ Type = 'Microsoft.Resources/resourceGroups'; Name = $resourceGroup; ResourceGroup = $resourceGroup }
    }

    $segments = $relative.Substring($providerIndex + '/providers/'.Length).Split('/')
    $types = for ($index = 1; $index -lt $segments.Count; $index += 2) { $segments[$index] }
    $names = for ($index = 2; $index -lt $segments.Count; $index += 2) { $segments[$index] }
    $name = $names -join '/'

    $parent = $relative.Substring(0, $providerIndex)
    if ($parent -match '/providers/.+/([^/]+)$') {
        $name = "$name on $($Matches[1])"
    }
    [pscustomobject]@{ Type = "$($segments[0])/$($types -join '/')"; Name = $name; ResourceGroup = $resourceGroup }
}

$account = Invoke-Az -Arguments @('account', 'show')
if (-not $account.Succeeded) {
    throw "Sign in with az login before running the inventory. $($account.Error)"
}
$subscriptionId = $account.Value.id

$build = Invoke-Az -Arguments @('bicep', 'build-params', '--file', $ParametersFile, '--stdout')
if (-not $build.Succeeded) {
    throw "Could not compile '$ParametersFile'. $($build.Error)"
}
$suppliedParameters = ($build.Value.parametersJson | ConvertFrom-Json -Depth 100).parameters
$templateParameters = ($build.Value.templateJson | ConvertFrom-Json -Depth 100).parameters

function Get-ParameterValue([string]$Name) {
    $supplied = Get-Property $suppliedParameters $Name
    if ($null -ne $supplied) {
        return Get-Property $supplied 'value'
    }
    $default = Get-Property (Get-Property $templateParameters $Name) 'defaultValue'
    if ($default -is [string] -and $default.StartsWith('[')) {
        return $null
    }
    return $default
}

$isExistingProfile = $null -ne (Get-Property $templateParameters 'primaryStorageAccountName')
$profileName = if ($isExistingProfile) { 'existing resources (infra/existing.bicep)' } else { 'greenfield (infra/main.bicep)' }
$primaryLocation = Get-ParameterValue 'primaryLocation'
$secondaryLocation = Get-ParameterValue 'secondaryLocation'
if (-not $Location) {
    $Location = $primaryLocation
}

$placeholders = @($suppliedParameters.PSObject.Properties | Where-Object {
    $value = Get-Property $_.Value 'value'
    @($value) | Where-Object { $_ -is [string] -and $_ -match '<[^>]+>' }
} | ForEach-Object { $_.Name })
$hasPlaceholders = $placeholders.Count -gt 0
if ($hasPlaceholders) {
    Add-Prerequisite -Area 'Parameters' -Item (Split-Path $ParametersFile -Leaf) -Status 'Action required' -Detail "Replace placeholder values: $($placeholders -join ', '). Resource lookups and what-if are skipped until then."
} else {
    Add-Prerequisite -Area 'Parameters' -Item (Split-Path $ParametersFile -Leaf) -Status 'Ready' -Detail 'No placeholder values.'
}
if (@(Get-ParameterValue 'alertEmailAddresses') | Where-Object { $_ -match '(?i)@example\.(com|org|net)$' }) {
    Add-Prerequisite -Area 'Parameters' -Item 'alertEmailAddresses' -Status 'Warning' -Detail 'Uses an example address; pass a monitored address, for example --parameters alertEmailAddresses=...'
}

foreach ($namespace in 'Microsoft.App', 'Microsoft.ContainerRegistry', 'Microsoft.Insights', 'Microsoft.ManagedIdentity', 'Microsoft.Network', 'Microsoft.OperationalInsights', 'Microsoft.Storage') {
    $provider = Invoke-Az -Arguments @('provider', 'show', '--namespace', $namespace)
    if (-not $provider.Succeeded) {
        Add-Prerequisite -Area 'Resource provider' -Item $namespace -Status 'Not verified' -Detail $provider.Error
        continue
    }
    $state = Get-Property $provider.Value 'registrationState'
    if ($state -eq 'Registered') {
        Add-Prerequisite -Area 'Resource provider' -Item $namespace -Status 'Ready' -Detail 'Registered.'
    } else {
        Add-Prerequisite -Area 'Resource provider' -Item $namespace -Status 'Action required' -Detail "State is $state. Run: az provider register --namespace $namespace"
    }

    if ($namespace -eq 'Microsoft.App') {
        $environmentType = @(Get-Property $provider.Value 'resourceTypes') | Where-Object { (Get-Property $_ 'resourceType') -eq 'managedEnvironments' } | Select-Object -First 1
        $supportedRegions = @(Get-Property $environmentType 'locations' | ForEach-Object { ConvertTo-Key $_ })
        foreach ($region in @($primaryLocation, $secondaryLocation) | Where-Object { $_ -and $_ -notmatch '<' }) {
            if ($supportedRegions -contains (ConvertTo-Key $region)) {
                Add-Prerequisite -Area 'Region' -Item "Container Apps in $region" -Status 'Ready' -Detail 'Available.'
            } else {
                Add-Prerequisite -Area 'Region' -Item "Container Apps in $region" -Status 'Action required' -Detail 'Microsoft.App/managedEnvironments is not offered in this region for the subscription.'
            }
        }
    }
}

if (-not $isExistingProfile -and $primaryLocation -and $secondaryLocation) {
    $skus = Invoke-Az -Arguments @('rest', '--method', 'get', '--url', "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Storage/skus?api-version=2023-05-01")
    foreach ($requirement in @(@{ Sku = 'Standard_ZRS'; Region = $primaryLocation; Purpose = 'primary storage accounts and zone-redundant ACR' }, @{ Sku = 'Standard_LRS'; Region = $secondaryLocation; Purpose = 'secondary storage accounts' })) {
        $item = "$($requirement.Sku) in $($requirement.Region)"
        if (-not $skus.Succeeded) {
            Add-Prerequisite -Area 'Region' -Item $item -Status 'Not verified' -Detail $skus.Error
            continue
        }
        $regionKey = ConvertTo-Key $requirement.Region
        $offer = @(Get-Property $skus.Value 'value') | Where-Object {
            (Get-Property $_ 'name') -eq $requirement.Sku -and (Get-Property $_ 'kind') -eq 'StorageV2' -and
            (@(Get-Property $_ 'locations' | ForEach-Object { ConvertTo-Key $_ }) -contains $regionKey)
        } | Select-Object -First 1
        $restricted = $offer -and @(Get-Property $offer 'restrictions' | Where-Object {
            @(Get-Property $_ 'values' | ForEach-Object { ConvertTo-Key $_ }) -contains $regionKey
        }).Count -gt 0
        if ($offer -and -not $restricted) {
            Add-Prerequisite -Area 'Region' -Item $item -Status 'Ready' -Detail "Available for $($requirement.Purpose)."
        } else {
            Add-Prerequisite -Area 'Region' -Item $item -Status 'Action required' -Detail "Not available for $($requirement.Purpose); choose another region."
        }
    }
}

if ($isExistingProfile -and -not $hasPlaceholders) {
    $storageSuffix = Get-Property (Invoke-Az -Arguments @('cloud', 'show')).Value 'suffixes.storageEndpoint'
    if (-not $storageSuffix) {
        $storageSuffix = 'core.windows.net'
    }
    $fileZoneName = "privatelink.file.$storageSuffix"
    $endpointCache = @{}

    function Get-EndpointDetails([string]$EndpointId) {
        $key = ConvertTo-Key $EndpointId
        if ($endpointCache.ContainsKey($key)) {
            return $endpointCache[$key]
        }
        $endpoint = Invoke-Az -Arguments @('network', 'private-endpoint', 'show', '--ids', $EndpointId)
        $details = $null
        if ($endpoint.Succeeded) {
            $connections = @(Get-Property $endpoint.Value 'privateLinkServiceConnections') + @(Get-Property $endpoint.Value 'manualPrivateLinkServiceConnections') | Where-Object { $_ }
            $ips = foreach ($nic in @(Get-Property $endpoint.Value 'networkInterfaces')) {
                $nicResult = Invoke-Az -Arguments @('network', 'nic', 'show', '--ids', (Get-Property $nic 'id'))
                @(Get-Property $nicResult.Value 'ipConfigurations') | ForEach-Object { Get-Property $_ 'privateIPAddress' }
            }
            $subnetId = [string](Get-Property $endpoint.Value 'subnet.id')
            $details = [pscustomobject]@{
                Id       = $EndpointId
                VnetId   = ConvertTo-Key ($subnetId -replace '/subnets/[^/]+$', '')
                GroupIds = @($connections | ForEach-Object { Get-Property $_ 'groupIds' })
                Ips      = @($ips | Where-Object { $_ })
            }
        }
        $endpointCache[$key] = $details
        return $details
    }

    function Get-ApprovedEndpoints($Resource, [string]$GroupId) {
        foreach ($connection in @(Get-Property $Resource 'privateEndpointConnections')) {
            $status = Get-Property $connection 'privateLinkServiceConnectionState.status'
            $endpointId = Get-Property $connection 'privateEndpoint.id'
            if ($status -ne 'Approved' -or -not $endpointId) {
                continue
            }
            $details = Get-EndpointDetails $endpointId
            if ($details -and $details.GroupIds -contains $GroupId) {
                $details
            }
        }
    }

    $sides = @{}
    foreach ($role in 'primary', 'secondary') {
        $accountName = Get-ParameterValue "${role}StorageAccountName"
        $accountGroup = Get-ParameterValue "${role}StorageResourceGroupName"
        $shareName = Get-ParameterValue "${role}FileShareName"
        $vnetName = Get-ParameterValue "${role}VnetName"
        $vnetGroup = Get-ParameterValue "${role}VnetResourceGroupName"
        $subnetName = Get-ParameterValue "${role}InfrastructureSubnetName"
        $expectedLocation = Get-ParameterValue "${role}Location"
        $side = [pscustomobject]@{ Role = $role; AccountName = $accountName; Account = $null; Share = $null; Vnet = $null; FileEndpoints = @() }

        $accountResult = Invoke-Az -Arguments @('storage', 'account', 'show', '--name', $accountName, '--resource-group', $accountGroup)
        if ($accountResult.Succeeded) {
            $side.Account = $accountResult.Value
            $accountDetail = "kind=$(Get-Property $side.Account 'kind'), sku=$(Get-Property $side.Account 'sku.name'), publicNetworkAccess=$(Get-Property $side.Account 'publicNetworkAccess')"
            if ((ConvertTo-Key (Get-Property $side.Account 'location')) -ne (ConvertTo-Key $expectedLocation)) {
                Add-Prerequisite -Area 'Storage' -Item "$role account $accountName" -Status 'Warning' -Detail "Located in $(Get-Property $side.Account 'location'), but the parameter file uses $expectedLocation. $accountDetail"
            } else {
                Add-Prerequisite -Area 'Storage' -Item "$role account $accountName" -Status 'Ready' -Detail $accountDetail
            }
            $side.FileEndpoints = @(Get-ApprovedEndpoints $side.Account 'file')

            $shareResult = Invoke-Az -Arguments @('storage', 'share-rm', 'show', '--resource-group', $accountGroup, '--storage-account', $accountName, '--name', $shareName, '--expand', 'stats')
            if ($shareResult.Succeeded) {
                $side.Share = $shareResult.Value
                $protocol = Get-Property $side.Share 'enabledProtocols'
                $usedGiB = [math]::Round([double](Get-Property $side.Share 'shareUsageBytes') / 1GB, 2)
                $shareDetail = "protocol=$protocol, quota=$(Get-Property $side.Share 'shareQuota') GiB, used=$usedGiB GiB"
                if ($protocol -and $protocol -ne 'SMB') {
                    Add-Prerequisite -Area 'Storage' -Item "$role share $shareName" -Status 'Action required' -Detail "Only SMB shares are supported. $shareDetail"
                } else {
                    Add-Prerequisite -Area 'Storage' -Item "$role share $shareName" -Status 'Ready' -Detail $shareDetail
                }
            } else {
                Add-LookupFailure -Area 'Storage' -Item "$role share $shareName" -Result $shareResult -MissingDetail "Share not found in account $accountName."
            }
        } else {
            Add-LookupFailure -Area 'Storage' -Item "$role account $accountName" -Result $accountResult -MissingDetail "Not found in resource group $accountGroup of subscription $subscriptionId."
        }

        $vnetResult = Invoke-Az -Arguments @('network', 'vnet', 'show', '--resource-group', $vnetGroup, '--name', $vnetName)
        if ($vnetResult.Succeeded) {
            $side.Vnet = $vnetResult.Value
            Add-Prerequisite -Area 'Network' -Item "$role VNet $vnetName" -Status 'Ready' -Detail "location=$(Get-Property $side.Vnet 'location')"
        } else {
            Add-LookupFailure -Area 'Network' -Item "$role VNet $vnetName" -Result $vnetResult -MissingDetail "Not found in resource group $vnetGroup."
        }

        $subnetResult = Invoke-Az -Arguments @('network', 'vnet', 'subnet', 'show', '--resource-group', $vnetGroup, '--vnet-name', $vnetName, '--name', $subnetName)
        if ($subnetResult.Succeeded) {
            $subnet = $subnetResult.Value
            $prefix = @(@(Get-Property $subnet 'addressPrefix') + @(Get-Property $subnet 'addressPrefixes') | Where-Object { $_ }) | Select-Object -First 1
            $prefixLength = if ($prefix -match '/(\d+)$') { [int]$Matches[1] } else { $null }
            $delegations = @(Get-Property $subnet 'delegations' | ForEach-Object { Get-Property $_ 'serviceName' })
            $links = @(Get-Property $subnet 'serviceAssociationLinks' | ForEach-Object { Get-Property $_ 'link' } | Where-Object { $_ })
            $subnetItem = "$role Container Apps subnet $subnetName"
            if ($delegations -notcontains 'Microsoft.App/environments') {
                Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'Action required' -Detail "Delegate the subnet to Microsoft.App/environments. prefix=$prefix"
            } elseif ($null -ne $prefixLength -and $prefixLength -gt 23) {
                Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'Warning' -Detail "prefix=$prefix is smaller than the documented /23."
            } elseif ($links.Count -gt 0) {
                Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'Warning' -Detail "Already used by $($links -join ', '). Expected only when redeploying this solution."
            } else {
                Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'Ready' -Detail "prefix=$prefix, delegated, not in use."
            }
        } else {
            Add-LookupFailure -Area 'Network' -Item "$role Container Apps subnet $subnetName" -Result $subnetResult -MissingDetail "Not found in VNet $vnetName."
        }
        $sides[$role] = $side
    }

    $primary = $sides['primary']
    $secondary = $sides['secondary']
    if ($primary.Share -and $secondary.Share) {
        $sourceBytes = [double](Get-Property $primary.Share 'shareUsageBytes')
        $destinationQuotaBytes = [double](Get-Property $secondary.Share 'shareQuota') * 1GB
        $destinationBytes = [double](Get-Property $secondary.Share 'shareUsageBytes')
        if ($destinationQuotaBytes -lt $sourceBytes) {
            Add-Prerequisite -Area 'Storage' -Item 'Destination share capacity' -Status 'Action required' -Detail 'The secondary share quota is smaller than the data in the primary share.'
        } elseif ($destinationBytes -gt 0) {
            Add-Prerequisite -Area 'Storage' -Item 'Destination share contents' -Status 'Warning' -Detail "The secondary share already holds $([math]::Round($destinationBytes / 1GB, 2)) GiB; replication merges into it and never deletes extra files."
        } else {
            Add-Prerequisite -Area 'Storage' -Item 'Destination share capacity' -Status 'Ready' -Detail 'The secondary share is empty and has enough quota for the primary data.'
        }
    }

    $registryName = Get-ParameterValue 'registryName'
    $registryResult = Invoke-Az -Arguments @('acr', 'show', '--name', $registryName, '--resource-group', (Get-ParameterValue 'registryResourceGroupName'))
    $registry = $null
    if ($registryResult.Succeeded) {
        $registry = $registryResult.Value
        $registryDetail = "sku=$(Get-Property $registry 'sku.name'), publicNetworkAccess=$(Get-Property $registry 'publicNetworkAccess')"
        if ((Get-Property $registry 'roleAssignmentMode') -match '(?i)abac') {
            Add-Prerequisite -Area 'Registry' -Item $registryName -Status 'Warning' -Detail "ABAC repository permissions are enabled, so AcrPull is not honored; assign Container Registry Repository Reader to both job identities. $registryDetail"
        } else {
            Add-Prerequisite -Area 'Registry' -Item $registryName -Status 'Ready' -Detail $registryDetail
        }

        $image = [string](Get-ParameterValue 'containerImage')
        $loginServer = [string](Get-Property $registry 'loginServer')
        if ($image -notmatch '@sha256:[a-fA-F0-9]{64}$') {
            Add-Prerequisite -Area 'Registry' -Item 'containerImage' -Status 'Action required' -Detail 'Pin the image by digest: <registry>.azurecr.io/<repository>@sha256:<digest>.'
        } elseif (-not $image.StartsWith("$loginServer/", [StringComparison]::OrdinalIgnoreCase)) {
            Add-Prerequisite -Area 'Registry' -Item 'containerImage' -Status 'Action required' -Detail "The image is not in $loginServer."
        } else {
            $manifest = Invoke-Az -Arguments @('acr', 'manifest', 'show-metadata', $image, '--registry', $registryName)
            if ($manifest.Succeeded) {
                Add-Prerequisite -Area 'Registry' -Item 'containerImage' -Status 'Ready' -Detail 'Digest found in the registry.'
            } else {
                Add-Prerequisite -Area 'Registry' -Item 'containerImage' -Status 'Not verified' -Detail "Could not read the manifest from this host. $($manifest.Error)"
            }
        }
    } else {
        Add-LookupFailure -Area 'Registry' -Item $registryName -Result $registryResult -MissingDetail 'Registry not found in the current subscription.'
    }

    $zones = Invoke-Az -Arguments @('network', 'private-dns', 'zone', 'list')
    $fileZones = @($zones.Value | Where-Object { (Get-Property $_ 'name') -eq $fileZoneName })
    $registryEndpoints = if ($registry) { @(Get-ApprovedEndpoints $registry 'registry') } else { @() }

    foreach ($direction in @(@{ Job = $primary; Destination = $secondary }, @{ Job = $secondary; Destination = $primary })) {
        $job = $direction.Job
        $destination = $direction.Destination
        $item = "$($job.Role) job copy path ($($job.AccountName) to $($destination.AccountName))"
        if (-not $job.Vnet -or -not $job.Account -or -not $destination.Account) {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Not verified' -Detail 'A storage account or VNet lookup failed.'
            continue
        }

        $jobVnetId = ConvertTo-Key (Get-Property $job.Vnet 'id')
        $peeredVnetIds = @(Get-Property $job.Vnet 'virtualNetworkPeerings' | Where-Object { (Get-Property $_ 'peeringState') -eq 'Connected' } | ForEach-Object { ConvertTo-Key (Get-Property $_ 'remoteVirtualNetwork.id') })
        $sourceLocal = @($job.FileEndpoints | Where-Object { $_.VnetId -eq $jobVnetId })
        $destinationLocal = @($destination.FileEndpoints | Where-Object { $_.VnetId -eq $jobVnetId })
        $destinationPeered = @($destination.FileEndpoints | Where-Object { $peeredVnetIds -contains $_.VnetId })

        $expected = @{}
        if ($sourceLocal.Count -eq 0) {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Action required' -Detail "No approved file private endpoint for $($job.AccountName) in the job VNet."
            continue
        } elseif ($destinationLocal.Count -gt 0) {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Ready' -Detail 'Local-endpoint layout: the job VNet has approved file endpoints for both accounts.'
            $expected[$destination.AccountName] = @($destinationLocal.Ips)
        } elseif ($destinationPeered.Count -gt 0) {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Ready' -Detail 'Direct-peering layout: the destination endpoint is in a directly peered VNet.'
            $expected[$destination.AccountName] = @($destinationPeered.Ips)
        } else {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Action required' -Detail "No approved file endpoint for $($destination.AccountName) in the job VNet or a directly peered VNet. Hub or Virtual WAN transit fails with CannotVerifyCopySource."
            continue
        }
        $expected[$job.AccountName] = @($sourceLocal.Ips)

        $dnsServers = @(Get-Property $job.Vnet 'dhcpOptions.dnsServers' | Where-Object { $_ })
        $dnsItem = "$($job.Role) job DNS for file endpoints"
        if ($dnsServers.Count -gt 0) {
            Add-Prerequisite -Area 'Network' -Item $dnsItem -Status 'Not verified' -Detail "The VNet uses custom DNS servers ($($dnsServers -join ', ')). Confirm both account names resolve to $(@($expected.Values | ForEach-Object { $_ }) -join ', ')."
            continue
        }
        $linkedZone = $null
        foreach ($zone in $fileZones) {
            $zoneLinks = Invoke-Az -Arguments @('network', 'private-dns', 'link', 'vnet', 'list', '--resource-group', (Get-Property $zone 'resourceGroup'), '--zone-name', $fileZoneName)
            if (@($zoneLinks.Value | ForEach-Object { ConvertTo-Key (Get-Property $_ 'virtualNetwork.id') }) -contains $jobVnetId) {
                $linkedZone = $zone
                break
            }
        }
        if (-not $linkedZone) {
            Add-Prerequisite -Area 'Network' -Item $dnsItem -Status 'Action required' -Detail "No $fileZoneName zone is linked to the job VNet."
            continue
        }
        foreach ($accountName in $expected.Keys) {
            $record = Invoke-Az -Arguments @('network', 'private-dns', 'record-set', 'a', 'show', '--resource-group', (Get-Property $linkedZone 'resourceGroup'), '--zone-name', $fileZoneName, '--name', $accountName)
            $recordIps = @(Get-Property $record.Value 'aRecords' | ForEach-Object { Get-Property $_ 'ipv4Address' })
            $matching = @($recordIps | Where-Object { $expected[$accountName] -contains $_ })
            if ($matching.Count -gt 0) {
                Add-Prerequisite -Area 'Network' -Item "$dnsItem ($accountName)" -Status 'Ready' -Detail "Resolves to $($matching -join ', ')."
            } elseif ($recordIps.Count -gt 0) {
                Add-Prerequisite -Area 'Network' -Item "$dnsItem ($accountName)" -Status 'Action required' -Detail "Resolves to $($recordIps -join ', '), expected $($expected[$accountName] -join ', ')."
            } else {
                Add-Prerequisite -Area 'Network' -Item "$dnsItem ($accountName)" -Status 'Action required' -Detail "No A record in the linked $fileZoneName zone."
            }
        }
    }

    if ($registry) {
        foreach ($side in $primary, $secondary) {
            $item = "$($side.Role) job registry path"
            if (-not $side.Vnet) {
                continue
            }
            $jobVnetId = ConvertTo-Key (Get-Property $side.Vnet 'id')
            $peeredVnetIds = @(Get-Property $side.Vnet 'virtualNetworkPeerings' | Where-Object { (Get-Property $_ 'peeringState') -eq 'Connected' } | ForEach-Object { ConvertTo-Key (Get-Property $_ 'remoteVirtualNetwork.id') })
            if (@($registryEndpoints | Where-Object { $_.VnetId -eq $jobVnetId -or $peeredVnetIds -contains $_.VnetId }).Count -gt 0) {
                Add-Prerequisite -Area 'Network' -Item $item -Status 'Ready' -Detail 'Approved registry private endpoint in the job VNet or a directly peered VNet.'
            } elseif ((Get-Property $registry 'publicNetworkAccess') -eq 'Enabled') {
                Add-Prerequisite -Area 'Network' -Item $item -Status 'Ready' -Detail 'Public registry endpoint; the job subnet needs outbound HTTPS access.'
            } else {
                Add-Prerequisite -Area 'Network' -Item $item -Status 'Action required' -Detail 'The registry denies public access and has no approved private endpoint reachable from the job VNet.'
            }
        }
    }

    foreach ($endpointId in @(Get-ParameterValue 'existingPrivateEndpointIds') | Where-Object { $_ -and $_ -notmatch '<' }) {
        if (-not (Get-EndpointDetails $endpointId)) {
            Add-Prerequisite -Area 'Network' -Item "Listed endpoint $(Split-Path $endpointId -Leaf)" -Status 'Warning' -Detail 'Listed in existingPrivateEndpointIds but not found.'
        }
    }
}

$whatIfStatus = 'Skipped'
if (-not $SkipWhatIf -and -not $hasPlaceholders) {
    Write-Host "Running deployment what-if in $Location. This can take a few minutes..."
    $whatIf = Invoke-Az -Arguments @('deployment', 'sub', 'what-if', '--location', $Location, '--parameters', $ParametersFile, '--result-format', 'ResourceIdOnly', '--no-pretty-print')
    if ($whatIf.Succeeded -and (Get-Property $whatIf.Value 'status') -ne 'Failed') {
        $whatIfStatus = 'Succeeded'
        $statusByChange = @{
            Create      = 'To be provisioned'
            Deploy      = 'Exists, will be redeployed'
            Modify      = 'Exists, will be updated'
            NoChange    = 'Exists'
            Ignore      = 'Exists, not managed by this template'
            Delete      = 'Will be deleted'
            Unsupported = 'Not evaluated'
        }
        foreach ($change in @(Get-Property $whatIf.Value 'changes') + @(Get-Property $whatIf.Value 'potentialChanges') | Where-Object { $_ }) {
            $descriptor = Get-ResourceDescriptor (Get-Property $change 'resourceId')
            $changeType = [string](Get-Property $change 'changeType')
            $status = if ($statusByChange.ContainsKey($changeType)) { $statusByChange[$changeType] } else { $changeType }
            $resources.Add([pscustomobject]@{ Status = $status; Type = $descriptor.Type; Name = $descriptor.Name; ResourceGroup = $descriptor.ResourceGroup })
        }
    } else {
        $whatIfStatus = 'Failed'
        $whatIfError = if ($whatIf.Error) { $whatIf.Error } else { Get-Property $whatIf.Value 'error.message' }
        Add-Prerequisite -Area 'Deployment' -Item 'What-if' -Status 'Not verified' -Detail "What-if could not run: $whatIfError"
    }
}

Write-Host ''
Write-Host 'Azure Files replication inventory' -ForegroundColor Cyan
Write-Host "Subscription : $($account.Value.name) ($subscriptionId)"
Write-Host "Tenant       : $($account.Value.tenantId)"
Write-Host "Profile      : $profileName"
Write-Host "Regions      : $primaryLocation (primary) -> $secondaryLocation (secondary)"

Write-Host ''
Write-Host 'Prerequisites' -ForegroundColor Cyan
$prerequisites | Format-Table -Property Status, Area, Item, Detail -AutoSize -Wrap | Out-String -Width 240 | Write-Host

Write-Host 'Template resources (deployment what-if)' -ForegroundColor Cyan
if ($resources.Count -gt 0) {
    $resources | Sort-Object Status, Type, Name | Format-Table -Property Status, Type, Name, ResourceGroup -AutoSize | Out-String -Width 240 | Write-Host
} else {
    Write-Host "No what-if results ($whatIfStatus)."
    Write-Host ''
}

$summary = [ordered]@{
    PrerequisitesReady          = @($prerequisites | Where-Object Status -eq 'Ready').Count
    PrerequisitesActionRequired = @($prerequisites | Where-Object Status -eq 'Action required').Count
    PrerequisiteWarnings        = @($prerequisites | Where-Object Status -eq 'Warning').Count
    PrerequisitesNotVerified    = @($prerequisites | Where-Object Status -eq 'Not verified').Count
    ResourcesExisting           = @($resources | Where-Object { $_.Status -like 'Exists*' }).Count
    ResourcesToProvision        = @($resources | Where-Object Status -eq 'To be provisioned').Count
    WhatIf                      = $whatIfStatus
}
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ("Prerequisites: {0} ready, {1} action required, {2} warnings, {3} not verified." -f $summary.PrerequisitesReady, $summary.PrerequisitesActionRequired, $summary.PrerequisiteWarnings, $summary.PrerequisitesNotVerified)
Write-Host ("Template resources: {0} existing, {1} to be provisioned (what-if: {2})." -f $summary.ResourcesExisting, $summary.ResourcesToProvision, $whatIfStatus)
if ($summary.PrerequisitesActionRequired -gt 0) {
    Write-Host 'Resolve the Action required items before deploying.' -ForegroundColor Yellow
}

if ($OutputPath) {
    [pscustomobject]@{
        GeneratedAt       = (Get-Date).ToUniversalTime().ToString('o')
        SubscriptionId    = $subscriptionId
        TenantId          = $account.Value.tenantId
        Profile           = $profileName
        ParametersFile    = $ParametersFile
        PrimaryLocation   = $primaryLocation
        SecondaryLocation = $secondaryLocation
        Summary           = $summary
        Prerequisites     = $prerequisites
        Resources         = $resources
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    Write-Host "Report written to $OutputPath"
}
