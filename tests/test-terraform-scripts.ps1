$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$deployScript = Join-Path $repositoryRoot 'deploy\terraform\deploy.ps1'
$switchScript = Join-Path $repositoryRoot 'scripts\switch-direction.ps1'
$grantScript = Join-Path $repositoryRoot 'scripts\grant-access.ps1'
$terraformDirectory = Join-Path $repositoryRoot 'deploy\terraform'
$isolatedTemp = Join-Path $repositoryRoot ".terraform-script-test-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $isolatedTemp -Force | Out-Null

$digest = 'b' * 64
$image = "acrtest.azurecr.io/azure-files-dr-azcopy@sha256:$digest"
$subscription = '/subscriptions/00000000-0000-0000-0000-000000000000'
$storageA = "$subscription/resourceGroups/rg-storage/providers/Microsoft.Storage/storageAccounts/stprimary"
$storageB = "$subscription/resourceGroups/rg-storage/providers/Microsoft.Storage/storageAccounts/stsecondary"
$registry = "$subscription/resourceGroups/rg-storage/providers/Microsoft.ContainerRegistry/registries/acrtest"
$fileRoleId = '69566ab7-960f-475b-8e7c-b3118f30c6bd'
$pullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
$assignments = @(foreach ($target in @(@($storageA, $fileRoleId, 'Storage File Data Privileged Contributor'), @($storageB, $fileRoleId, 'Storage File Data Privileged Contributor'), @($registry, $pullRoleId, 'AcrPull'))) {
    foreach ($identity in @(@('id-replication-pri', '22222222-2222-2222-2222-222222222222'), @('id-replication-sec', '33333333-3333-3333-3333-333333333333'))) {
        @{ name = [guid]::NewGuid().ToString(); scope = $target[0]; principalId = $identity[1]; principalName = $identity[0]; roleDefinitionId = $target[1]; roleName = $target[2] }
    }
})

$terraformCalls = [System.Collections.Generic.List[string]]::new()
$azCalls = [System.Collections.Generic.List[string]]::new()
$global:TerraformScriptCreateRoleAssignments = $true
$global:TerraformScriptJobImages = @($image, $image)
$global:TerraformScriptRunningExecutions = 0
$global:TerraformScriptApplyError = $null

function New-Outputs([bool]$CreateRoles = $true) {
    @{
        resource_group_name        = @{ value = 'rg-terraform' }
        registry_name              = @{ value = 'acrtest' }
        registry_login_server      = @{ value = 'acrtest.azurecr.io' }
        primary_job_name           = @{ value = 'job-sync-primary' }
        secondary_job_name         = @{ value = 'job-sync-secondary' }
        monitoring_action_group_id = @{ value = 'action-group' }
        create_role_assignments    = @{ value = $CreateRoles }
        registry_created           = @{ value = $true }
        job_role_assignments       = @{ value = $assignments }
    }
}

function terraform {
    $joined = $args -join ' '
    $terraformCalls.Add($joined)
    $global:LASTEXITCODE = 0
    if ($joined -like '* output -json job_role_assignments*') {
        return (ConvertTo-Json -InputObject $assignments -Depth 8 -Compress)
    }
    if ($joined -like '* output -json*') {
        return (ConvertTo-Json -InputObject (New-Outputs $global:TerraformScriptCreateRoleAssignments) -Depth 10 -Compress)
    }
    if ($joined -like '* plan *') { return 'plan ok' }
    if ($global:TerraformScriptApplyError -and $joined -like '* apply *') {
        $global:LASTEXITCODE = 1
        Write-Error $global:TerraformScriptApplyError -ErrorAction Continue
        return
    }
    return ''
}

function az {
    $joined = $args -join ' '
    $azCalls.Add($joined)
    $global:LASTEXITCODE = 0
    if ($joined -like 'account show*') { return '{"id":"00000000-0000-0000-0000-000000000000","name":"Test subscription"}' }
    if ($joined -like 'acr manifest show-metadata*') { return "sha256:$digest" }
    if ($joined -like 'containerapp job show*job-sync-primary*') { return (@{ name = 'job-sync-primary'; location = 'southcentralus'; image = $global:TerraformScriptJobImages[0] } | ConvertTo-Json -Compress) }
    if ($joined -like 'containerapp job show*job-sync-secondary*') { return (@{ name = 'job-sync-secondary'; location = 'westus'; image = $global:TerraformScriptJobImages[1] } | ConvertTo-Json -Compress) }
    if ($joined -like 'containerapp job execution list*') { return "$global:TerraformScriptRunningExecutions" }
    if ($joined -like 'identity list*') {
        return (@(
            @{ id = "$subscription/resourceGroups/rg-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-replication-pri"; name = 'id-replication-pri'; principalId = '22222222-2222-2222-2222-222222222222' },
            @{ id = "$subscription/resourceGroups/rg-identities/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-replication-sec"; name = 'id-replication-sec'; principalId = '33333333-3333-3333-3333-333333333333' }
        ) | ConvertTo-Json -Depth 6 -Compress)
    }
    if ($joined -like 'acr show --ids *') { return 'LegacyRegistryPermissions' }
    if ($joined -like 'role assignment list*') { return '' }
    return ''
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "terraform script check failed: $Message" }
}

function Invoke-Isolated([scriptblock]$Action) {
    $previous = @{}
    foreach ($name in 'TMP', 'TEMP', 'TMPDIR') {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $isolatedTemp)
    }
    $terraformCalls.Clear()
    $azCalls.Clear()
    $global:TerraformScriptCreateRoleAssignments = $true
    $global:TerraformScriptJobImages = @($image, $image)
    $global:TerraformScriptRunningExecutions = 0
    $global:TerraformScriptApplyError = $null
    try {
        & $Action
    } finally {
        foreach ($name in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name])
        }
    }
}

try {
        Invoke-Isolated { & $deployScript -TerraformDirectory $terraformDirectory -VarFile (Join-Path $terraformDirectory 'terraform.tfvars') -WhatIf 6> $null }
        Assert-True (@($terraformCalls | Where-Object { $_ -like '* plan *' }).Count -eq 1) 'deploy.ps1 -WhatIf did not plan'
        Assert-True (@($terraformCalls | Where-Object { $_ -like '* apply *' }).Count -eq 0) 'deploy.ps1 -WhatIf applied'
        Assert-True (@($azCalls | Where-Object { $_ -like 'acr *' }).Count -eq 0) 'deploy.ps1 -WhatIf built an image'

        Invoke-Isolated { & $deployScript -TerraformDirectory $terraformDirectory -VarFile (Join-Path $terraformDirectory 'terraform.tfvars') -Confirm:$false 6> $null }
        $applies = @($terraformCalls | Where-Object { $_ -like '* apply *' })
        Assert-True ($applies.Count -eq 2) "deploy.ps1 ran $($applies.Count) applies instead of bootstrap and final"
        Assert-True ($applies[0] -like '*-var active_region=none*' -and $applies[0] -like '*-var acr_public_network_access_enabled=true*') "bootstrap vars were wrong: $($applies[0])"
        Assert-True ($applies[1] -like "*-var container_image=$image*" -and $applies[1] -like '*-var active_region=primary*' -and $applies[1] -like '*-var acr_public_network_access_enabled=false*') "final vars were wrong: $($applies[1])"
        Assert-True (@($azCalls | Where-Object { $_ -like 'acr build*' }).Count -eq 1) 'deploy.ps1 did not build the image'

        $failure = $null
        try { Invoke-Isolated { & $deployScript -TerraformDirectory $terraformDirectory -ContainerImage 'acr.azurecr.io/repo:tag' -WhatIf 6> $null } } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like '*must be pinned by digest*') 'deploy.ps1 accepted a non-digest ContainerImage'
        Assert-True ($azCalls.Count -eq 0 -and $terraformCalls.Count -eq 0) 'deploy.ps1 continued after rejecting ContainerImage'

        Invoke-Isolated { & $deployScript -TerraformDirectory $terraformDirectory -ContainerImage $image -Confirm:$false 6> $null }
        Assert-True (@($azCalls | Where-Object { $_ -like 'acr *' }).Count -eq 0) 'deploy.ps1 built although a digest image was supplied'

        $failure = $null
        try { Invoke-Isolated { $global:TerraformScriptCreateRoleAssignments = $false; & $deployScript -TerraformDirectory $terraformDirectory -Confirm:$false 6> $null } } catch { $failure = $_.Exception.Message }
        $applies = @($terraformCalls | Where-Object { $_ -like '* apply *' })
        Assert-True ($failure -like '*missing role assignments*grant-access.ps1 -TerraformDirectory*') "missing role guidance was not shown: $failure"
        Assert-True ($applies.Count -eq 2 -and $applies[1] -like '*active_region=none*' -and $applies[1] -like '*acr_public_network_access_enabled=false*') 'deploy.ps1 did not close the registry after missing roles'

        # Terraform frames diagnostics with box-drawing characters; the image hint must still find the Container Apps error.
        $bar = [char]0x2502
        $imageFailure = @(
            "$bar Error: creating Container App Job (Subscription: `"00000000-0000-0000-0000-000000000000`""
            "$bar Resource Group Name: `"rg-terraform`""
            "$bar Job Name: `"job-sync-secondary`"): polling after CreateOrUpdate: polling failed: the Azure API returned the following error:"
            $bar
            "$bar Status: `"InvalidParameterValueInContainerTemplate`""
            "$bar Message: `"The following field(s) are either invalid or missing. Field 'template.containers.azcopy.image' is invalid with details: 'Invalid value: \`"mcr.microsoft.com/azuredocs/containerapps-helloworld:latest\`": Get \`"https://mcr.microsoft.com/v2/\`": EOF';.`""
        ) -join "`n"
        $failure = $null
        try { Invoke-Isolated { $global:TerraformScriptApplyError = $imageFailure; & $deployScript -TerraformDirectory $terraformDirectory -Confirm:$false 6> $null } } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like "*The job subnet couldn't reach mcr.microsoft.com*packages.aks.azure.com*") "deploy.ps1 did not explain an image that the job subnet can't reach: $failure"
        Assert-True ($failure.Contains('*.login.microsoftonline.com, login.microsoft.com, and *.login.microsoft.com')) "deploy.ps1 did not list the sign-in endpoints, including login.microsoft.com: $failure"
        Assert-True (@($azCalls | Where-Object { $_ -like 'acr *' }).Count -eq 0) 'deploy.ps1 built the image after the bootstrap apply failed'

        $expiredFailure = @(
            "$bar Error: creating Container App Job (Subscription: `"00000000-0000-0000-0000-000000000000`""
            "$bar Resource Group Name: `"rg-terraform`""
            "$bar Job Name: `"job-sync-primary`"): polling after CreateOrUpdate: polling failed: the Azure API returned the following error:"
            $bar
            "$bar Status: `"ContainerAppOperationError`""
            "$bar Message: `"Failed to provision revision for container app 'job-sync-primary'. Error details: Operation expired.`""
        ) -join "`n"
        $failure = $null
        try { Invoke-Isolated { $global:TerraformScriptApplyError = $expiredFailure; & $deployScript -TerraformDirectory $terraformDirectory -Confirm:$false 6> $null } } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like "*Container Apps couldn't finish creating these jobs before the operation expired*job-sync-primary in resource group rg-terraform*") "deploy.ps1 did not explain an expired job operation: $failure"
        Assert-True ($failure.Contains('az containerapp job delete --resource-group rg-terraform --name job-sync-primary --yes') -and $failure.Contains("Terraform can't create a job that already exists outside its state")) "deploy.ps1 did not say to delete the expired job before rerunning: $failure"

        Invoke-Isolated { & $switchScript -ActiveRegion secondary -WritesFenced -TerraformDirectory $terraformDirectory -WhatIf 6> $null }
        Assert-True (@($azCalls | Where-Object { $_ -like 'containerapp job execution list*' }).Count -eq 2) 'switch-direction.ps1 did not check running executions'
        Assert-True (@($terraformCalls | Where-Object { $_ -like '* apply *' }).Count -eq 0) 'switch-direction.ps1 -WhatIf applied'

        Invoke-Isolated { & $switchScript -ActiveRegion secondary -WritesFenced -TerraformDirectory $terraformDirectory -Confirm:$false 6> $null }
        $apply = @($terraformCalls | Where-Object { $_ -like '* apply *' })[0]
        Assert-True ($apply -like "*-var container_image=$image*" -and $apply -like '*-var active_region=secondary*' -and $apply -like '*-var acr_public_network_access_enabled=false*') "switch apply vars were wrong: $apply"

        $failure = $null
        try { Invoke-Isolated { $global:TerraformScriptRunningExecutions = 1; & $switchScript -ActiveRegion secondary -WritesFenced -TerraformDirectory $terraformDirectory -Confirm:$false 6> $null } } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like '*running execution*' -and @($terraformCalls | Where-Object { $_ -like '* apply *' }).Count -eq 0) 'switch did not reject running executions'

        $failure = $null
        try { Invoke-Isolated { $global:TerraformScriptJobImages = @($image, "acrtest.azurecr.io/azure-files-dr-azcopy@sha256:$('c' * 64)"); & $switchScript -ActiveRegion secondary -WritesFenced -TerraformDirectory $terraformDirectory -Confirm:$false 6> $null } } catch { $failure = $_.Exception.Message }
        Assert-True ($failure -like '*same digest-pinned image*' -and @($terraformCalls | Where-Object { $_ -like '* apply *' }).Count -eq 0) 'switch did not reject mismatched images'

        $grantResults = Invoke-Isolated { @(& $grantScript -TerraformDirectory $terraformDirectory -WhatIf -PassThru 6> $null) }
        Assert-True ($grantResults.Count -eq 6 -and @($terraformCalls | Where-Object { $_ -like '* output -json job_role_assignments*' }).Count -eq 1) 'grant-access.ps1 did not read Terraform role assignments'
} finally {
    Remove-Item -LiteralPath $isolatedTemp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Terraform script checks passed.'

