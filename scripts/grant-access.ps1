[CmdletBinding(SupportsShouldProcess, DefaultParameterSetName = 'Deployment')]
param(
    # A subscription deployment of either template whose jobRoleAssignments output lists the assignments, such as the
    # bootstrap deployment that scripts/deploy.ps1 names when it stops for them.
    [Parameter(Mandatory, ParameterSetName = 'Deployment')]
    [string]$DeploymentName,

    # Resource IDs of existing user-assigned identities of the jobs, to grant their roles before the first deployment.
    [Parameter(Mandatory, ParameterSetName = 'Resources')]
    [string[]]$IdentityId,

    # Resource IDs of the storage accounts that the jobs replicate between.
    [Parameter(ParameterSetName = 'Resources')]
    [string[]]$StorageAccountId = @(),

    # Resource ID of the registry that the jobs pull the AzCopy image from.
    [Parameter(ParameterSetName = 'Resources')]
    [string]$RegistryId,

    # Also returns one object per role assignment.
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Creates only role assignments; with -WhatIf it only reads them. No Microsoft Graph calls are made, so the job
# identities are passed by object ID, and the signed-in identity doesn't need directory read permissions. It grants
# only the job roles, whatever a deployment's outputs list, so review the identities and scopes that it shows.

function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments)

    # -WhatIf would otherwise skip the stderr redirection and the temp-file cleanup below.
    $WhatIfPreference = $false

    # Azure CLI writes warnings to stderr; keeping them out of stdout protects JSON parsing.
    $errorPath = [IO.Path]::GetTempFileName()
    try {
        $output = & az @Arguments --only-show-errors 2> $errorPath
        $exitCode = $LASTEXITCODE
        $errorText = [IO.File]::ReadAllText($errorPath)
    } finally {
        Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue
    }

    # Error output can arrive wrapped over several lines; one line keeps it readable in the summary.
    $flatError = [regex]::Replace($errorText, '\s*\r?\n[ \t]*(\|[ \t]?)?', ' ').Trim()
    [pscustomobject]@{
        Succeeded = $exitCode -eq 0
        Text      = ($output -join [Environment]::NewLine).Trim()
        Error     = if ($exitCode -ne 0) { if ($flatError) { $flatError } else { "Azure CLI exited with code $exitCode." } } else { $null }
    }
}

function Get-Property {
    param($Object, [Parameter(Mandatory)][string]$Name)

    if ($null -eq $Object) {
        return $null
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) {
        return $property.Value
    }
    return $null
}

function Split-List([string[]]$Values) {
    return @($Values | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$fileDataRole = @{ Id = '69566ab7-960f-475b-8e7c-b3118f30c6bd'; Name = 'Storage File Data Privileged Contributor' }
$acrPullRole = @{ Id = '7f951dda-4ed3-4680-a7ca-43fe172d538d'; Name = 'AcrPull' }
# Registries with ABAC repository permissions ignore AcrPull.
$repositoryReaderRole = @{ Id = 'b93aa761-3e63-49ed-ac28-beffa264f7ac'; Name = 'Container Registry Repository Reader' }
$storagePattern = '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.Storage/storageAccounts/[^/]+$'
$registryPattern = '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ContainerRegistry/registries/[^/]+$'
$identityPattern = '^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\.ManagedIdentity/userAssignedIdentities/[^/]+$'
$guidPattern = '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'

# The only roles that the job identities need, with the resource type that each one is granted on.
$jobRoles = @{}
$jobRoles[$fileDataRole.Id] = @{ Role = $fileDataRole; ScopePattern = $storagePattern }
$jobRoles[$acrPullRole.Id] = @{ Role = $acrPullRole; ScopePattern = $registryPattern }

$account = Invoke-Az -Arguments @('account', 'show', '--output', 'json')
if (-not $account.Succeeded) {
    throw "Sign in with az login before granting access. $($account.Error)"
}
$subscription = if ($account.Text) { $account.Text | ConvertFrom-Json } else { [pscustomobject]@{ name = 'the current subscription'; id = '' } }

$required = [System.Collections.Generic.List[object]]::new()
if ($PSCmdlet.ParameterSetName -eq 'Deployment') {
    $source = "deployment $DeploymentName"
    $deployment = Invoke-Az -Arguments @(
        'deployment', 'sub', 'show',
        '--name', $DeploymentName,
        '--query', '{state: properties.provisioningState, assignments: properties.outputs.jobRoleAssignments.value}',
        '--output', 'json'
    )
    if (-not $deployment.Succeeded) {
        throw "Could not read subscription deployment '$DeploymentName' in $($subscription.name). $($deployment.Error)"
    }
    $details = $deployment.Text | ConvertFrom-Json
    $listed = Get-Property $details 'assignments'
    if ((Get-Property $details 'state') -ne 'Succeeded' -or $null -eq $listed) {
        throw "Deployment '$DeploymentName' ($(Get-Property $details 'state')) doesn't list the job identities' role assignments. Name a successful deployment of the current templates, such as the bootstrap deployment that scripts/deploy.ps1 names, or grant the roles with -IdentityId, -StorageAccountId, and -RegistryId."
    }

    # Whoever deploys controls the outputs, so they can't widen the grant: only the job roles, on their resource types
    # in this subscription, for user-assigned identities in it. The names shown come from Azure, not from the outputs.
    $identityList = Invoke-Az -Arguments @('identity', 'list', '--query', '[].{id: id, name: name, principalId: principalId}', '--output', 'json')
    if (-not $identityList.Succeeded) {
        throw "Could not list the user-assigned identities in $($subscription.name) to confirm the job identities of deployment '$DeploymentName'. $($identityList.Error)"
    }
    $identitiesByPrincipal = @{}
    foreach ($identity in @($identityList.Text | ConvertFrom-Json)) {
        $principalId = [string](Get-Property $identity 'principalId')
        if ($principalId) {
            $identitiesByPrincipal[$principalId.ToLowerInvariant()] = $identity
        }
    }
    $subscriptionPrefix = "/subscriptions/$($subscription.id)/"
    $rejected = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($listed)) {
        $scope = [string](Get-Property $entry 'scope')
        $principalId = [string](Get-Property $entry 'principalId')
        $roleId = [string](Get-Property $entry 'roleDefinitionId')
        $name = [string](Get-Property $entry 'name')
        $jobRole = $jobRoles[$roleId.ToLowerInvariant()]
        $identity = $identitiesByPrincipal[$principalId.ToLowerInvariant()]
        if (-not $jobRole -or $scope -notmatch $jobRole.ScopePattern -or -not $scope.StartsWith($subscriptionPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $rejected.Add("  role $roleId on $scope for principal $principalId")
        } elseif (-not $identity) {
            $rejected.Add("  $($jobRole.Role.Name) on $scope for principal $principalId, which isn't a user-assigned identity in this subscription")
        } else {
            $required.Add([pscustomobject]@{
                Name          = if ($name -match $guidPattern) { $name } else { '' }
                Scope         = $scope
                PrincipalId   = $principalId
                PrincipalName = [string](Get-Property $identity 'name')
                IdentityId    = [string](Get-Property $identity 'id')
                RoleId        = $jobRole.Role.Id
                RoleName      = $jobRole.Role.Name
            })
        }
    }
    if ($rejected.Count -gt 0) {
        throw "Deployment '$DeploymentName' lists role assignments that the replication jobs don't need, so nothing was granted:`n$($rejected -join "`n")`nThe job identities need only Storage File Data Privileged Contributor on storage accounts and AcrPull on registries in this subscription, and they're user-assigned identities in it. Find out who changed the deployment before you grant any access."
    }
} else {
    $identityIds = @(Split-List $IdentityId)
    $storageIds = @(Split-List $StorageAccountId)
    $registryIds = @(Split-List @($RegistryId))
    if ($storageIds.Count -eq 0 -and $registryIds.Count -eq 0) {
        throw 'Name the storage accounts with -StorageAccountId, the registry with -RegistryId, or both.'
    }
    foreach ($id in $storageIds) {
        if ($id -notmatch $storagePattern) {
            throw "'$id' isn't a storage account resource ID."
        }
    }
    foreach ($id in $registryIds) {
        if ($id -notmatch $registryPattern) {
            throw "'$id' isn't a container registry resource ID."
        }
    }

    $source = 'the named identities and resources'
    $identities = foreach ($id in $identityIds) {
        if ($id -notmatch $identityPattern) {
            throw "'$id' isn't a user-assigned managed identity resource ID."
        }
        $identity = Invoke-Az -Arguments @('identity', 'show', '--ids', $id, '--query', '{principalId: principalId, name: name}', '--output', 'json')
        if (-not $identity.Succeeded) {
            throw "Could not read identity '$id'. $($identity.Error)"
        }
        $identity.Text | ConvertFrom-Json | Add-Member -NotePropertyName id -NotePropertyValue $id -PassThru
    }
    $targets = @($storageIds | ForEach-Object { @{ Scope = $_; Role = $fileDataRole } }) + @($registryIds | ForEach-Object { @{ Scope = $_; Role = $acrPullRole } })
    foreach ($target in $targets) {
        foreach ($identity in @($identities)) {
            # Azure generates the names, because the templates' names depend on values known only during a deployment.
            $required.Add([pscustomobject]@{
                Name          = ''
                Scope         = $target.Scope
                PrincipalId   = [string]$identity.principalId
                PrincipalName = [string]$identity.name
                IdentityId    = [string]$identity.id
                RoleId        = $target.Role.Id
                RoleName      = $target.Role.Name
            })
        }
    }
}

# A registry with ABAC repository permissions needs Container Registry Repository Reader instead of AcrPull.
$abacRegistries = @{}
foreach ($scope in @($required | Where-Object { $_.Scope -match $registryPattern } | ForEach-Object { $_.Scope.ToLowerInvariant() } | Sort-Object -Unique)) {
    $mode = Invoke-Az -Arguments @('acr', 'show', '--ids', $scope, '--query', 'roleAssignmentMode', '--output', 'tsv')
    if ($mode.Succeeded) {
        $abacRegistries[$scope] = $mode.Text -eq 'AbacRepositoryPermissions'
    } else {
        Write-Warning "Could not read the permissions mode of registry '$scope', so AcrPull is assumed. $($mode.Error)"
    }
}

$assignments = [ordered]@{}
foreach ($assignment in $required) {
    if ($abacRegistries[$assignment.Scope.ToLowerInvariant()] -and $assignment.RoleId -eq $acrPullRole.Id) {
        $assignment.RoleId = $repositoryReaderRole.Id
        $assignment.RoleName = $repositoryReaderRole.Name
        $assignment.Name = ''
    }
    # The same identity can serve both jobs.
    $key = "$($assignment.Scope)|$($assignment.PrincipalId)|$($assignment.RoleId)".ToLowerInvariant()
    if (-not $assignments.Contains($key)) {
        $assignments[$key] = $assignment
    }
}

$heldRoles = @{}
function Get-HeldRoles([string]$Scope, [string]$PrincipalId) {
    $key = "$Scope|$PrincipalId".ToLowerInvariant()
    if (-not $heldRoles.ContainsKey($key)) {
        # Assignments inherited from a resource group or the subscription also count.
        $list = Invoke-Az -Arguments @(
            'role', 'assignment', 'list',
            '--scope', $Scope,
            '--assignee-object-id', $PrincipalId,
            '--include-inherited',
            '--fill-principal-name', 'false',
            '--fill-role-definition-name', 'false',
            '--query', '[].roleDefinitionId',
            '--output', 'tsv'
        )
        $heldRoles[$key] = [pscustomobject]@{
            Roles = if ($list.Succeeded) { @($list.Text -split '\r?\n' | Where-Object { $_ } | ForEach-Object { ($_ -split '/')[-1].ToLowerInvariant() }) } else { @() }
            Error = $list.Error
        }
    }
    return $heldRoles[$key]
}

$checkOnly = [bool]$WhatIfPreference
$results = foreach ($assignment in $assignments.Values) {
    $held = Get-HeldRoles $assignment.Scope $assignment.PrincipalId
    $status = ''
    $detail = ''
    if ($held.Roles -contains $assignment.RoleId.ToLowerInvariant()) {
        $status = 'Exists'
    } elseif ($checkOnly) {
        $status = if ($held.Error) { 'Not verified' } else { 'Missing' }
        $detail = if ($held.Error) { $held.Error } else { '' }
    } elseif ($PSCmdlet.ShouldProcess("$($assignment.RoleName) for $($assignment.PrincipalName) on $($assignment.Scope)", 'Create role assignment')) {
        $arguments = @(
            'role', 'assignment', 'create',
            '--assignee-object-id', $assignment.PrincipalId,
            '--assignee-principal-type', 'ServicePrincipal',
            '--role', $assignment.RoleId,
            '--scope', $assignment.Scope,
            '--description', 'Azure Files replication job identity',
            '--output', 'none'
        )
        if ($assignment.Name) {
            $arguments += @('--name', $assignment.Name)
        }
        $created = Invoke-Az -Arguments $arguments
        if ($created.Succeeded) {
            $status = 'Created'
        } elseif ($created.Error -match 'RoleAssignmentExists') {
            $status = 'Exists'
        } else {
            $status = 'Failed'
            $detail = $created.Error
        }
    } else {
        $status = 'Skipped'
    }
    $identitySegments = $assignment.IdentityId -split '/'
    [pscustomobject]@{
        Status           = $status
        RoleName         = $assignment.RoleName
        PrincipalName    = $assignment.PrincipalName
        # The identity's resource group and name, so that an administrator can tell it from a look-alike.
        Identity         = if ($identitySegments.Count -ge 9) { "$($identitySegments[4])/$($identitySegments[8])" } else { $assignment.PrincipalName }
        Scope            = $assignment.Scope
        PrincipalId      = $assignment.PrincipalId
        IdentityId       = $assignment.IdentityId
        RoleDefinitionId = $assignment.RoleId
        Name             = $assignment.Name
        Detail           = $detail
    }
}
$results = @($results)

Write-Host ''
Write-Host "Job identity role assignments from $source" -ForegroundColor Cyan
Write-Host "Subscription: $($subscription.name) ($($subscription.id))"
$results | Format-Table -Property Status, RoleName, Identity, Scope -AutoSize -Wrap | Out-String -Width 240 | Write-Host

$failed = @($results | Where-Object Status -eq 'Failed')
$missing = @($results | Where-Object { $_.Status -in 'Missing', 'Not verified' })
if ($failed.Count -gt 0) {
    $details = ($failed | ForEach-Object { "  $($_.RoleName) for $($_.PrincipalName) on $($_.Scope): $($_.Detail)" }) -join "`n"
    $hint = if ($failed | Where-Object { $_.Detail -match '(?i)AuthorizationFailed|does not have (authorization|permission)|roleAssignments/write' }) {
        "`nRun this script as an identity that can create role assignments on these scopes, such as Owner, User Access Administrator, or Role Based Access Control Administrator, which can be limited to these roles. Activate the role first if it's eligible through Privileged Identity Management."
    } else { '' }
    throw "$($failed.Count) of $($results.Count) role assignments couldn't be created:`n$details$hint"
}
if ($checkOnly -and $missing.Count -gt 0) {
    Write-Host "$($missing.Count) of $($results.Count) role assignments are missing or couldn't be read. Run without -WhatIf, as an identity that can create role assignments on these scopes, to create them."
} elseif (@($results | Where-Object Status -eq 'Created').Count -gt 0) {
    Write-Host 'Role assignments can take up to 10 minutes to take effect. Then rerun scripts/deploy.ps1 to finish the deployment and activate the schedule.'
}

if ($PassThru) {
    $results
}
