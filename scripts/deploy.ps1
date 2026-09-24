[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Location = 'southcentralus',
    # Template compiled as a pre-deployment check. Azure CLI deploys the template in the parameter file's using declaration.
    [string]$TemplateFile,
    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\infra\main.bicepparam'),
    [string]$ImageContext = (Join-Path $PSScriptRoot '..\src\azcopy-job'),
    [string]$ImageRepository = 'azure-files-dr-azcopy',
    [string]$ImageTag = '10.30.1',
    [string]$ContainerImage,
    [switch]$SkipWhatIf
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

$null = Invoke-AzCli -Arguments @('account', 'show', '--output', 'none')
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

if ($ContainerImage -and $ContainerImage -notmatch '@sha256:[a-fA-F0-9]{64}$') {
    throw 'ContainerImage must be pinned by digest: <registry>/<repository>@sha256:<64 hex characters>.'
}

if (-not $PSCmdlet.ShouldProcess('current subscription', 'Deploy the replication foundation and activate the primary region')) {
    return
}

# acrPublicNetworkAccess applies only to a registry the templates create; it's public only while the image is built.
$bootstrapAccess = if ($ContainerImage) { 'Disabled' } else { 'Enabled' }
$bootstrapOverrides = @('activeRegion=none', "acrPublicNetworkAccess=$bootstrapAccess")
$bootstrapArguments = @(
    'deployment', 'sub', 'create',
    '--name', "azure-files-dr-bootstrap-$(Get-Date -Format 'yyyyMMddHHmmss')",
    '--location', $Location,
    '--parameters', $ParametersFile,
    '--parameters'
) + $bootstrapOverrides + @(
    '--output', 'json'
)
$bootstrap = Invoke-AzCli -Arguments $bootstrapArguments | ConvertFrom-Json

$registryName = $bootstrap.properties.outputs.registryName.value
if ($ContainerImage) {
    $image = $ContainerImage
} else {
    $null = Invoke-AzCli -Arguments @(
        'acr', 'build',
        '--registry', $registryName,
        '--image', "${ImageRepository}:${ImageTag}",
        $ImageContext,
        '--output', 'none'
    )

    $digest = Invoke-AzCli -Arguments @(
        'acr', 'manifest', 'show-metadata',
        "${registryName}.azurecr.io/${ImageRepository}:${ImageTag}",
        '--registry', $registryName,
        '--query', 'digest',
        '--output', 'tsv'
    )
    $image = "${registryName}.azurecr.io/${ImageRepository}@$($digest.Trim())"
}

$finalOverrides = @("containerImage=$image", 'activeRegion=primary', 'acrPublicNetworkAccess=Disabled')
$finalArguments = @(
    'deployment', 'sub', 'create',
    '--name', "azure-files-dr-final-$(Get-Date -Format 'yyyyMMddHHmmss')",
    '--location', $Location,
    '--parameters', $ParametersFile,
    '--parameters'
) + $finalOverrides + @(
    '--output', 'json'
)
$final = Invoke-AzCli -Arguments $finalArguments | ConvertFrom-Json

Write-Host "Primary scheduled job: $($final.properties.outputs.primaryJobName.value)"
Write-Host "Secondary standby job: $($final.properties.outputs.secondaryJobName.value)"
Write-Host "Monitoring action group: $($final.properties.outputs.monitoringActionGroupId.value)"
Write-Host "Pinned image: $image"