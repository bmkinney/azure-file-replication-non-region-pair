[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('primary', 'secondary')]
    [string]$ActiveRegion,

    [Parameter(Mandatory)]
    [switch]$WritesFenced,

    [string]$ResourceGroupName = 'rg-azure-files-replication-demo',
    [string]$Location = 'southcentralus',
    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\infra\main.bicepparam'),
    [string]$TemplateFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)

    # -WhatIf would otherwise skip the stderr redirection and the temp-file cleanup below.
    $WhatIfPreference = $false

    # Azure CLI writes warnings to stderr; keeping them out of stdout protects JSON parsing.
    $errorPath = [IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments --only-show-errors 2> $errorPath
        $exitCode = $LASTEXITCODE
        $errorOutput = [IO.File]::ReadAllText($errorPath)
    } finally {
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -ne 0) {
        throw "az $($Arguments -join ' ') failed:`n$errorOutput`n$($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine)
}

if (-not $WritesFenced) {
    throw 'WritesFenced is required. Stop application writes before changing replication direction.'
}
if ([string]::IsNullOrWhiteSpace($TemplateFile)) {
    # A .bicepparam file names its template in its using declaration, for example main.local.bicepparam.
    $parametersDirectory = Split-Path -Parent $ParametersFile
    if (-not $parametersDirectory) {
        $parametersDirectory = '.'
    }
    $usingDeclaration = Select-String -LiteralPath $ParametersFile -Pattern "^\s*using\s+'([^']+)'" | Select-Object -First 1
    $templateName = if ($usingDeclaration) {
        $usingDeclaration.Matches[0].Groups[1].Value
    } else {
        "$([IO.Path]::GetFileNameWithoutExtension($ParametersFile)).bicep"
    }
    $TemplateFile = Join-Path $parametersDirectory $templateName
}
if (-not (Test-Path $TemplateFile -PathType Leaf)) {
    throw "Template file '$TemplateFile' was not found."
}

$jobs = Invoke-AzCli -Arguments @(
    'containerapp', 'job', 'list',
    '--resource-group', $ResourceGroupName,
    '--query', "[?tags.Workload=='azure-files-dr-replication'].[name,location,properties.template.containers[0].image]",
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

# acrPublicNetworkAccess applies only to a registry the templates create.
$deploymentOverrides = @("containerImage=$($images[0])", "activeRegion=$ActiveRegion", 'acrPublicNetworkAccess=Disabled')
$deploymentArguments = @(
    'deployment', 'sub', 'create',
    '--name', "azure-files-dr-switch-$(Get-Date -Format 'yyyyMMddHHmmss')",
    '--location', $Location,
    '--parameters', $ParametersFile,
    '--parameters'
) + $deploymentOverrides + @(
    '--output', 'json'
)
$deployment = Invoke-AzCli -Arguments $deploymentArguments | ConvertFrom-Json

$activeJob = if ($ActiveRegion -eq 'primary') {
    $deployment.properties.outputs.primaryJobName.value
} else {
    $deployment.properties.outputs.secondaryJobName.value
}

Write-Host "Replication direction switched. Active scheduled job: $activeJob"
Write-Host 'Application writes remain fenced until validation is complete.'