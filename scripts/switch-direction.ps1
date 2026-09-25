[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateSet('primary', 'secondary')]
    [string]$ActiveRegion,

    [Parameter(Mandatory)]
    [switch]$WritesFenced,

    [string]$ResourceGroupName = 'rg-azure-files-replication-demo',

    # Resource group of the secondary-region job when it differs from -ResourceGroupName.
    [string]$SecondaryResourceGroupName,

    [string]$Location = 'southcentralus',
    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\infra\main.bicepparam'),
    # Checked for existence only. Azure CLI deploys the template in the parameter file's using declaration.
    [string]$TemplateFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RoleAssignmentHint([string]$ErrorText) {
    # The switch redeploys the template, including the job identities' role assignments on the storage accounts and registry.
    $flatText = [regex]::Replace($ErrorText, '\s*\r?\n[ \t]*(\|[ \t]?)?', ' ')
    $scopes = @([regex]::Matches($flatText, "roleAssignments/write'\s+at\s+scope\s+'(?<scope>[^'\s]+?)/providers/Microsoft\.Authorization/roleAssignments/") |
        ForEach-Object { $_.Groups['scope'].Value } | Sort-Object -Unique)
    if ($scopes.Count -eq 0) {
        return ''
    }
    $scopeList = ($scopes | ForEach-Object { "  $_" }) -join "`n"
    return "`n`nThe signed-in identity isn't allowed to create role assignments at:`n$scopeList`nThe switch redeploys the job identities' AcrPull and Storage File Data Privileged Contributor assignments, and the jobs deploy only after them, so the replication direction didn't change. Grant Role Based Access Control Administrator, which can be limited to those two roles, or User Access Administrator or Owner, at these scopes or above, or activate the role if it's eligible through Privileged Identity Management. After a few minutes, rerun this script. See 'RBAC requirements' in the README."
}

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
        throw "az $($Arguments -join ' ') failed:`n$errorOutput`n$($output -join [Environment]::NewLine)$(Get-RoleAssignmentHint $errorOutput)"
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

$jobGroups = @($ResourceGroupName)
if ($SecondaryResourceGroupName -and $SecondaryResourceGroupName -ne $ResourceGroupName) {
    $jobGroups += $SecondaryResourceGroupName
}
$jobs = @(foreach ($jobGroup in $jobGroups) {
    $groupJobs = Invoke-AzCli -Arguments @(
        'containerapp', 'job', 'list',
        '--resource-group', $jobGroup,
        '--query', "[?tags.Workload=='azure-files-dr-replication'].[name,location,properties.template.containers[0].image]",
        '--output', 'json'
    ) | ConvertFrom-Json -NoEnumerate
    foreach ($groupJob in @($groupJobs | Where-Object { $_ })) {
        [pscustomobject]@{ Name = $groupJob[0]; Location = $groupJob[1]; Image = $groupJob[2]; ResourceGroup = $jobGroup }
    }
})

if ($jobs.Count -ne 2) {
    $hint = if ($jobGroups.Count -eq 1) { ' If the secondary job is in another resource group, pass -SecondaryResourceGroupName.' } else { '' }
    throw "Expected two replication jobs in $($jobGroups -join ' and '); found $($jobs.Count).$hint"
}

foreach ($job in $jobs) {
    $running = Invoke-AzCli -Arguments @(
        'containerapp', 'job', 'execution', 'list',
        '--resource-group', $job.ResourceGroup,
        '--name', $job.Name,
        '--query', "[?properties.status=='Running'] | length(@)",
        '--output', 'tsv'
    )
    if ([int]$running -gt 0) {
        throw "Job '$($job.Name)' has a running execution. Wait for it to finish before switching direction."
    }
}

$images = @($jobs | ForEach-Object { $_.Image } | Select-Object -Unique)
if ($images.Count -ne 1 -or $images[0] -notmatch '@sha256:[a-fA-F0-9]{64}$') {
    throw 'Both jobs must use the same digest-pinned image before direction can be switched.'
}

if (-not $PSCmdlet.ShouldProcess($jobGroups -join ', ', "Set '$ActiveRegion' as the only scheduled replication direction")) {
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