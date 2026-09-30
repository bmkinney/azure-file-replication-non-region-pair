$ErrorActionPreference = 'Stop'

# Compiles deploy/bicep/existing.bicep, sample parameter files, and the README examples to check the reuse-or-create, naming, and placement contract; no Azure calls are made.

$repositoryRoot = Split-Path $PSScriptRoot -Parent

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "existing-profile check failed: $Message"
    }
}

$compiledJson = (& az bicep build --file (Join-Path $repositoryRoot 'deploy/bicep/existing.bicep') --stdout) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to compile deploy/bicep/existing.bicep.'
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

# Identities default to new and the deployment assigns their roles, as in earlier versions.
Assert-True ($template.parameters.identityMode.defaultValue -eq 'new') 'identityMode must default to new'
Assert-True (@($template.parameters.identityMode.allowedValues) -join ',' -eq 'new,existing') 'identity modes must be new and existing'
Assert-True ($template.parameters.createRoleAssignments.defaultValue -eq $true) 'createRoleAssignments must default to true'
foreach ($parameter in 'primaryIdentityId', 'secondaryIdentityId') {
    Assert-True ($template.parameters.$parameter.defaultValue -eq '') "$parameter must be optional"
}

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

# The role assignment modules run only with createRoleAssignments, and each identity module reuses an identity in existing mode.
foreach ($name in 'primaryStorageRbac', 'secondaryStorageRbac', 'registryRbac') {
    $module = Get-Resource $name
    Assert-True ([string]$module.condition -eq "[parameters('createRoleAssignments')]") "$name must depend on createRoleAssignments"
    Assert-True (([string]$module.properties.parameters.principalIds.value).StartsWith('[union(')) "$name must not assign a role twice when both jobs reuse one identity"
}
foreach ($side in 'primary', 'secondary') {
    $module = Get-Resource "${side}Identity"
    Assert-True ([string]$module.properties.parameters.existingIdentityId -eq "[if(equals(parameters('identityMode'), 'existing'), createObject('value', parameters('${side}IdentityId')), createObject('value', ''))]") "${side}Identity doesn't reuse ${side}IdentityId in existing mode"
}

# The output lists every assignment with the name its module gives it, so that scripts can check and create them.
$listed = $template.outputs.jobRoleAssignments
Assert-True ($listed.type -eq 'array' -and $listed.copy.count -eq '[length(range(0, 6))]') 'the template must output the six job role assignments'
foreach ($property in 'name', 'scope', 'principalId', 'principalName', 'roleDefinitionId', 'roleName') {
    Assert-True ($null -ne $listed.copy.input.$property) "the jobRoleAssignments output lacks $property"
}
Assert-True ([string]$listed.copy.input.name -match "^\[guid\(createArray\(.+\)\[div\(range\(0, 6\)\[copyIndex\(\)\], 2\)\]\.scope, createArray\(.+\)\[mod\(range\(0, 6\)\[copyIndex\(\)\], 2\)\]\.principalId, subscriptionResourceId\('Microsoft\.Authorization/roleDefinitions', createArray\(.+\)\[div\(range\(0, 6\)\[copyIndex\(\)\], 2\)\]\.roleDefinitionId\)\)\]$") "the jobRoleAssignments names don't use the modules' formula: $($listed.copy.input.name)"
foreach ($scope in "variables('primaryStorageName')", "variables('secondaryStorageName')", "variables('registryResolvedName')", "reference('newPrimaryStorage').outputs.id.value", "reference('newRegistry').outputs.id.value") {
    Assert-True (([string]$listed.copy.input.scope).Contains($scope)) "the jobRoleAssignments scopes ignore $scope"
}
$rbacModules = @{
    primaryStorageRbac = @{ Type = 'Microsoft.Storage/storageAccounts'; NameParameter = 'storageAccountName'; RoleVariable = 'fileDataRoleDefinitionId'; RoleId = '69566ab7-960f-475b-8e7c-b3118f30c6bd' }
    registryRbac       = @{ Type = 'Microsoft.ContainerRegistry/registries'; NameParameter = 'registryName'; RoleVariable = 'acrPullRoleDefinitionId'; RoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d' }
}
foreach ($name in $rbacModules.Keys) {
    $expected = $rbacModules[$name]
    $nested = (Get-Resource $name).properties.template
    $assignment = @($nested.resources)[0]
    Assert-True ($assignment.name -eq "[guid(resourceId('$($expected.Type)', parameters('$($expected.NameParameter)')), parameters('principalIds')[copyIndex()], variables('$($expected.RoleVariable)'))]") "$name names its assignments differently from the jobRoleAssignments output: $($assignment.name)"
    Assert-True ($nested.variables.($expected.RoleVariable) -eq "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '$($expected.RoleId)')]") "$name assigns another role than the jobRoleAssignments output lists"
    Assert-True (([string]$listed.copy.input.roleDefinitionId).Contains("'$($expected.RoleId)'")) "the jobRoleAssignments output doesn't list role $($expected.RoleId)"
}
foreach ($output in 'createRoleAssignments', 'registryCreated') {
    Assert-True ($null -ne $template.outputs.$output) "the template must output $output"
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
Assert-True ($validation.Contains('identityMode is existing, so set primaryIdentityId and secondaryIdentityId.')) 'reused identities without resource IDs must be rejected'
Assert-True ($validation.Contains("variables('primaryIdentityIdValid')") -and $validation.Contains("variables('secondaryIdentityIdValid')")) 'identity IDs outside the deployment subscription must be rejected'

# Parameter files compile for the example and for single, per-region, and per-service layouts; unknown values are rejected.
$workRoot = Join-Path ([IO.Path]::GetTempPath()) "existing-profile-test-$([guid]::NewGuid().ToString('N'))"
Copy-Item -Path (Join-Path $repositoryRoot 'deploy/bicep') -Destination $workRoot -Recurse
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

    $identityRoot = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities'
    $pipeline = @"
$base
param createRoleAssignments = false
param identityMode = 'existing'
param primaryIdentityId = '$identityRoot/id-replication-eus2'
param secondaryIdentityId = '$identityRoot/id-replication-wus2'
"@
    Assert-True (Test-Compiles 'pipeline' $pipeline) 'a parameter file with reused identities and separately granted roles does not compile'
    Assert-True (-not (Test-Compiles 'unknown-identity-mode' "$base`nparam identityMode = 'shared'")) 'an unknown identityMode was accepted'

    # The complete parameter files in deploy/bicep/README.md must compile, so the documented examples can't drift from the template.
    $readme = [IO.File]::ReadAllText((Join-Path $repositoryRoot 'deploy/bicep/README.md'))
    $examples = @([regex]::Matches($readme, '(?ms)^```bicep\r?\n(using ''\./existing\.bicep''.*?)^```') | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($examples.Count -ge 4) "expected at least four complete README parameter files, found $($examples.Count)"
    for ($index = 0; $index -lt $examples.Count; $index++) {
        Assert-True (Test-Compiles "readme-example-$index" $examples[$index]) "README parameter file example $($index + 1) does not compile"
    }
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Existing-resource profile contract checks passed.'
