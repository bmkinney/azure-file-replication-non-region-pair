$ErrorActionPreference = 'Stop'

$content = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'run-sync.sh') -Raw
$requiredFragments = @(
    'AZCOPY_AUTO_LOGIN_TYPE=MSI',
    'AZCOPY_MSI_CLIENT_ID',
    '--recursive=true',
    '--delete-destination="$delete_destination"',
    '--output-type=json',
    'Source and destination URLs must differ',
    'AZURE_FILES_REPLICATION_FAILED',
    'AZURE_FILES_REPLICATION_SUCCEEDED'
)

foreach ($fragment in $requiredFragments) {
    if (-not $content.Contains($fragment)) {
        throw "run-sync.sh is missing required fragment: $fragment"
    }
}

Write-Host 'AzCopy wrapper contract checks passed.'