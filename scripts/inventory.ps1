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
        [Parameter(Mandatory)][ValidateSet('Ready', 'To be created', 'Action required', 'Warning', 'Not verified')][string]$Status,
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
    # What-if returns an unevaluated expression when a name depends on a value created during the deployment.
    if ($ResourceId -match "^\[extensionResourceId\('([^']+)',\s*'([^']+)'") {
        $type = $Matches[2]
        $scope = Get-ResourceDescriptor $Matches[1]
        return [pscustomobject]@{ Type = $type; Name = "(named during deployment) on $(($scope.Name -split ' on ')[0] -split '/' | Select-Object -Last 1)"; ResourceGroup = $scope.ResourceGroup }
    }
    if ($ResourceId.StartsWith('[')) {
        return [pscustomobject]@{ Type = '(named during deployment)'; Name = ''; ResourceGroup = '' }
    }
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
    # Object parameters such as resourceNames are checked one level deep.
    $values = @($value) + @(@($value) | Where-Object { $_ -is [System.Management.Automation.PSCustomObject] } | ForEach-Object { $_.PSObject.Properties } | ForEach-Object { $_.Value })
    $values | Where-Object { $_ -is [string] -and $_ -match '<[^>]+>' }
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

$skuCatalog = $null

function Test-StorageSku([string]$SkuName, [string]$Kind, [string]$Region, [string]$Purpose) {
    $item = "$SkuName in $Region"
    if ($null -eq $script:skuCatalog) {
        $script:skuCatalog = Invoke-Az -Arguments @('rest', '--method', 'get', '--url', "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Storage/skus?api-version=2023-05-01")
    }
    if (-not $script:skuCatalog.Succeeded) {
        Add-Prerequisite -Area 'Region' -Item $item -Status 'Not verified' -Detail $script:skuCatalog.Error
        return
    }
    $regionKey = ConvertTo-Key $Region
    $offer = @(Get-Property $script:skuCatalog.Value 'value') | Where-Object {
        (Get-Property $_ 'name') -eq $SkuName -and (Get-Property $_ 'kind') -eq $Kind -and
        (@(Get-Property $_ 'locations' | ForEach-Object { ConvertTo-Key $_ }) -contains $regionKey)
    } | Select-Object -First 1
    $restricted = $offer -and @(Get-Property $offer 'restrictions' | Where-Object {
        @(Get-Property $_ 'values' | ForEach-Object { ConvertTo-Key $_ }) -contains $regionKey
    }).Count -gt 0
    if ($offer -and -not $restricted) {
        Add-Prerequisite -Area 'Region' -Item $item -Status 'Ready' -Detail "Available for $Purpose."
    } else {
        Add-Prerequisite -Area 'Region' -Item $item -Status 'Action required' -Detail "Not available for $Purpose; choose another SKU or region."
    }
}

if (-not $isExistingProfile -and $primaryLocation -and $secondaryLocation) {
    Test-StorageSku -SkuName 'Standard_ZRS' -Kind 'StorageV2' -Region $primaryLocation -Purpose 'primary storage accounts and zone-redundant ACR'
    Test-StorageSku -SkuName 'Standard_LRS' -Kind 'StorageV2' -Region $secondaryLocation -Purpose 'secondary storage accounts'
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
        return [pscustomobject]@{ Start = $start; End = $start + $size - 1; Length = $length }
    }

    function Test-CidrOverlap($First, $Second) {
        return $First.Start -le $Second.End -and $Second.Start -le $First.End
    }

    function Get-DnsZoneState([string]$ZoneId, [string]$VnetId) {
        $zoneSubscription = if ($ZoneId -match '(?i)^/subscriptions/([^/]+)/') { $Matches[1] } else { $subscriptionId }
        $zoneGroup = if ($ZoneId -match '(?i)/resourceGroups/([^/]+)/') { $Matches[1] } else { '' }
        $zoneName = ($ZoneId.TrimEnd('/') -split '/')[-1]
        $links = Invoke-Az -Arguments @('network', 'private-dns', 'link', 'vnet', 'list', '--subscription', $zoneSubscription, '--resource-group', $zoneGroup, '--zone-name', $zoneName)
        if (-not $links.Succeeded) {
            return [pscustomobject]@{ Status = 'Not verified'; Detail = "Could not read the links of zone $zoneName. $($links.Error)" }
        }
        if (@($links.Value | ForEach-Object { ConvertTo-Key (Get-Property $_ 'virtualNetwork.id') }) -contains (ConvertTo-Key $VnetId)) {
            return [pscustomobject]@{ Status = 'Ready'; Detail = "Zone $zoneName in $zoneGroup receives the records and is linked to the VNet." }
        }
        return [pscustomobject]@{ Status = 'Action required'; Detail = "Zone $zoneName in $zoneGroup isn't linked to the VNet, so the job can't resolve the records it receives." }
    }

    $workloadGroup = [string](Get-ParameterValue 'resourceGroupName')
    $registryMode = [string](Get-ParameterValue 'registryMode')
    $registryEndpointsEnabled = [bool](Get-ParameterValue 'registryPrivateEndpointsEnabled')
    $storageModes = @{}
    $networkModes = @{}
    foreach ($role in 'primary', 'secondary') {
        $storageModes[$role] = [string](Get-ParameterValue "${role}StorageMode")
        $networkModes[$role] = [string](Get-ParameterValue "${role}NetworkMode")
    }

    # Mirrors the endpoint rules in existing.bicep: every new service and every new VNet gets endpoints, plus the listed ones.
    $plans = @{}
    foreach ($role in 'primary', 'secondary') {
        $networkIsNew = $networkModes[$role] -eq 'new'
        $requested = @(Get-ParameterValue "${role}EndpointsToCreate")
        $plans[$role] = @{
            primary   = $networkIsNew -or $storageModes['primary'] -eq 'new' -or $requested -contains 'primaryStorage'
            secondary = $networkIsNew -or $storageModes['secondary'] -eq 'new' -or $requested -contains 'secondaryStorage'
            registry  = $registryEndpointsEnabled -and ($networkIsNew -or $registryMode -eq 'new' -or $requested -contains 'registry')
        }
    }

    # Mirrors the placement rules in existing.bicep: a resource goes to its own resource group parameter, or else to its region's group.
    $secondaryGroup = [string](Get-ParameterValue 'secondaryResourceGroupName')
    if (-not $secondaryGroup) {
        $secondaryGroup = $workloadGroup
    }
    $regionGroups = @{ primary = $workloadGroup; secondary = $secondaryGroup }
    $placement = @{}
    foreach ($role in 'primary', 'secondary') {
        $regionGroup = $regionGroups[$role]
        $storageGroup = [string](Get-ParameterValue "${role}StorageResourceGroupName")
        $vnetGroup = [string](Get-ParameterValue "${role}VnetResourceGroupName")
        $endpointGroup = [string](Get-ParameterValue "${role}EndpointResourceGroupName")
        $dnsGroup = [string](Get-ParameterValue "${role}DnsResourceGroupName")
        $newVnetGroup = if ($vnetGroup) { $vnetGroup } else { $regionGroup }
        $placement[$role] = @{
            Storage  = if ($storageGroup) { $storageGroup } else { $regionGroup }
            Vnet     = $newVnetGroup
            Endpoint = if ($endpointGroup) { $endpointGroup } elseif ($networkModes[$role] -eq 'new') { $newVnetGroup } else { $regionGroup }
            Dns      = if ($dnsGroup) { $dnsGroup } else { "$regionGroup-$(Get-ParameterValue "${role}RegionCode")-dns" }
        }
    }
    $registryPlacement = [string](Get-ParameterValue 'registryResourceGroupName')
    if (-not $registryPlacement) {
        $registryPlacement = $workloadGroup
    }

    if ((ConvertTo-Key (Get-ParameterValue 'primaryRegionCode')) -eq (ConvertTo-Key (Get-ParameterValue 'secondaryRegionCode'))) {
        Add-Prerequisite -Area 'Parameters' -Item 'Region codes' -Status 'Action required' -Detail 'primaryRegionCode and secondaryRegionCode must differ because they distinguish the regional resource names.'
    }
    if ($networkModes['primary'] -eq 'new' -and $networkModes['secondary'] -eq 'new' -and (ConvertTo-Key $placement['primary'].Dns) -eq (ConvertTo-Key $placement['secondary'].Dns)) {
        Add-Prerequisite -Area 'Resource group' -Item "DNS resource group $($placement['primary'].Dns)" -Status 'Action required' -Detail 'Both new VNets need their own private DNS zones, which have the same names, so primaryDnsResourceGroupName and secondaryDnsResourceGroupName must differ.'
    }

    $groupPlan = @(
        @{ Name = $placement['primary'].Dns; Used = $networkModes['primary'] -eq 'new'; Purpose = 'primary private DNS zones' },
        @{ Name = $placement['secondary'].Dns; Used = $networkModes['secondary'] -eq 'new'; Purpose = 'secondary private DNS zones' },
        @{ Name = $placement['primary'].Endpoint; Used = $plans['primary'].primary -or $plans['primary'].secondary -or $plans['primary'].registry; Purpose = 'primary VNet private endpoints' },
        @{ Name = $placement['secondary'].Endpoint; Used = $plans['secondary'].primary -or $plans['secondary'].secondary -or $plans['secondary'].registry; Purpose = 'secondary VNet private endpoints' },
        @{ Name = $registryPlacement; Used = $registryMode -eq 'new'; Purpose = 'new registry' },
        @{ Name = $placement['primary'].Vnet; Used = $networkModes['primary'] -eq 'new'; Purpose = 'new primary VNet' },
        @{ Name = $placement['secondary'].Vnet; Used = $networkModes['secondary'] -eq 'new'; Purpose = 'new secondary VNet' },
        @{ Name = $placement['primary'].Storage; Used = $storageModes['primary'] -eq 'new'; Purpose = 'new primary storage' },
        @{ Name = $placement['secondary'].Storage; Used = $storageModes['secondary'] -eq 'new'; Purpose = 'new secondary storage' },
        @{ Name = $secondaryGroup; Used = $true; Purpose = 'secondary-region compute' },
        @{ Name = $workloadGroup; Used = $true; Purpose = 'primary-region compute and monitoring' }
    )
    $existingGroups = @(Get-ParameterValue 'existingResourceGroups' | Where-Object { $_ } | ForEach-Object { ConvertTo-Key $_ })
    $targetGroups = [ordered]@{}
    foreach ($entry in $groupPlan | Where-Object { $_.Used -and $_.Name }) {
        $key = ConvertTo-Key $entry.Name
        if (-not $targetGroups.Contains($key)) {
            $targetGroups[$key] = [pscustomobject]@{ Name = $entry.Name; Purposes = [System.Collections.Generic.List[string]]::new() }
        }
        $targetGroups[$key].Purposes.Add($entry.Purpose)
    }
    foreach ($target in $targetGroups.Values) {
        $item = "Resource group $($target.Name)"
        $purposes = ($target.Purposes | Select-Object -Unique) -join ', '
        $listed = $existingGroups -contains (ConvertTo-Key $target.Name)
        $group = Invoke-Az -Arguments @('group', 'show', '--name', $target.Name)
        if ($group.Succeeded) {
            if ($listed) {
                Add-Prerequisite -Area 'Resource group' -Item $item -Status 'Ready' -Detail "Exists and is listed in existingResourceGroups, so the deployment adds the $purposes without modifying it."
            } elseif ((Get-Property $group.Value 'tags.Workload') -eq 'azure-files-dr-replication') {
                Add-Prerequisite -Area 'Resource group' -Item $item -Status 'Ready' -Detail "Created by an earlier deployment of this template; holds the $purposes."
            } else {
                Add-Prerequisite -Area 'Resource group' -Item $item -Status 'Warning' -Detail "Exists but isn't listed in existingResourceGroups, so the deployment would replace its tags. List it to leave the group unchanged. Holds the $purposes."
            }
        } elseif ($group.NotFound) {
            if ($listed) {
                Add-Prerequisite -Area 'Resource group' -Item $item -Status 'Action required' -Detail 'Listed in existingResourceGroups but not found. Create it, or remove it from the list so that the deployment creates it.'
            } else {
                Add-Prerequisite -Area 'Resource group' -Item $item -Status 'To be created' -Detail "The deployment creates it for the $purposes."
            }
        } else {
            Add-Prerequisite -Area 'Resource group' -Item $item -Status 'Not verified' -Detail $group.Error
        }
    }

    # Names the deployment will use for new resources must meet each resource type's rules.
    $nameRules = @{
        storageAccount  = @{ Pattern = '^[a-z0-9]{3,24}$'; Text = '3 to 24 lowercase letters and digits' }
        fileShare       = @{ Pattern = '^(?!.*--)[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'; Text = '3 to 63 lowercase letters, digits, and single hyphens, starting and ending with a letter or digit' }
        registry        = @{ Pattern = '^[a-zA-Z0-9]{5,50}$'; Text = '5 to 50 letters and digits' }
        network         = @{ Pattern = '^[a-zA-Z0-9]([a-zA-Z0-9._-]{0,62}[a-zA-Z0-9_])?$'; Text = 'up to 64 letters, digits, periods, hyphens, and underscores, starting with a letter or digit and ending with a letter, digit, or underscore' }
        job             = @{ Pattern = '^(?!.*--)[a-z][a-z0-9-]{0,30}[a-z0-9]$'; Text = '2 to 32 lowercase letters, digits, and single hyphens, starting with a letter and ending with a letter or digit' }
        environment     = @{ Pattern = '^(?!.*--)[a-z][a-z0-9-]{0,58}[a-z0-9]$'; Text = '2 to 60 lowercase letters, digits, and single hyphens, starting with a letter and ending with a letter or digit' }
        identity        = @{ Pattern = '^[a-zA-Z0-9][a-zA-Z0-9_-]{2,127}$'; Text = '3 to 128 letters, digits, hyphens, and underscores, starting with a letter or digit' }
        logWorkspace    = @{ Pattern = '^[a-zA-Z0-9][a-zA-Z0-9-]{2,61}[a-zA-Z0-9]$'; Text = '4 to 63 letters, digits, and hyphens, starting and ending with a letter or digit' }
        monitoring      = @{ Pattern = '^[^*#&+:<>?@%{}\\/]{0,259}[^*#&+:<>?@%{}\\/. ]$'; Text = 'up to 260 characters, without * # & + : < > ? @ % { } \ /, and not ending with a period or space' }
    }
    $customNames = [System.Collections.Generic.List[object]]::new()
    foreach ($role in 'primary', 'secondary') {
        if ($storageModes[$role] -eq 'new') {
            $customNames.Add(@{ Parameter = "${role}StorageAccountName"; Value = Get-ParameterValue "${role}StorageAccountName"; Rule = 'storageAccount' })
            $customNames.Add(@{ Parameter = "${role}FileShareName"; Value = Get-ParameterValue "${role}FileShareName"; Rule = 'fileShare' })
        }
        if ($networkModes[$role] -eq 'new') {
            $customNames.Add(@{ Parameter = "${role}VnetName"; Value = Get-ParameterValue "${role}VnetName"; Rule = 'network' })
            $customNames.Add(@{ Parameter = "${role}PrivateEndpointSubnetName"; Value = Get-ParameterValue "${role}PrivateEndpointSubnetName"; Rule = 'network' })
        }
        if ($networkModes[$role] -ne 'existing') {
            $customNames.Add(@{ Parameter = "${role}InfrastructureSubnetName"; Value = Get-ParameterValue "${role}InfrastructureSubnetName"; Rule = 'network' })
        }
    }
    if ($registryMode -eq 'new') {
        $customNames.Add(@{ Parameter = 'registryName'; Value = Get-ParameterValue 'registryName'; Rule = 'registry' })
    }
    $resourceNames = Get-ParameterValue 'resourceNames'
    foreach ($property in @($(if ($resourceNames) { $resourceNames.PSObject.Properties }))) {
        $rule = switch -Regex ($property.Name) {
            'Identity$' { 'identity' }
            'LogWorkspace$' { 'logWorkspace' }
            'Environment$' { 'environment' }
            'Job$' { 'job' }
            'Endpoint$' { 'network' }
            default { 'monitoring' }
        }
        $customNames.Add(@{ Parameter = "resourceNames.$($property.Name)"; Value = $property.Value; Rule = $rule })
    }
    $checkedNames = @($customNames | Where-Object { $_.Value })
    $invalidNames = @($checkedNames | Where-Object { [string]$_.Value -cnotmatch $nameRules[$_.Rule].Pattern })
    foreach ($name in $invalidNames) {
        Add-Prerequisite -Area 'Names' -Item "$($name.Parameter) '$($name.Value)'" -Status 'Action required' -Detail "Use $($nameRules[$name.Rule].Text)."
    }
    if ($checkedNames.Count -gt 0 -and $invalidNames.Count -eq 0) {
        Add-Prerequisite -Area 'Names' -Item 'Custom names' -Status 'Ready' -Detail "$($checkedNames.Count) custom name(s) follow the naming rules of their resource types."
    }

    $allVnets = $null
    $sides = @{}
    foreach ($role in 'primary', 'secondary') {
        $expectedLocation = Get-ParameterValue "${role}Location"
        $regionCode = Get-ParameterValue "${role}RegionCode"
        $side = [pscustomobject]@{ Role = $role; StorageMode = $storageModes[$role]; NetworkMode = $networkModes[$role]; AccountName = ''; Account = $null; Share = $null; Vnet = $null; FileEndpoints = @() }
        $plan = $plans[$role]

        if ($side.StorageMode -eq 'new') {
            $accountName = [string](Get-ParameterValue "${role}StorageAccountName")
            $skuName = [string](Get-ParameterValue "${role}StorageSkuName")
            $shareName = [string](Get-ParameterValue "${role}FileShareName")
            if (-not $shareName) {
                $shareName = 'replication'
            }
            $kind = if ($skuName -like 'Premium*') { 'FileStorage' } else { 'StorageV2' }
            $side.AccountName = if ($accountName) { $accountName } else { "new $role account" }
            $newDetail = "The deployment creates a $kind $skuName account$(if ($accountName) { " named $accountName" } else { ' with a generated name' }) and SMB share $shareName in $($placement[$role].Storage)."
            $item = "$role account $(if ($accountName) { $accountName } else { '(new)' })"
            if ($accountName) {
                $created = Invoke-Az -Arguments @('storage', 'account', 'show', '--name', $accountName, '--resource-group', $placement[$role].Storage)
                if ($created.Succeeded) {
                    Add-Prerequisite -Area 'Storage' -Item $item -Status 'Ready' -Detail 'Created by an earlier deployment of this template.'
                } else {
                    $availability = Invoke-Az -Arguments @('storage', 'account', 'check-name', '--name', $accountName)
                    if (-not $availability.Succeeded) {
                        Add-Prerequisite -Area 'Storage' -Item $item -Status 'Not verified' -Detail "Could not check the name. $($availability.Error)"
                    } elseif ((Get-Property $availability.Value 'nameAvailable') -eq $false) {
                        Add-Prerequisite -Area 'Storage' -Item $item -Status 'Action required' -Detail "The name isn't available: $(Get-Property $availability.Value 'message') Choose another name, or leave ${role}StorageAccountName empty to generate one."
                    } else {
                        Add-Prerequisite -Area 'Storage' -Item $item -Status 'To be created' -Detail $newDetail
                    }
                }
            } else {
                Add-Prerequisite -Area 'Storage' -Item $item -Status 'To be created' -Detail $newDetail
            }
            Test-StorageSku -SkuName $skuName -Kind $kind -Region $expectedLocation -Purpose "the new $role storage account"
        } else {
            $accountName = Get-ParameterValue "${role}StorageAccountName"
            $accountGroup = Get-ParameterValue "${role}StorageResourceGroupName"
            $shareName = Get-ParameterValue "${role}FileShareName"
            $side.AccountName = $accountName
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
                Add-LookupFailure -Area 'Storage' -Item "$role account $accountName" -Result $accountResult -MissingDetail "Not found in resource group $accountGroup of subscription $subscriptionId. Set ${role}StorageMode to new to create one."
            }
        }

        $vnetName = [string](Get-ParameterValue "${role}VnetName")
        $vnetGroup = [string](Get-ParameterValue "${role}VnetResourceGroupName")
        $subnetName = [string](Get-ParameterValue "${role}InfrastructureSubnetName")
        if ($side.NetworkMode -eq 'new') {
            $prefix = [string](Get-ParameterValue "${role}VnetAddressPrefix")
            $range = ConvertTo-CidrRange $prefix
            $dnsGroup = $placement[$role].Dns

            $newVnetName = if ($vnetName) { $vnetName } else { "vnet-replication-$regionCode" }
            $item = "$role VNet $newVnetName (new)"
            if (-not $range -or $range.Length -gt 22) {
                Add-Prerequisite -Area 'Network' -Item $item -Status 'Action required' -Detail "${role}VnetAddressPrefix '$prefix' must be an IPv4 range of /22 or larger."
            } else {
                Add-Prerequisite -Area 'Network' -Item $item -Status 'To be created' -Detail "The deployment creates $newVnetName ($prefix) in $($placement[$role].Vnet) with a delegated /23 job subnet, an endpoint subnet, private endpoints for the storage accounts and registry in $($placement[$role].Endpoint), and private DNS zones in $dnsGroup."
                $zonesInGroup = Invoke-Az -Arguments @('network', 'private-dns', 'zone', 'list', '--resource-group', $dnsGroup)
                if ($zonesInGroup.Succeeded) {
                    $foreignZones = @($zonesInGroup.Value | Where-Object { (Get-Property $_ 'name') -like 'privatelink.*' -and (Get-Property $_ 'tags.Workload') -ne 'azure-files-dr-replication' } | ForEach-Object { Get-Property $_ 'name' })
                    if ($foreignZones.Count -gt 0) {
                        Add-Prerequisite -Area 'Network' -Item "$role DNS resource group $dnsGroup" -Status 'Warning' -Detail "Already holds $($foreignZones -join ', '). The deployment links the new VNet to those zones and adds its endpoint records, which also changes name resolution in every VNet already linked to them. Use a dedicated resource group for split-horizon zones."
                    }
                }
                if ($null -eq $allVnets) {
                    $allVnets = @((Invoke-Az -Arguments @('network', 'vnet', 'list')).Value | Where-Object { $_ })
                }
                $overlapping = @($allVnets | Where-Object {
                    $candidate = $_
                    (ConvertTo-Key (Get-Property $candidate 'name')) -ne (ConvertTo-Key $newVnetName) -and
                    @(Get-Property $candidate 'addressSpace.addressPrefixes' | ForEach-Object { ConvertTo-CidrRange $_ } | Where-Object { $_ -and (Test-CidrOverlap $_ $range) }).Count -gt 0
                } | ForEach-Object { Get-Property $_ 'name' })
                if ($overlapping.Count -gt 0) {
                    Add-Prerequisite -Area 'Network' -Item "$role VNet address space" -Status 'Warning' -Detail "$prefix overlaps $($overlapping -join ', '). The replication VNets aren't peered, but choose another range if you plan to connect them."
                }
            }
        } else {
            $vnetResult = Invoke-Az -Arguments @('network', 'vnet', 'show', '--resource-group', $vnetGroup, '--name', $vnetName)
            if ($vnetResult.Succeeded) {
                $side.Vnet = $vnetResult.Value
                $vnetLocation = Get-Property $side.Vnet 'location'
                if ((ConvertTo-Key $vnetLocation) -ne (ConvertTo-Key $expectedLocation)) {
                    Add-Prerequisite -Area 'Network' -Item "$role VNet $vnetName" -Status 'Action required' -Detail "Located in $vnetLocation, but ${role}Location is $expectedLocation. The job environment and its endpoints must be in the VNet's region."
                } else {
                    Add-Prerequisite -Area 'Network' -Item "$role VNet $vnetName" -Status 'Ready' -Detail "location=$vnetLocation"
                }
            } else {
                Add-LookupFailure -Area 'Network' -Item "$role VNet $vnetName" -Result $vnetResult -MissingDetail "Not found in resource group $vnetGroup. Set ${role}NetworkMode to new to create a dedicated VNet."
            }

            if ($side.NetworkMode -eq 'existing') {
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
                    Add-LookupFailure -Area 'Network' -Item "$role Container Apps subnet $subnetName" -Result $subnetResult -MissingDetail "Not found in VNet $vnetName. Set ${role}NetworkMode to newSubnet to add one."
                }
            } else {
                if (-not $subnetName) {
                    $subnetName = 'snet-replication-jobs'
                }
                $prefix = [string](Get-ParameterValue "${role}InfrastructureSubnetPrefix")
                $range = ConvertTo-CidrRange $prefix
                $subnetItem = "$role Container Apps subnet $subnetName (new)"
                if (-not $side.Vnet) {
                    Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'Not verified' -Detail 'The VNet lookup failed.'
                } else {
                    $subnets = @(Get-Property $side.Vnet 'subnets' | Where-Object { $_ })
                    $sameName = @($subnets | Where-Object { (Get-Property $_ 'name') -eq $subnetName }) | Select-Object -First 1
                    if ($sameName) {
                        $samePrefix = @(@(Get-Property $sameName 'addressPrefix') + @(Get-Property $sameName 'addressPrefixes') | Where-Object { $_ }) -contains $prefix
                        if ($samePrefix -and @(Get-Property $sameName 'delegations' | ForEach-Object { Get-Property $_ 'serviceName' }) -contains 'Microsoft.App/environments') {
                            Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'Ready' -Detail 'Created by an earlier deployment of this template.'
                        } else {
                            Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'Action required' -Detail "A different subnet named $subnetName already exists in $vnetName; set ${role}InfrastructureSubnetName to another name."
                        }
                    } elseif (-not $range -or $range.Length -gt 27) {
                        Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'Action required' -Detail "${role}InfrastructureSubnetPrefix '$prefix' must be an IPv4 range of /27 or larger."
                    } else {
                        $spaces = @(Get-Property $side.Vnet 'addressSpace.addressPrefixes')
                        $inside = @($spaces | ForEach-Object { ConvertTo-CidrRange $_ } | Where-Object { $_ -and $_.Start -le $range.Start -and $range.End -le $_.End }).Count -gt 0
                        $conflicts = @($subnets | Where-Object {
                            @(@(Get-Property $_ 'addressPrefix') + @(Get-Property $_ 'addressPrefixes') | Where-Object { $_ } | ForEach-Object { ConvertTo-CidrRange $_ } | Where-Object { $_ -and (Test-CidrOverlap $_ $range) }).Count -gt 0
                        } | ForEach-Object { Get-Property $_ 'name' })
                        if (-not $inside) {
                            Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'Action required' -Detail "$prefix is outside the VNet address space ($($spaces -join ', '))."
                        } elseif ($conflicts.Count -gt 0) {
                            Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'Action required' -Detail "$prefix overlaps subnet $($conflicts -join ', ')."
                        } else {
                            $sizeNote = if ($range.Length -gt 23) { ' It is smaller than the documented /23.' } else { '' }
                            Add-Prerequisite -Area 'Network' -Item $subnetItem -Status 'To be created' -Detail "The deployment adds $subnetName ($prefix), delegated to Microsoft.App/environments, to $vnetName. Add it to any other IaC that manages this VNet so that a later deployment doesn't remove it.$sizeNote"
                        }
                    }
                }
            }

            $targets = @(
                if ($plan.primary) { 'primary storage' }
                if ($plan.secondary) { 'secondary storage' }
                if ($plan.registry) { 'registry' }
            )
            if ($targets.Count -gt 0) {
                $endpointSubnetName = [string](Get-ParameterValue "${role}PrivateEndpointSubnetName")
                $endpointItem = "$role endpoint subnet $endpointSubnetName"
                if (-not $endpointSubnetName) {
                    Add-Prerequisite -Area 'Network' -Item "$role endpoint subnet" -Status 'Action required' -Detail "The deployment creates endpoints for the $($targets -join ', ') in this VNet; set ${role}PrivateEndpointSubnetName."
                } elseif ($side.Vnet) {
                    $endpointSubnet = @(Get-Property $side.Vnet 'subnets' | Where-Object { $_ -and (Get-Property $_ 'name') -eq $endpointSubnetName }) | Select-Object -First 1
                    if (-not $endpointSubnet) {
                        Add-Prerequisite -Area 'Network' -Item $endpointItem -Status 'Action required' -Detail "Not found in VNet $vnetName."
                    } elseif (@(Get-Property $endpointSubnet 'delegations' | Where-Object { $_ }).Count -gt 0) {
                        Add-Prerequisite -Area 'Network' -Item $endpointItem -Status 'Action required' -Detail 'Private endpoints cannot use a delegated subnet.'
                    } else {
                        Add-Prerequisite -Area 'Network' -Item $endpointItem -Status 'To be created' -Detail "The deployment creates endpoints for the $($targets -join ', ') in this subnet."
                    }
                }
                foreach ($zone in @(
                        @{ Needed = $plan.primary -or $plan.secondary; Parameter = "${role}FileDnsZoneId"; Label = 'file' },
                        @{ Needed = $plan.registry; Parameter = "${role}RegistryDnsZoneId"; Label = 'registry' })) {
                    if (-not $zone.Needed) {
                        continue
                    }
                    $zoneId = [string](Get-ParameterValue $zone.Parameter)
                    $zoneItem = "$role $($zone.Label) DNS zone for new endpoints"
                    if (-not $zoneId) {
                        Add-Prerequisite -Area 'Network' -Item $zoneItem -Status 'Warning' -Detail "$($zone.Parameter) is empty, so policy or another process must create the DNS records for the new $($zone.Label) endpoints."
                    } elseif ($side.Vnet) {
                        $zoneState = Get-DnsZoneState -ZoneId $zoneId -VnetId (Get-Property $side.Vnet 'id')
                        Add-Prerequisite -Area 'Network' -Item $zoneItem -Status $zoneState.Status -Detail $zoneState.Detail
                    }
                }
            }
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
            $held = if ($destinationBytes -ge 1GB) { "$([math]::Round($destinationBytes / 1GB, 2)) GiB" } elseif ($destinationBytes -ge 1MB) { "$([math]::Round($destinationBytes / 1MB, 2)) MiB" } else { "$destinationBytes bytes" }
            Add-Prerequisite -Area 'Storage' -Item 'Destination share contents' -Status 'Warning' -Detail "The secondary share already holds $held; replication merges into it and never deletes extra files."
        } else {
            Add-Prerequisite -Area 'Storage' -Item 'Destination share capacity' -Status 'Ready' -Detail 'The secondary share is empty and has enough quota for the primary data.'
        }
    }

    $registry = $null
    $registryName = [string](Get-ParameterValue 'registryName')
    if ($registryMode -eq 'new') {
        $item = "Registry $(if ($registryName) { $registryName } else { '(new)' })"
        $newDetail = "The deployment creates a Premium registry$(if ($registryName) { " named $registryName" } else { ' with a generated name' }) in $primaryLocation with a replica in $secondaryLocation. scripts/deploy.ps1 builds the AzCopy image into it."
        if ($registryName) {
            $created = Invoke-Az -Arguments @('acr', 'show', '--name', $registryName, '--resource-group', $registryPlacement)
            if ($created.Succeeded) {
                Add-Prerequisite -Area 'Registry' -Item $item -Status 'Ready' -Detail 'Created by an earlier deployment of this template.'
            } else {
                $availability = Invoke-Az -Arguments @('acr', 'check-name', '--name', $registryName)
                if (-not $availability.Succeeded) {
                    Add-Prerequisite -Area 'Registry' -Item $item -Status 'Not verified' -Detail "Could not check the name. $($availability.Error)"
                } elseif ((Get-Property $availability.Value 'nameAvailable') -eq $false) {
                    Add-Prerequisite -Area 'Registry' -Item $item -Status 'Action required' -Detail "The name isn't available: $(Get-Property $availability.Value 'message') Choose another name, or leave registryName empty to generate one."
                } else {
                    Add-Prerequisite -Area 'Registry' -Item $item -Status 'To be created' -Detail $newDetail
                }
            }
        } else {
            Add-Prerequisite -Area 'Registry' -Item $item -Status 'To be created' -Detail $newDetail
        }
    } else {
        $registryResult = Invoke-Az -Arguments @('acr', 'show', '--name', $registryName, '--resource-group', (Get-ParameterValue 'registryResourceGroupName'))
        if ($registryResult.Succeeded) {
            $registry = $registryResult.Value
            $registrySku = [string](Get-Property $registry 'sku.name')
            $registryDetail = "sku=$registrySku, publicNetworkAccess=$(Get-Property $registry 'publicNetworkAccess')"
            if ((Get-Property $registry 'roleAssignmentMode') -match '(?i)abac') {
                Add-Prerequisite -Area 'Registry' -Item $registryName -Status 'Warning' -Detail "ABAC repository permissions are enabled, so AcrPull is not honored; assign Container Registry Repository Reader to both job identities. $registryDetail"
            } elseif ($registrySku -ne 'Premium' -and ($plans['primary'].registry -or $plans['secondary'].registry)) {
                Add-Prerequisite -Area 'Registry' -Item $registryName -Status 'Action required' -Detail "A $registrySku registry doesn't support private endpoints, but the deployment would create one. Set registryPrivateEndpointsEnabled to false so that the jobs use its public endpoint. $registryDetail"
            } else {
                Add-Prerequisite -Area 'Registry' -Item $registryName -Status 'Ready' -Detail $registryDetail
            }

            $image = [string](Get-ParameterValue 'containerImage')
            $loginServer = [string](Get-Property $registry 'loginServer')
            if ($image -eq [string](Get-Property (Get-Property $templateParameters 'containerImage') 'defaultValue')) {
                Add-Prerequisite -Area 'Registry' -Item 'containerImage' -Status 'Warning' -Detail 'Not set. scripts/deploy.ps1 builds and pins the image unless you pass -ContainerImage; a direct deployment needs a digest-pinned image in the registry.'
            } elseif ($image -notmatch '@sha256:[a-fA-F0-9]{64}$') {
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
            Add-LookupFailure -Area 'Registry' -Item $registryName -Result $registryResult -MissingDetail 'Registry not found in the current subscription. Set registryMode to new to create one.'
        }
    }

    $zones = Invoke-Az -Arguments @('network', 'private-dns', 'zone', 'list')
    $fileZones = @($zones.Value | Where-Object { (Get-Property $_ 'name') -eq $fileZoneName })
    $registryEndpoints = if ($registry) { @(Get-ApprovedEndpoints $registry 'registry') } else { @() }

    foreach ($direction in @(@{ Job = $primary; Destination = $secondary }, @{ Job = $secondary; Destination = $primary })) {
        $job = $direction.Job
        $destination = $direction.Destination
        $plan = $plans[$job.Role]
        $sourceCreated = $plan[$job.Role]
        $destinationCreated = $plan[$destination.Role]
        $item = "$($job.Role) job copy path ($($job.AccountName) to $($destination.AccountName))"
        if ($sourceCreated -and $destinationCreated) {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Ready' -Detail 'Local-endpoint layout: the deployment creates file endpoints for both accounts in the job VNet.'
            continue
        }
        if (-not $job.Vnet -or (-not $sourceCreated -and -not $job.Account) -or (-not $destinationCreated -and -not $destination.Account)) {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Not verified' -Detail 'A storage account or VNet lookup failed.'
            continue
        }

        $jobVnetId = ConvertTo-Key (Get-Property $job.Vnet 'id')
        $peeredVnetIds = @(Get-Property $job.Vnet 'virtualNetworkPeerings' | Where-Object { (Get-Property $_ 'peeringState') -eq 'Connected' } | ForEach-Object { ConvertTo-Key (Get-Property $_ 'remoteVirtualNetwork.id') })
        $expected = @{}
        if (-not $sourceCreated) {
            $sourceLocal = @($job.FileEndpoints | Where-Object { $_.VnetId -eq $jobVnetId })
            if ($sourceLocal.Count -eq 0) {
                Add-Prerequisite -Area 'Network' -Item $item -Status 'Action required' -Detail "No approved file private endpoint for $($job.AccountName) in the job VNet. Add $($job.Role)Storage to $($job.Role)EndpointsToCreate to create one."
                continue
            }
            $expected[$job.AccountName] = @($sourceLocal.Ips)
        }
        $layout = 'Local-endpoint layout: the job VNet has approved file endpoints for both accounts.'
        if (-not $destinationCreated) {
            $destinationLocal = @($destination.FileEndpoints | Where-Object { $_.VnetId -eq $jobVnetId })
            $destinationPeered = @($destination.FileEndpoints | Where-Object { $peeredVnetIds -contains $_.VnetId })
            if ($destinationLocal.Count -gt 0) {
                $expected[$destination.AccountName] = @($destinationLocal.Ips)
            } elseif ($destinationPeered.Count -gt 0) {
                $layout = 'Direct-peering layout: the destination endpoint is in a directly peered VNet.'
                $expected[$destination.AccountName] = @($destinationPeered.Ips)
            } else {
                Add-Prerequisite -Area 'Network' -Item $item -Status 'Action required' -Detail "No approved file endpoint for $($destination.AccountName) in the job VNet or a directly peered VNet. Hub or Virtual WAN transit fails with CannotVerifyCopySource. Add $($destination.Role)Storage to $($job.Role)EndpointsToCreate to create one."
                continue
            }
        }
        if ($sourceCreated -or $destinationCreated) {
            $layout = "$layout The deployment creates the endpoint for $(if ($sourceCreated) { $job.AccountName } else { $destination.AccountName })."
        }
        Add-Prerequisite -Area 'Network' -Item $item -Status 'Ready' -Detail $layout

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

    foreach ($side in $primary, $secondary) {
        $item = "$($side.Role) job registry path"
        if ($plans[$side.Role].registry) {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Ready' -Detail 'The deployment creates a registry private endpoint in the job VNet.'
            continue
        }
        if (-not $registry) {
            continue
        }
        $publicAccess = Get-Property $registry 'publicNetworkAccess'
        if ($side.NetworkMode -eq 'new' -or -not $side.Vnet) {
            if ($side.NetworkMode -eq 'new' -and $publicAccess -eq 'Enabled') {
                Add-Prerequisite -Area 'Network' -Item $item -Status 'Ready' -Detail 'Public registry endpoint; the new job subnet reaches it through outbound HTTPS.'
            } elseif ($side.NetworkMode -eq 'new') {
                Add-Prerequisite -Area 'Network' -Item $item -Status 'Action required' -Detail 'The registry denies public access and registryPrivateEndpointsEnabled is false, so the new VNet has no path to it.'
            }
            continue
        }
        $jobVnetId = ConvertTo-Key (Get-Property $side.Vnet 'id')
        $peeredVnetIds = @(Get-Property $side.Vnet 'virtualNetworkPeerings' | Where-Object { (Get-Property $_ 'peeringState') -eq 'Connected' } | ForEach-Object { ConvertTo-Key (Get-Property $_ 'remoteVirtualNetwork.id') })
        if (@($registryEndpoints | Where-Object { $_.VnetId -eq $jobVnetId -or $peeredVnetIds -contains $_.VnetId }).Count -gt 0) {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Ready' -Detail 'Approved registry private endpoint in the job VNet or a directly peered VNet.'
        } elseif ($publicAccess -eq 'Enabled') {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Ready' -Detail 'Public registry endpoint; the job subnet needs outbound HTTPS access.'
        } else {
            Add-Prerequisite -Area 'Network' -Item $item -Status 'Action required' -Detail "The registry denies public access and has no approved private endpoint reachable from the job VNet. Add registry to $($side.Role)EndpointsToCreate to create one."
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
    PrerequisitesToBeCreated    = @($prerequisites | Where-Object Status -eq 'To be created').Count
    PrerequisitesActionRequired = @($prerequisites | Where-Object Status -eq 'Action required').Count
    PrerequisiteWarnings        = @($prerequisites | Where-Object Status -eq 'Warning').Count
    PrerequisitesNotVerified    = @($prerequisites | Where-Object Status -eq 'Not verified').Count
    ResourcesExisting           = @($resources | Where-Object { $_.Status -like 'Exists*' }).Count
    ResourcesToProvision        = @($resources | Where-Object Status -eq 'To be provisioned').Count
    WhatIf                      = $whatIfStatus
}
Write-Host 'Summary' -ForegroundColor Cyan
Write-Host ("Prerequisites: {0} ready, {1} to be created, {2} action required, {3} warnings, {4} not verified." -f $summary.PrerequisitesReady, $summary.PrerequisitesToBeCreated, $summary.PrerequisitesActionRequired, $summary.PrerequisiteWarnings, $summary.PrerequisitesNotVerified)
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
