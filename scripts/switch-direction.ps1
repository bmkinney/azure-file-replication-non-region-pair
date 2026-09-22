[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('primary', 'secondary')]
    [string]$ActiveRegion,

    [Parameter(Mandatory)]
    [switch]$WritesFenced,

    [string]$ResourceGroupName = 'ppl-storagereplication-demo',
    [string]$Location = 'centralus',
    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\infra\main.bicepparam')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & az @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

if (-not $WritesFenced) {
    throw 'WritesFenced is required. Stop application writes before changing replication direction.'
}

$jobs = Invoke-AzCli -Arguments @(
    'containerapp', 'job', 'list',
    '--resource-group', $ResourceGroupName,
    '--query', "[?tags.Workload=='ppl-storage-replication'].[name,location,properties.template.containers[0].image]",
    '--output', 'json'
) | ConvertFrom-Json

if ($jobs.Count -ne 2) {
    throw "Expected two replication jobs in '$ResourceGroupName'; found $($jobs.Count)."
}

foreach ($job in $jobs) {
    $running = Invoke-AzCli -Arguments @(
        'containerapp', 'job', 'execution', 'list',
        '--resource-group', $ResourceGroupName,
        '--name', $job[0],
        '--query', "[?properties.status=='Running'] | length(@)",
        '--output', 'tsv'
    )
    if ([int]$running -gt 0) {
        throw "Job '$($job[0])' has a running execution. Wait for it to finish before switching direction."
    }
}

$images = @($jobs | ForEach-Object { $_[2] } | Select-Object -Unique)
if ($images.Count -ne 1 -or $images[0] -notmatch '@sha256:[a-fA-F0-9]{64}$') {
    throw 'Both jobs must use the same digest-pinned image before direction can be switched.'
}

if (-not $PSCmdlet.ShouldProcess($ResourceGroupName, "Set '$ActiveRegion' as the only scheduled replication direction")) {
    return
}

$deployment = Invoke-AzCli -Arguments @(
    'deployment', 'sub', 'create',
    '--name', "ppl-storage-replication-switch-$(Get-Date -Format 'yyyyMMddHHmmss')",
    '--location', $Location,
    '--parameters', $ParametersFile,
    '--parameters', "containerImage=$($images[0])", "activeRegion=$ActiveRegion", 'acrPublicNetworkAccess=Disabled',
    '--output', 'json'
) | ConvertFrom-Json

$activeJob = if ($ActiveRegion -eq 'primary') {
    $deployment.properties.outputs.primaryJobName.value
} else {
    $deployment.properties.outputs.secondaryJobName.value
}

Write-Host "Replication direction switched. Active scheduled job: $activeJob"
Write-Host 'Application writes remain fenced until validation is complete.'