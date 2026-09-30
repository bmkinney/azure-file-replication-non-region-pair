[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Location = 'southcentralus',
    # Template compiled as a pre-deployment check. Azure CLI deploys the template in the parameter file's using declaration.
    [string]$TemplateFile,
    [string]$ParametersFile = (Join-Path $PSScriptRoot '..\deploy\bicep\main.bicepparam'),
    [string]$ImageContext = (Join-Path $PSScriptRoot '..\src\azcopy-job'),
    [string]$ImageRepository = 'azure-files-dr-azcopy',
    [string]$ImageTag = '10.30.1',
    [string]$ContainerImage,
    [switch]$SkipWhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-RoleAssignmentHint([string]$ErrorText) {
    # Azure checks the right to create role assignments only when it starts the nested deployments that create them,
    # after validation and what-if pass, because they depend on the job identities' principal IDs.
    $flatText = [regex]::Replace($ErrorText, '\s*\r?\n[ \t]*(\|[ \t]?)?', ' ')
    $scopes = @([regex]::Matches($flatText, "roleAssignments/write'\s+at\s+scope\s+'(?<scope>[^'\s]+?)/providers/Microsoft\.Authorization/roleAssignments/") |
        ForEach-Object { $_.Groups['scope'].Value } | Sort-Object -Unique)
    if ($scopes.Count -eq 0) {
        return ''
    }
    $scopeList = ($scopes | ForEach-Object { "  $_" }) -join "`n"
    return "`n`nThe signed-in identity isn't allowed to create role assignments at:`n$scopeList`nThe deployment assigns AcrPull on the registry and Storage File Data Privileged Contributor on the file storage accounts to the replication job identities. Grant Role Based Access Control Administrator, which can be limited to those two roles, or User Access Administrator or Owner, at these scopes or above. Activate the role first if it's eligible through Privileged Identity Management. After a few minutes, rerun this script; the deployment reuses the resources it already created. Alternatively, set createRoleAssignments = false in the parameter file, so that the deployment doesn't create role assignments and an administrator grants them once with scripts/grant-access.ps1. See 'RBAC requirements' in the README."
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
    $whatIfOutput = Invoke-AzCli -Arguments @(
        'deployment', 'sub', 'what-if',
        '--location', $Location,
        '--parameters', $ParametersFile,
        '--result-format', 'FullResourcePayloads'
    )
    $whatIfOutput | Write-Host
    if ($whatIfOutput -match 'NestedDeploymentShortCircuited') {
        Write-Host 'The NestedDeploymentShortCircuited diagnostics are expected: nested deployments that use values created during the deployment, such as the job identities'' IDs, are evaluated only when the deployment runs, so what-if skips their resources, including any role assignments and the right to create them. scripts/inventory.ps1 checks those permissions.'
    }
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
$bootstrapName = "azure-files-dr-bootstrap-$(Get-Date -Format 'yyyyMMddHHmmss')"
$bootstrapArguments = @(
    'deployment', 'sub', 'create',
    '--name', $bootstrapName,
    '--location', $Location,
    '--parameters', $ParametersFile,
    '--parameters'
) + $bootstrapOverrides + @(
    '--output', 'json'
)
$bootstrap = Invoke-AzCli -Arguments $bootstrapArguments | ConvertFrom-Json

# With createRoleAssignments = false, an administrator grants the job identities' roles. Check them before the image
# build and activation, because the jobs can't pull the image or replicate without them.
if ((Get-OutputValue $bootstrap 'createRoleAssignments') -eq $false) {
    $roleCheck = @()
    $checkError = $null
    try {
        $roleCheck = @(& (Join-Path $PSScriptRoot 'grant-access.ps1') -DeploymentName $bootstrapName -WhatIf -PassThru 6> $null)
    } catch {
        $checkError = $_.Exception.Message
    }
    $missing = @($roleCheck | Where-Object Status -ne 'Exists')
    if ($checkError -or $roleCheck.Count -eq 0 -or $missing.Count -gt 0) {
        if ($bootstrapAccess -eq 'Enabled' -and (Get-OutputValue $bootstrap 'registryCreated') -eq $true) {
            # Close the registry that the bootstrap deployment opened for the image build.
            $holdArguments = @(
                'deployment', 'sub', 'create',
                '--name', "azure-files-dr-hold-$(Get-Date -Format 'yyyyMMddHHmmss')",
                '--location', $Location,
                '--parameters', $ParametersFile,
                '--parameters', 'activeRegion=none', 'acrPublicNetworkAccess=Disabled',
                '--output', 'none'
            )
            $null = Invoke-AzCli -Arguments $holdArguments
        }

        $grantCommand = "pwsh ./scripts/grant-access.ps1 -DeploymentName $bootstrapName"
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
        Write-Host 'The deployment does not create them, because createRoleAssignments is false. Ask an administrator who can assign roles on these scopes, such as an Owner, User Access Administrator, or Role Based Access Control Administrator, to run:'
        Write-Host "  $grantCommand"
        if ($missing.Count -gt 0) {
            Write-Host 'or the equivalent Azure CLI commands:'
            foreach ($assignment in $missing) {
                $name = if ($assignment.Name) { " --name $($assignment.Name)" } else { '' }
                Write-Host "  az role assignment create --assignee-object-id $($assignment.PrincipalId) --assignee-principal-type ServicePrincipal --role $($assignment.RoleDefinitionId) --scope $($assignment.Scope)$name"
            }
        }
        Write-Host 'Then rerun this command. Until then, both jobs stay unscheduled, and a registry that the templates create stays closed.'
        $reason = if ($checkError -or $roleCheck.Count -eq 0) { "The job identities' role assignments could not be checked" } else { 'The job identities are missing role assignments' }
        throw "$reason. An administrator must run '$grantCommand', and then you rerun this command."
    }
}

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