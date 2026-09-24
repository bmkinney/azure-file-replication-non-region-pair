$ErrorActionPreference = 'Stop'

# Compiles the foundation modules and checks the Container Apps environment and job contract; no Azure calls are made.

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
    $modulePath = Join-Path $PSScriptRoot "../infra/modules/$moduleName"
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
}

Write-Host 'Foundation template contract checks passed.'
