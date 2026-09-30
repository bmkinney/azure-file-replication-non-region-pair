[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Bicep')]
param(
    [Parameter(Mandatory)]
    [ValidateSet('primary', 'secondary')]
    [string]$ActiveRegion,

    [Parameter(Mandatory)]
    [switch]$WritesFenced,

    [string]$ResourceGroupName,

    # Resource group of the secondary-region job when it differs from -ResourceGroupName.
    [Parameter(ParameterSetName = 'Bicep')]
    [string]$SecondaryResourceGroupName,

    [Parameter(ParameterSetName = 'Bicep')]
    [string]$Location = 'southcentralus',
    [Parameter(ParameterSetName = 'Bicep')]
    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\deploy\bicep\main.bicepparam'),
    # Checked for existence only. Azure CLI deploys the template in the parameter file's using declaration.
    [Parameter(ParameterSetName = 'Bicep')]
    [string]$TemplateFile,

    [Parameter(Mandatory, ParameterSetName = 'Terraform')]
    [string]$TerraformDirectory,

    [Parameter(ParameterSetName = 'Terraform')]
    [string]$VarFile,

    [Parameter(ParameterSetName = 'Terraform')]
    [string]$BackendConfig
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
    return "`n`nThe signed-in identity isn't allowed to create role assignments at:`n$scopeList`nThe switch redeploys the job identities' AcrPull and Storage File Data Privileged Contributor assignments, and the jobs deploy only after them, so the replication direction didn't change. Grant Role Based Access Control Administrator, which can be limited to those two roles, or User Access Administrator or Owner, at these scopes or above, or activate the role if it's eligible through Privileged Identity Management. After a few minutes, rerun this script. Alternatively, set createRoleAssignments = false in the parameter file, so that deployments and switches don't create role assignments; the job identities keep the roles that they already have. See 'RBAC requirements' in the README."
}

function Get-OutputValue($Deployment, [string]$Name) {
    # Deployments of earlier template versions lack newer outputs.
    $output = $Deployment.properties.outputs.PSObject.Properties[$Name]
    if ($output) {
        return $output.Value.value
    }
    return $null
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

function Invoke-Terraform {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $WhatIfPreference = $false
    $errorPath = [IO.Path]::GetTempFileName()
    try {
        $output = & terraform @Arguments 2> $errorPath
        $exitCode = $LASTEXITCODE
        $errorOutput = [IO.File]::ReadAllText($errorPath)
    } finally {
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -ne 0) {
        $flatError = [regex]::Replace($errorOutput, '\s*\r?\n[ \t]*(\|[ \t]?)?', ' ').Trim()
        throw "terraform $($Arguments -join ' ') failed:`n$flatError`n$($output -join [Environment]::NewLine)$(Get-RoleAssignmentHint $flatError)"
    }
    return ($output -join [Environment]::NewLine)
}

function Get-TerraformOutputValue($Outputs, [string]$Name) {
    $property = $Outputs.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value.value
    }
    return $null
}

if (-not $WritesFenced) {
    throw 'WritesFenced is required. Stop application writes before changing replication direction.'
}
if ($PSCmdlet.ParameterSetName -eq 'Terraform') {
    if ([string]::IsNullOrWhiteSpace($VarFile)) {
        $VarFile = Join-Path $TerraformDirectory 'terraform.tfvars'
    }
    $initArguments = @("-chdir=$TerraformDirectory", 'init', '-input=false', '-no-color')
    if ($BackendConfig) {
        $initArguments += "-backend-config=$BackendConfig"
    }
    $null = Invoke-Terraform -Arguments $initArguments
    $outputs = Invoke-Terraform -Arguments @("-chdir=$TerraformDirectory", 'output', '-json') | ConvertFrom-Json
    $terraformResourceGroupName = Get-TerraformOutputValue $outputs 'resource_group_name'
    $jobGroup = if ($ResourceGroupName) { $ResourceGroupName } else { $terraformResourceGroupName }
    if ([string]::IsNullOrWhiteSpace($jobGroup)) {
        throw "Terraform output 'resource_group_name' was not found. Pass -ResourceGroupName."
    }

    $jobNames = @(
        (Get-TerraformOutputValue $outputs 'primary_job_name'),
        (Get-TerraformOutputValue $outputs 'secondary_job_name')
    ) | Where-Object { $_ }
    if ($jobNames.Count -ne 2) {
        throw "Terraform output must include primary_job_name and secondary_job_name."
    }

    $jobs = foreach ($jobName in $jobNames) {
        $job = Invoke-AzCli -Arguments @(
            'containerapp', 'job', 'show',
            '--resource-group', $jobGroup,
            '--name', $jobName,
            '--query', '{name:name,location:location,image:properties.template.containers[0].image}',
            '--output', 'json'
        ) | ConvertFrom-Json
        [pscustomobject]@{ Name = $job.name; Location = $job.location; Image = $job.image; ResourceGroup = $jobGroup }
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

    if (-not $PSCmdlet.ShouldProcess($jobGroup, "Set '$ActiveRegion' as the only scheduled replication direction")) {
        return
    }

    $applyArguments = @(
        "-chdir=$TerraformDirectory", 'apply',
        '-input=false', '-no-color', '-auto-approve',
        "-var-file=$VarFile",
        '-var', "container_image=$($images[0])",
        '-var', "active_region=$ActiveRegion",
        '-var', 'acr_public_network_access_enabled=false'
    )
    $null = Invoke-Terraform -Arguments $applyArguments
    $postOutputs = Invoke-Terraform -Arguments @("-chdir=$TerraformDirectory", 'output', '-json') | ConvertFrom-Json
    $activeJob = if ($ActiveRegion -eq 'primary') {
        Get-TerraformOutputValue $postOutputs 'primary_job_name'
    } else {
        Get-TerraformOutputValue $postOutputs 'secondary_job_name'
    }

    Write-Host "Replication direction switched. Active scheduled job: $activeJob"
    Write-Host 'Application writes remain fenced until validation is complete.'

    if ((Get-TerraformOutputValue $postOutputs 'create_role_assignments') -eq $false) {
        $grantCommand = "pwsh ./scripts/grant-access.ps1 -TerraformDirectory $TerraformDirectory"
        try {
            $missing = @(& (Join-Path $PSScriptRoot 'grant-access.ps1') -TerraformDirectory $TerraformDirectory -WhatIf -PassThru 6> $null | Where-Object Status -ne 'Exists')
            if ($missing.Count -gt 0) {
                $list = ($missing | ForEach-Object { "  $($_.Status): $($_.RoleName) for $($_.PrincipalName) on $($_.Scope)" }) -join "`n"
                Write-Warning "The job identities are missing role assignments, so replication in the new direction fails until an administrator runs '$grantCommand':`n$list"
            }
        } catch {
            Write-Warning "Could not check the job identities' role assignments. Check them with '$grantCommand -WhatIf'. $($_.Exception.Message)"
        }
    }
    return
}

if ([string]::IsNullOrWhiteSpace($ResourceGroupName)) {
    $ResourceGroupName = 'rg-azure-files-replication-demo'
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
$deploymentName = "azure-files-dr-switch-$(Get-Date -Format 'yyyyMMddHHmmss')"
$deploymentArguments = @(
    'deployment', 'sub', 'create',
    '--name', $deploymentName,
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

# When an administrator grants the job identities' roles, the switch neither needs nor changes them. A missing one
# fails the new direction's executions, so report it without undoing the switch.
if ((Get-OutputValue $deployment 'createRoleAssignments') -eq $false) {
    $grantCommand = "pwsh ./scripts/grant-access.ps1 -DeploymentName $deploymentName"
    try {
        $missing = @(& (Join-Path $PSScriptRoot 'grant-access.ps1') -DeploymentName $deploymentName -WhatIf -PassThru 6> $null | Where-Object Status -ne 'Exists')
        if ($missing.Count -gt 0) {
            $list = ($missing | ForEach-Object { "  $($_.Status): $($_.RoleName) for $($_.PrincipalName) on $($_.Scope)" }) -join "`n"
            Write-Warning "The job identities are missing role assignments, so replication in the new direction fails until an administrator runs '$grantCommand':`n$list"
        }
    } catch {
        Write-Warning "Could not check the job identities' role assignments. Check them with '$grantCommand -WhatIf'. $($_.Exception.Message)"
    }
}