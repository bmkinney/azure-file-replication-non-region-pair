$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '../deploy/bicep/modules/monitoring.bicep'
$compiledJson = (& az bicep build --file $modulePath --stdout) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to compile the monitoring Bicep module.'
}

$template = $compiledJson | ConvertFrom-Json -Depth 100
$freshnessQuery = $template.variables.freshnessQueryTemplate
if (-not $freshnessQuery) {
    throw 'The monitoring module has no freshness query template.'
}

if ($freshnessQuery.Contains('${replicationLagThresholdMinutes}')) {
    throw 'The compiled freshness query contains an uninterpolated Bicep placeholder.'
}
if (-not $freshnessQuery.Contains('ago({0}m)')) {
    throw 'The compiled freshness query does not format the configured lag threshold.'
}
# Both regions can share one workspace, so each rule must count only its own job's successes.
if (-not $freshnessQuery.Contains('| where ContainerJobName_s == "{2}"')) {
    throw 'The compiled freshness query does not filter on the job name.'
}
foreach ($role in 'primary', 'secondary') {
    $query = [string]$template.variables."${role}FreshnessQuery"
    if (-not $query.Contains("variables('freshnessQueryTemplate')") -or -not $query.Contains("parameters('replicationLagThresholdMinutes')") -or -not $query.Contains("parameters('${role}JobName')")) {
        throw "The $role freshness query does not format the template with the lag threshold and the $role job name."
    }
}

# A newly activated direction must not alert before its first scheduled run is logged and ingested.
$graceParameter = $template.parameters.freshnessGraceStartTime
if (-not $graceParameter -or $graceParameter.defaultValue -ne "[utcNow('o')]") {
    throw 'The freshness grace period must default to the deployment time in ISO 8601 format.'
}
if (-not $template.variables.primaryFreshnessQuery.Contains("parameters('freshnessGraceStartTime')") -or -not $freshnessQuery.Contains('let graceEndsAt = datetime({1}) + {0}m;')) {
    throw 'The compiled freshness query does not end its grace period one lag threshold after the grace start.'
}
if (-not $freshnessQuery.Contains('iff(now() < graceEndsAt, max_of(SuccessCount, 1), SuccessCount)')) {
    throw 'The compiled freshness query does not treat the active direction as fresh during the grace period.'
}

$freshnessRules = @($template.resources | Where-Object {
    $_.type -eq 'Microsoft.Insights/scheduledQueryRules'
})
if ($freshnessRules.Count -ne 2) {
    throw "Expected two freshness rules but found $($freshnessRules.Count)."
}

foreach ($rule in $freshnessRules) {
    $role = if ($rule.name -match 'secondaryFreshnessAlertName') { 'secondary' } else { 'primary' }
    if ($rule.properties.criteria.allOf[0].query -ne "[variables('${role}FreshnessQuery')]") {
        throw "Scheduled query rule $($rule.name) does not use the $role job's freshness query."
    }
    if ($rule.location -ne "[parameters('${role}LogWorkspaceLocation')]") {
        throw "Scheduled query rule $($rule.name) is not placed in its workspace's region."
    }
}

Write-Host 'Monitoring template contract checks passed.'