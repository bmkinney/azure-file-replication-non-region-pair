$ErrorActionPreference = 'Stop'

# Compiles the foundation modules and checks the Container Apps environment and job contract, and the job identities'
# role assignments; no Azure calls are made.

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "foundation template check failed: $Message"
    }
}

function Resolve-TemplateValue($Template, $Value) {
    if ($Value -is [string] -and $Value -match "^\[variables\('([^']+)'\)\]$") {
        return $Template.variables.($Matches[1])
    }
    return $Value
}

# The greenfield foundation declares both regions; the existing-resource profile deploys one region module per region.
$expectedCounts = [ordered]@{ 'foundation.bicep' = 2; 'replication-region.bicep' = 1 }
foreach ($moduleName in $expectedCounts.Keys) {
    $modulePath = Join-Path $PSScriptRoot "../deploy/bicep/modules/$moduleName"
    $compiledJson = (& az bicep build --file $modulePath --stdout) -join [Environment]::NewLine
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to compile $moduleName."
    }
    $template = $compiledJson | ConvertFrom-Json -Depth 100
    # languageVersion 2.0 templates use a resource dictionary instead of an array.
    $resources = if ($template.resources -is [array]) { $template.resources } else { @($template.resources.PSObject.Properties.Value) }

    $expected = $expectedCounts[$moduleName]
    $environments = @($resources | Where-Object { $_.type -eq 'Microsoft.App/managedEnvironments' -and -not $_.existing })
    $jobs = @($resources | Where-Object { $_.type -eq 'Microsoft.App/jobs' })
    Assert-True ($environments.Count -eq $expected) "$moduleName declares $($environments.Count) Container Apps environments; expected $expected"
    Assert-True ($jobs.Count -eq $expected) "$moduleName declares $($jobs.Count) Container Apps jobs; expected $expected"

    # Delegated subnets require a workload profiles environment, so the profile must be explicit rather than an RP default.
    $profileNames = @()
    foreach ($environment in $environments) {
        Assert-True ([bool]$environment.properties.vnetConfiguration.infrastructureSubnetId) "$moduleName environment $($environment.name) is not VNet-integrated"
        $consumptionProfiles = @($environment.properties.workloadProfiles | Where-Object { $_.workloadProfileType -eq 'Consumption' })
        Assert-True ($consumptionProfiles.Count -eq 1) "$moduleName environment $($environment.name) must declare exactly one Consumption workload profile"
        $profileNames += Resolve-TemplateValue $template $consumptionProfiles[0].name
    }
    foreach ($job in $jobs) {
        $jobProfile = Resolve-TemplateValue $template $job.properties.workloadProfileName
        Assert-True ($jobProfile -and $profileNames -contains $jobProfile) "$moduleName job $($job.name) must run on the declared Consumption workload profile"
    }

    if ($moduleName -eq 'foundation.bicep') {
        # With createRoleAssignments = false an administrator grants the six assignments, which the output lists either way.
        $assignments = @($resources | Where-Object { $_.type -eq 'Microsoft.Authorization/roleAssignments' })
        Assert-True ($assignments.Count -eq 6) "foundation.bicep declares $($assignments.Count) role assignments; expected 6"
        foreach ($assignment in $assignments) {
            Assert-True ($assignment.condition -eq "[parameters('createRoleAssignments')]") "role assignment $($assignment.name) doesn't depend on createRoleAssignments"
            Assert-True ([string]$assignment.name -match "^\[guid\(resourceId\('Microsoft\.(Storage/storageAccounts|ContainerRegistry/registries)', variables\('[^']+'\)\), resourceId\('Microsoft\.ManagedIdentity/userAssignedIdentities', variables\('(primary|secondary)IdentityName'\)\), variables\('(fileData|acrPull)RoleDefinitionId'\)\)\]$") "role assignment name '$($assignment.name)' no longer matches the jobRoleAssignments output"
        }
        $listed = $template.outputs.jobRoleAssignments
        Assert-True ($listed.type -eq 'array' -and $listed.copy.count -eq '[length(range(0, 6))]') 'foundation.bicep must output the six job role assignments'
        foreach ($property in 'name', 'scope', 'principalId', 'principalName', 'roleDefinitionId', 'roleName') {
            Assert-True ($null -ne $listed.copy.input.$property) "the jobRoleAssignments output lacks $property"
        }
        # The names must equal the resources' names, which use each identity's resource ID rather than its principal ID.
        Assert-True ([string]$listed.copy.input.name -match "^\[guid\(variables\('jobRoleTargets'\)\[div\(range\(0, 6\)\[copyIndex\(\)\], 2\)\]\.scope, createArray\(createObject\('id', resourceId\('Microsoft\.ManagedIdentity/userAssignedIdentities'") "the jobRoleAssignments names don't use the formula of the role assignments: $($listed.copy.input.name)"
        $targets = @($template.variables.jobRoleTargets)
        Assert-True ($targets.Count -eq 3) 'jobRoleTargets must list both storage accounts and the registry'
        $roleIds = @($assignments | ForEach-Object { [string]$_.properties.roleDefinitionId } | Sort-Object -Unique)
        foreach ($target in $targets) {
            $roleVariable = if ($target.roleDefinitionId -eq '7f951dda-4ed3-4680-a7ca-43fe172d538d') { 'acrPullRoleDefinitionId' } else { 'fileDataRoleDefinitionId' }
            Assert-True ($template.variables.$roleVariable -eq "[subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '$($target.roleDefinitionId)')]") "role $($target.roleName) doesn't match $roleVariable"
            Assert-True ($roleIds -contains "[variables('$roleVariable')]") "no role assignment uses $roleVariable"
        }
    }
}

# main.bicep passes createRoleAssignments through and reports the assignments for scripts/deploy.ps1 and scripts/grant-access.ps1.
$mainJson = (& az bicep build --file (Join-Path $PSScriptRoot '../deploy/bicep/main.bicep') --stdout) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to compile main.bicep.'
}
$main = $mainJson | ConvertFrom-Json -Depth 100
Assert-True ($main.parameters.createRoleAssignments.defaultValue -eq $true) 'createRoleAssignments must default to true in main.bicep'
$mainResources = if ($main.resources -is [array]) { $main.resources } else { @($main.resources.PSObject.Properties.Value) }
$foundation = @($mainResources | Where-Object { $_.type -eq 'Microsoft.Resources/deployments' -and $_.name -eq 'storage-replication-foundation' })[0]
Assert-True ($foundation.properties.parameters.createRoleAssignments.value -eq "[parameters('createRoleAssignments')]") 'main.bicep must pass createRoleAssignments to the foundation'
foreach ($output in 'createRoleAssignments', 'registryCreated', 'jobRoleAssignments') {
    Assert-True ($null -ne $main.outputs.$output) "main.bicep must output $output"
}

Write-Host 'Foundation template contract checks passed.'
