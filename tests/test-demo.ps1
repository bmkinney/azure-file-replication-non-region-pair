$ErrorActionPreference = 'Stop'

# Runs scripts/demo.ps1 against a simulated deployment. A fake Azure CLI runs the real replication wrapper and the
# demo helper scripts under sh, with a stub AzCopy that keeps share contents in files. No Azure calls are made.

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$wrapperPath = Join-Path $repositoryRoot 'src/azcopy-job/run-sync.sh'

$shellPath = (Get-Command sh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $shellPath -and $IsWindows -and (Test-Path (Join-Path $env:ProgramFiles 'Git\bin\sh.exe'))) {
    $shellPath = Join-Path $env:ProgramFiles 'Git\bin\sh.exe'
}
if (-not $shellPath) {
    Write-Host 'Demo script checks were skipped because sh is not available.'
    return
}

function ConvertTo-ShellPath([string]$Path) {
    return $Path -replace '\\', '/'
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "demo check failed: $Message"
    }
}

$workRoot = Join-Path ([IO.Path]::GetTempPath()) "demo-test-$([guid]::NewGuid().ToString('N'))"
$stubBin = Join-Path $workRoot 'bin'
$stateDirectory = Join-Path $workRoot 'state'
$scriptsDirectory = Join-Path $workRoot 'scripts'
New-Item -ItemType Directory -Path $stubBin, $stateDirectory, $scriptsDirectory -Force | Out-Null

# The demo runs from a copy so that a stand-in inventory.ps1 can record what the inventory command passes to it.
Copy-Item -LiteralPath (Join-Path $repositoryRoot 'scripts/demo.ps1') -Destination $scriptsDirectory
$demoScript = Join-Path $scriptsDirectory 'demo.ps1'
@'
param([string]$ParametersFile, [string[]]$ParameterOverrides)
$global:FakeInventoryInvocation = [pscustomobject]@{ ParametersFile = $ParametersFile; ParameterOverrides = @($ParameterOverrides) }
Write-Host 'Stand-in inventory report'
'@ | Set-Content -LiteralPath (Join-Path $scriptsDirectory 'inventory.ps1') -Encoding utf8

$stub = @'
#!/bin/sh
# Simulates the AzCopy commands that the wrapper and the demo helpers use. Share contents live in $STUB_STATE.
set -u
state="$STUB_STATE"
printf '%s %s\n' "${STUB_CALLER:-unknown}" "$*" >> "$state/azcopy-calls.txt"

tick() {
    n="$(cat "$state/clock" 2>/dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" > "$state/clock"
    printf '2026-01-01T00:%02d:%02dZ' $((n / 60 % 60)) $((n % 60))
}

json() {
    content="$(printf '%s' "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    printf '{"TimeStamp":"2026-01-01T00:00:00Z","MessageType":"%s","MessageContent":"%s","PromptDetails":{"PromptType":"","ResponseOptions":null,"PromptTarget":""}}\n' "$1" "$content"
}

locate() {
    rest="${1#https://}"
    account="${rest%%.*}"
    rest="${rest#*/}"
    share="${rest%%/*}"
    case "$rest" in
        */*) prefix="${rest#*/}" ;;
        *) prefix="" ;;
    esac
    file="$state/$account.$share.files"
    touch "$file"
}

remove_entry() {
    grep -v "^$2|" "$1" > "$1.tmp" || true
    mv "$1.tmp" "$1"
}

command="$1"
shift
case "$command" in
    copy)
        source_directory="$1"
        locate "$2"
        folder="$(basename "$source_directory")"
        for path in "$source_directory"/*; do
            name="$(basename "$path")"
            size="$(wc -c < "$path" | tr -d ' ')"
            remove_entry "$file" "$folder/$name"
            printf '%s|%s|%s\n' "$folder/$name" "$(tick)" "$size" >> "$file"
        done
        echo 'Final Job Status: Completed'
        ;;
    list)
        locate "$1"
        if ! grep -q "^$prefix/" "$file"; then
            json Error "failed to traverse container: ResourceNotFound The specified parent path does not exist. $1"
            exit 1
        fi
        count=0
        while IFS='|' read -r path time size; do
            case "$path" in
                "$prefix"/*) ;;
                *) continue ;;
            esac
            count=$((count + 1))
            json ListObject '{"Path":"'"${path#"$prefix"/}"'","LastModifiedTime":"'"$time"'","ContentLength":"'"$size"'"}'
        done < "$file"
        json ListSummary '{"FileCount":"'"$count"'","TotalFileSize":"0"}'
        ;;
    sync)
        source_url="$1"
        destination_url="$2"
        dry_run=false
        for argument in "$@"; do
            if [ "$argument" = '--dry-run' ]; then dry_run=true; fi
        done
        locate "$source_url"
        case "$share" in
            replication-demo-missing-*)
                json Error "Cannot perform sync due to error: RESPONSE 404: The specified share does not exist. ERROR CODE: ShareNotFound $source_url"
                exit 1
                ;;
        esac
        source_file="$file"
        locate "$destination_url"
        destination_file="$file"
        copied=0
        bytes=0
        while IFS='|' read -r path time size; do
            [ -n "$path" ] || continue
            destination_time="$(grep "^$path|" "$destination_file" | cut -d '|' -f 2)"
            if [ -z "$destination_time" ] || expr "$time" \> "$destination_time" > /dev/null; then
                copied=$((copied + 1))
                if [ "$dry_run" = true ]; then
                    echo "DRYRUN: copy $source_url/$path to $destination_url/$path"
                else
                    remove_entry "$destination_file" "$path"
                    printf '%s|%s|%s\n' "$path" "$(tick)" "$size" >> "$destination_file"
                    bytes=$((bytes + size))
                fi
            fi
        done < "$source_file"
        if [ "$dry_run" = false ] && [ "$copied" -gt 0 ]; then
            json EndOfJob '{"TotalTransfers":"'"$copied"'","TransfersCompleted":"'"$copied"'","TransfersFailed":"0","TransfersSkipped":"0","TotalBytesTransferred":"'"$bytes"'","DeleteTotalTransfers":"0","JobStatus":"Completed"}'
        fi
        ;;
    remove)
        locate "$1"
        if ! grep -q "^$prefix/" "$file"; then
            echo 'failed to remove: ResourceNotFound'
            exit 1
        fi
        grep -v "^$prefix/" "$file" > "$file.tmp" || true
        mv "$file.tmp" "$file"
        echo 'Final Job Status: Completed'
        ;;
    *)
        echo "stub azcopy does not support: $command" >&2
        exit 2
        ;;
esac
exit 0
'@
$stubPath = Join-Path $stubBin 'azcopy'
[IO.File]::WriteAllText($stubPath, ($stub -replace "`r`n", "`n"))
$runnerPath = Join-Path $workRoot 'run-container.sh'
[IO.File]::WriteAllText($runnerPath, "sh `"`$1`" > `"`$STUB_OUTPUT_FILE`" 2>&1`n")
if (-not $IsWindows) {
    & chmod +x $stubPath
}

function Get-ShareEntries([string]$Account) {
    $path = Join-Path $global:FakePaths.State "$Account.share.files"
    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }
    return @([IO.File]::ReadAllLines($path) | Where-Object { $_ })
}

# Runs one container the way a job execution would: the image entrypoint (the wrapper) or a /bin/sh -c override.
# The fake Azure CLI runs inside demo.ps1's scope chain, so it reads test state only through $global: variables.
function Invoke-FakeContainer([string]$ExecutionName, [hashtable]$Environment, [string[]]$Command, [string[]]$Arguments) {
    $paths = $global:FakePaths
    if ($Command.Count -gt 0) {
        Assert-True ($Command.Count -eq 2 -and $Command[0] -eq '/bin/sh' -and $Command[1] -eq '-c' -and $Arguments.Count -eq 1) "unexpected command override: $($Command -join ' ')"
        $target = Join-Path $paths.WorkRoot "$ExecutionName.sh"
        [IO.File]::WriteAllText($target, $Arguments[0])
    } else {
        $target = $paths.Wrapper
    }
    $outputPath = Join-Path $paths.WorkRoot "$ExecutionName.out"
    $variables = @{} + $Environment
    $variables['PATH'] = "$($paths.StubBin)$([IO.Path]::PathSeparator)$env:PATH"
    $variables['STUB_STATE'] = ConvertTo-ShellPath $paths.State
    $variables['STUB_CALLER'] = $ExecutionName
    $variables['STUB_OUTPUT_FILE'] = ConvertTo-ShellPath $outputPath
    $previous = @{}
    foreach ($name in @($variables.Keys)) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $variables[$name])
    }
    try {
        & $paths.Shell (ConvertTo-ShellPath $paths.Runner) (ConvertTo-ShellPath $target)
        $exitCode = $LASTEXITCODE
    } finally {
        foreach ($name in @($variables.Keys)) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name])
        }
    }
    return [pscustomobject]@{ ExitCode = $exitCode; Lines = @([IO.File]::ReadAllLines($outputPath)) }
}

#region Fake deployment

$subscriptionId = '00000000-0000-0000-0000-000000000000'
$groupId = "/subscriptions/$subscriptionId/resourceGroups/rg-azure-files-replication-demo"
$image = "acrdemo.azurecr.io/azure-files-dr-azcopy@sha256:$('b' * 64)"
$primaryShareUrl = 'https://stprimarydemo.file.core.windows.net/share'
$secondaryShareUrl = 'https://stsecondarydemo.file.core.windows.net/share'

function New-FakeJob([string]$Role, [string]$Location, [string]$Source, [string]$Destination, [bool]$Scheduled) {
    $name = "job-sync-$Role-demo"
    $configuration = [ordered]@{
        triggerType       = if ($Scheduled) { 'Schedule' } else { 'Manual' }
        replicaRetryLimit = 2
        replicaTimeout    = 3600
        registries        = @(@{ server = 'acrdemo.azurecr.io'; identity = "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-$Role" })
    }
    if ($Scheduled) {
        $configuration['scheduleTriggerConfig'] = [ordered]@{ cronExpression = '*/10 * * * *'; parallelism = 1; replicaCompletionCount = 1 }
    } else {
        $configuration['manualTriggerConfig'] = [ordered]@{ parallelism = 1; replicaCompletionCount = 1 }
    }
    return [ordered]@{
        id         = "$groupId/providers/Microsoft.App/jobs/$name"
        name       = $name
        location   = $Location
        type       = 'Microsoft.App/jobs'
        tags       = [ordered]@{ Workload = 'azure-files-dr-replication'; Environment = 'demo' }
        properties = [ordered]@{
            environmentId = "$groupId/providers/Microsoft.App/managedEnvironments/cae-replication-$Role-demo"
            configuration = $configuration
            template      = [ordered]@{
                containers     = @([ordered]@{
                        name      = 'azcopy'
                        image     = $image
                        env       = @(
                            [ordered]@{ name = 'SOURCE_FILE_URL'; value = $Source },
                            [ordered]@{ name = 'DESTINATION_FILE_URL'; value = $Destination },
                            [ordered]@{ name = 'AZCOPY_MSI_CLIENT_ID'; value = "client-id-$Role" },
                            [ordered]@{ name = 'DELETE_DESTINATION'; value = 'false' }
                        )
                        resources = [ordered]@{ cpu = 1.0; memory = '2Gi'; ephemeralStorage = '4Gi' }
                        probes    = @()
                    })
                initContainers = $null
                volumes        = @()
            }
        }
    }
}

function New-FakeResource([string]$Id, [string]$Location) {
    $segments = $Id.Split('/')
    return [ordered]@{ id = $Id; name = $segments[-1]; type = "$($segments[6])/$($segments[7])"; resourceGroup = $segments[4]; location = $Location }
}

$global:Fake = [pscustomobject]@{
    SubscriptionId    = $subscriptionId
    TenantId          = '11111111-1111-1111-1111-111111111111'
    GroupId           = $groupId
    Workspaces        = @{ primary = 'aaaaaaaa-0000-0000-0000-000000000001'; secondary = 'aaaaaaaa-0000-0000-0000-000000000002' }
    Jobs              = [ordered]@{}
    Environments      = @{}
    MetricRules       = @()
    QueryRules        = @()
    TaggedResources   = @()
    ExistingResources = @{}
    Alerts            = [System.Collections.Generic.List[object]]::new()
    Executions        = [System.Collections.Generic.List[object]]::new()
    Logs              = [System.Collections.Generic.List[object]]::new()
    Starts            = [System.Collections.Generic.List[object]]::new()
    Calls             = [System.Collections.Generic.List[string]]::new()
    LogOrder          = 0
    LogTableMissing   = $false
    TagFailure        = $false
}
$global:FakePaths = [pscustomobject]@{ WorkRoot = $workRoot; StubBin = $stubBin; State = $stateDirectory; Wrapper = $wrapperPath; Shell = $shellPath; Runner = $runnerPath }

foreach ($job in @((New-FakeJob 'primary' 'westus2' $primaryShareUrl $secondaryShareUrl $true), (New-FakeJob 'secondary' 'northcentralus' $secondaryShareUrl $primaryShareUrl $false))) {
    $global:Fake.Jobs[$job.name] = $job
}
$vnetIds = @{
    primary   = "/subscriptions/$subscriptionId/resourceGroups/rg-network-primary/providers/Microsoft.Network/virtualNetworks/vnet-primary"
    secondary = "/subscriptions/$subscriptionId/resourceGroups/rg-network-secondary/providers/Microsoft.Network/virtualNetworks/vnet-secondary"
}
foreach ($role in 'primary', 'secondary') {
    $global:Fake.Environments["$groupId/providers/Microsoft.App/managedEnvironments/cae-replication-$role-demo"] = [ordered]@{
        properties = [ordered]@{
            appLogsConfiguration = [ordered]@{ destination = 'log-analytics'; logAnalyticsConfiguration = [ordered]@{ customerId = $global:Fake.Workspaces[$role] } }
            vnetConfiguration    = [ordered]@{ infrastructureSubnetId = "$($vnetIds[$role])/subnets/snet-jobs"; internal = $true }
        }
    }
}
$global:Fake.ExistingResources[$vnetIds.primary] = New-FakeResource $vnetIds.primary 'westus2'
$global:Fake.ExistingResources[$vnetIds.secondary] = New-FakeResource $vnetIds.secondary 'northcentralus'
$global:Fake.ExistingResources['stprimarydemo'] = New-FakeResource "/subscriptions/$subscriptionId/resourceGroups/rg-storage-primary/providers/Microsoft.Storage/storageAccounts/stprimarydemo" 'westus2'
$global:Fake.ExistingResources['stsecondarydemo'] = New-FakeResource "/subscriptions/$subscriptionId/resourceGroups/rg-storage-secondary/providers/Microsoft.Storage/storageAccounts/stsecondarydemo" 'northcentralus'
$global:Fake.ExistingResources['acrdemo'] = New-FakeResource "/subscriptions/$subscriptionId/resourceGroups/rg-registry/providers/Microsoft.ContainerRegistry/registries/acrdemo" 'westus2'

# The Azure CLI prints metric alert durations as 0:05:00; ARM returns scheduled query rule durations as PT30M.
$global:Fake.MetricRules = @(
    foreach ($role in 'primary', 'secondary') {
        [ordered]@{ name = "alert-replication-failed-$role-tok"; scopes = @("$groupId/providers/Microsoft.App/jobs/job-sync-$role-demo"); severity = 1; enabled = $true; evaluationFrequency = '0:01:00'; windowSize = '0:05:00' }
    }
    [ordered]@{ name = 'unrelated-cpu-alert'; scopes = @("$groupId/providers/Microsoft.Compute/virtualMachines/vm-other"); severity = 3; enabled = $true; evaluationFrequency = '0:05:00'; windowSize = '0:15:00' }
)
$global:Fake.QueryRules = @(
    [ordered]@{ name = 'alert-replication-stale-primary-tok'; properties = [ordered]@{ severity = 2; enabled = $true; evaluationFrequency = 'PT10M'; windowSize = 'PT30M' } },
    [ordered]@{ name = 'alert-replication-stale-secondary-tok'; properties = [ordered]@{ severity = 2; enabled = $false; evaluationFrequency = 'PT10M'; windowSize = 'PT30M' } }
)
$global:Fake.TaggedResources = @(
    foreach ($role in 'primary', 'secondary') {
        $location = if ($role -eq 'primary') { 'westus2' } else { 'northcentralus' }
        New-FakeResource "$groupId/providers/Microsoft.App/jobs/job-sync-$role-demo" $location
        New-FakeResource "$groupId/providers/Microsoft.App/managedEnvironments/cae-replication-$role-demo" $location
        New-FakeResource "$groupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-$role" $location
    }
    New-FakeResource "$groupId/providers/Microsoft.Insights/actionGroups/ag-replication-tok" 'global'
)
$global:Fake.Alerts.Add([ordered]@{ name = 'cpu high'; properties = [ordered]@{ essentials = [ordered]@{ alertRule = "$groupId/providers/Microsoft.Insights/metricAlerts/unrelated-cpu-alert"; severity = 'Sev3'; monitorCondition = 'Fired'; alertState = 'New'; startDateTime = [DateTime]::UtcNow.AddMinutes(-30).ToString('o') } } })

function Add-FakeExecution([string]$JobName, [string]$Name, [string[]]$Statuses, [datetime]$Start, [datetime]$LogTime, $Template, [string[]]$Lines) {
    $role = if ($JobName -match 'primary') { 'primary' } else { 'secondary' }
    $record = [pscustomobject]@{
        Job      = $JobName
        Role     = $role
        Name     = $Name
        Statuses = [System.Collections.Generic.Queue[string]]::new([string[]]$Statuses)
        Start    = $Start
        Template = $Template
    }
    $global:Fake.Executions.Add($record)
    foreach ($line in $Lines) {
        $global:Fake.LogOrder++
        $global:Fake.Logs.Add([pscustomobject]@{ Workspace = $global:Fake.Workspaces[$role]; Execution = $Name; Time = $LogTime; Order = $global:Fake.LogOrder; Line = $line })
    }
    return $record
}

#endregion

#region Fake Azure CLI

function Get-FakeOption([string[]]$Arguments, [string]$Name) {
    $index = [Array]::IndexOf($Arguments, $Name)
    if ($index -ge 0 -and $index + 1 -lt $Arguments.Count) {
        return $Arguments[$index + 1]
    }
    return $null
}

# Reports the current status, then advances, so a waiting caller sees Running before the final status.
function ConvertTo-FakeExecution($Record, [switch]$Advance) {
    $status = $Record.Statuses.Peek()
    if ($Advance -and $Record.Statuses.Count -gt 1) {
        [void]$Record.Statuses.Dequeue()
    }
    $properties = [ordered]@{ status = $status; startTime = $Record.Start.ToString('o'); template = $Record.Template }
    if ($status -in 'Succeeded', 'Failed', 'Stopped', 'Degraded') {
        $properties['endTime'] = $Record.Start.AddSeconds(45).ToString('o')
    }
    return [ordered]@{ id = "$($global:Fake.GroupId)/providers/Microsoft.App/jobs/$($Record.Job)/executions/$($Record.Name)"; name = $Record.Name; properties = $properties }
}

function New-FakeLogTable([string[]]$Columns, [object[]]$Rows) {
    return [ordered]@{ tables = @([ordered]@{ name = 'PrimaryResult'; columns = @($Columns | ForEach-Object { [ordered]@{ name = $_; type = 'string' } }); rows = $Rows }) }
}

function Get-FakeLogResult([string]$Url, [string]$Query) {
    $workspace = ($Url -split '/workspaces/')[1].Split('/')[0]
    if ($Query -match "startswith '([a-z0-9-]+)'") {
        $execution = $Matches[1]
        Assert-True ($Query -match 'datetime\(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\)') "the execution log query has an invalid datetime literal: $Query"
        $rows = @($global:Fake.Logs | Where-Object { $_.Execution -eq $execution } | Sort-Object Order | ForEach-Object { , @($_.Time.ToString('o'), $_.Order, $_.Line) })
        return New-FakeLogTable @('TimeGenerated', 'Order', 'Line') $rows
    }
    if ($Query -match 'arg_max\(TimeGenerated, Line\) by Marker') {
        $rows = @(foreach ($marker in 'AZURE_FILES_REPLICATION_SUCCEEDED', 'AZURE_FILES_REPLICATION_FAILED') {
                $latest = $global:Fake.Logs | Where-Object { $_.Workspace -eq $workspace -and $_.Line.Contains($marker) } | Sort-Object Time, Order | Select-Object -Last 1
                if ($latest) {
                    , @($marker, $latest.Time.ToString('o'), $latest.Line)
                }
            })
        return New-FakeLogTable @('Marker', 'TimeGenerated', 'Line') $rows
    }
    throw "unexpected log query: $Query"
}

function Start-FakeExecution([string[]]$Arguments) {
    $jobName = Get-FakeOption $Arguments '--name'
    $job = $global:Fake.Jobs[$jobName]
    Assert-True ($null -ne $job) "job start for an unknown job: $jobName"
    $yamlPath = Get-FakeOption $Arguments '--yaml'
    $yamlText = $null
    if ($yamlPath) {
        $yamlText = [IO.File]::ReadAllText($yamlPath)
        $template = $yamlText | ConvertFrom-Json -AsHashtable -Depth 50
    } else {
        $template = $job.properties.template | ConvertTo-Json -Depth 50 | ConvertFrom-Json -AsHashtable -Depth 50
    }
    $container = $template['containers'][0]
    $environment = @{}
    foreach ($entry in @($container['env'])) {
        $environment[[string]$entry['name']] = [string]$entry['value']
    }
    $command = @($container['command'] | Where-Object { $_ })
    $containerArguments = @($container['args'] | Where-Object { $_ })
    $role = if ($jobName -match 'primary') { 'primary' } else { 'secondary' }
    $executionName = '{0}-{1}' -f $jobName, [guid]::NewGuid().ToString('N').Substring(0, 7)

    $run = Invoke-FakeContainer -ExecutionName $executionName -Environment $environment -Command $command -Arguments $containerArguments
    $final = if ($run.ExitCode -eq 0) { 'Succeeded' } else { 'Failed' }
    $null = Add-FakeExecution -JobName $jobName -Name $executionName -Statuses @('Running', $final) -Start ([DateTime]::UtcNow) -LogTime ([DateTime]::UtcNow) -Template $template -Lines $run.Lines
    $global:Fake.Starts.Add([pscustomobject]@{
            Job         = $jobName
            Execution   = $executionName
            YamlText    = $yamlText
            Environment = $environment
            Command     = $command
            Script      = if ($command.Count -gt 0) { $containerArguments[0] } else { $null }
            ExitCode    = $run.ExitCode
            Output      = $run.Lines
        })
    # Azure Monitor raises the failed-execution metric alert for the job. The alert is stateful: while it is
    # firing, another failure doesn't create a new alert instance.
    $ruleId = "$($global:Fake.GroupId)/providers/Microsoft.Insights/metricAlerts/alert-replication-failed-$role-tok"
    $firing = @($global:Fake.Alerts | Where-Object { $_.properties.essentials.alertRule -eq $ruleId -and $_.properties.essentials.monitorCondition -eq 'Fired' })
    if ($final -eq 'Failed' -and $firing.Count -eq 0) {
        $global:Fake.Alerts.Add([ordered]@{ name = 'Replication job failed'; properties = [ordered]@{ essentials = [ordered]@{ alertRule = $ruleId; severity = 'Sev1'; monitorCondition = 'Fired'; alertState = 'New'; startDateTime = [DateTime]::UtcNow.ToString('o'); targetResourceName = $jobName } } })
    }
    return [ordered]@{ id = "$($job.id)/executions/$executionName"; name = $executionName }
}

function az {
    $arguments = @($args | ForEach-Object { [string]$_ })
    $joined = $arguments -join ' '
    $fake = $global:Fake
    $fake.Calls.Add($joined)
    $result = $null
    $failure = $null
    switch -Regex ($joined) {
        '^account show' { $result = [ordered]@{ id = $fake.SubscriptionId; name = 'Demo subscription'; tenantId = $fake.TenantId }; break }
        '^cloud show' { $result = [ordered]@{ endpoints = [ordered]@{ portal = 'https://portal.azure.com'; logAnalyticsResourceId = 'https://api.loganalytics.io' } }; break }
        '^containerapp job list ' { $result = @($fake.Jobs.Values); break }
        '^containerapp env show ' { $result = $fake.Environments[(Get-FakeOption $arguments '--ids')]; break }
        '^containerapp job start ' { $result = Start-FakeExecution $arguments; break }
        '^containerapp job execution show ' {
            $record = $fake.Executions | Where-Object Name -eq (Get-FakeOption $arguments '--job-execution-name') | Select-Object -First 1
            $result = ConvertTo-FakeExecution $record -Advance
            break
        }
        '^containerapp job execution list ' {
            $jobName = Get-FakeOption $arguments '--name'
            $result = @($fake.Executions | Where-Object Job -eq $jobName | ForEach-Object { ConvertTo-FakeExecution $_ })
            break
        }
        '^containerapp job update ' {
            $job = $fake.Jobs[(Get-FakeOption $arguments '--name')]
            $job.properties.configuration.scheduleTriggerConfig.cronExpression = Get-FakeOption $arguments '--cron-expression'
            $result = $job
            break
        }
        '^tag update ' {
            if ($fake.TagFailure) {
                $failure = 'ERROR: (AuthorizationFailed) The client does not have authorization to perform action Microsoft.Resources/tags/write.'
                break
            }
            $job = @($fake.Jobs.Values | Where-Object { $_.id -eq (Get-FakeOption $arguments '--resource-id') })[0]
            $key, $value = (Get-FakeOption $arguments '--tags').Split('=', 2)
            if ((Get-FakeOption $arguments '--operation') -eq 'Merge') {
                $job.tags[$key] = $value
            } elseif ($job.tags[$key] -eq $value) {
                $job.tags.Remove($key)
            }
            $result = [ordered]@{ properties = [ordered]@{ tags = $job.tags } }
            break
        }
        '^monitor metrics alert list ' { $result = $fake.MetricRules; break }
        '^monitor action-group list ' {
            $result = @(
                [ordered]@{ name = 'ag-replication-tok'; enabled = $true; emailReceivers = @([ordered]@{ name = 'replication-email-1'; emailAddress = 'ops-team@example.com' }) },
                [ordered]@{ name = 'ag-unrelated'; enabled = $true; emailReceivers = @() }
            )
            break
        }
        '^rest --method get --url \S+/scheduledQueryRules ' { $result = [ordered]@{ value = $fake.QueryRules }; break }
        '^rest --method get --url \S+/Microsoft\.AlertsManagement/alerts ' { $result = [ordered]@{ value = @($fake.Alerts) }; break }
        '^rest --method post --url \S+/v1/workspaces/' {
            if ($fake.LogTableMissing) {
                $failure = "ERROR: Bad Request({`"error`":{`"message`":`"'where' operator: Failed to resolve table or column expression named 'ContainerAppConsoleLogs_CL'`"}})"
                break
            }
            $body = [IO.File]::ReadAllText((Get-FakeOption $arguments '--body').Substring(1)) | ConvertFrom-Json
            $result = Get-FakeLogResult (Get-FakeOption $arguments '--url') $body.query
            break
        }
        '^resource list --tag ' { $result = $fake.TaggedResources; break }
        '^resource list --name ' { $result = @($fake.ExistingResources[(Get-FakeOption $arguments '--name')] | Where-Object { $_ }); break }
        '^resource show --ids ' {
            $result = $fake.ExistingResources[(Get-FakeOption $arguments '--ids')]
            if (-not $result) {
                $failure = 'ERROR: (ResourceNotFound) The resource was not found.'
            }
            break
        }
        '^acr show ' { $result = [ordered]@{ name = 'acrdemo'; publicNetworkAccess = 'Disabled' }; break }
        default { $failure = "ERROR: no fake response for: az $joined" }
    }
    if ($failure) {
        $global:LASTEXITCODE = 1
        Write-Error $failure -ErrorAction Continue
        return
    }
    $global:LASTEXITCODE = 0
    return (ConvertTo-Json -InputObject $result -Depth 50 -Compress)
}

#endregion

#region Tests

function Invoke-Demo([string]$Command, [hashtable]$Parameters = @{}) {
    $output = & $demoScript $Command -PollSeconds 0 -TimeoutMinutes 1 @Parameters 3>&1 6>&1 | ForEach-Object { "$_" }
    return ($output -join "`n")
}

function Get-LastStart {
    return $global:Fake.Starts[$global:Fake.Starts.Count - 1]
}

function Get-DemoEntries([string]$Account) {
    return @(Get-ShareEntries $Account | Where-Object { $_ -like 'replication-demo/*' })
}

try {
    # A new deployment has no console log table until the first job writes output.
    $global:Fake.LogTableMissing = $true
    $output = Invoke-Demo 'status'
    Assert-True ($output -match 'Direction : primary \(westus2\) -> secondary \(northcentralus\)') "status did not report the direction: $output"
    Assert-True ($output -match 'none in the last 7 days') 'a missing log table was not reported as no successful runs'
    $global:Fake.LogTableMissing = $false

    $finished = [DateTime]::UtcNow.AddMinutes(-5)
    $jobTemplate = $global:Fake.Jobs['job-sync-primary-demo'].properties.template
    $null = Add-FakeExecution -JobName 'job-sync-primary-demo' -Name 'job-sync-primary-demo-sched01' -Statuses @('Succeeded') -Start $finished.AddSeconds(-45) -LogTime $finished -Template $jobTemplate -Lines @("AZURE_FILES_REPLICATION_SUCCEEDED startedAt=$($finished.AddSeconds(-41).ToString('yyyy-MM-ddTHH:mm:ssZ')) durationSeconds=41")
    $output = Invoke-Demo 'status'
    Assert-True ($output -match 'State\s+: Healthy') "status did not report healthy replication: $output"
    Assert-True ($output -match 'took 41s' -and $output -match 'Recovery point') 'status did not show the run duration and recovery point'
    Assert-True ($output -match '\.\.\.@sha256:bbbbbbbbbbbb\.\.\.') 'status did not shorten the image digest'
    Assert-True ($output -notmatch 'unrelated-cpu-alert') 'status listed an alert that is not a replication alert'
    Assert-True ($output.Contains("https://portal.azure.com/#@$($global:Fake.TenantId)/resource$($global:Fake.GroupId)/overview")) 'status did not print the resource group portal link'

    $output = Invoke-Demo 'inventory'
    Assert-True ($output -match '7 resources: .*Container Apps job x2') "inventory did not summarize the tagged resources: $output"
    foreach ($expected in 'stprimarydemo', 'rg-storage-secondary', 'acrdemo', 'rg-registry', 'vnet-secondary', 'snet-jobs') {
        Assert-True ($output.Contains($expected)) "inventory did not list $expected"
    }
    $null = Invoke-Demo 'inventory' @{ ParametersFile = 'deployment.bicepparam' }
    $overrides = @($global:FakeInventoryInvocation.ParameterOverrides) -join ','
    Assert-True ($overrides -eq "activeRegion=primary,containerImage=$image,acrPublicNetworkAccess=Disabled") "inventory passed overrides: $overrides"

    $startCount = $global:Fake.Starts.Count
    $null = Invoke-Demo 'seed' @{ WhatIf = $true }
    Assert-True ($global:Fake.Starts.Count -eq $startCount) 'seed -WhatIf started an execution'

    $output = Invoke-Demo 'seed' @{ Force = $true }
    $start = Get-LastStart
    Assert-True ($start.Job -eq 'job-sync-primary-demo' -and $start.YamlText) 'seed must run on the active job with an execution template'
    Assert-True ($start.Environment['DEMO_TARGET_URL'] -eq $primaryShareUrl) 'seed did not target the active source share'
    Assert-True ($start.Environment['AZCOPY_MSI_CLIENT_ID'] -eq 'client-id-primary') 'the execution template dropped the job environment'
    Assert-True ($start.YamlText -match '"containers": \[') 'the execution template must be indented JSON, which the CLI YAML loader accepts'
    foreach ($field in 'ephemeralStorage', 'probes', 'volumes') {
        Assert-True (-not $start.YamlText.Contains($field)) "the execution template included $field"
    }
    Assert-True ($output -match 'Wrote replication-demo/demo-\d{8}T\d{6}Z\.txt to the primary share') "seed output: $output"
    Assert-True ((Get-DemoEntries 'stprimarydemo').Count -eq 1) 'seed did not write the file to the source share'

    $output = Invoke-Demo 'files'
    Assert-True ((Get-LastStart).Job -eq 'job-sync-secondary-demo') 'files must run on the standby job'
    Assert-True ($output -match '1 of 1 source file\(s\) are not in the replica yet') "files before replication: $output"
    Assert-True ($output -match 'The folder does not exist in this share yet') 'the missing replica folder was not explained'

    $output = Invoke-Demo 'replicate'
    $start = Get-LastStart
    Assert-True ($start.Job -eq 'job-sync-primary-demo' -and -not $start.YamlText) 'replicate must start the active job with its own template'
    Assert-True ($output -match 'AZURE_FILES_REPLICATION_SUCCEEDED startedAt=') "replicate output: $output"
    Assert-True ($output -match 'AzCopy summary: 1 transfers completed, 0 failed, 0 skipped') 'replicate did not summarize the AzCopy job'
    Assert-True ((Get-DemoEntries 'stsecondarydemo').Count -eq 1) 'replication did not copy the file'

    $output = Invoke-Demo 'files'
    Assert-True ($output -match 'All 1 source file\(s\) are in the replica share') "files after replication: $output"

    $null = Add-FakeExecution -JobName 'job-sync-primary-demo' -Name 'job-sync-primary-demo-sched02' -Statuses @('Running', 'Running', 'Succeeded') -Start ([DateTime]::UtcNow.AddSeconds(-20)) -LogTime ([DateTime]::UtcNow) -Template $jobTemplate -Lines @('AZURE_FILES_REPLICATION_SUCCEEDED startedAt=2026-01-01T00:00:00Z durationSeconds=12')
    $startCount = $global:Fake.Starts.Count
    $output = Invoke-Demo 'replicate'
    Assert-True ($global:Fake.Starts.Count -eq $startCount) 'replicate started a second run while one was in progress'
    Assert-True ($output -match 'already in progress; following it') "replicate did not follow the running run: $output"

    $primaryBefore = (Get-ShareEntries 'stprimarydemo') -join '|'
    $output = Invoke-Demo 'standby-check'
    $start = Get-LastStart
    Assert-True ($start.Job -eq 'job-sync-secondary-demo' -and $start.Script -match 'azcopy sync .*--dry-run') 'standby-check must run a dry run on the standby job'
    Assert-True ($output -match 'A reverse run would copy 1 file\(s\), remove 0, and update properties on 0') "standby-check output: $output"
    Assert-True (((Get-ShareEntries 'stprimarydemo') -join '|') -eq $primaryBefore) 'the standby dry run changed the primary share'

    $replicaBefore = (Get-ShareEntries 'stsecondarydemo') -join '|'
    $output = Invoke-Demo 'fail-run' @{ Force = $true }
    $start = Get-LastStart
    Assert-True ($start.Job -eq 'job-sync-primary-demo' -and $start.Command.Count -eq 0) 'fail-run must run the real wrapper on the active job'
    Assert-True ($start.Environment['SOURCE_FILE_URL'] -match '^https://stprimarydemo\.file\.core\.windows\.net/replication-demo-missing-[0-9a-f]{8}$') "fail-run source was $($start.Environment['SOURCE_FILE_URL'])"
    Assert-True ($start.Environment['DELETE_DESTINATION'] -eq 'false' -and $start.Environment['DESTINATION_FILE_URL'] -eq $secondaryShareUrl) 'fail-run must keep the destination and force DELETE_DESTINATION=false'
    Assert-True ($output -match 'AZURE_FILES_REPLICATION_FAILED exitCode=1') "fail-run output: $output"
    Assert-True ($output -match 'AzCopy error: .*ShareNotFound <redacted-url>') 'fail-run did not show the redacted AzCopy error'
    Assert-True ($output -match 'Alert fired: alert-replication-failed-primary-tok \(Sev1\)') 'fail-run did not report the fired alert'
    Assert-True (((Get-ShareEntries 'stsecondarydemo') -join '|') -eq $replicaBefore) 'the simulated failure changed the replica'

    # The failure alert is stateful, so a second failure while it fires raises no new alert.
    $output = Invoke-Demo 'fail-run' @{ Force = $true }
    Assert-True ($output -match 'has been firing since' -and $output -match 'is still firing from an earlier failure') "a repeated fail-run did not explain the firing alert: $output"

    $output = Invoke-Demo 'status'
    foreach ($kind in 'Demo: simulated failure', 'Demo: write file', 'Demo: list files', 'Demo: standby dry run') {
        Assert-True ($output.Contains($kind)) "status did not classify '$kind' executions: $output"
    }
    Assert-True ($output -match 'Last failed run') 'status did not report the failure after the last success'

    $output = Invoke-Demo 'alerts'
    Assert-True ($output -match 'every 1 min over 5 min' -and $output -match 'every 10 min over 30 min') "alert rule timings: $output"
    Assert-True ($output -match 'op\*\*\*@example\.com' -and $output -notmatch 'ops-team@example\.com') 'the alert email address was not masked'
    Assert-True ($output -notmatch 'ag-unrelated' -and $output -notmatch 'unrelated-cpu-alert') 'alerts listed resources outside the solution'
    Assert-True ($output -match 'alert-replication-failed-primary-tok') 'alerts did not list the fired alert'

    $primaryJob = $global:Fake.Jobs['job-sync-primary-demo']
    $global:Fake.TagFailure = $true
    $pauseRejected = $false
    try {
        $null = Invoke-Demo 'pause' @{ Force = $true }
    } catch {
        $pauseRejected = $_.Exception.Message -match 'AuthorizationFailed'
    }
    $global:Fake.TagFailure = $false
    Assert-True $pauseRejected 'pause did not stop when the original schedule could not be recorded'
    Assert-True ($primaryJob.properties.configuration.scheduleTriggerConfig.cronExpression -eq '*/10 * * * *') 'pause changed the schedule without recording it'

    $output = Invoke-Demo 'pause' @{ Force = $true }
    Assert-True ($primaryJob.properties.configuration.scheduleTriggerConfig.cronExpression -match '^0 0 \d{1,2} \d{1,2} \*$') 'pause did not set the far-future schedule'
    Assert-True ($primaryJob.tags['ReplicationDemoOriginalCron'] -eq '*/10 * * * *') 'pause did not record the original schedule'
    Assert-True ($output -match 'should fire between') 'pause did not estimate when the alert fires'

    $replicateRefused = $false
    try {
        $null = Invoke-Demo 'replicate'
    } catch {
        $replicateRefused = $_.Exception.Message -match 'paused'
    }
    Assert-True $replicateRefused 'replicate ran while scheduled replication was paused'
    Assert-True ((Invoke-Demo 'status') -match 'PAUSED by the demo script') 'status did not show the pause'

    $null = Invoke-Demo 'resume'
    Assert-True ($primaryJob.properties.configuration.scheduleTriggerConfig.cronExpression -eq '*/10 * * * *') 'resume did not restore the schedule'
    Assert-True (-not $primaryJob.tags.Contains('ReplicationDemoOriginalCron')) 'resume did not remove the pause tag'

    $output = Invoke-Demo 'cleanup' @{ Force = $true }
    Assert-True ((Get-LastStart).Job -eq 'job-sync-secondary-demo') 'cleanup must run on the standby job'
    Assert-True ($output -match "Removed 'replication-demo' from the source share" -and $output -match "Removed 'replication-demo' from the replica share") "cleanup output: $output"
    Assert-True ((Get-DemoEntries 'stprimarydemo').Count -eq 0 -and (Get-DemoEntries 'stsecondarydemo').Count -eq 0) 'cleanup left demo files'
    Assert-True ((Invoke-Demo 'files') -match "The source share has no files in 'replication-demo'") 'files did not report the empty folder after cleanup'

    # Safety properties across every execution the demo started.
    foreach ($start in $global:Fake.Starts) {
        if ($start.Job -eq 'job-sync-secondary-demo') {
            Assert-True ($start.Command.Count -eq 2) 'the standby job was started without a command override, which would run a reverse replication'
        }
        if ($start.Script) {
            Assert-True (-not $start.Script.Contains('AZURE_FILES_REPLICATION_SUCCEEDED')) 'a helper script can print the replication success marker'
            Assert-True (($start.Output -join "`n") -notmatch 'AZURE_FILES_REPLICATION_') "helper execution $($start.Execution) printed a replication marker"
            Assert-True ($start.ExitCode -eq 0) "helper execution $($start.Execution) exited with $($start.ExitCode)"
        }
    }
    $helperExecutions = @($global:Fake.Starts | Where-Object Script | ForEach-Object Execution)
    foreach ($call in [IO.File]::ReadAllLines((Join-Path $stateDirectory 'azcopy-calls.txt'))) {
        $caller, $azcopyArguments = $call.Split(' ', 2)
        if ($helperExecutions -contains $caller -and $azcopyArguments -like 'sync *') {
            Assert-True ($azcopyArguments -like '* --dry-run *') "a helper ran azcopy sync without --dry-run: $azcopyArguments"
        }
    }

    # Without a scheduled direction, the commands that write refuse to run.
    $primaryJob.properties.configuration.triggerType = 'Manual'
    $primaryJob.properties.configuration.Remove('scheduleTriggerConfig')
    $output = Invoke-Demo 'status'
    Assert-True ($output -match 'Direction : none') 'status did not report a deployment without an active direction'
    $seedRefused = $false
    try {
        $null = Invoke-Demo 'seed' @{ Force = $true }
    } catch {
        $seedRefused = $_.Exception.Message -match 'No replication job has a schedule'
    }
    Assert-True $seedRefused 'seed ran without an active direction'
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name Fake, FakePaths, FakeInventoryInvocation -Scope Global -ErrorAction SilentlyContinue
}

Write-Host 'Demo script checks passed.'
