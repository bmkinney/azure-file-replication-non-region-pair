$ErrorActionPreference = 'Stop'

$wrapperPath = Join-Path $PSScriptRoot 'run-sync.sh'
$content = Get-Content -LiteralPath $wrapperPath -Raw
if ($content.Contains("`r")) {
    throw 'run-sync.sh must use LF line endings so /bin/sh can run it in the container.'
}

$requiredFragments = @(
    'AZCOPY_AUTO_LOGIN_TYPE=MSI',
    'AZCOPY_MSI_CLIENT_ID',
    '--recursive=true',
    '--delete-destination="$delete_destination"',
    '--preserve-info=true',
    '--preserve-permissions="$preserve_permissions"',
    '--include-root=true',
    '--force-if-read-only=true',
    '--dry-run',
    '--output-type=json',
    'Source and destination URLs must differ',
    'AZURE_FILES_REPLICATION_FAILED',
    'AZURE_FILES_REPLICATION_SUCCEEDED',
    'AZURE_FILES_REPLICATION_DRY_RUN_COMPLETED'
)

foreach ($fragment in $requiredFragments) {
    if (-not $content.Contains($fragment)) {
        throw "run-sync.sh is missing required fragment: $fragment"
    }
}

$shell = Get-Command sh -ErrorAction SilentlyContinue
if (-not $shell) {
    Write-Host 'AzCopy wrapper contract checks passed. Behavior checks were skipped because sh is not available.'
    return
}

function ConvertTo-ShellPath([string]$Path) {
    return $Path -replace '\\', '/'
}

$workRoot = Join-Path ([IO.Path]::GetTempPath()) "run-sync-test-$([guid]::NewGuid().ToString('N'))"
$binDirectory = Join-Path $workRoot 'bin'
$logDirectory = Join-Path $workRoot 'logs'
$argumentsPath = Join-Path $workRoot 'azcopy-arguments.txt'
New-Item -ItemType Directory -Path $binDirectory, $logDirectory -Force | Out-Null

# The stub records AzCopy arguments and simulates output, a failure log, and exit codes.
$stubPath = Join-Path $binDirectory 'azcopy'
$stub = @'
#!/bin/sh
printf '%s\n' "$@" > "$STUB_ARGUMENTS_FILE"
if [ -n "${STUB_OUTPUT:-}" ]; then
    printf '%b\n' "$STUB_OUTPUT"
fi
if [ "${STUB_EXIT_CODE:-0}" != "0" ]; then
    printf '%s\n' 'ERR: COPYFAILED https://source.file.core.windows.net/share/private-name.txt : 403 CannotVerifyCopySource' > "$AZCOPY_LOG_LOCATION/job.log"
fi
exit "${STUB_EXIT_CODE:-0}"
'@
[IO.File]::WriteAllText($stubPath, ($stub -replace "`r`n", "`n"))
if (-not [Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([Runtime.InteropServices.OSPlatform]::Windows)) {
    & chmod +x $stubPath
}

$baseEnvironment = @{
    SOURCE_FILE_URL          = 'https://source.file.core.windows.net/share'
    DESTINATION_FILE_URL     = 'https://destination.file.core.windows.net/share'
    AZCOPY_MSI_CLIENT_ID     = '00000000-0000-0000-0000-000000000000'
    AZCOPY_LOG_LOCATION      = ConvertTo-ShellPath $logDirectory
    AZCOPY_JOB_PLAN_LOCATION = ConvertTo-ShellPath $logDirectory
    STUB_ARGUMENTS_FILE      = ConvertTo-ShellPath $argumentsPath
    PATH                     = "$binDirectory$([IO.Path]::PathSeparator)$env:PATH"
}
$caseVariables = 'DELETE_DESTINATION', 'DRY_RUN', 'PRESERVE_PERMISSIONS', 'STUB_EXIT_CODE', 'STUB_OUTPUT'

function Invoke-Wrapper([hashtable]$Overrides = @{}) {
    $environment = $baseEnvironment.Clone()
    foreach ($name in $caseVariables) {
        $environment[$name] = $null
    }
    foreach ($name in $Overrides.Keys) {
        $environment[$name] = $Overrides[$name]
    }

    Remove-Item -Path $argumentsPath -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path $logDirectory -File | Remove-Item -Force

    $previous = @{}
    foreach ($name in $environment.Keys) {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $environment[$name])
    }
    try {
        $stdoutPath = Join-Path $workRoot 'stdout.txt'
        $stderrPath = Join-Path $workRoot 'stderr.txt'
        & $shell.Source (ConvertTo-ShellPath $wrapperPath) 1> $stdoutPath 2> $stderrPath
        return [pscustomobject]@{
            ExitCode  = $LASTEXITCODE
            Stdout    = [IO.File]::ReadAllText($stdoutPath)
            Stderr    = [IO.File]::ReadAllText($stderrPath)
            Arguments = if (Test-Path $argumentsPath) { @([IO.File]::ReadAllLines($argumentsPath)) } else { @() }
        }
    } finally {
        foreach ($name in $environment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name])
        }
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "run-sync.sh behavior check failed: $Message"
    }
}

try {
    $result = Invoke-Wrapper
    Assert-True ($result.ExitCode -eq 0) "replication exit code was $($result.ExitCode). $($result.Stderr)"
    Assert-True ($result.Stdout -match 'AZURE_FILES_REPLICATION_SUCCEEDED startedAt=\S+ durationSeconds=\d+') 'the success marker is missing timing details'
    foreach ($argument in '--preserve-info=true', '--preserve-permissions=true', '--include-root=true', '--force-if-read-only=true', '--delete-destination=false', '--log-level=ERROR', '--output-type=json') {
        Assert-True ($result.Arguments -contains $argument) "replication did not pass $argument"
    }
    Assert-True ($result.Arguments -notcontains '--dry-run') 'replication must not pass --dry-run'

    $dryRunOutput = 'INFO: Scanning...\nDRYRUN: copy https://source.file.core.windows.net/share/a.txt to https://destination.file.core.windows.net/share/a.txt\nDRYRUN: copy https://source.file.core.windows.net/share/b.txt to https://destination.file.core.windows.net/share/b.txt\nDRYRUN: remove https://destination.file.core.windows.net/share/c.txt'
    $result = Invoke-Wrapper @{ DRY_RUN = 'true'; STUB_OUTPUT = $dryRunOutput }
    Assert-True ($result.ExitCode -eq 0) "dry-run exit code was $($result.ExitCode). $($result.Stderr)"
    Assert-True ($result.Stdout -match 'AZURE_FILES_REPLICATION_DRY_RUN_COMPLETED wouldCopy=2 wouldRemove=1 wouldSetProperties=0 ') 'dry-run counts are incorrect'
    Assert-True (-not $result.Stdout.Contains('AZURE_FILES_REPLICATION_SUCCEEDED')) 'a dry run must not emit the replication success marker'
    Assert-True (-not $result.Stdout.Contains('a.txt')) 'a dry run must not log file paths'
    Assert-True ($result.Arguments -contains '--dry-run' -and $result.Arguments -contains '--output-type=text') 'a dry run must pass --dry-run with text output'

    $result = Invoke-Wrapper @{ STUB_EXIT_CODE = '1' }
    Assert-True ($result.ExitCode -eq 1) "failure exit code was $($result.ExitCode)"
    Assert-True ($result.Stderr -match 'AZURE_FILES_REPLICATION_FAILED exitCode=1 ') 'the failure marker is missing'
    Assert-True ($result.Stderr.Contains('403 CannotVerifyCopySource')) 'failure output must include the AzCopy error'
    Assert-True (-not $result.Stderr.Contains('private-name.txt')) 'failure output must redact file URLs'

    $result = Invoke-Wrapper @{ PRESERVE_PERMISSIONS = 'false' }
    Assert-True ($result.Arguments -contains '--preserve-permissions=false') 'PRESERVE_PERMISSIONS=false was not honored'

    foreach ($invalidSetting in @(@{ DRY_RUN = 'yes' }, @{ DELETE_DESTINATION = 'prompt' }, @{ PRESERVE_PERMISSIONS = 'maybe' })) {
        $result = Invoke-Wrapper $invalidSetting
        Assert-True ($result.ExitCode -eq 64) "invalid $($invalidSetting.Keys) value was accepted"
    }
} finally {
    Remove-Item -Path $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'AzCopy wrapper contract and behavior checks passed.'