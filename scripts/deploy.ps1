[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Location = 'centralus',
    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\infra\main.bicepparam'),
    [string]$ImageContext = (Join-Path $PSScriptRoot '..\src\azcopy-job'),
    [string]$ImageRepository = 'ppl-azcopy-job',
    [string]$ImageTag = '10.30.1',
    [switch]$SkipWhatIf
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

$null = Invoke-AzCli -Arguments @('account', 'show', '--output', 'none')
$templateFile = Join-Path $PSScriptRoot '..\infra\main.bicep'
$null = Invoke-AzCli -Arguments @('bicep', 'build', '--file', $templateFile, '--stdout')
$null = Invoke-AzCli -Arguments @(
    'deployment', 'sub', 'validate',
    '--location', $Location,
    '--parameters', $ParametersFile
)

if (-not $SkipWhatIf) {
    Invoke-AzCli -Arguments @(
        'deployment', 'sub', 'what-if',
        '--location', $Location,
        '--parameters', $ParametersFile,
        '--result-format', 'FullResourcePayloads'
    ) | Write-Host
}

if (-not $PSCmdlet.ShouldProcess('current subscription', 'Deploy the replication foundation, build AzCopy, and activate Central US')) {
    return
}

$bootstrap = Invoke-AzCli -Arguments @(
    'deployment', 'sub', 'create',
    '--name', "ppl-storage-replication-bootstrap-$(Get-Date -Format 'yyyyMMddHHmmss')",
    '--location', $Location,
    '--parameters', $ParametersFile,
    '--parameters', 'activeRegion=none', 'acrPublicNetworkAccess=Enabled',
    '--output', 'json'
) | ConvertFrom-Json

$registryName = $bootstrap.properties.outputs.registryName.value
$null = Invoke-AzCli -Arguments @(
    'acr', 'build',
    '--registry', $registryName,
    '--image', "${ImageRepository}:${ImageTag}",
    $ImageContext,
    '--output', 'none'
)

$digest = Invoke-AzCli -Arguments @(
    'acr', 'manifest', 'show-metadata',
    "${ImageRepository}:${ImageTag}",
    '--registry', $registryName,
    '--query', 'digest',
    '--output', 'tsv'
)
$image = "${registryName}.azurecr.io/${ImageRepository}@$($digest.Trim())"

$final = Invoke-AzCli -Arguments @(
    'deployment', 'sub', 'create',
    '--name', "ppl-storage-replication-final-$(Get-Date -Format 'yyyyMMddHHmmss')",
    '--location', $Location,
    '--parameters', $ParametersFile,
    '--parameters', "containerImage=$image", 'activeRegion=primary', 'acrPublicNetworkAccess=Disabled',
    '--output', 'json'
) | ConvertFrom-Json

Write-Host "Primary scheduled job: $($final.properties.outputs.primaryJobName.value)"
Write-Host "Secondary standby job: $($final.properties.outputs.secondaryJobName.value)"
Write-Host "Pinned image: $image"