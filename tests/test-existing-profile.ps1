$ErrorActionPreference = 'Stop'

# Compiles infra/existing.bicep and sample parameter files to check the reuse-or-create, naming, and placement contract; no Azure calls are made.

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

function Get-Resource([string]$SymbolicName) {
    $resource = if ($template.resources -is [array]) { $null } else { $template.resources.$SymbolicName }
    Assert-True ($null -ne $resource) "resource $SymbolicName is missing"
    return $resource
}

# Every service defaults to reuse, and everything defaults to one resource group, so older parameter files keep their meaning.
foreach ($mode in 'primaryStorageMode', 'secondaryStorageMode', 'primaryNetworkMode', 'secondaryNetworkMode', 'registryMode') {
    Assert-True ($template.parameters.$mode.defaultValue -eq 'existing') "$mode must default to existing"
}
Assert-True (@($template.parameters.primaryNetworkMode.allowedValues) -join ',' -eq 'existing,newSubnet,new') 'network modes must be existing, newSubnet, and new'
Assert-True (@($template.parameters.existingPrivateEndpointIds.defaultValue).Count -eq 0) 'existingPrivateEndpointIds must be optional'
Assert-True ($template.parameters.secondaryResourceGroupName.defaultValue -eq "[parameters('resourceGroupName')]") 'secondaryResourceGroupName must default to resourceGroupName'
Assert-True (@($template.parameters.existingResourceGroups.defaultValue).Count -eq 0) 'existingResourceGroups must default to an empty list'

# Custom names are optional, and an unknown key is rejected rather than ignored.
$namesType = $template.definitions.resourceNamesType
Assert-True ($namesType.additionalProperties -eq $false) 'resourceNames must be a sealed object'
foreach ($key in 'primaryJob', 'secondaryJob', 'primaryEnvironment', 'primaryIdentity', 'primaryLogWorkspace', 'actionGroup', 'secondaryFreshnessAlert', 'secondaryVnetRegistryEndpoint') {
    Assert-True ($namesType.properties.$key.nullable -eq $true) "resourceNames.$key must be optional"
}

# Each creation module runs only for its own mode, in its own resource group.
$creations = @{
    newPrimaryStorage   = @{ Condition = "equals(parameters('primaryStorageMode'), 'new')"; Scope = "variables('primaryStorageGroup')" }
    newSecondaryStorage = @{ Condition = "equals(parameters('secondaryStorageMode'), 'new')"; Scope = "variables('secondaryStorageGroup')" }
    newRegistry         = @{ Condition = "equals(parameters('registryMode'), 'new')"; Scope = "variables('registryGroup')" }
    newPrimaryNetwork   = @{ Condition = "variables('primaryNetworkIsNew')"; Scope = "variables('primaryVnetGroup')" }
    newSecondaryNetwork = @{ Condition = "variables('secondaryNetworkIsNew')"; Scope = "variables('secondaryVnetGroup')" }
    newPrimarySubnet    = @{ Condition = "equals(parameters('primaryNetworkMode'), 'newSubnet')"; Scope = "parameters('primaryVnetResourceGroupName')" }
    newSecondarySubnet  = @{ Condition = "equals(parameters('secondaryNetworkMode'), 'newSubnet')"; Scope = "parameters('secondaryVnetResourceGroupName')" }
    primaryDns          = @{ Condition = "variables('primaryNetworkIsNew')"; Scope = "parameters('primaryDnsResourceGroupName')" }
    secondaryDns        = @{ Condition = "variables('secondaryNetworkIsNew')"; Scope = "parameters('secondaryDnsResourceGroupName')" }
}
foreach ($name in $creations.Keys) {
    $module = Get-Resource $name
    Assert-True ([string]$module.condition -eq "[$($creations[$name].Condition)]") "$name condition was '$($module.condition)'"
    Assert-True (([string]$module.resourceGroup).Contains($creations[$name].Scope)) "$name must deploy to $($creations[$name].Scope), not '$($module.resourceGroup)'"
}

# Endpoints follow the matrix: new VNet, new target, or an explicit request; registry endpoints can be turned off.
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
$endpointModules = @($template.resources.PSObject.Properties | Where-Object { $_.Name -like '*Endpoint' -and $_.Value.type -eq 'Microsoft.Resources/deployments' })
Assert-True ($endpointModules.Count -eq 6) "expected six conditional endpoint modules, found $($endpointModules.Count)"
foreach ($module in $endpointModules) {
    Assert-True ([string]$module.Value.condition -match "^\[variables\('(primary|secondary)Endpoints'\)\.(primaryStorage|secondaryStorage|registry)\]$") "endpoint module $($module.Name) has condition '$($module.Value.condition)'"
    Assert-True (([string]$module.Value.resourceGroup) -match "variables\('(primary|secondary)EndpointGroup'\)") "endpoint module $($module.Name) must deploy to its endpoint resource group"
}

# Each region's compute lands in its region's resource group and waits for its role assignments and endpoints.
foreach ($side in 'primary', 'secondary') {
    $expectedGroup = if ($side -eq 'primary') { "parameters('resourceGroupName')" } else { "parameters('secondaryResourceGroupName')" }
    foreach ($name in "${side}Identity", "${side}Region") {
        $module = Get-Resource $name
        Assert-True ([string]$module.resourceGroup -eq "[$expectedGroup]") "$name must deploy to $expectedGroup, not '$($module.resourceGroup)'"
    }
    $region = Get-Resource "${side}Region"
    foreach ($dependency in 'primaryStorageRbac', 'secondaryStorageRbac', 'registryRbac', "${side}VnetPrimaryFileEndpoint", "${side}VnetSecondaryFileEndpoint", "${side}VnetRegistryEndpoint") {
        Assert-True (@($region.dependsOn) -contains $dependency) "${side}Region must wait for $dependency"
    }
    Assert-True (([string]$region.properties.parameters.jobName.value).Contains("resourceNames')") ) "${side}Region ignores resourceNames for the job name"
}

# Resource groups are created from the placement plan, except the ones listed as existing, and carry the input validation.
$groups = Get-Resource 'createdResourceGroups'
Assert-True ([string]$groups.copy.count -eq "[length(items(variables('groupsToCreate')))]") 'resource groups must be created from groupsToCreate'
Assert-True (([string]$groups.tags).Contains("variables('validatedTags')")) 'created resource groups must evaluate the input validation'
Assert-True (([string]$template.variables.groupsToCreate).Contains("variables('existingGroupKeys')")) 'groups listed in existingResourceGroups must not be created'
$plannedNames = @($template.variables.groupPlan | ForEach-Object { [string]$_.name })
foreach ($placement in "parameters('resourceGroupName')", "parameters('secondaryResourceGroupName')", "parameters('primaryDnsResourceGroupName')", "variables('primaryStorageGroup')", "variables('registryGroup')", "variables('secondaryEndpointGroup')") {
    Assert-True (@($plannedNames | Where-Object { $_ -eq "[$placement]" }).Count -eq 1) "the resource group plan is missing $placement"
}
Assert-True (([string]$template.variables.validatedTags).Contains('fail(')) 'input validation must call fail()'
$validation = [string]$template.variables.inputErrors
Assert-True ($validation.Contains("parameters('primaryDnsResourceGroupName')") -and $validation.Contains("parameters('secondaryDnsResourceGroupName')")) 'two new VNets sharing a DNS resource group must be rejected'
Assert-True ($validation.Contains("parameters('primaryRegionCode')") -and $validation.Contains("parameters('secondaryRegionCode')")) 'identical region codes must be rejected'

# Parameter files compile for the example and for single, per-region, and per-service layouts; unknown values are rejected.
$workRoot = Join-Path ([IO.Path]::GetTempPath()) "existing-profile-test-$([guid]::NewGuid().ToString('N'))"
Copy-Item -Path (Join-Path $repositoryRoot 'infra') -Destination $workRoot -Recurse
function Test-Compiles([string]$Name, [string]$Body) {
    $path = Join-Path $workRoot "$Name.bicepparam"
    Set-Content -LiteralPath $path -Value $Body
    & az bicep build-params --file $path --stdout *> $null
    return $LASTEXITCODE -eq 0
}
try {
    & az bicep build-params --file (Join-Path $workRoot 'existing.example.bicepparam') --stdout *> $null
    Assert-True ($LASTEXITCODE -eq 0) 'the example parameter file no longer compiles'

    $base = @"
using './existing.bicep'
param resourceGroupName = 'rg-replication'
param resourceGroupLocation = 'eastus2'
param primaryLocation = 'eastus2'
param secondaryLocation = 'westus2'
param primaryRegionCode = 'eus2'
param secondaryRegionCode = 'wus2'
param alertEmailAddresses = ['alerts@replication.test']
param primaryStorageMode = 'new'
param secondaryStorageMode = 'new'
param primaryNetworkMode = 'new'
param secondaryNetworkMode = 'new'
param registryMode = 'new'
"@
    Assert-True (Test-Compiles 'single' "$base`nparam primaryDnsResourceGroupName = 'rg-replication'") 'a single-resource-group layout does not compile'
    Assert-True (Test-Compiles 'regional' "$base`nparam secondaryResourceGroupName = 'rg-replication-west'`nparam secondaryResourceGroupLocation = 'westus2'") 'a per-region layout does not compile'
    $perService = @"
$base
param primaryStorageAccountName = 'stfilesprimary'
param primaryStorageResourceGroupName = 'rg-storage-east'
param secondaryStorageResourceGroupName = 'rg-storage-west'
param primaryVnetName = 'vnet-replication-east'
param primaryVnetResourceGroupName = 'rg-network-east'
param primaryPrivateEndpointSubnetName = 'snet-endpoints'
param registryName = 'acrreplication'
param registryResourceGroupName = 'rg-shared'
param existingResourceGroups = ['rg-shared']
param resourceNames = {
  primaryJob: 'job-files-east'
  secondaryEnvironment: 'cae-files-west'
  primaryVnetRegistryEndpoint: 'pe-acr-east'
  actionGroup: 'ag-files-replication'
}
"@
    Assert-True (Test-Compiles 'service' $perService) 'a per-service layout with custom names does not compile'
    Assert-True (-not (Test-Compiles 'unknown-name' ($perService -replace 'actionGroup:', 'actionGrop:'))) 'an unknown resourceNames key was accepted'
    Assert-True (-not (Test-Compiles 'unknown-target' "$base`nparam primaryEndpointsToCreate = ['firewall']")) 'an unknown endpoint target was accepted'
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Existing-resource profile contract checks passed.'
