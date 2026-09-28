$ErrorActionPreference = 'Stop'

# Runs scripts/grant-access.ps1 against a fake Azure CLI; no Azure calls are made.

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$grantScript = Join-Path $repositoryRoot 'scripts/grant-access.ps1'
$isolatedTemp = Join-Path ([IO.Path]::GetTempPath()) "grant-access-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $isolatedTemp -Force | Out-Null

$subscription = '/subscriptions/00000000-0000-0000-0000-000000000000'
$storageA = "$subscription/resourceGroups/rg-storage/providers/Microsoft.Storage/storageAccounts/stprimary"
$storageB = "$subscription/resourceGroups/rg-storage/providers/Microsoft.Storage/storageAccounts/stsecondary"
$registry = "$subscription/resourceGroups/rg-registry/providers/Microsoft.ContainerRegistry/registries/acrtest"
$identityRoot = "$subscription/resourceGroups/rg-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities"
$fileRoleId = '69566ab7-960f-475b-8e7c-b3118f30c6bd'
$pullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
$readerRoleId = 'b93aa761-3e63-49ed-ac28-beffa264f7ac'
$primaryPrincipal = '22222222-2222-2222-2222-222222222222'
$secondaryPrincipal = '33333333-3333-3333-3333-333333333333'
$pipelinePrincipal = '44444444-4444-4444-4444-444444444444'
$ownerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'

$fakeAzRules = @()
$azCalls = [System.Collections.Generic.List[string]]::new()

function az {
    $joined = $args -join ' '
    $azCalls.Add($joined)
    foreach ($rule in $fakeAzRules) {
        if ($joined -like $rule.Pattern) {
            if ($rule.ExitCode -ne 0) {
                $global:LASTEXITCODE = $rule.ExitCode
                Write-Error $rule.Response -ErrorAction Continue
                return
            }
            $global:LASTEXITCODE = 0
            if ($rule.Response -is [string]) {
                return $rule.Response
            }
            return (ConvertTo-Json -InputObject $rule.Response -Depth 20 -Compress)
        }
    }
    $global:LASTEXITCODE = 3
    Write-Error "ERROR: No test fixture for: $joined" -ErrorAction Continue
}

function New-Rule([string]$Pattern, $Response, [int]$ExitCode = 0) {
    [pscustomobject]@{ Pattern = $Pattern; Response = $Response; ExitCode = $ExitCode }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        throw "grant-access check failed: $Message"
    }
}

# Runs the script with an isolated temp folder, and returns its objects or its error message.
function Invoke-Grant([hashtable]$Arguments) {
    $previous = @{}
    foreach ($name in 'TMP', 'TEMP', 'TMPDIR') {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $isolatedTemp)
    }
    $azCalls.Clear()
    try {
        $results = @(& $grantScript @Arguments -PassThru 6> $null)
        return [pscustomobject]@{ Results = $results; Error = $null }
    } catch {
        return [pscustomobject]@{ Results = @(); Error = $_.Exception.Message }
    } finally {
        foreach ($name in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name])
        }
    }
}

function Get-Calls([string]$Pattern) {
    return @($azCalls | Where-Object { $_ -like $Pattern })
}

# The six assignments that the templates list, with the names they give them.
$assignments = @(foreach ($target in @(@($storageA, $fileRoleId, 'Storage File Data Privileged Contributor'), @($storageB, $fileRoleId, 'Storage File Data Privileged Contributor'), @($registry, $pullRoleId, 'AcrPull'))) {
    foreach ($identity in @(@('id-replication-pri', $primaryPrincipal), @('id-replication-sec', $secondaryPrincipal))) {
        @{ name = [guid]::NewGuid().ToString(); scope = $target[0]; principalId = $identity[1]; principalName = $identity[0]; roleDefinitionId = $target[1]; roleName = $target[2] }
    }
})
$commonRules = @(
    (New-Rule 'account show*' @{ id = '00000000-0000-0000-0000-000000000000'; name = 'Test subscription' })
    (New-Rule 'deployment sub show --name azure-files-dr-bootstrap-test *' @{ state = 'Succeeded'; assignments = $assignments })
    # The user-assigned identities in the subscription, including a pipeline identity.
    (New-Rule 'identity list*' @(
        @{ id = "$identityRoot/id-replication-pri"; name = 'id-replication-pri'; principalId = $primaryPrincipal },
        @{ id = "$identityRoot/id-replication-sec"; name = 'id-replication-sec'; principalId = $secondaryPrincipal },
        @{ id = "$subscription/resourceGroups/rg-platform/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-pipeline"; name = 'id-pipeline'; principalId = $pipelinePrincipal }
    ))
)
$legacyRegistry = New-Rule 'acr show --ids *' 'LegacyRegistryPermissions'
# The primary identity already holds its storage role on the primary account; everything else is missing.
$partialRoles = @(
    (New-Rule "role assignment list --scope $storageA --assignee-object-id $primaryPrincipal *" "$subscription/providers/Microsoft.Authorization/roleDefinitions/$fileRoleId")
    (New-Rule 'role assignment list *' '')
)

try {
    # -WhatIf reads the assignments and reports the missing ones without creating any.
    $fakeAzRules = $commonRules + @($legacyRegistry) + $partialRoles
    $run = Invoke-Grant @{ DeploymentName = 'azure-files-dr-bootstrap-test'; WhatIf = $true }
    Assert-True ($null -eq $run.Error) "-WhatIf failed: $($run.Error)"
    Assert-True ($run.Results.Count -eq 6) "-WhatIf returned $($run.Results.Count) assignments instead of 6"
    Assert-True (@($run.Results | Where-Object Status -eq 'Exists').Count -eq 1 -and @($run.Results | Where-Object Status -eq 'Missing').Count -eq 5) "-WhatIf statuses were $(@($run.Results | ForEach-Object Status) -join ', ')"
    Assert-True ((Get-Calls 'role assignment create*').Count -eq 0) '-WhatIf created role assignments'
    Assert-True ((Get-Calls 'role assignment list*').Count -eq 6) 'each identity was not checked once on each scope'
    Assert-True ((Get-Calls 'role assignment list*' | Where-Object { $_ -notlike '*--include-inherited*--fill-principal-name false*' }).Count -eq 0) 'the check must include inherited assignments without Microsoft Graph lookups'
    Assert-True ((Get-Calls 'ad *').Count -eq 0) 'the script called Microsoft Graph'
    Assert-True (@($run.Results | Where-Object { $_.Identity -eq 'rg-identities/id-replication-pri' }).Count -eq 3) "identities were not shown with their resource group: $(@($run.Results | ForEach-Object Identity) -join ', ')"

    # Whoever deploys controls the outputs, so they can't widen the grant: another role, a role on the wrong resource
    # type or in another subscription, or a principal that isn't a user-assigned identity stops the run before any change.
    $template = $assignments[0]
    $tampered = [ordered]@{
        'owner-role'         = @{ name = $template.name; scope = $subscription; principalId = $primaryPrincipal; principalName = 'id-replication-pri'; roleDefinitionId = $ownerRoleId; roleName = 'Storage File Data Privileged Contributor' }
        'wrong-resource'     = @{ name = $template.name; scope = $registry; principalId = $primaryPrincipal; principalName = 'id-replication-pri'; roleDefinitionId = $fileRoleId; roleName = 'Storage File Data Privileged Contributor' }
        'other-subscription' = @{ name = $template.name; scope = '/subscriptions/55555555-5555-5555-5555-555555555555/resourceGroups/rg-other/providers/Microsoft.Storage/storageAccounts/stother'; principalId = $primaryPrincipal; principalName = 'id-replication-pri'; roleDefinitionId = $fileRoleId; roleName = 'Storage File Data Privileged Contributor' }
        'unknown-principal'  = @{ name = $template.name; scope = $storageA; principalId = '99999999-9999-9999-9999-999999999999'; principalName = 'id-replication-pri'; roleDefinitionId = $fileRoleId; roleName = 'Storage File Data Privileged Contributor' }
    }
    foreach ($case in $tampered.Keys) {
        $fakeAzRules = @((New-Rule "deployment sub show --name azure-files-dr-$case *" @{ state = 'Succeeded'; assignments = @($assignments[1], $tampered[$case]) })) + $commonRules + @($legacyRegistry, (New-Rule 'role assignment list *' ''), (New-Rule 'role assignment create*' ''))
        $run = Invoke-Grant @{ DeploymentName = "azure-files-dr-$case" }
        Assert-True ($run.Error -like "*lists role assignments that the replication jobs don't need, so nothing was granted*") "the $case output was not refused: $($run.Error)"
        Assert-True ((Get-Calls 'role assignment *').Count -eq 0) "the $case output led to role assignment calls: $($azCalls -join '; ')"
    }

    # The job roles for another user-assigned identity are shown with that identity's real name and role, not the outputs' labels.
    $relabeled = @{ name = $template.name; scope = $storageA; principalId = $pipelinePrincipal; principalName = 'id-replication-pri'; roleDefinitionId = $fileRoleId; roleName = 'AcrPull' }
    $fakeAzRules = @((New-Rule 'deployment sub show --name azure-files-dr-relabeled *' @{ state = 'Succeeded'; assignments = @($relabeled) })) + $commonRules + @($legacyRegistry, (New-Rule 'role assignment list *' ''))
    $run = Invoke-Grant @{ DeploymentName = 'azure-files-dr-relabeled'; WhatIf = $true }
    Assert-True ($run.Results.Count -eq 1 -and $run.Results[0].PrincipalName -eq 'id-pipeline' -and $run.Results[0].Identity -eq 'rg-platform/id-pipeline' -and $run.Results[0].RoleName -eq 'Storage File Data Privileged Contributor') "the outputs' labels were shown instead of Azure's: $($run.Results | ConvertTo-Json -Compress)"

    # Without -WhatIf, only the missing assignments are created, with the templates' names and without Microsoft Graph.
    $fakeAzRules = $commonRules + @($legacyRegistry) + $partialRoles + @((New-Rule 'role assignment create*' ''))
    $run = Invoke-Grant @{ DeploymentName = 'azure-files-dr-bootstrap-test' }
    Assert-True ($null -eq $run.Error) "the grant failed: $($run.Error)"
    Assert-True (@($run.Results | Where-Object Status -eq 'Created').Count -eq 5) "statuses were $(@($run.Results | ForEach-Object Status) -join ', ')"
    $creates = Get-Calls 'role assignment create*'
    Assert-True ($creates.Count -eq 5) "created $($creates.Count) role assignments instead of 5"
    $registryAssignment = $assignments | Where-Object { $_.scope -eq $registry -and $_.principalId -eq $primaryPrincipal }
    Assert-True (@($creates | Where-Object { $_ -like "role assignment create --assignee-object-id $primaryPrincipal --assignee-principal-type ServicePrincipal --role $pullRoleId --scope $registry --description * --name $($registryAssignment.name) *" }).Count -eq 1) "the registry assignment was not created with the template's name: $($creates -join '; ')"
    Assert-True (@($creates | Where-Object { $_ -like "*--assignee-object-id $primaryPrincipal*--scope $storageA *" }).Count -eq 0) 'an existing assignment was created again'
    Assert-True (@(Get-ChildItem -LiteralPath $isolatedTemp -File -Force).Count -eq 0) 'the script left temporary files'

    # A registry with ABAC repository permissions gets Container Registry Repository Reader instead of AcrPull.
    $fakeAzRules = $commonRules + @((New-Rule 'acr show --ids *' 'AbacRepositoryPermissions'), (New-Rule 'role assignment list *' ''), (New-Rule 'role assignment create*' ''))
    $run = Invoke-Grant @{ DeploymentName = 'azure-files-dr-bootstrap-test' }
    $registryCreates = @(Get-Calls "role assignment create * --scope $registry *")
    Assert-True ($registryCreates.Count -eq 2 -and @($registryCreates | Where-Object { $_ -like "*--role $readerRoleId *" -and $_ -notlike '*--name*' }).Count -eq 2) "an ABAC registry did not get Container Registry Repository Reader: $($registryCreates -join '; ')"
    Assert-True (@($run.Results | Where-Object RoleName -eq 'Container Registry Repository Reader').Count -eq 2) 'the ABAC role was not reported'

    # Refused assignments fail the run with the scopes and the rights needed; an assignment that already exists counts as granted.
    $fakeAzRules = $commonRules + @($legacyRegistry, (New-Rule 'role assignment list *' '')) + @(
        (New-Rule "role assignment create * --scope $registry *" "ERROR: (AuthorizationFailed) The client 'admin@example.com' does not have authorization to perform action 'Microsoft.Authorization/roleAssignments/write' over scope '$registry'." 1)
        (New-Rule "role assignment create --assignee-object-id $secondaryPrincipal * --scope $storageB *" 'ERROR: (RoleAssignmentExists) The role assignment already exists.' 1)
        (New-Rule 'role assignment create*' '')
    )
    $run = Invoke-Grant @{ DeploymentName = 'azure-files-dr-bootstrap-test' }
    Assert-True ($null -ne $run.Error -and $run.Error -like '2 of 6 role assignments couldn''t be created*') "refused assignments did not fail the run: $($run.Error)"
    Assert-True ($run.Error -like "*AcrPull for id-replication-pri on $registry*" -and $run.Error -like '*User Access Administrator*') "the failure doesn't name the scope and the rights: $($run.Error)"
    Assert-True ((Get-Calls 'role assignment create*').Count -eq 6) 'a refused assignment stopped the others'

    # Reused identities can be granted before the first deployment, from their resource IDs.
    $fakeAzRules = @(
        (New-Rule 'account show*' @{ id = '00000000-0000-0000-0000-000000000000'; name = 'Test subscription' })
        (New-Rule "identity show --ids $identityRoot/id-replication-pri *" @{ name = 'id-replication-pri'; principalId = $primaryPrincipal })
        (New-Rule "identity show --ids $identityRoot/id-replication-sec *" @{ name = 'id-replication-sec'; principalId = $secondaryPrincipal })
        $legacyRegistry
        (New-Rule 'role assignment list *' '')
        (New-Rule 'role assignment create*' '')
    )
    $run = Invoke-Grant @{ IdentityId = @("$identityRoot/id-replication-pri,$identityRoot/id-replication-sec"); StorageAccountId = @($storageA, $storageB); RegistryId = $registry }
    Assert-True ($null -eq $run.Error) "the grant from resource IDs failed: $($run.Error)"
    $creates = Get-Calls 'role assignment create*'
    Assert-True ($creates.Count -eq 6 -and @($creates | Where-Object { $_ -like '*--name*' }).Count -eq 0) "resource ID grants were $($creates -join '; ')"
    Assert-True (@($creates | Where-Object { $_ -like "*--assignee-object-id $secondaryPrincipal *--role $pullRoleId --scope $registry *" }).Count -eq 1) 'the secondary identity did not get AcrPull'

    # The same identity for both jobs is granted once per scope.
    $run = Invoke-Grant @{ IdentityId = @("$identityRoot/id-replication-pri", "$identityRoot/id-replication-pri"); StorageAccountId = @($storageA); RegistryId = $registry }
    Assert-True ((Get-Calls 'role assignment create*').Count -eq 2) "a shared identity was granted $((Get-Calls 'role assignment create*').Count) times on two scopes"

    # Invalid input stops the run before any change.
    foreach ($case in @(
            @{ Arguments = @{ IdentityId = @("$identityRoot/id-replication-pri") }; Expected = '*Name the storage accounts*' },
            @{ Arguments = @{ IdentityId = @("$identityRoot/id-replication-pri"); StorageAccountId = @($registry) }; Expected = "*isn't a storage account resource ID*" },
            @{ Arguments = @{ IdentityId = @($storageA); StorageAccountId = @($storageA) }; Expected = "*isn't a user-assigned managed identity resource ID*" }
        )) {
        $run = Invoke-Grant $case.Arguments
        Assert-True ($run.Error -like $case.Expected) "invalid input was not rejected: $($run.Error)"
        Assert-True ((Get-Calls 'role assignment create*').Count -eq 0) 'invalid input created role assignments'
    }

    # A deployment that failed, or that predates the output, can't supply the assignments.
    $fakeAzRules = @(
        (New-Rule 'account show*' @{ id = '00000000-0000-0000-0000-000000000000'; name = 'Test subscription' })
        (New-Rule 'deployment sub show --name azure-files-dr-old *' @{ state = 'Succeeded'; assignments = $null })
        (New-Rule 'deployment sub show --name azure-files-dr-missing *' 'ERROR: (DeploymentNotFound) Deployment not found.' 1)
    )
    $run = Invoke-Grant @{ DeploymentName = 'azure-files-dr-old' }
    Assert-True ($run.Error -like "*doesn't list the job identities' role assignments*") "a deployment without the output was accepted: $($run.Error)"
    $run = Invoke-Grant @{ DeploymentName = 'azure-files-dr-missing' }
    Assert-True ($run.Error -like "*Could not read subscription deployment 'azure-files-dr-missing'*DeploymentNotFound*") "a missing deployment was not reported: $($run.Error)"
} finally {
    Remove-Item -LiteralPath $isolatedTemp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Grant access script checks passed.'
