[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('status', 'inventory', 'seed', 'replicate', 'files', 'standby-check', 'fail-run', 'pause', 'resume', 'alerts', 'cleanup')]
    [string]$Command = 'status',

    [string]$ResourceGroupName = $(if ($env:REPLICATION_DEMO_RESOURCE_GROUP) { $env:REPLICATION_DEMO_RESOURCE_GROUP } else { 'rg-azure-files-replication-demo' }),

    # inventory: the deployment parameter file. Adds the prerequisite checks and the what-if drift report.
    [string]$ParametersFile,

    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$')]
    [string]$DemoFolder = 'replication-demo',

    # resume: the schedule to restore when the job has no pause tag.
    [ValidatePattern('^\S+( \S+){4}$')]
    [string]$CronExpression,

    [ValidateSet('1h', '1d', '7d', '30d')]
    [string]$TimeRange = '1d',

    [ValidateRange(1, 120)]
    [int]$TimeoutMinutes = 15,

    [switch]$NoWait,

    [switch]$Force,

    [ValidateRange(0, 300)]
    [int]$PollSeconds = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Helper executions replace the job command for a single execution. They never print AZURE_FILES_REPLICATION_SUCCEEDED,
# so they can't satisfy the freshness alert, and they exit 0, so they can't raise the failed-execution alert.
$WorkloadTag = 'azure-files-dr-replication'
$PauseTagName = 'ReplicationDemoOriginalCron'
$MissingSharePrefix = 'replication-demo-missing-'
$TerminalStatuses = @('Succeeded', 'Failed', 'Stopped', 'Degraded')
$LogWaitMinutes = 10
$script:CloudSettings = $null

$ScriptPrelude = @'
set -u
export AZCOPY_AUTO_LOGIN_TYPE=MSI
export AZCOPY_LOG_LOCATION=/tmp/azcopy-demo
export AZCOPY_JOB_PLAN_LOCATION=/tmp/azcopy-demo
mkdir -p "$AZCOPY_LOG_LOCATION"
redact() { sed -E 's#https?://[^[:space:]"]+#<redacted-url>#g'; }
'@

$SeedScript = $ScriptPrelude + @'

work=/tmp/replication-demo-seed
rm -rf "$work"
mkdir -p "$work/$DEMO_FOLDER"
printf 'Azure Files replication demo file\ncreatedAt=%s\nexecution=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CONTAINER_APP_JOB_EXECUTION_NAME:-unknown}" > "$work/$DEMO_FOLDER/$DEMO_FILE_NAME"
azcopy copy "$work/$DEMO_FOLDER" "$DEMO_TARGET_URL" --recursive=true --log-level=ERROR --output-type=text > /tmp/replication-demo-seed.out 2>&1
code=$?
if [ "$code" -ne 0 ]; then tail -n 5 /tmp/replication-demo-seed.out | redact | sed 's/^/REPLICATION_DEMO_SEED_ERROR /'; fi
echo "REPLICATION_DEMO_SEED_COMPLETED file=$DEMO_FOLDER/$DEMO_FILE_NAME exitCode=$code"
exit 0
'@

$ListScript = $ScriptPrelude + @'

list_side() {
    side="$1"
    url="$2"
    azcopy list "$url/$DEMO_FOLDER" --properties=LastModifiedTime --machine-readable --running-tally --output-type=json > /tmp/replication-demo-list.out 2>&1
    code=$?
    grep -E '"MessageType":"(ListObject|ListSummary)"' /tmp/replication-demo-list.out | sed "s/^/REPLICATION_DEMO_LIST_ITEM side=$side /"
    if [ "$code" -ne 0 ]; then grep -vE '"MessageType":"(ListObject|ListSummary)"' /tmp/replication-demo-list.out | tail -n 3 | redact | sed "s/^/REPLICATION_DEMO_LIST_ERROR side=$side /"; fi
    echo "REPLICATION_DEMO_LIST_END side=$side exitCode=$code"
}
list_side source "$DEMO_SOURCE_URL"
list_side replica "$DEMO_REPLICA_URL"
exit 0
'@

$DryRunScript = $ScriptPrelude + @'

case "${DELETE_DESTINATION:-false}" in
    true) delete_destination=true ;;
    *) delete_destination=false ;;
esac
out=/tmp/replication-demo-dry-run.out
azcopy sync "$SOURCE_FILE_URL" "$DESTINATION_FILE_URL" --recursive=true --delete-destination="$delete_destination" --preserve-info=true --preserve-permissions="${PRESERVE_PERMISSIONS:-true}" --include-root=true --force-if-read-only=true --log-level=ERROR --dry-run --output-type=text > "$out" 2>&1
code=$?
would_copy="$(grep -c '^DRYRUN: copy ' "$out" || true)"
would_remove="$(grep -c '^DRYRUN: remove ' "$out" || true)"
would_set_properties="$(grep -c '^DRYRUN: set-properties ' "$out" || true)"
if [ "$code" -ne 0 ]; then grep -v '^DRYRUN: ' "$out" | tail -n 5 | redact | sed 's/^/REPLICATION_DEMO_DRY_RUN_ERROR /'; fi
echo "REPLICATION_DEMO_DRY_RUN_COMPLETED wouldCopy=$would_copy wouldRemove=$would_remove wouldSetProperties=$would_set_properties exitCode=$code"
exit 0
'@

$CleanupScript = $ScriptPrelude + @'

remove_side() {
    side="$1"
    url="$2"
    azcopy remove "$url/$DEMO_FOLDER" --recursive=true --log-level=ERROR --output-type=text > /tmp/replication-demo-remove.out 2>&1
    code=$?
    if [ "$code" -ne 0 ]; then tail -n 3 /tmp/replication-demo-remove.out | redact | sed "s/^/REPLICATION_DEMO_CLEANUP_ERROR side=$side /"; fi
    echo "REPLICATION_DEMO_CLEANUP_COMPLETED side=$side exitCode=$code"
}
remove_side source "$DEMO_SOURCE_URL"
remove_side replica "$DEMO_REPLICA_URL"
exit 0
'@

#region Helpers

# Returns nothing (not $null) for a missing value, so @(Get-Value ...) is empty.
function Get-Value {
    param($Object, [Parameter(Mandatory)][string]$Path)

    $current = $Object
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) {
            return
        }
        # Direct assignment keeps nested arrays intact; an if-expression would unroll them.
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) {
                return
            }
            $current = $current[$segment]
            continue
        }
        $property = $current.PSObject.Properties[$segment]
        if (-not $property) {
            return
        }
        $current = $property.Value
    }
    if ($null -ne $current) {
        return $current
    }
}

function ConvertTo-Key([string]$Value) {
    if (-not $Value) {
        return ''
    }
    return $Value.Trim().ToLowerInvariant()
}

function ConvertTo-UtcDate($Value) {
    if ($null -eq $Value -or ($Value -is [string] -and -not $Value)) {
        return $null
    }
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            return [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)
        }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [datetimeoffset]) {
        return $Value.UtcDateTime
    }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.UtcDateTime
    }
    return $null
}

# ARM returns ISO 8601 durations (PT5M); some Azure CLI commands print them as 0:05:00.
function ConvertTo-TimeSpan($Value) {
    $text = [string]$Value
    if (-not $text) {
        return $null
    }
    try {
        if ($text -match '^-?P') {
            return [System.Xml.XmlConvert]::ToTimeSpan($text)
        }
        return [timespan]::Parse($text, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return $null
    }
}

function Format-Utc($Value) {
    $date = ConvertTo-UtcDate $Value
    if ($null -eq $date) {
        return '-'
    }
    return $date.ToString('yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'
}

function Format-Span([timespan]$Span) {
    if ($Span.TotalSeconds -lt 0) {
        $Span = [timespan]::Zero
    }
    if ($Span.TotalMinutes -lt 1) {
        return '{0}s' -f [int][math]::Floor($Span.TotalSeconds)
    }
    if ($Span.TotalHours -lt 1) {
        return '{0}m {1:D2}s' -f [int][math]::Floor($Span.TotalMinutes), $Span.Seconds
    }
    if ($Span.TotalDays -lt 1) {
        return '{0}h {1:D2}m' -f [int][math]::Floor($Span.TotalHours), $Span.Minutes
    }
    return '{0}d {1:D2}h' -f [int][math]::Floor($Span.TotalDays), $Span.Hours
}

function Format-Minutes($Value) {
    $span = ConvertTo-TimeSpan $Value
    if ($null -eq $span) {
        return [string]$Value
    }
    return '{0} min' -f [int]$span.TotalMinutes
}

function Format-Bytes($Value) {
    $bytes = 0.0
    if (-not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$bytes)) {
        return [string]$Value
    }
    foreach ($unit in 'B', 'KiB', 'MiB', 'GiB') {
        if ($bytes -lt 1024 -or $unit -eq 'GiB') {
            if ($unit -eq 'B') {
                return '{0:N0} B' -f $bytes
            }
            return '{0:N1} {1}' -f $bytes, $unit
        }
        $bytes /= 1024
    }
}

# File paths can be sensitive, so URLs are removed from AzCopy messages before they're shown.
function Protect-Text([string]$Text, [int]$MaxLength = 300) {
    $clean = (($Text -replace 'https?://[^\s"]+', '<redacted-url>') -replace '\s+', ' ').Trim()
    if ($clean.Length -gt $MaxLength) {
        $clean = $clean.Substring(0, $MaxLength) + '...'
    }
    return $clean
}

function Write-Step([string]$Message, [ConsoleColor]$Color = [ConsoleColor]::Gray) {
    Write-Host ('[{0:HH:mm:ss}Z] {1}' -f [DateTime]::UtcNow, $Message) -ForegroundColor $Color
}

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host $Title -ForegroundColor Cyan
}

function Write-Table($Rows, [string[]]$Property, [string]$Empty = '(none)') {
    $items = @($Rows | Where-Object { $null -ne $_ })
    if ($items.Count -eq 0) {
        Write-Host "  $Empty"
        return
    }
    $width = 200
    try {
        if (-not [Console]::IsOutputRedirected -and $Host.UI.RawUI.BufferSize.Width -gt 0) {
            $width = [Math]::Max(100, $Host.UI.RawUI.BufferSize.Width - 1)
        }
    } catch {
        $width = 200
    }
    Write-Host (($items | Format-Table -Property $Property -AutoSize -Wrap | Out-String -Width $width).TrimEnd())
}

function Remove-TempFile([string]$Path) {
    if ($Path) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue -WhatIf:$false -Confirm:$false
    }
}

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)

    # Changes are gated by Confirm-Action. -WhatIf would otherwise also suppress the stderr redirect below.
    $WhatIfPreference = $false
    $errorPath = [IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments --only-show-errors --output json 2> $errorPath
        $exitCode = $LASTEXITCODE
        $errorText = [IO.File]::ReadAllText($errorPath).Trim()
    } finally {
        Remove-TempFile $errorPath
    }

    $text = ($output -join [Environment]::NewLine).Trim()
    $value = $null
    if ($exitCode -eq 0 -and $text) {
        $value = $text | ConvertFrom-Json -Depth 100
    }
    if ($AllowFailure) {
        return [pscustomobject]@{ Succeeded = ($exitCode -eq 0); Value = $value; Error = $errorText }
    }
    if ($exitCode -ne 0) {
        throw "az $(($Arguments | Select-Object -First 3) -join ' ') failed. $errorText"
    }
    return $value
}

# A plain function (not advanced), so $PSCmdlet is this script's and honors -WhatIf and -Confirm.
function Confirm-Action([string]$Target, [string]$Operation, [string]$Warning) {
    if (-not $PSCmdlet.ShouldProcess($Target, $Operation)) {
        return $false
    }
    if (-not $Warning -or $Force) {
        return $true
    }
    return $PSCmdlet.ShouldContinue("$Warning Continue?", $Operation)
}

function Get-CloudSetting([string]$Path, [string]$Default) {
    if ($null -eq $script:CloudSettings) {
        $cloud = Invoke-Az -AllowFailure -Arguments @('cloud', 'show')
        $script:CloudSettings = if ($cloud.Succeeded -and $cloud.Value) { $cloud.Value } else { [pscustomobject]@{} }
    }
    $value = [string](Get-Value $script:CloudSettings $Path)
    if ($value) {
        return $value.TrimEnd('/')
    }
    return $Default
}

#endregion

#region Azure lookups

function Invoke-LogQuery {
    param([Parameter(Mandatory)][string]$WorkspaceId, [Parameter(Mandatory)][string]$Query, [string]$Timespan = 'P7D')

    $endpoint = Get-CloudSetting 'endpoints.logAnalyticsResourceId' 'https://api.loganalytics.io'
    $bodyPath = Join-Path ([IO.Path]::GetTempPath()) ('replication-demo-query-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($bodyPath, (ConvertTo-Json -InputObject @{ query = $Query; timespan = $Timespan } -Compress))
        $result = Invoke-Az -AllowFailure -Arguments @('rest', '--method', 'post', '--url', "$endpoint/v1/workspaces/$WorkspaceId/query", '--resource', $endpoint, '--headers', 'Content-Type=application/json', '--body', "@$bodyPath")
    } finally {
        Remove-TempFile $bodyPath
    }

    if (-not $result.Succeeded) {
        # A new workspace has no ContainerAppConsoleLogs_CL table until the first console log arrives.
        if ($result.Error -match 'Failed to resolve table') {
            return
        }
        throw "Log Analytics query failed. $($result.Error)"
    }

    $table = @(Get-Value $result.Value 'tables') | Select-Object -First 1
    if (-not $table) {
        return
    }
    $columns = @(Get-Value $table 'columns' | ForEach-Object { [string](Get-Value $_ 'name') })
    foreach ($row in @(Get-Value $table 'rows')) {
        $cells = @($row)
        $record = [ordered]@{}
        for ($index = 0; $index -lt $columns.Count; $index++) {
            $record[$columns[$index]] = $cells[$index]
        }
        [pscustomobject]$record
    }
}

function Get-DemoContext {
    $account = Invoke-Az -Arguments @('account', 'show')
    $subscriptionId = [string](Get-Value $account 'id')

    $jobs = @(Invoke-Az -Arguments @('containerapp', 'job', 'list', '--resource-group', $ResourceGroupName) | Where-Object { (Get-Value $_ 'tags.Workload') -eq $WorkloadTag })
    if ($jobs.Count -eq 0) {
        throw "No Container Apps jobs tagged Workload=$WorkloadTag were found in resource group '$ResourceGroupName'. Pass -ResourceGroupName or set REPLICATION_DEMO_RESOURCE_GROUP."
    }

    # Both profiles create one failed-execution rule per job; its name and scope identify the job's role.
    $metricRules = @(Invoke-Az -Arguments @('monitor', 'metrics', 'alert', 'list', '--resource-group', $ResourceGroupName) | Where-Object { $_ })
    $roleByJobId = @{}
    foreach ($rule in $metricRules) {
        if ([string](Get-Value $rule 'name') -match '^alert-replication-failed-(primary|secondary)-') {
            $role = $Matches[1]
            foreach ($scope in @(Get-Value $rule 'scopes')) {
                $roleByJobId[(ConvertTo-Key $scope)] = $role
            }
        }
    }

    $queryRulesResult = Invoke-Az -AllowFailure -Arguments @('rest', '--method', 'get', '--url', "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/scheduledQueryRules", '--url-parameters', 'api-version=2023-12-01')
    $queryRules = @()
    if ($queryRulesResult.Succeeded) {
        $queryRules = @(Get-Value $queryRulesResult.Value 'value')
    } else {
        Write-Warning "Could not read the log search alert rules. $($queryRulesResult.Error)"
    }

    $environments = @{}
    $records = foreach ($job in $jobs) {
        $jobId = [string](Get-Value $job 'id')
        $name = [string](Get-Value $job 'name')
        $template = Get-Value $job 'properties.template'
        $container = @(Get-Value $template 'containers') | Select-Object -First 1
        $variables = @{}
        foreach ($entry in @(Get-Value $container 'env')) {
            $variables[[string](Get-Value $entry 'name')] = [string](Get-Value $entry 'value')
        }

        $environmentId = [string](Get-Value $job 'properties.environmentId')
        $environmentKey = ConvertTo-Key $environmentId
        if (-not $environments.ContainsKey($environmentKey)) {
            $lookup = Invoke-Az -AllowFailure -Arguments @('containerapp', 'env', 'show', '--ids', $environmentId)
            if (-not $lookup.Succeeded) {
                Write-Warning "Could not read Container Apps environment $environmentId; log-based checks are skipped for its jobs. $($lookup.Error)"
            }
            $environments[$environmentKey] = $lookup.Value
        }
        $environment = $environments[$environmentKey]

        $role = if ($roleByJobId.ContainsKey((ConvertTo-Key $jobId))) {
            $roleByJobId[(ConvertTo-Key $jobId)]
        } elseif ($name -match 'primary') {
            'primary'
        } elseif ($name -match 'secondary') {
            'secondary'
        } else {
            $name
        }

        $freshnessRule = $queryRules | Where-Object { [string](Get-Value $_ 'name') -match "^alert-replication-stale-$role-" } | Select-Object -First 1
        $threshold = ConvertTo-TimeSpan (Get-Value $freshnessRule 'properties.windowSize')

        [pscustomobject]@{
            Role             = $role
            Name             = $name
            Id               = $jobId
            Location         = [string](Get-Value $job 'location')
            TriggerType      = [string](Get-Value $job 'properties.configuration.triggerType')
            Cron             = [string](Get-Value $job 'properties.configuration.scheduleTriggerConfig.cronExpression')
            Image            = [string](Get-Value $container 'image')
            Environment      = $variables
            Template         = $template
            PausedCron       = [string](Get-Value $job "tags.$PauseTagName")
            Registry         = [string](Get-Value (@(Get-Value $job 'properties.configuration.registries') | Select-Object -First 1) 'server')
            WorkspaceId      = [string](Get-Value $environment 'properties.appLogsConfiguration.logAnalyticsConfiguration.customerId')
            SubnetId         = [string](Get-Value $environment 'properties.vnetConfiguration.infrastructureSubnetId')
            FreshnessRule    = [string](Get-Value $freshnessRule 'name')
            FreshnessEnabled = [bool](Get-Value $freshnessRule 'properties.enabled')
            ThresholdMinutes = if ($threshold) { [int]$threshold.TotalMinutes } else { $null }
        }
    }
    $records = @($records | Sort-Object { if ($_.Role -eq 'primary') { 0 } elseif ($_.Role -eq 'secondary') { 1 } else { 2 } }, Name)

    $scheduled = @($records | Where-Object TriggerType -eq 'Schedule')
    if ($scheduled.Count -gt 1) {
        Write-Warning 'More than one replication job has a schedule. Opposing directions must never run at the same time; fix the deployment before continuing.'
    }
    $active = if ($scheduled.Count -eq 1) { $scheduled[0] } else { $null }
    $standby = if ($active) { @($records | Where-Object Id -ne $active.Id) | Select-Object -First 1 } else { $null }

    [pscustomobject]@{
        SubscriptionId   = $subscriptionId
        SubscriptionName = [string](Get-Value $account 'name')
        TenantId         = [string](Get-Value $account 'tenantId')
        Jobs             = $records
        Active           = $active
        Standby          = $standby
        MetricRules      = $metricRules
        QueryRules       = $queryRules
    }
}

function Get-ActiveJob($Context, [string]$Reason) {
    if (-not $Context.Active) {
        throw "No replication job has a schedule (activeRegion=none), so $Reason. Deploy with activeRegion=primary or secondary first."
    }
    return $Context.Active
}

function Get-ReplicationUrls($Context) {
    $reference = $Context.Active
    if (-not $reference) {
        $reference = @(@($Context.Jobs | Where-Object Role -eq 'primary') + @($Context.Jobs))[0]
    }
    [pscustomobject]@{
        Source      = $reference.Environment['SOURCE_FILE_URL']
        Replica     = $reference.Environment['DESTINATION_FILE_URL']
        SourceRole  = $reference.Role
        ReplicaRole = [string](@($Context.Jobs | Where-Object Id -ne $reference.Id | ForEach-Object Role) | Select-Object -First 1)
    }
}

function Get-ExecutionKind($Execution) {
    $template = Get-Value $Execution 'properties.template'
    if (-not $template) {
        return 'Unknown'
    }
    $container = @(Get-Value $template 'containers') | Select-Object -First 1
    $arguments = @(Get-Value $container 'args') -join ' '
    switch -Regex ($arguments) {
        'REPLICATION_DEMO_SEED' { return 'Demo: write file' }
        'REPLICATION_DEMO_LIST' { return 'Demo: list files' }
        'REPLICATION_DEMO_DRY_RUN' { return 'Demo: standby dry run' }
        'REPLICATION_DEMO_CLEANUP' { return 'Demo: cleanup' }
    }
    $source = @(Get-Value $container 'env' | Where-Object { (Get-Value $_ 'name') -eq 'SOURCE_FILE_URL' } | ForEach-Object { [string](Get-Value $_ 'value') }) | Select-Object -First 1
    if ($source -and $source.Contains("/$MissingSharePrefix")) {
        return 'Demo: simulated failure'
    }
    if ($arguments) {
        return 'Custom command'
    }
    return 'Replication'
}

function Get-Executions($Job) {
    foreach ($execution in @(Invoke-Az -Arguments @('containerapp', 'job', 'execution', 'list', '--name', $Job.Name, '--resource-group', $ResourceGroupName) | Where-Object { $_ })) {
        $start = ConvertTo-UtcDate (Get-Value $execution 'properties.startTime')
        $end = ConvertTo-UtcDate (Get-Value $execution 'properties.endTime')
        $duration = '-'
        if ($start -and $end) {
            $duration = Format-Span ($end - $start)
        } elseif ($start) {
            $duration = 'running ' + (Format-Span ([DateTime]::UtcNow - $start))
        }
        [pscustomobject]@{
            Role     = $Job.Role
            Name     = [string](Get-Value $execution 'name')
            Kind     = Get-ExecutionKind $execution
            Status   = [string](Get-Value $execution 'properties.status')
            Started  = $start
            Duration = $duration
        }
    }
}

# Mirrors the freshness alert: the latest success and failure markers in the job environment's workspace.
function Get-ReplicationMarkers($Job) {
    if (-not $Job.WorkspaceId) {
        return
    }
    $query = @'
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(7d)
| extend Line = tostring(column_ifexists('Log_s', ''))
| where Line contains 'AZURE_FILES_REPLICATION_'
| extend Marker = extract(@'(AZURE_FILES_REPLICATION_[A-Z_]+)', 1, Line)
| where Marker in ('AZURE_FILES_REPLICATION_SUCCEEDED', 'AZURE_FILES_REPLICATION_FAILED')
| summarize arg_max(TimeGenerated, Line) by Marker
'@
    try {
        $rows = @(Invoke-LogQuery -WorkspaceId $Job.WorkspaceId -Query $query)
    } catch {
        Write-Warning "Could not query replication logs for $($Job.Name). $_"
        return
    }
    foreach ($row in $rows) {
        $line = [string]$row.Line
        [pscustomobject]@{
            Marker          = [string]$row.Marker
            Time            = ConvertTo-UtcDate $row.TimeGenerated
            StartedAt       = if ($line -match 'startedAt=(\S+)') { ConvertTo-UtcDate $Matches[1] } else { $null }
            DurationSeconds = if ($line -match 'durationSeconds=(\d+)') { [int]$Matches[1] } else { $null }
        }
    }
}

function Get-AlertInstances([string]$SubscriptionId, [string]$Range) {
    $result = Invoke-Az -AllowFailure -Arguments @('rest', '--method', 'get', '--url', "/subscriptions/$SubscriptionId/providers/Microsoft.AlertsManagement/alerts", '--url-parameters', 'api-version=2019-03-01', "targetResourceGroup=$ResourceGroupName", "timeRange=$Range")
    if (-not $result.Succeeded) {
        Write-Warning "Could not read alert instances. $($result.Error)"
        return
    }
    foreach ($alert in @(Get-Value $result.Value 'value')) {
        $essentials = Get-Value $alert 'properties.essentials'
        $ruleId = [string](Get-Value $essentials 'alertRule')
        $rule = if ($ruleId) { $ruleId.TrimEnd('/').Split('/')[-1] } else { [string](Get-Value $alert 'name') }
        if ($rule -notmatch '^alert-replication-') {
            continue
        }
        [pscustomobject]@{
            Rule      = $rule
            Severity  = [string](Get-Value $essentials 'severity')
            Condition = [string](Get-Value $essentials 'monitorCondition')
            State     = [string](Get-Value $essentials 'alertState')
            Started   = ConvertTo-UtcDate (Get-Value $essentials 'startDateTime')
            Resolved  = ConvertTo-UtcDate (Get-Value $essentials 'monitorConditionResolvedDateTime')
        }
    }
}

function ConvertTo-AzCopyMessage([string]$Line) {
    $message = $Line
    if ($Line.TrimStart().StartsWith('{')) {
        try {
            $content = [string](Get-Value ($Line | ConvertFrom-Json -Depth 20) 'MessageContent')
            if ($content) {
                $message = $content
            }
        } catch {
            Write-Verbose "Couldn't parse an AzCopy message: $_"
        }
    }
    return Protect-Text $message 400
}

function Get-AzCopyError($Lines) {
    foreach ($line in @($Lines | ForEach-Object Line)) {
        if ($line -match '"MessageType":"Error"') {
            ConvertTo-AzCopyMessage $line
        }
    }
}

#endregion

#region Executions

function ConvertTo-ExecutionContainer($Container) {
    $result = [ordered]@{
        name  = [string](Get-Value $Container 'name')
        image = [string](Get-Value $Container 'image')
    }
    foreach ($property in 'command', 'args', 'env') {
        $values = @(Get-Value $Container $property)
        if ($values.Count -gt 0) {
            $result[$property] = $values
        }
    }
    $resources = Get-Value $Container 'resources'
    if ($resources) {
        $result['resources'] = [ordered]@{ cpu = Get-Value $resources 'cpu'; memory = [string](Get-Value $resources 'memory') }
    }
    return $result
}

function Start-Execution {
    param([Parameter(Mandatory)]$Job, [hashtable]$Environment = @{}, [string]$Script)

    if ($Job.Image -match 'containerapps-helloworld') {
        throw "$($Job.Name) still runs the placeholder image. Deploy the AzCopy image first (scripts/deploy.ps1)."
    }

    $arguments = @('containerapp', 'job', 'start', '--name', $Job.Name, '--resource-group', $ResourceGroupName)
    $templatePath = $null
    if ($Environment.Count -gt 0 -or $Script) {
        # The execution template replaces the job's containers for this execution only.
        $containers = @(Get-Value $Job.Template 'containers' | ForEach-Object { ConvertTo-ExecutionContainer $_ })
        $first = $containers[0]
        $variables = @(@($first['env']) | Where-Object { $_ -and -not $Environment.ContainsKey([string](Get-Value $_ 'name')) })
        foreach ($name in @($Environment.Keys | Sort-Object)) {
            $variables += [ordered]@{ name = $name; value = [string]$Environment[$name] }
        }
        $first['env'] = $variables
        if ($Script) {
            $first['command'] = @('/bin/sh', '-c')
            $first['args'] = @($Script -replace "`r`n", "`n")
        }
        $template = [ordered]@{ containers = $containers }
        $initContainers = @(Get-Value $Job.Template 'initContainers' | ForEach-Object { ConvertTo-ExecutionContainer $_ })
        if ($initContainers.Count -gt 0) {
            $template['initContainers'] = $initContainers
        }

        # JSON is valid YAML, and the Azure CLI accepts it for --yaml.
        $templatePath = Join-Path ([IO.Path]::GetTempPath()) ('replication-demo-template-{0}.yaml' -f [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($templatePath, (ConvertTo-Json -InputObject $template -Depth 50))
        $arguments += @('--yaml', $templatePath)
    }

    try {
        $started = Invoke-Az -Arguments $arguments
    } finally {
        Remove-TempFile $templatePath
    }
    $executionName = [string](Get-Value $started 'name')
    if ($executionName -notmatch '^[a-z0-9][a-z0-9-]*$') {
        throw 'The job start response did not include a valid execution name.'
    }
    return $executionName
}

function Wait-Execution {
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$ExecutionName)

    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    $lastStatus = ''
    while ($true) {
        $execution = Invoke-Az -Arguments @('containerapp', 'job', 'execution', 'show', '--name', $Job.Name, '--resource-group', $ResourceGroupName, '--job-execution-name', $ExecutionName)
        $status = [string](Get-Value $execution 'properties.status')
        if ($status -ne $lastStatus) {
            Write-Step "Execution $ExecutionName is $status."
            $lastStatus = $status
        }
        if ($TerminalStatuses -contains $status) {
            return $execution
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            Write-Step "Stopped waiting after $TimeoutMinutes minutes; the execution is still $status." Yellow
            return $execution
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-ExecutionLog {
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$ExecutionName, [Parameter(Mandatory)][datetime]$Since, [Parameter(Mandatory)][string]$UntilPattern)

    $portalHint = "In the portal, open job $($Job.Name) > Execution history > $ExecutionName to see its console logs."
    if (-not $Job.WorkspaceId) {
        Write-Step "The job environment has no Log Analytics workspace to read. $portalHint" Yellow
        return
    }
    # The invariant culture keeps ':' as the time separator, which the KQL datetime() literal requires.
    $sinceText = $Since.AddMinutes(-5).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $query = @"
ContainerAppConsoleLogs_CL
| where TimeGenerated >= datetime($sinceText)
| where tostring(column_ifexists('ContainerGroupName_s', '')) startswith '$ExecutionName'
| extend Line = tostring(column_ifexists('Log_s', '')), Order = todouble(column_ifexists('_timestamp_d', 0.0))
| project TimeGenerated, Order, Line
| order by Order asc, TimeGenerated asc
"@
    $deadline = [DateTime]::UtcNow.AddMinutes($LogWaitMinutes)
    $announced = $false
    while ($true) {
        try {
            $lines = @(Invoke-LogQuery -WorkspaceId $Job.WorkspaceId -Query $query -Timespan 'P1D')
        } catch {
            Write-Step "Could not read the execution output. $portalHint $_" Yellow
            return
        }
        if (@($lines | Where-Object { $_.Line -match $UntilPattern }).Count -gt 0) {
            return $lines
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            Write-Step "The execution output hasn't reached Log Analytics yet. $portalHint" Yellow
            return $lines
        }
        if (-not $announced) {
            Write-Step 'Waiting for the execution output to reach Log Analytics (usually 2-5 minutes)...'
            $announced = $true
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Invoke-HelperExecution {
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][hashtable]$Environment, [Parameter(Mandatory)][string]$Script, [Parameter(Mandatory)][string]$UntilPattern)

    $since = [DateTime]::UtcNow
    $executionName = Start-Execution -Job $Job -Environment $Environment -Script $Script
    Write-Step "Started execution $executionName on $($Job.Name) ($($Job.Role) job)."
    if ($NoWait) {
        Write-Step "Not waiting. View the output in the portal: job $($Job.Name) > Execution history > $executionName."
        return [pscustomobject]@{ Waited = $false; Lines = @() }
    }
    $execution = Wait-Execution -Job $Job -ExecutionName $executionName
    if ((Get-Value $execution 'properties.status') -ne 'Succeeded') {
        Write-Step 'The helper execution did not succeed. Check its system and console logs in the portal.' Yellow
    }
    $lines = @(Get-ExecutionLog -Job $Job -ExecutionName $executionName -Since $since -UntilPattern $UntilPattern)
    return [pscustomobject]@{ Waited = $true; Lines = $lines }
}

function Wait-ForAlert {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$RulePattern, [Parameter(Mandatory)][datetime]$Since, $AlreadyFiring)

    Write-Step 'Waiting for Azure Monitor to fire the alert. The rule evaluates every minute; allow 3-10 minutes for metric ingestion...'
    $deadline = [DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
    while ([DateTime]::UtcNow -lt $deadline) {
        $alerts = @(Get-AlertInstances -SubscriptionId $Context.SubscriptionId -Range '1h' | Where-Object { $_.Rule -match $RulePattern })
        $fired = @($alerts | Where-Object { $_.Started -and $_.Started -ge $Since.AddMinutes(-2) -and -not ($AlreadyFiring -and $_.Started -eq $AlreadyFiring.Started) })
        if ($fired.Count -gt 0) {
            Write-Step "Alert fired: $($fired[0].Rule) ($($fired[0].Severity)) at $(Format-Utc $fired[0].Started). The action group sends its email now." Green
            return
        }
        # A stateful alert that is still firing doesn't fire again or notify again until it resolves.
        if ($AlreadyFiring -and @($alerts | Where-Object { $_.Started -eq $AlreadyFiring.Started -and $_.Condition -eq 'Fired' }).Count -gt 0) {
            Write-Step "Alert $($AlreadyFiring.Rule) is still firing from an earlier failure (since $(Format-Utc $AlreadyFiring.Started)), so this failure doesn't raise a new alert or email." Yellow
            return
        }
        Start-Sleep -Seconds ($PollSeconds * 3)
    }
    Write-Step 'The alert has not fired yet. Check again with: ./scripts/demo.ps1 alerts' Yellow
}

#endregion

#region Commands

function Show-Status($Context) {
    Write-Section "Azure Files replication status: $ResourceGroupName ($($Context.SubscriptionName))"

    $active = $Context.Active
    if ($active) {
        $standbyRole = if ($Context.Standby) { $Context.Standby.Role } else { '?' }
        $standbyRegion = if ($Context.Standby) { $Context.Standby.Location } else { '?' }
        Write-Host ("Direction : {0} ({1}) -> {2} ({3})" -f $active.Role, $active.Location, $standbyRole, $standbyRegion)
        Write-Host ("Schedule  : {0} runs on '{1}' (UTC)" -f $active.Name, $active.Cron)
        if ($active.PausedCron) {
            Write-Host ("            PAUSED by the demo script; the original schedule is '{0}'. Resume with: ./scripts/demo.ps1 resume" -f $active.PausedCron) -ForegroundColor Yellow
        }
    } else {
        Write-Host 'Direction : none. No job has a schedule (activeRegion=none), and the freshness alerts are disabled.' -ForegroundColor Yellow
    }

    Write-Section 'Jobs'
    $jobRows = foreach ($job in $Context.Jobs) {
        [pscustomobject]@{
            Role     = $job.Role
            Job      = $job.Name
            Region   = $job.Location
            Trigger  = $job.TriggerType
            Schedule = if ($job.Cron) { $job.Cron } else { '-' }
            Image    = if ($job.Image -match '@sha256:([0-9a-fA-F]{12})') { "...@sha256:$($Matches[1])..." } else { $job.Image }
        }
    }
    Write-Table $jobRows @('Role', 'Job', 'Region', 'Trigger', 'Schedule', 'Image')
    if (@($Context.Jobs | ForEach-Object Image | Select-Object -Unique).Count -ne 1) {
        Write-Host '  The jobs use different images; switch-direction.ps1 refuses to run until they match.' -ForegroundColor Yellow
    }

    Write-Section 'Recent executions'
    $executions = @($Context.Jobs | ForEach-Object { Get-Executions $_ } | Where-Object Started | Sort-Object Started -Descending | Select-Object -First 8)
    $executionRows = $executions | ForEach-Object {
        [pscustomobject]@{ Role = $_.Role; Execution = $_.Name; Kind = $_.Kind; Status = $_.Status; Started = Format-Utc $_.Started; Duration = $_.Duration }
    }
    Write-Table $executionRows @('Role', 'Execution', 'Kind', 'Status', 'Started', 'Duration')

    Write-Section 'Replication freshness'
    $monitored = if ($active) { @($active) } else { @($Context.Jobs) }
    foreach ($job in $monitored) {
        $markers = @(Get-ReplicationMarkers $job)
        $success = $markers | Where-Object Marker -eq 'AZURE_FILES_REPLICATION_SUCCEEDED' | Select-Object -First 1
        $failure = $markers | Where-Object Marker -eq 'AZURE_FILES_REPLICATION_FAILED' | Select-Object -First 1
        $threshold = if ($job.ThresholdMinutes) { "$($job.ThresholdMinutes) minutes" } else { 'unknown' }
        $alertState = if ($job.FreshnessEnabled) { 'enabled' } else { 'disabled' }
        Write-Host ("{0} job {1}: freshness alert {2}, threshold {3}" -f $job.Role, $job.Name, $alertState, $threshold)
        if ($success) {
            $age = [DateTime]::UtcNow - $success.Time
            $duration = if ($null -ne $success.DurationSeconds) { ", took $($success.DurationSeconds)s" } else { '' }
            Write-Host ("  Last successful run : finished {0} ({1} ago{2})" -f (Format-Utc $success.Time), (Format-Span $age), $duration)
            if ($success.StartedAt) {
                Write-Host ("  Recovery point      : about {0}, when that run started ({1} ago)" -f (Format-Utc $success.StartedAt), (Format-Span ([DateTime]::UtcNow - $success.StartedAt)))
            }
            if (-not $job.ThresholdMinutes) {
                Write-Host '  State               : unknown; no freshness rule was found for this job'
            } elseif ($age.TotalMinutes -ge $job.ThresholdMinutes) {
                $consequence = if ($job.FreshnessEnabled) { 'The freshness alert fires at its next 10-minute evaluation if it has not already.' } else { 'The freshness alert for this job is disabled.' }
                Write-Host "  State               : STALE (older than the threshold). $consequence" -ForegroundColor Red
            } else {
                Write-Host '  State               : Healthy (within the threshold)' -ForegroundColor Green
            }
        } else {
            Write-Host '  Last successful run : none in the last 7 days, or the logs have not arrived yet' -ForegroundColor Yellow
        }
        if ($failure -and (-not $success -or $failure.Time -gt $success.Time)) {
            Write-Host ("  Last failed run     : finished {0}, after the last success" -f (Format-Utc $failure.Time)) -ForegroundColor Yellow
        }
    }

    Write-Section 'Open alerts'
    $open = @(Get-AlertInstances -SubscriptionId $Context.SubscriptionId -Range '1d' | Where-Object Condition -eq 'Fired')
    $openRows = $open | ForEach-Object { [pscustomobject]@{ Rule = $_.Rule; Severity = $_.Severity; State = $_.State; Fired = Format-Utc $_.Started } }
    Write-Table $openRows @('Rule', 'Severity', 'State', 'Fired')

    Write-Section 'Portal'
    $portal = Get-CloudSetting 'endpoints.portal' 'https://portal.azure.com'
    Write-Host ("  Resource group : {0}/#@{1}/resource/subscriptions/{2}/resourceGroups/{3}/overview" -f $portal, $Context.TenantId, $Context.SubscriptionId, $ResourceGroupName)
    foreach ($job in $Context.Jobs) {
        Write-Host ("  {0,-14} : {1}/#@{2}/resource{3}" -f "$($job.Role) job", $portal, $Context.TenantId, $job.Id)
    }
}

function Show-Inventory($Context) {
    $serviceNames = @{
        'microsoft.app/jobs'                                    = 'Container Apps job'
        'microsoft.app/managedenvironments'                     = 'Container Apps environment'
        'microsoft.containerregistry/registries'                = 'Container registry'
        'microsoft.containerregistry/registries/replications'   = 'Registry geo-replica'
        'microsoft.insights/actiongroups'                       = 'Action group'
        'microsoft.insights/metricalerts'                       = 'Alert rule (metric)'
        'microsoft.insights/scheduledqueryrules'                = 'Alert rule (log search)'
        'microsoft.managedidentity/userassignedidentities'      = 'Managed identity'
        'microsoft.network/networkinterfaces'                   = 'Network interface'
        'microsoft.network/privatednszones'                     = 'Private DNS zone'
        'microsoft.network/privatednszones/virtualnetworklinks' = 'Private DNS zone link'
        'microsoft.network/privateendpoints'                    = 'Private endpoint'
        'microsoft.network/virtualnetworks'                     = 'Virtual network'
        'microsoft.operationalinsights/workspaces'              = 'Log Analytics workspace'
        'microsoft.storage/storageaccounts'                     = 'Storage account'
    }
    function Get-ServiceName([string]$Type) {
        $key = ConvertTo-Key $Type
        if ($serviceNames.ContainsKey($key)) {
            return $serviceNames[$key]
        }
        return $Type
    }

    $tagged = @(Invoke-Az -Arguments @('resource', 'list', '--tag', "Workload=$WorkloadTag") | Where-Object { $_ })
    $taggedIds = @($tagged | ForEach-Object { ConvertTo-Key (Get-Value $_ 'id') })

    Write-Section "Resources deployed by this solution (tag Workload=$WorkloadTag)"
    $rows = @($tagged | ForEach-Object {
            [pscustomobject]@{
                Service       = Get-ServiceName (Get-Value $_ 'type')
                Name          = [string](Get-Value $_ 'name')
                ResourceGroup = [string](Get-Value $_ 'resourceGroup')
                Location      = [string](Get-Value $_ 'location')
            }
        } | Sort-Object Service, ResourceGroup, Name)
    Write-Table $rows @('Service', 'Name', 'ResourceGroup', 'Location')
    if ($rows.Count -gt 0) {
        $counts = @($rows | Group-Object Service | Sort-Object Name | ForEach-Object { '{0} x{1}' -f $_.Name, $_.Count }) -join '; '
        Write-Host "  $($rows.Count) resources: $counts"
    }

    # The existing-resource profile uses storage, networks, and a registry that it doesn't deploy or tag.
    $referenced = [System.Collections.Generic.List[object]]::new()
    $urls = Get-ReplicationUrls $Context
    foreach ($entry in @([pscustomobject]@{ Url = $urls.Source; Role = $urls.SourceRole }, [pscustomobject]@{ Url = $urls.Replica; Role = $urls.ReplicaRole })) {
        if (-not $entry.Url) {
            continue
        }
        $uri = [Uri]$entry.Url
        $referenced.Add([pscustomobject]@{ Id = $null; Type = 'Microsoft.Storage/storageAccounts'; Name = $uri.Host.Split('.')[0]; UsedFor = "$($entry.Role) file share '$($uri.AbsolutePath.Trim('/'))'" })
    }
    foreach ($registryName in @($Context.Jobs | ForEach-Object Registry | Where-Object { $_ } | ForEach-Object { $_.Split('.')[0] } | Select-Object -Unique)) {
        $referenced.Add([pscustomobject]@{ Id = $null; Type = 'Microsoft.ContainerRegistry/registries'; Name = $registryName; UsedFor = 'AzCopy job image' })
    }
    foreach ($job in $Context.Jobs) {
        if ($job.SubnetId -match '^(?<vnet>.+/virtualNetworks/(?<name>[^/]+))/subnets/(?<subnet>[^/]+)$') {
            $referenced.Add([pscustomobject]@{ Id = $Matches['vnet']; Type = 'Microsoft.Network/virtualNetworks'; Name = $Matches['name']; UsedFor = "$($job.Role) job subnet '$($Matches['subnet'])'" })
        }
    }

    $referencedRows = foreach ($item in $referenced) {
        $found = if ($item.Id) {
            (Invoke-Az -AllowFailure -Arguments @('resource', 'show', '--ids', $item.Id)).Value
        } else {
            @((Invoke-Az -AllowFailure -Arguments @('resource', 'list', '--name', $item.Name, '--resource-type', $item.Type)).Value | Where-Object { $_ }) | Select-Object -First 1
        }
        $foundId = ConvertTo-Key (Get-Value $found 'id')
        if ($foundId -and $taggedIds -contains $foundId) {
            continue
        }
        [pscustomobject]@{
            Service       = Get-ServiceName $item.Type
            Name          = $item.Name
            ResourceGroup = if ($found) { [string](Get-Value $found 'resourceGroup') } else { 'not found in this subscription' }
            Location      = [string](Get-Value $found 'location')
            UsedFor       = $item.UsedFor
        }
    }
    Write-Section 'Existing resources the replication jobs use'
    Write-Table $referencedRows @('Service', 'Name', 'ResourceGroup', 'Location', 'UsedFor') -Empty '(none; the jobs use only resources that this solution deployed)'

    if (-not $ParametersFile) {
        Write-Host ''
        Write-Host 'For prerequisite checks and a what-if drift report, rerun with -ParametersFile <the deployment parameter file>.'
        return
    }

    # What-if needs the values that the deployment scripts passed as overrides, or it reports them as changes.
    $overrides = [System.Collections.Generic.List[string]]::new()
    if ($Context.Active) {
        $overrides.Add("activeRegion=$($Context.Active.Role)")
    } elseif (@($Context.Jobs | Where-Object TriggerType -eq 'Schedule').Count -eq 0) {
        $overrides.Add('activeRegion=none')
    }
    $images = @($Context.Jobs | ForEach-Object Image | Select-Object -Unique)
    if ($images.Count -eq 1 -and $images[0] -match '@sha256:[0-9a-fA-F]{64}$') {
        $overrides.Add("containerImage=$($images[0])")
    }
    foreach ($registryName in @($Context.Jobs | ForEach-Object Registry | Where-Object { $_ } | ForEach-Object { $_.Split('.')[0] } | Select-Object -Unique)) {
        $publicAccess = [string](Get-Value (Invoke-Az -AllowFailure -Arguments @('acr', 'show', '--name', $registryName)).Value 'publicNetworkAccess')
        if ($publicAccess) {
            $overrides.Add("acrPublicNetworkAccess=$publicAccess")
        }
    }
    Write-Section 'Prerequisites and what-if drift report'
    Write-Host "Using the deployed values as parameter overrides: $($overrides -join ', ')"
    $WhatIfPreference = $false
    & (Join-Path $PSScriptRoot 'inventory.ps1') -ParametersFile $ParametersFile -ParameterOverrides $overrides.ToArray()
}

function Invoke-Seed($Context) {
    $job = Get-ActiveJob $Context 'there is no authoritative source share to write to'
    $target = $job.Environment['SOURCE_FILE_URL']
    $fileName = 'demo-' + [DateTime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'") + '.txt'
    if (-not (Confirm-Action "$target/$DemoFolder" 'Write a demo file' "This writes $DemoFolder/$fileName to the $($job.Role) source share $target.")) {
        return
    }
    Write-Step "Writing $DemoFolder/$fileName from inside $($job.Name), using the job's managed identity and network."
    $result = Invoke-HelperExecution -Job $job -Environment @{ DEMO_FOLDER = $DemoFolder; DEMO_FILE_NAME = $fileName; DEMO_TARGET_URL = $target } -Script $SeedScript -UntilPattern '^REPLICATION_DEMO_SEED_COMPLETED'
    if (-not $result.Waited) {
        return
    }
    foreach ($line in @($result.Lines | Where-Object { $_.Line -match '^REPLICATION_DEMO_SEED_ERROR ' })) {
        Write-Host ('  ' + ($line.Line -replace '^REPLICATION_DEMO_SEED_ERROR ', '')) -ForegroundColor Yellow
    }
    $done = @($result.Lines | Where-Object { $_.Line -match '^REPLICATION_DEMO_SEED_COMPLETED' }) | Select-Object -Last 1
    if ($done -and $done.Line -match 'exitCode=(\d+)') {
        if ($Matches[1] -eq '0') {
            Write-Step "Wrote $DemoFolder/$fileName to the $($job.Role) share." Green
            Write-Host "  The next scheduled run copies it ('$($job.Cron)'). To copy it now: ./scripts/demo.ps1 replicate"
        } else {
            Write-Step "AzCopy could not write the file (exit code $($Matches[1])). The errors above show why." Red
        }
    }
}

function Show-ReplicationResult($Lines) {
    $marker = @($Lines | Where-Object { $_.Line -match 'AZURE_FILES_REPLICATION_(SUCCEEDED|FAILED)' }) | Select-Object -Last 1
    if (-not $marker) {
        return
    }
    $succeeded = $marker.Line -match 'AZURE_FILES_REPLICATION_SUCCEEDED'
    Write-Step $marker.Line.Trim() $(if ($succeeded) { 'Green' } else { 'Red' })
    if (-not $succeeded) {
        foreach ($message in @(Get-AzCopyError $Lines) | Select-Object -Last 1) {
            Write-Host "  AzCopy error: $message" -ForegroundColor Yellow
        }
        return
    }

    # In JSON output mode, AzCopy prints the job summary as the EndOfJob message.
    $summaryLine = @($Lines | Where-Object { $_.Line -match '"MessageType":"EndOfJob"' }) | Select-Object -Last 1
    if (-not $summaryLine) {
        Write-Host '  AzCopy printed no transfer summary, which happens when the shares are already in sync.'
        return
    }
    try {
        $summary = [string](Get-Value ($summaryLine.Line | ConvertFrom-Json -Depth 20) 'MessageContent') | ConvertFrom-Json -Depth 20
        Write-Host ('  AzCopy summary: {0} transfers completed, {1} failed, {2} skipped; {3} copied; job status {4}.' -f (Get-Value $summary 'TransfersCompleted'), (Get-Value $summary 'TransfersFailed'), (Get-Value $summary 'TransfersSkipped'), (Format-Bytes (Get-Value $summary 'TotalBytesTransferred')), (Get-Value $summary 'JobStatus'))
    } catch {
        Write-Verbose "Couldn't parse the AzCopy summary: $_"
    }
}

function Invoke-Replicate($Context) {
    $job = Get-ActiveJob $Context 'there is no replication direction to run'
    if ($job.PausedCron -and -not $Force) {
        throw "Scheduled replication is paused for the stale-replication scenario, and a successful run resets the freshness clock. Run './scripts/demo.ps1 resume' first, or pass -Force."
    }

    $since = [DateTime]::UtcNow
    $running = @(Get-Executions $job | Where-Object { $_.Status -in 'Running', 'Processing' -and $_.Kind -in 'Replication', 'Unknown' })
    if ($running.Count -gt 0) {
        $executionName = $running[0].Name
        if ($running[0].Started) {
            $since = $running[0].Started
        }
        Write-Step "Replication run $executionName is already in progress; following it instead of starting a second run into the same destination."
    } else {
        if (-not (Confirm-Action $job.Name 'Start a replication run')) {
            return
        }
        $executionName = Start-Execution -Job $job
        $standbyRole = if ($Context.Standby) { $Context.Standby.Role } else { 'replica' }
        Write-Step "Started replication run $executionName on $($job.Name) ($($job.Role) -> $standbyRole)."
    }
    if ($NoWait) {
        Write-Step "Not waiting. Follow it in the portal: job $($job.Name) > Execution history."
        return
    }
    $execution = Wait-Execution -Job $job -ExecutionName $executionName
    $start = ConvertTo-UtcDate (Get-Value $execution 'properties.startTime')
    $end = ConvertTo-UtcDate (Get-Value $execution 'properties.endTime')
    if ($start -and $end) {
        Write-Step "Execution finished as $(Get-Value $execution 'properties.status') after $(Format-Span ($end - $start))."
    }
    Show-ReplicationResult @(Get-ExecutionLog -Job $job -ExecutionName $executionName -Since $since -UntilPattern 'AZURE_FILES_REPLICATION_(SUCCEEDED|FAILED)')
}

function Invoke-Files($Context) {
    $runner = if ($Context.Standby) { $Context.Standby } else { @($Context.Jobs)[0] }
    $urls = Get-ReplicationUrls $Context
    if (-not (Confirm-Action $runner.Name 'Start a read-only listing')) {
        return
    }
    Write-Step "Listing '$DemoFolder' in both shares from inside $($runner.Name), using the job's managed identity and network. Nothing is written."
    $result = Invoke-HelperExecution -Job $runner -Environment @{ DEMO_FOLDER = $DemoFolder; DEMO_SOURCE_URL = $urls.Source; DEMO_REPLICA_URL = $urls.Replica } -Script $ListScript -UntilPattern '^REPLICATION_DEMO_LIST_END side=replica'
    if (-not $result.Waited) {
        return
    }

    $sides = [ordered]@{
        source  = [pscustomobject]@{ Title = "Source share ($($urls.SourceRole)): $($urls.Source)/$DemoFolder"; Files = @{}; ExitCode = $null; Errors = @() }
        replica = [pscustomobject]@{ Title = "Replica share ($($urls.ReplicaRole)): $($urls.Replica)/$DemoFolder"; Files = @{}; ExitCode = $null; Errors = @() }
    }
    foreach ($line in @($result.Lines | ForEach-Object Line)) {
        if ($line -match '^REPLICATION_DEMO_LIST_ITEM side=(source|replica) (\{.*\})\s*$') {
            $side = $sides[$Matches[1]]
            try {
                $message = $Matches[2] | ConvertFrom-Json -Depth 20
                if ((Get-Value $message 'MessageType') -eq 'ListObject') {
                    $item = [string](Get-Value $message 'MessageContent') | ConvertFrom-Json -Depth 20
                    $side.Files[[string](Get-Value $item 'Path')] = $item
                }
            } catch {
                Write-Verbose "Skipped a listing line that could not be parsed: $line"
            }
        } elseif ($line -match '^REPLICATION_DEMO_LIST_END side=(source|replica) exitCode=(\d+)') {
            $sides[$Matches[1]].ExitCode = [int]$Matches[2]
        } elseif ($line -match '^REPLICATION_DEMO_LIST_ERROR side=(source|replica) (.*)$') {
            $sideName = $Matches[1]
            $message = ConvertTo-AzCopyMessage $Matches[2]
            $sides[$sideName].Errors += $message
        }
    }

    foreach ($side in $sides.Values) {
        Write-Section $side.Title
        if ($side.ExitCode -and $side.Files.Count -eq 0) {
            if (($side.Errors -join ' ') -match 'NotFound|does not exist') {
                Write-Host '  The folder does not exist in this share yet.' -ForegroundColor Yellow
            } else {
                Write-Host "  AzCopy could not list the folder (exit code $($side.ExitCode)):" -ForegroundColor Yellow
            }
            $side.Errors | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
            continue
        }
        $fileRows = @($side.Files.Keys | Sort-Object | ForEach-Object {
                $file = $side.Files[$_]
                [pscustomobject]@{ Path = $_; Size = Format-Bytes (Get-Value $file 'ContentLength'); LastModified = Format-Utc (Get-Value $file 'LastModifiedTime') }
            })
        Write-Table $fileRows @('Path', 'Size', 'LastModified')
    }

    $sourceFiles = @($sides['source'].Files.Keys | Sort-Object)
    $missing = @($sourceFiles | Where-Object { -not $sides['replica'].Files.ContainsKey($_) })
    Write-Host ''
    if ($sourceFiles.Count -eq 0) {
        Write-Host "The source share has no files in '$DemoFolder'. Write one with: ./scripts/demo.ps1 seed"
    } elseif ($missing.Count -eq 0) {
        Write-Step "All $($sourceFiles.Count) source file(s) are in the replica share." Green
    } else {
        Write-Step "$($missing.Count) of $($sourceFiles.Count) source file(s) are not in the replica yet: $($missing -join ', '). To replicate now: ./scripts/demo.ps1 replicate" Yellow
    }
}

function Invoke-StandbyCheck($Context) {
    if (-not $Context.Standby) {
        throw 'There is no standby job because no job has a schedule.'
    }
    $job = $Context.Standby
    if (-not (Confirm-Action $job.Name 'Start a read-only dry run')) {
        return
    }
    Write-Step "Dry run of the reverse direction ($($job.Role) -> $($Context.Active.Role)) from inside $($job.Name). The command override runs azcopy sync --dry-run, so nothing is written."
    $result = Invoke-HelperExecution -Job $job -Environment @{} -Script $DryRunScript -UntilPattern '^REPLICATION_DEMO_DRY_RUN_COMPLETED'
    if (-not $result.Waited) {
        return
    }
    foreach ($line in @($result.Lines | Where-Object { $_.Line -match '^REPLICATION_DEMO_DRY_RUN_ERROR ' })) {
        Write-Host ('  ' + ($line.Line -replace '^REPLICATION_DEMO_DRY_RUN_ERROR ', '')) -ForegroundColor Yellow
    }
    $done = @($result.Lines | Where-Object { $_.Line -match '^REPLICATION_DEMO_DRY_RUN_COMPLETED' }) | Select-Object -Last 1
    if ($done -and $done.Line -match 'wouldCopy=(\d+) wouldRemove=(\d+) wouldSetProperties=(\d+) exitCode=(\d+)') {
        if ($Matches[4] -eq '0') {
            Write-Step ("The standby job is ready: its image, identity, and network path reached both shares. A reverse run would copy {0} file(s), remove {1}, and update properties on {2}." -f $Matches[1], $Matches[2], $Matches[3]) Green
            Write-Host '  Replicated files are newer than their source copies, so a reverse run recopies most files. Plan for a full-share copy after a direction switch.'
        } else {
            Write-Step "The standby dry run failed with AzCopy exit code $($Matches[4]). The errors above show why." Red
        }
    }
}

function Invoke-FailRun($Context) {
    $job = Get-ActiveJob $Context 'there is no active replication run to fail'
    $source = [Uri]$job.Environment['SOURCE_FILE_URL']
    $missingShare = '{0}://{1}/{2}{3}' -f $source.Scheme, $source.Host, $MissingSharePrefix, [guid]::NewGuid().ToString('N').Substring(0, 8)
    $warning = "This starts one execution of $($job.Name) that fails on purpose: its source points at a share that does not exist. Nothing is copied or deleted, and scheduled runs continue. The failure raises a Sev1 alert that emails the action group."
    $firing = @(Get-AlertInstances -SubscriptionId $Context.SubscriptionId -Range '1d' | Where-Object { $_.Rule -match "^alert-replication-failed-$($job.Role)-" -and $_.Condition -eq 'Fired' }) | Select-Object -First 1
    if ($firing) {
        Write-Step "The failed-run alert has been firing since $(Format-Utc $firing.Started). Until it resolves, about 10 minutes after the last failure, a new failure raises no new alert or email." Yellow
    }
    if (-not (Confirm-Action $job.Name 'Simulate a failed replication run' $warning)) {
        return
    }
    $since = [DateTime]::UtcNow
    # DELETE_DESTINATION=false guarantees that a failed source can never remove replica files.
    $executionName = Start-Execution -Job $job -Environment @{ SOURCE_FILE_URL = $missingShare; DELETE_DESTINATION = 'false' }
    Write-Step "Started execution $executionName with SOURCE_FILE_URL pointed at a missing share."
    if ($NoWait) {
        Write-Step 'Not waiting. The execution fails after its retries (2-3 minutes), and the alert fires a few minutes later.'
        return
    }
    Write-Step 'The job retries the replica twice before the execution fails (2-3 minutes).'
    $execution = Wait-Execution -Job $job -ExecutionName $executionName
    $status = [string](Get-Value $execution 'properties.status')
    $lines = @(Get-ExecutionLog -Job $job -ExecutionName $executionName -Since $since -UntilPattern 'AZURE_FILES_REPLICATION_FAILED')
    foreach ($message in @(Get-AzCopyError $lines) | Select-Object -Last 1) {
        Write-Host "  AzCopy error: $message" -ForegroundColor Yellow
    }
    foreach ($marker in @($lines | Where-Object { $_.Line -match 'AZURE_FILES_REPLICATION_FAILED' }) | Select-Object -Last 1) {
        Write-Host "  $($marker.Line.Trim())" -ForegroundColor Yellow
    }
    if ($status -ne 'Failed') {
        Write-Step "The execution ended as $status, not Failed, so no failure alert is expected." Yellow
        return
    }
    Wait-ForAlert -Context $Context -RulePattern "^alert-replication-failed-$($job.Role)-" -Since $since -AlreadyFiring $firing
    Write-Host '  The alert resolves on its own after three consecutive one-minute checks find no failures, about 10 minutes after the failed run.'
}

function Get-PausedCron {
    # Cron can't express "never", so the paused schedule runs once a year, about six months from now.
    $target = [DateTime]::UtcNow.AddMonths(6)
    return '0 0 {0} {1} *' -f [Math]::Min($target.Day, 28), $target.Month
}

function Invoke-Pause($Context) {
    $job = Get-ActiveJob $Context 'there is no schedule to pause'
    if ($job.PausedCron) {
        Write-Step "Scheduled replication on $($job.Name) is already paused. The original schedule is '$($job.PausedCron)'."
        return
    }
    $pausedCron = Get-PausedCron
    $warning = "This changes the schedule of $($job.Name) from '$($job.Cron)' to '$pausedCron', so replication stops without failing and the replica falls behind. The freshness alert stays enabled and emails the action group when it fires. Run './scripts/demo.ps1 resume' afterward."
    if (-not (Confirm-Action $job.Name 'Pause scheduled replication' $warning)) {
        return
    }

    # Record the original schedule first, so a paused job always carries what resume needs.
    Invoke-Az -Arguments @('tag', 'update', '--resource-id', $job.Id, '--operation', 'Merge', '--tags', "$PauseTagName=$($job.Cron)") | Out-Null
    try {
        Invoke-Az -Arguments @('containerapp', 'job', 'update', '--name', $job.Name, '--resource-group', $ResourceGroupName, '--cron-expression', $pausedCron) | Out-Null
    } catch {
        Invoke-Az -AllowFailure -Arguments @('tag', 'update', '--resource-id', $job.Id, '--operation', 'Delete', '--tags', "$PauseTagName=$($job.Cron)") | Out-Null
        throw
    }
    Write-Step "Paused scheduled replication on $($job.Name). Its $PauseTagName tag records the original schedule." Green

    $success = @(Get-ReplicationMarkers $job | Where-Object Marker -eq 'AZURE_FILES_REPLICATION_SUCCEEDED') | Select-Object -First 1
    if ($job.ThresholdMinutes) {
        $base = if ($success) { $success.Time } else { [DateTime]::UtcNow }
        $basis = if ($success) { "the last successful run at $(Format-Utc $success.Time)" } else { 'now' }
        $earliest = $base.AddMinutes($job.ThresholdMinutes)
        Write-Host ("  Based on {0} and a {1}-minute threshold, the stale-replication alert should fire between {2} and {3}." -f $basis, $job.ThresholdMinutes, (Format-Utc $earliest), (Format-Utc $earliest.AddMinutes(15)))
        Write-Host '  The rule evaluates every 10 minutes; log ingestion and alert processing add a few minutes.'
    }
    Write-Host '  A run that is already in progress still finishes and resets the clock. Check with: ./scripts/demo.ps1 status'
}

function Invoke-Resume($Context) {
    $paused = @($Context.Jobs | Where-Object PausedCron)
    if ($paused.Count -eq 0) {
        if (-not ($CronExpression -and $Context.Active)) {
            Write-Step 'No job is paused by this script. To set a specific schedule on the active job, pass -CronExpression.'
            return
        }
        $paused = @($Context.Active)
    }
    foreach ($job in $paused) {
        $cron = if ($CronExpression) { $CronExpression } else { $job.PausedCron }
        if (-not (Confirm-Action $job.Name "Restore schedule '$cron'")) {
            continue
        }
        if ($job.TriggerType -eq 'Schedule') {
            Invoke-Az -Arguments @('containerapp', 'job', 'update', '--name', $job.Name, '--resource-group', $ResourceGroupName, '--cron-expression', $cron) | Out-Null
            Write-Step "Restored schedule '$cron' on $($job.Name)." Green
        } else {
            Write-Step "$($job.Name) no longer has a schedule, so only its $PauseTagName tag is removed." Yellow
        }
        if ($job.PausedCron) {
            Invoke-Az -Arguments @('tag', 'update', '--resource-id', $job.Id, '--operation', 'Delete', '--tags', "$PauseTagName=$($job.PausedCron)") | Out-Null
        }
    }
    Write-Host '  Replication resumes at the next schedule boundary. To run now: ./scripts/demo.ps1 replicate'
    Write-Host '  A fired stale-replication alert resolves about 30 minutes after the next successful run (three evaluations without the condition).'
}

function Show-Alerts($Context) {
    Write-Section 'Alert rules'
    $ruleRows = @()
    foreach ($rule in $Context.MetricRules) {
        $name = [string](Get-Value $rule 'name')
        if ($name -notmatch '^alert-replication-') {
            continue
        }
        $ruleRows += [pscustomobject]@{
            Rule       = $name
            Signal     = 'Failed job execution (metric)'
            Severity   = "Sev$(Get-Value $rule 'severity')"
            Enabled    = [bool](Get-Value $rule 'enabled')
            Evaluation = 'every {0} over {1}' -f (Format-Minutes (Get-Value $rule 'evaluationFrequency')), (Format-Minutes (Get-Value $rule 'windowSize'))
        }
    }
    foreach ($rule in $Context.QueryRules) {
        $name = [string](Get-Value $rule 'name')
        if ($name -notmatch '^alert-replication-') {
            continue
        }
        $ruleRows += [pscustomobject]@{
            Rule       = $name
            Signal     = 'No successful replication (log search)'
            Severity   = "Sev$(Get-Value $rule 'properties.severity')"
            Enabled    = [bool](Get-Value $rule 'properties.enabled')
            Evaluation = 'every {0} over {1}' -f (Format-Minutes (Get-Value $rule 'properties.evaluationFrequency')), (Format-Minutes (Get-Value $rule 'properties.windowSize'))
        }
    }
    Write-Table ($ruleRows | Sort-Object Rule) @('Rule', 'Signal', 'Severity', 'Enabled', 'Evaluation')
    Write-Host '  Only the active direction has its freshness rule enabled; both failure rules are always enabled.'

    Write-Section 'Notifications'
    $groups = @(Invoke-Az -Arguments @('monitor', 'action-group', 'list', '--resource-group', $ResourceGroupName) | Where-Object { $_ -and [string](Get-Value $_ 'name') -match '^ag-replication-' })
    foreach ($group in $groups) {
        $receivers = @(Get-Value $group 'emailReceivers' | ForEach-Object {
                $address = [string](Get-Value $_ 'emailAddress')
                if ($address -match '^(.{1,2})[^@]*(@.+)$') { "$($Matches[1])***$($Matches[2])" } else { '***' }
            })
        Write-Host ("  Action group {0}: enabled={1}; email: {2}" -f (Get-Value $group 'name'), [bool](Get-Value $group 'enabled'), ($receivers -join ', '))
    }
    if ($groups.Count -eq 0) {
        Write-Host '  (no replication action group found)'
    }

    Write-Section "Alerts in the last $TimeRange"
    $alertRows = @(Get-AlertInstances -SubscriptionId $Context.SubscriptionId -Range $TimeRange | Sort-Object Started -Descending | ForEach-Object {
            [pscustomobject]@{ Rule = $_.Rule; Severity = $_.Severity; Condition = $_.Condition; State = $_.State; Fired = Format-Utc $_.Started; Resolved = Format-Utc $_.Resolved }
        })
    Write-Table $alertRows @('Rule', 'Severity', 'Condition', 'State', 'Fired', 'Resolved')
}

function Invoke-Cleanup($Context) {
    $runner = if ($Context.Standby) { $Context.Standby } else { @($Context.Jobs)[0] }
    $urls = Get-ReplicationUrls $Context
    $warning = "This deletes the '$DemoFolder' folder and its files from both shares: $($urls.Source) and $($urls.Replica)."
    if (-not (Confirm-Action "$DemoFolder in both shares" 'Delete the demo folder' $warning)) {
        return
    }
    $result = Invoke-HelperExecution -Job $runner -Environment @{ DEMO_FOLDER = $DemoFolder; DEMO_SOURCE_URL = $urls.Source; DEMO_REPLICA_URL = $urls.Replica } -Script $CleanupScript -UntilPattern '^REPLICATION_DEMO_CLEANUP_COMPLETED side=replica'
    if (-not $result.Waited) {
        return
    }
    foreach ($line in @($result.Lines | ForEach-Object Line)) {
        if ($line -match '^REPLICATION_DEMO_CLEANUP_COMPLETED side=(source|replica) exitCode=(\d+)') {
            if ($Matches[2] -eq '0') {
                Write-Step "Removed '$DemoFolder' from the $($Matches[1]) share." Green
            } else {
                Write-Step "Nothing was removed from the $($Matches[1]) share (AzCopy exit code $($Matches[2])); the folder may not exist." Yellow
            }
        } elseif ($line -match '^REPLICATION_DEMO_CLEANUP_ERROR side=\w+ (.*)$') {
            Write-Host "  $($Matches[1])" -ForegroundColor DarkGray
        }
    }
}

#endregion

$context = Get-DemoContext
switch ($Command) {
    'status' { Show-Status $context }
    'inventory' { Show-Inventory $context }
    'seed' { Invoke-Seed $context }
    'replicate' { Invoke-Replicate $context }
    'files' { Invoke-Files $context }
    'standby-check' { Invoke-StandbyCheck $context }
    'fail-run' { Invoke-FailRun $context }
    'pause' { Invoke-Pause $context }
    'resume' { Invoke-Resume $context }
    'alerts' { Show-Alerts $context }
    'cleanup' { Invoke-Cleanup $context }
}
