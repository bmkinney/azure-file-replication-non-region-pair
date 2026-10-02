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

function Get-PolicyHint([string]$ErrorText) {
    # Policy denials are reported per resource, in JSON whose quotes may be escaped, inside the deployment error.
    $flatText = [regex]::Replace($ErrorText, '\s*\r?\n[ \t]*(\|[ \t]?)?', ' ') -replace '\\"', '"'
    if ($flatText -notmatch 'RequestDisallowedByPolicy') {
        return ''
    }
    $policies = @([regex]::Matches($flatText, '"policyDefinitionDisplayName"\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    $policyList = if ($policies.Count -gt 0) { " ($($policies -join '; '))" } else { '' }
    $hint = "`n`nAzure Policy denied resources that the deployment creates$policyList. The error lists each policy assignment and the resource it denied."
    if ($flatText -match '"expressionValue"\s*:\s*"Microsoft\.OperationalInsights/workspaces"') {
        $hint += " A policy blocks new Log Analytics workspaces. With the existing-resource profile, set primaryLogWorkspaceId and secondaryLogWorkspaceId in the parameter file to existing workspaces, such as a central workspace; the deploying identity needs Log Analytics Contributor on them. See 'Use existing Log Analytics workspaces' in deploy/bicep/README.md."
    }
    return "$hint Alternatively, ask the policy owner for an exemption on the replication resource groups. Then rerun this script; the deployment reuses the resources it already created."
}

function Get-ContainerImageHint([string]$ErrorText) {
    # Container Apps reads a job's image from its registry, over the job subnet's network, when it creates or updates the job.
    $flatText = [regex]::Replace($ErrorText, '\s*\r?\n[ \t]*(\|[ \t]?)?', ' ') -replace '\\"', '"'
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
            return "$hint With registry private endpoints, check that the job VNet has an approved private endpoint for the registry, that its DNS resolves $registry to that endpoint, and that network security groups allow the traffic. With registryPrivateEndpointsEnabled = false, which Basic and Standard registries need, the jobs use the registry's public endpoint: allow outbound HTTPS from the job subnets to $registry and its data endpoint, *.blob.core.windows.net or the registry's dedicated data endpoints, and, if the registry restricts public network access, allow the subnets' outbound IP addresses. In both cases, the job identities sign in to the registry through Microsoft Entra ID, which private endpoints don't cover, so a firewall must also allow login.microsoft.com, login.microsoftonline.com, and the other sign-in endpoints in 'Outbound access through a firewall' in the README. Then rerun this script."
        }
        return "$hint The job subnet couldn't reach $registry, usually because its internet traffic goes through a firewall, or a proxy that inspects TLS. Container Apps needs outbound HTTPS from the job subnets to mcr.microsoft.com, *.data.mcr.microsoft.com, packages.aks.azure.com, and acs-mirror.azureedge.net, and, for the job identities, to *.identity.azure.net, login.microsoftonline.com, *.login.microsoftonline.com, login.microsoft.com, and *.login.microsoft.com. Private endpoints can't replace these, so allow them in the firewall, without TLS inspection, and rerun this script. See 'Outbound access through a firewall' in the README; scripts/inventory.ps1 reports job subnets that route internet traffic through a firewall."
    }
    if ($detail -match '(?i)unauthori[sz]ed|authentication required|denied|forbidden') {
        return "$hint The job identity isn't allowed to pull from $registry. Grant it AcrPull, or Container Registry Repository Reader on a registry with ABAC repository permissions, wait up to 10 minutes for the assignment to take effect, and rerun this script."
    }
    if ($detail -match '(?i)manifest unknown|not found') {
        return "$hint The image isn't in the registry. Check it with az acr manifest show-metadata, or import it as described in 'Put the AzCopy image in the registry' in deploy/bicep/README.md."
    }
    return $hint
}

function Get-DeploymentActiveHint([string]$ErrorText) {
    # Nested deployments have fixed names, so a run that starts before an earlier run's deployments finish collides with them.
    $flatText = [regex]::Replace($ErrorText, '\s*\r?\n[ \t]*(\|[ \t]?)?', ' ') -replace '\\"', '"'
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $details = foreach ($match in [regex]::Matches($flatText, "The deployment with resource id '(?<id>[^']+/providers/Microsoft\.Resources/deployments/(?<name>[^'/]+))' cannot be saved")) {
        if (-not $seen.Add($match.Groups['id'].Value)) {
            continue
        }
        $name = $match.Groups['name'].Value
        $started = [regex]::Match($flatText.Substring($match.Index), "was started at '(?<time>[^']+)'").Groups['time'].Value
        $startedText = if ($started) { ", started at $started" } else { '' }
        $group = [regex]::Match($match.Groups['id'].Value, '(?i)/resourceGroups/(?<group>[^/]+)/').Groups['group'].Value
        if ($group) {
            "  $name in resource group $group$startedText`n    az deployment operation group list --resource-group $group --name $name --output table`n    az deployment group cancel --resource-group $group --name $name"
        } else {
            "  $name$startedText`n    az deployment operation sub list --name $name --output table`n    az deployment sub cancel --name $name"
        }
    }
    if (@($details).Count -eq 0) {
        return ''
    }
    return "`n`nDeployments from an earlier run are still running, so this run couldn't replace them. Stopping this script, or a Cloud Shell session that ends, doesn't stop deployments in Azure. For each one, the first command shows what it's still deploying, and the second cancels it:`n$($details -join "`n")`nWait for them to finish, or cancel them. A Container Apps environment that's still provisioning after 30 minutes usually can't reach the Container Apps outbound dependencies; see 'Outbound access through a firewall' in the README. Then rerun this script; the deployment reuses the resources it already created."
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
        throw "az $($Arguments -join ' ') failed:`n$errorOutput`n$($output -join [Environment]::NewLine)$(Get-RoleAssignmentHint $errorOutput)$(Get-PolicyHint $errorOutput)$(Get-ContainerImageHint $errorOutput)$(Get-DeploymentActiveHint $errorOutput)"
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