[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TerraformDirectory = $PSScriptRoot,
    [string]$VarFile,
    [string]$BackendConfig,
    [string]$ImageContext = (Join-Path $PSScriptRoot '..\..\src\azcopy-job'),
    [string]$ImageRepository = 'azure-files-dr-azcopy',
    [string]$ImageTag = '10.30.1',
    [string]$ContainerImage,
    [switch]$SkipPlan,
    [switch]$SkipInit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($VarFile)) {
    $VarFile = Join-Path $TerraformDirectory 'terraform.tfvars'
}

function Get-RoleAssignmentHint([string]$ErrorText) {
    $flatText = [regex]::Replace($ErrorText, '\s*\r?\n[ \t]*(\|[ \t]?)?', ' ')
    $scopes = @([regex]::Matches($flatText, "roleAssignments/write'\s+at\s+scope\s+'(?<scope>[^'\s]+?)/providers/Microsoft\.Authorization/roleAssignments/") |
        ForEach-Object { $_.Groups['scope'].Value } | Sort-Object -Unique)
    if ($scopes.Count -eq 0) {
        return ''
    }
    $scopeList = ($scopes | ForEach-Object { "  $_" }) -join "`n"
    return "`n`nThe signed-in identity isn't allowed to create role assignments at:`n$scopeList`nThe deployment assigns AcrPull on the registry and Storage File Data Privileged Contributor on the file storage accounts to the replication job identities. Grant Role Based Access Control Administrator, which can be limited to those two roles, or User Access Administrator or Owner at these scopes or above. After a few minutes, rerun this script. Alternatively, set create_role_assignments = false in terraform.tfvars and have an administrator run scripts/grant-access.ps1."
}

function Invoke-AzCli {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $WhatIfPreference = $false
    $errorPath = [IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments --only-show-errors 2> $errorPath
        $exitCode = $LASTEXITCODE
        $errorOutput = [IO.File]::ReadAllText($errorPath)
    } finally {
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }

    if ($exitCode -ne 0) {
        $flatError = [regex]::Replace($errorOutput, '\s*\r?\n[ \t]*(\|[ \t]?)?', ' ').Trim()
        throw "az $($Arguments -join ' ') failed:`n$flatError`n$($output -join [Environment]::NewLine)"
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

function Get-OutputValue($Outputs, [string]$Name) {
    $property = $Outputs.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value.value
    }
    return $null
}

function Get-VarArguments([hashtable]$Vars) {
    $arguments = @()
    foreach ($key in $Vars.Keys) {
        $value = $Vars[$key]
        if ($null -ne $value) {
            if ($value -is [bool]) {
                $value = $value.ToString().ToLowerInvariant()
            }
            $arguments += @('-var', "$key=$value")
        }
    }
    return $arguments
}

if ($ContainerImage -and $ContainerImage -notmatch '@sha256:[a-fA-F0-9]{64}$') {
    throw 'ContainerImage must be pinned by digest: <registry>/<repository>@sha256:<64 hex characters>.'
}

$null = Invoke-AzCli -Arguments @('account', 'show', '--output', 'none')

if (-not $SkipInit) {
    $initArguments = @("-chdir=$TerraformDirectory", 'init', '-input=false', '-no-color')
    if ($BackendConfig) {
        $initArguments += "-backend-config=$BackendConfig"
    }
    $null = Invoke-Terraform -Arguments $initArguments
}

$null = Invoke-Terraform -Arguments @("-chdir=$TerraformDirectory", 'validate', '-no-color')

$bootstrapPublic = -not [bool]$ContainerImage
$bootstrapVars = @{
    active_region                     = 'none'
    acr_public_network_access_enabled = $bootstrapPublic
    container_image                   = $ContainerImage
}

if (-not $SkipPlan) {
    $planArguments = @("-chdir=$TerraformDirectory", 'plan', '-input=false', '-no-color', "-var-file=$VarFile") + (Get-VarArguments $bootstrapVars)
    Invoke-Terraform -Arguments $planArguments | Write-Host
}

if (-not $PSCmdlet.ShouldProcess($TerraformDirectory, 'Deploy the Terraform replication foundation and activate the primary region')) {
    return
}

$bootstrapArguments = @("-chdir=$TerraformDirectory", 'apply', '-input=false', '-no-color', '-auto-approve', "-var-file=$VarFile") + (Get-VarArguments $bootstrapVars)
$null = Invoke-Terraform -Arguments $bootstrapArguments
$outputs = Invoke-Terraform -Arguments @("-chdir=$TerraformDirectory", 'output', '-json') | ConvertFrom-Json

if ((Get-OutputValue $outputs 'create_role_assignments') -eq $false) {
    $roleCheck = @()
    $checkError = $null
    try {
        $roleCheck = @(& (Join-Path $PSScriptRoot '..\..\scripts\grant-access.ps1') -TerraformDirectory $TerraformDirectory -WhatIf -PassThru 6> $null)
    } catch {
        $checkError = $_.Exception.Message
    }
    $missing = @($roleCheck | Where-Object Status -ne 'Exists')
    if ($checkError -or $roleCheck.Count -eq 0 -or $missing.Count -gt 0) {
        if ($bootstrapPublic -and (Get-OutputValue $outputs 'registry_created') -eq $true) {
            $holdVars = @{
                active_region                     = 'none'
                acr_public_network_access_enabled = $false
                container_image                   = $ContainerImage
            }
            $holdArguments = @("-chdir=$TerraformDirectory", 'apply', '-input=false', '-no-color', '-auto-approve', "-var-file=$VarFile") + (Get-VarArguments $holdVars)
            $null = Invoke-Terraform -Arguments $holdArguments
        }

        $grantCommand = "pwsh ./scripts/grant-access.ps1 -TerraformDirectory $TerraformDirectory"
        Write-Host ''
        if ($checkError -or $roleCheck.Count -eq 0) {
            Write-Host "Could not check the job identities' role assignments, so the schedule was not activated. $checkError" -ForegroundColor Yellow
        } else {
            Write-Host 'The job identities are missing role assignments, so the schedule was not activated:' -ForegroundColor Yellow
            foreach ($assignment in $missing) {
                $detail = if ($assignment.Detail) { " ($($assignment.Detail))" } else { '' }
                Write-Host "  $($assignment.Status): $($assignment.RoleName) for $($assignment.PrincipalName) on $($assignment.Scope)$detail"
            }
        }
        Write-Host ''
        Write-Host 'The deployment does not create them, because create_role_assignments is false. Ask an administrator who can assign roles on these scopes to run:'
        Write-Host "  $grantCommand"
        if ($missing.Count -gt 0) {
            Write-Host 'or the equivalent Azure CLI commands:'
            foreach ($assignment in $missing) {
                $name = if ($assignment.Name) { " --name $($assignment.Name)" } else { '' }
                Write-Host "  az role assignment create --assignee-object-id $($assignment.PrincipalId) --assignee-principal-type ServicePrincipal --role $($assignment.RoleDefinitionId) --scope $($assignment.Scope)$name"
            }
        }
        Write-Host 'Then rerun this command. Until then, both jobs stay unscheduled, and the registry stays closed.'
        $reason = if ($checkError -or $roleCheck.Count -eq 0) { "The job identities' role assignments could not be checked" } else { 'The job identities are missing role assignments' }
        throw "$reason. An administrator must run '$grantCommand', and then you rerun this command."
    }
}

$registryName = Get-OutputValue $outputs 'registry_name'
$registryLoginServer = Get-OutputValue $outputs 'registry_login_server'
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
        "${registryLoginServer}/${ImageRepository}:${ImageTag}",
        '--registry', $registryName,
        '--query', 'digest',
        '--output', 'tsv'
    )
    $image = "${registryLoginServer}/${ImageRepository}@$($digest.Trim())"
}

$finalVars = @{
    container_image                   = $image
    active_region                     = 'primary'
    acr_public_network_access_enabled = $false
}
$finalArguments = @("-chdir=$TerraformDirectory", 'apply', '-input=false', '-no-color', '-auto-approve', "-var-file=$VarFile") + (Get-VarArguments $finalVars)
$null = Invoke-Terraform -Arguments $finalArguments
$finalOutputs = Invoke-Terraform -Arguments @("-chdir=$TerraformDirectory", 'output', '-json') | ConvertFrom-Json

Write-Host "Primary scheduled job: $(Get-OutputValue $finalOutputs 'primary_job_name')"
Write-Host "Secondary standby job: $(Get-OutputValue $finalOutputs 'secondary_job_name')"
Write-Host "Monitoring action group: $(Get-OutputValue $finalOutputs 'monitoring_action_group_id')"
Write-Host "Pinned image: $image"
Write-Host 'Record active_region = "primary", the pinned container_image, and acr_public_network_access_enabled = false in terraform.tfvars.'
