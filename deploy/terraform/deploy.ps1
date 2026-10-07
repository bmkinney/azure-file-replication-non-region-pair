#Requires -Version 7.2

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

function Get-ContainerImageHint([string]$ErrorText) {
    # Container Apps reads a job's image from its registry, over the job subnet's network, when it creates or updates the
    # job. Terraform frames its diagnostics with box-drawing characters, which are removed with the line breaks.
    $flatText = [regex]::Replace($ErrorText, '\s*\r?\n[ \t]*([|\u2502][ \t]?)?', ' ') -replace '\\"', '"'
    $match = [regex]::Match($flatText, "image' is invalid with details: 'Invalid value: `"(?<image>[^`"]+)`": (?<detail>.+?)';")
    if (-not $match.Success) {
        return ''
    }
    $image = $match.Groups['image'].Value
    $detail = $match.Groups['detail'].Value
    $registry = ($image -split '/')[0]
    $hint = "`n`nContainer Apps couldn't read the job image $image from its registry ($detail). It reads the image over the job subnet's network when it creates or updates a job."
    if ($detail -match '(?i)\b(EOF|timeout|deadline exceeded|connection reset|connection refused|no route to host|network is unreachable|no such host|tls|x509|certificate|client with IP|not allowed access)\b') {
        if ($registry -match '(?i)\.azurecr\.io$') {
            return "$hint Check that the job VNet has an approved private endpoint for the registry, that its DNS resolves $registry to that endpoint, and that network security groups allow the traffic. The job identities also sign in to the registry through Microsoft Entra ID, which private endpoints don't cover, so a firewall must also allow login.microsoft.com, login.microsoftonline.com, and the other sign-in endpoints in 'Outbound access through a firewall' in the README. Then rerun this script."
        }
        return "$hint The job subnet couldn't reach $registry, usually because its internet traffic goes through a firewall, or a proxy that inspects TLS. Container Apps needs outbound HTTPS from the job subnets to mcr.microsoft.com, *.data.mcr.microsoft.com, packages.aks.azure.com, and acs-mirror.azureedge.net, and, for the job identities, to *.identity.azure.net, login.microsoftonline.com, *.login.microsoftonline.com, login.microsoft.com, and *.login.microsoft.com. Private endpoints can't replace these, so allow them in the firewall, without TLS inspection, and rerun this script. See 'Outbound access through a firewall' in the README."
    }
    if ($detail -match '(?i)unauthori[sz]ed|authentication required|denied|forbidden') {
        return "$hint The job identity isn't allowed to pull from $registry. Grant it AcrPull, or Container Registry Repository Reader on a registry with ABAC repository permissions, wait up to 10 minutes for the assignment to take effect, and rerun this script."
    }
    if ($detail -match '(?i)manifest unknown|not found') {
        return "$hint The image isn't in the registry. Check it with az acr manifest show-metadata, or build or import it again."
    }
    return $hint
}

function Get-OperationExpiredHint([string]$ErrorText) {
    # Container Apps reports a job that its environment couldn't create in time as an expired operation.
    $flatText = [regex]::Replace($ErrorText, '\s*\r?\n[ \t]*([|\u2502][ \t]?)?', ' ') -replace '\\"', '"'
    $jobs = @([regex]::Matches($flatText, "(?i)container app '(?<job>[^']+)'\. Error details: Operation expired") | ForEach-Object { $_.Groups['job'].Value } | Select-Object -Unique)
    if ($jobs.Count -eq 0) {
        return ''
    }
    $details = foreach ($job in $jobs) {
        $group = [regex]::Match($flatText, "Resource Group Name: `"(?<group>[^`"]+)`"[\s|\u2502]+Job Name: `"$([regex]::Escape($job))`"").Groups['group'].Value
        if (-not $group) {
            $group = '<resource-group>'
        }
        "  $job in resource group $group`n    az containerapp env list --resource-group $group --query `"[].{name:name, location:location, state:properties.provisioningState}`" --output table`n    az containerapp job delete --resource-group $group --name $job --yes"
    }
    return "`n`nContainer Apps couldn't finish creating these jobs before the operation expired. Usually their Container Apps environment can't reach all of the Container Apps outbound dependencies, for example because a firewall allows only some of them, or the environment is unhealthy after an earlier failed or canceled run. Allow outbound HTTPS from both job subnets to every endpoint in 'Outbound access through a firewall' in the README. Terraform can't create a job that already exists outside its state, so delete each failed job before you rerun this script. For each job, the first command shows the state of the environments in its resource group, and the second deletes the job:`n$($details -join "`n")`nIf an environment is Failed, delete it as well with az containerapp env delete, and wait until az containerapp env list no longer shows it, because a rerun fails while it's still being deleted. Then rerun this script; the environments and jobs hold no data, and Terraform recreates them."
}

function Get-EnvironmentNotReadyHint([string]$ErrorText) {
    # Container Apps refuses new jobs in an environment that's being deleted or hasn't finished provisioning, for
    # example when this script reruns before an environment that was deleted to recreate it is gone. Terraform
    # starts each diagnostic line with a box-drawing character, and PowerShell can reflow redirected error text so
    # that one lands inside a line, so all of them are removed with the line breaks.
    $flatText = [regex]::Replace($ErrorText, '\s*\r?\n[ \t]*(?:\|[ \t]*)?', ' ') -replace '\s*\u2502\s*', ' '
    $states = @([regex]::Matches($flatText, "(?i)not ready for container app creation as it is in state '(?<state>[^']+)'") | ForEach-Object { $_.Groups['state'].Value } | Sort-Object -Unique)
    if ($states.Count -eq 0) {
        return ''
    }
    $hint = ''
    if ($states -contains 'ScheduledForDelete') {
        $hint += "`n`nA Container Apps environment is still being deleted, so Azure can't create a job in it, and a rerun fails this way until the deletion finishes. This command lists the environments that are still being deleted:`n    az containerapp env list --query `"[?properties.provisioningState=='ScheduledForDelete'].id`" --output tsv`nRerun this script after it no longer lists the environment; Terraform then recreates it. If an environment stays in this state, its deletion is stuck; see 'Container Apps deployment problems' in the README."
    }
    $pending = @($states | Where-Object { $_ -ne 'ScheduledForDelete' })
    if ($pending.Count -gt 0) {
        $hint += "`n`nA Container Apps environment isn't ready for jobs (state $($pending -join ', ')). Wait until its provisioning state is Succeeded, and rerun this script. If it's Failed, delete it with az containerapp env delete, wait until az containerapp env list no longer shows it, and rerun; Terraform then recreates it."
    }
    return $hint
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
        throw "terraform $($Arguments -join ' ') failed:`n$flatError`n$($output -join [Environment]::NewLine)$(Get-RoleAssignmentHint $flatError)$(Get-ContainerImageHint $errorOutput)$(Get-OperationExpiredHint $errorOutput)$(Get-EnvironmentNotReadyHint $errorOutput)"
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
