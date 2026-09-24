$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot '../infra/modules/monitoring.bicep'
$compiledJson = (& az bicep build --file $modulePath --stdout) -join [Environment]::NewLine
if ($LASTEXITCODE -ne 0) {
    throw 'Failed to compile the monitoring Bicep module.'
}

$template = $compiledJson | ConvertFrom-Json -Depth 100
$freshnessQuery = $template.variables.freshnessQuery

if ($freshnessQuery.Contains('${replicationLagThresholdMinutes}')) {
    throw 'The compiled freshness query contains an uninterpolated Bicep placeholder.'
}
if (-not $freshnessQuery.Contains('ago({0}m)')) {
    throw 'The compiled freshness query does not format the configured lag threshold.'
}
if (-not $freshnessQuery.Contains("parameters('replicationLagThresholdMinutes')")) {
    throw 'The compiled freshness query does not use the lag-threshold parameter.'
}

# A newly activated direction must not alert before its first scheduled run is logged and ingested.
$graceParameter = $template.parameters.freshnessGraceStartTime
if (-not $graceParameter -or $graceParameter.defaultValue -ne "[utcNow('o')]") {
    throw 'The freshness grace period must default to the deployment time in ISO 8601 format.'
}
if (-not $freshnessQuery.Contains("parameters('freshnessGraceStartTime')") -or -not $freshnessQuery.Contains('let graceEndsAt = datetime({1}) + {0}m;')) {
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
    if ($rule.properties.criteria.allOf[0].query -ne "[variables('freshnessQuery')]") {
        throw "Scheduled query rule $($rule.name) does not use the validated freshness query."
    }
}

Write-Host 'Monitoring template contract checks passed.'