$ErrorActionPreference = 'Stop'

# Compiles infra/existing.bicep and sample parameter files to check the reuse-or-create contract; no Azure calls are made.

$repositoryRoot = Split-Path $PSScriptRoot -Parent

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "existing-profile check failed: $Message"
    }
}

$compiledJson = (& az bicep build --file (Join-Path $repositoryRoot 'infra/existing.bicep') --stdout) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to compile infra/existing.bicep.'
}
$template = $compiledJson | ConvertFrom-Json -Depth 100
$resources = if ($template.resources -is [array]) { $template.resources } else { @($template.resources.PSObject.Properties.Value) }

function Get-Deployment([string]$Name) {
    $match = @($resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq $Name }) | Select-Object -First 1
    Assert-True ($null -ne $match) "module deployment $Name is missing"
    return $match
}

# Every service defaults to reuse, so parameter files written before the modes existed keep their meaning.
foreach ($mode in 'primaryStorageMode', 'secondaryStorageMode', 'primaryNetworkMode', 'secondaryNetworkMode', 'registryMode') {
    Assert-True ($template.parameters.$mode.defaultValue -eq 'existing') "$mode must default to existing"
}
Assert-True (@($template.parameters.primaryNetworkMode.allowedValues) -join ',' -eq 'existing,newSubnet,new') 'network modes must be existing, newSubnet, and new'
Assert-True (@($template.parameters.existingPrivateEndpointIds.defaultValue).Count -eq 0) 'existingPrivateEndpointIds must be optional'

# Each creation module runs only for its own mode.
$creations = @{
    'replication-new-primary-storage'   = "equals(parameters('primaryStorageMode'), 'new')"
    'replication-new-secondary-storage' = "equals(parameters('secondaryStorageMode'), 'new')"
    'replication-new-registry'          = "equals(parameters('registryMode'), 'new')"
    'replication-new-primary-network'   = "variables('primaryNetworkIsNew')"
    'replication-new-secondary-network' = "variables('secondaryNetworkIsNew')"
    'replication-new-primary-subnet'    = "equals(parameters('primaryNetworkMode'), 'newSubnet')"
    'replication-new-secondary-subnet'  = "equals(parameters('secondaryNetworkMode'), 'newSubnet')"
    'replication-primary-private-dns'   = "variables('primaryNetworkIsNew')"
    'replication-secondary-private-dns' = "variables('secondaryNetworkIsNew')"
}
foreach ($name in $creations.Keys) {
    $deployment = Get-Deployment $name
    Assert-True ([string]$deployment.condition -eq "[$($creations[$name])]") "$name condition was '$($deployment.condition)'"
}

# Endpoints follow the matrix: new VNet, new target, or an explicit request, and registry endpoints can be turned off.
foreach ($side in 'primary', 'secondary') {
    $plan = $template.variables."${side}Endpoints"
    foreach ($target in 'primaryStorage', 'secondaryStorage', 'registry') {
        $expression = [string]$plan.$target
        Assert-True ($expression.Contains("variables('${side}NetworkIsNew')")) "$side $target endpoint ignores a new VNet"
        Assert-True ($expression.Contains("contains(parameters('${side}EndpointsToCreate'), '$target')")) "$side $target endpoint ignores ${side}EndpointsToCreate"
        $modeParameter = if ($target -eq 'registry') { 'registryMode' } else { "${target}Mode" }
        Assert-True ($expression.Contains("equals(parameters('$modeParameter'), 'new')")) "$side $target endpoint ignores $modeParameter"
    }
    Assert-True (([string]$plan.registry).Contains("parameters('registryPrivateEndpointsEnabled')")) "$side registry endpoint ignores registryPrivateEndpointsEnabled"
}
$endpointModules = @($resources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and [string]$_.name -like '*-pe*' })
Assert-True ($endpointModules.Count -eq 6) "expected six conditional endpoint modules, found $($endpointModules.Count)"
foreach ($module in $endpointModules) {
    Assert-True ([string]$module.condition -match "^\[variables\('(primary|secondary)Endpoints'\)\.(primaryStorage|secondaryStorage|registry)\]$") "endpoint module $($module.name) has condition '$($module.condition)'"
}

$foundation = Get-Deployment 'existing-storage-replication-foundation'
Assert-True (@($foundation.dependsOn | Where-Object { $_ -like '*-pe*' }).Count -eq 6) 'the jobs must wait for every endpoint module'

# Missing inputs must stop validation before any resource changes.
Assert-True (([string]$template.variables.validatedTags).Contains('fail(')) 'input validation must call fail()'
$workloadGroup = @($resources | Where-Object { $_.type -eq 'Microsoft.Resources/resourceGroups' -and -not $_.condition }) | Select-Object -First 1
Assert-True ($workloadGroup.tags -eq "[variables('validatedTags')]") 'the workload resource group must evaluate the input validation'

# Parameter files compile for reuse-only, mixed, and invalid configurations.
$workRoot = Join-Path ([IO.Path]::GetTempPath()) "existing-profile-test-$([guid]::NewGuid().ToString('N'))"
Copy-Item -Path (Join-Path $repositoryRoot 'infra') -Destination $workRoot -Recurse
try {
    & az bicep build-params --file (Join-Path $workRoot 'existing.example.bicepparam') --stdout *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'the example parameter file no longer compiles'

    $mixed = @"
using './existing.bicep'
param resourceGroupName = 'rg-replication'
param resourceGroupLocation = 'eastus2'
param primaryLocation = 'eastus2'
param secondaryLocation = 'westus2'
param primaryRegionCode = 'eus2'
param secondaryRegionCode = 'wus2'
param primaryStorageAccountName = 'stexisting'
param primaryStorageResourceGroupName = 'rg-storage'
param primaryFileShareName = 'finance'
param secondaryStorageMode = 'new'
param secondaryStorageSkuName = 'Premium_LRS'
param primaryNetworkMode = 'newSubnet'
param primaryVnetName = 'vnet-spoke'
param primaryVnetResourceGroupName = 'rg-network'
param primaryInfrastructureSubnetPrefix = '10.1.8.0/23'
param primaryPrivateEndpointSubnetName = 'snet-endpoints'
param primaryEndpointsToCreate = ['registry']
param secondaryNetworkMode = 'new'
param registryMode = 'new'
param alertEmailAddresses = ['alerts@replication.test']
"@
    Set-Content -LiteralPath (Join-Path $workRoot 'mixed.bicepparam') -Value $mixed
    & az bicep build-params --file (Join-Path $workRoot 'mixed.bicepparam') --stdout *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'a mixed reuse-and-create parameter file does not compile'

    Set-Content -LiteralPath (Join-Path $workRoot 'invalid.bicepparam') -Value ($mixed -replace "\['registry'\]", "['firewall']")
    & az bicep build-params --file (Join-Path $workRoot 'invalid.bicepparam') --stdout *> $null
    Assert-True ($LASTEXITCODE -ne 0) 'an unknown endpoint target was accepted'
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Existing-resource profile contract checks passed.'
