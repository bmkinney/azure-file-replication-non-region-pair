$ErrorActionPreference = 'Stop'

# Runs scripts/deploy.ps1 and scripts/switch-direction.ps1 with -WhatIf against a fake Azure CLI; no Azure calls are made.

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$deployScript = Join-Path $repositoryRoot 'scripts/deploy.ps1'
$switchScript = Join-Path $repositoryRoot 'scripts/switch-direction.ps1'
$workRoot = Join-Path ([IO.Path]::GetTempPath()) "deployment-scripts-test-$([guid]::NewGuid().ToString('N'))"
$templateDirectory = Join-Path $workRoot 'infra'
$isolatedTemp = Join-Path $workRoot 'temp'
New-Item -ItemType Directory -Path $templateDirectory, $isolatedTemp -Force | Out-Null

# A local parameter file whose name does not match its template, as recommended for git-ignored overrides.
$templateFile = Join-Path $templateDirectory 'main.bicep'
$parametersFile = Join-Path $templateDirectory 'demo.local.bicepparam'
Set-Content -LiteralPath $templateFile -Value "targetScope = 'subscription'"
Set-Content -LiteralPath $parametersFile -Value "using './main.bicep'"

$digest = 'b' * 64
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
        throw "deployment script check failed: $Message"
    }
}

function Invoke-WithIsolatedTemp([scriptblock]$Script) {
    $previous = @{}
    foreach ($name in 'TMP', 'TEMP', 'TMPDIR') {
        $previous[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $isolatedTemp)
    }
    $azCalls.Clear()
    try {
        & $Script
    } finally {
        foreach ($name in $previous.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previous[$name])
        }
    }
}

function Get-LeakedTempFiles {
    return @(Get-ChildItem -LiteralPath $isolatedTemp -File -Force)
}

$commonRules = @(
    (New-Rule 'account show*' '')
    (New-Rule 'bicep build*' '{}')
)

try {
    # deploy.ps1 -WhatIf previews without deploying, cleans up, and finds the template from the using declaration.
    $whatIfDiagnostics = "Resource changes: 1 to create.`nDiagnostics (1):`n/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-storage/providers/Microsoft.Resources/deployments/replication-primary-storage-rbac (NestedDeploymentShortCircuited) A nested deployment got short-circuited and all its resources got skipped from validation."
    $fakeAzRules = $commonRules + @(
        (New-Rule 'deployment sub validate*' '{}')
        (New-Rule 'deployment sub what-if*' $whatIfDiagnostics)
    )
    $output = Invoke-WithIsolatedTemp { & $deployScript -ParametersFile $parametersFile -WhatIf 6>&1 | Out-String }
    Assert-True ($output.Contains('Resource changes: 1 to create.')) 'deploy.ps1 -WhatIf did not print the what-if result'
    Assert-True ($output.Contains('diagnostics are expected') -and $output.Contains('scripts/inventory.ps1 checks those permissions')) "deploy.ps1 did not explain the short-circuited nested deployments: $output"
    Assert-True (@($azCalls | Where-Object { $_ -like 'bicep build --file *main.bicep --stdout*' }).Count -eq 1) "deploy.ps1 did not resolve the template from the using declaration: $($azCalls -join '; ')"
    Assert-True (@($azCalls | Where-Object { $_ -like 'deployment sub create*' -or $_ -like 'acr *' }).Count -eq 0) 'deploy.ps1 -WhatIf changed Azure resources'
    Assert-True ((Get-LeakedTempFiles).Count -eq 0) "deploy.ps1 -WhatIf left temporary files: $((Get-LeakedTempFiles).Name -join ', ')"

    # Azure CLI errors must still be reported under -WhatIf.
    $fakeAzRules = $commonRules + @(
        (New-Rule 'deployment sub validate*' 'ERROR: (InvalidTemplateDeployment) validation detail for the test' 1)
    )
    $failure = $null
    try {
        Invoke-WithIsolatedTemp { & $deployScript -ParametersFile $parametersFile -WhatIf 6> $null 2> $null }
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True ($null -ne $failure) 'deploy.ps1 -WhatIf did not fail when validation failed'
    Assert-True ($failure.Contains('validation detail for the test')) "deploy.ps1 -WhatIf dropped the Azure CLI error output: $failure"
    Assert-True (-not $failure.Contains('create role assignments')) 'deploy.ps1 added the role assignment hint to an unrelated failure'
    Assert-True ((Get-LeakedTempFiles).Count -eq 0) 'deploy.ps1 -WhatIf left temporary files after a failure'

    # switch-direction.ps1 -WhatIf checks the jobs without deploying and cleans up.
    $jobs = @(
        @('job-sync-primary', 'southcentralus', "registry.azurecr.io/azure-files-dr-azcopy@sha256:$digest"),
        @('job-sync-secondary', 'westus', "registry.azurecr.io/azure-files-dr-azcopy@sha256:$digest")
    )
    $fakeAzRules = @(
        (New-Rule 'containerapp job list*' (ConvertTo-Json -InputObject $jobs -Depth 5 -Compress))
        (New-Rule 'containerapp job execution list*' '0')
    )
    Invoke-WithIsolatedTemp { & $switchScript -ActiveRegion secondary -WritesFenced -ParametersFile $parametersFile -WhatIf 6> $null }
    Assert-True (@($azCalls | Where-Object { $_ -like 'containerapp job execution list*' }).Count -eq 2) 'switch-direction.ps1 did not check both jobs for running executions'
    Assert-True (@($azCalls | Where-Object { $_ -like 'deployment sub create*' }).Count -eq 0) 'switch-direction.ps1 -WhatIf changed Azure resources'
    Assert-True ((Get-LeakedTempFiles).Count -eq 0) "switch-direction.ps1 -WhatIf left temporary files: $((Get-LeakedTempFiles).Name -join ', ')"

    # A registry the templates create is public only while deploy.ps1 builds the image, for either profile.
    $outputs = @{ properties = @{ outputs = @{
        registryName            = @{ value = 'acrtest' }
        primaryJobName          = @{ value = 'job-sync-primary' }
        secondaryJobName        = @{ value = 'job-sync-secondary' }
        monitoringActionGroupId = @{ value = 'action-group' }
    } } }
    $fakeAzRules = $commonRules + @(
        (New-Rule 'deployment sub validate*' '{}')
        (New-Rule 'deployment sub create*' (ConvertTo-Json -InputObject $outputs -Depth 5 -Compress))
        (New-Rule 'acr build*' '')
        (New-Rule 'acr manifest show-metadata*' "sha256:$digest")
    )
    Invoke-WithIsolatedTemp { & $deployScript -ParametersFile $parametersFile -SkipWhatIf -Confirm:$false 6> $null }
    $creates = @($azCalls | Where-Object { $_ -like 'deployment sub create*' })
    Assert-True ($creates.Count -eq 2) "deploy.ps1 ran $($creates.Count) deployments instead of bootstrap and final"
    Assert-True ($creates[0] -like '*activeRegion=none acrPublicNetworkAccess=Enabled*') "the bootstrap deployment doesn't open the registry for the build: $($creates[0])"
    Assert-True ($creates[1] -like "*containerImage=acrtest.azurecr.io/azure-files-dr-azcopy@sha256:$digest activeRegion=primary acrPublicNetworkAccess=Disabled*") "the final deployment doesn't pin the image and close the registry: $($creates[1])"

    # With a prebuilt image nothing is built, so the registry stays closed in both stages.
    $prebuiltImage = "prebuilt.azurecr.io/azure-files-dr-azcopy@sha256:$digest"
    Invoke-WithIsolatedTemp { & $deployScript -ParametersFile $parametersFile -ContainerImage $prebuiltImage -SkipWhatIf -Confirm:$false 6> $null }
    $creates = @($azCalls | Where-Object { $_ -like 'deployment sub create*' })
    Assert-True ($creates.Count -eq 2) "deploy.ps1 ran $($creates.Count) deployments with a prebuilt image"
    Assert-True ($creates[0] -like '*activeRegion=none acrPublicNetworkAccess=Disabled*') "the bootstrap deployment opened the registry without a build: $($creates[0])"
    Assert-True ($creates[1] -like "*containerImage=$prebuiltImage activeRegion=primary acrPublicNetworkAccess=Disabled*") "the final deployment doesn't use the prebuilt image: $($creates[1])"
    Assert-True (@($azCalls | Where-Object { $_ -like 'acr *' }).Count -eq 0) "deploy.ps1 built or inspected an image although one was supplied: $($azCalls -join '; ')"

    $fakeAzRules = @(
        (New-Rule 'containerapp job list*' (ConvertTo-Json -InputObject $jobs -Depth 5 -Compress))
        (New-Rule 'containerapp job execution list*' '0')
        (New-Rule 'deployment sub create*' (ConvertTo-Json -InputObject $outputs -Depth 5 -Compress))
    )
    Invoke-WithIsolatedTemp { & $switchScript -ActiveRegion secondary -WritesFenced -ParametersFile $parametersFile -Confirm:$false 6> $null }
    $creates = @($azCalls | Where-Object { $_ -like 'deployment sub create*' })
    Assert-True ($creates.Count -eq 1 -and $creates[0] -like '*activeRegion=secondary acrPublicNetworkAccess=Disabled*') "switch-direction.ps1 doesn't keep the registry closed: $($creates -join '; ')"

    # With one resource group per region, each job is found and checked in its own group.
    $image = "registry.azurecr.io/azure-files-dr-azcopy@sha256:$digest"
    $fakeAzRules = @(
        (New-Rule 'containerapp job list --resource-group rg-replication-pri *' "[[`"job-sync-primary`",`"southcentralus`",`"$image`"]]")
        (New-Rule 'containerapp job list --resource-group rg-replication-sec *' "[[`"job-sync-secondary`",`"westus`",`"$image`"]]")
        (New-Rule 'containerapp job execution list --resource-group rg-replication-pri --name job-sync-primary *' '0')
        (New-Rule 'containerapp job execution list --resource-group rg-replication-sec --name job-sync-secondary *' '0')
        (New-Rule 'deployment sub create*' (ConvertTo-Json -InputObject $outputs -Depth 5 -Compress))
    )
    Invoke-WithIsolatedTemp { & $switchScript -ActiveRegion secondary -WritesFenced -ResourceGroupName rg-replication-pri -SecondaryResourceGroupName rg-replication-sec -ParametersFile $parametersFile -Confirm:$false 6> $null }
    Assert-True (@($azCalls | Where-Object { $_ -like 'containerapp job execution list*' }).Count -eq 2) "switch-direction.ps1 did not check each job in its own resource group: $($azCalls -join '; ')"
    Assert-True (@($azCalls | Where-Object { $_ -like 'deployment sub create*' }).Count -eq 1) 'switch-direction.ps1 did not deploy once across two resource groups'

    $failure = $null
    try {
        Invoke-WithIsolatedTemp { & $switchScript -ActiveRegion secondary -WritesFenced -ResourceGroupName rg-replication-pri -ParametersFile $parametersFile -Confirm:$false 6> $null }
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True ($failure -like '*found 1.*-SecondaryResourceGroupName*') "a missing secondary resource group was not explained: $failure"
    Assert-True (@($azCalls | Where-Object { $_ -like 'deployment sub create*' }).Count -eq 0) 'switch-direction.ps1 deployed with only one job'

    # A deployment that can't create the job identities' role assignments names each refused scope once.
    $storageScope = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-storage/providers/Microsoft.Storage/storageAccounts/stprimary'
    $registryScope = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-registry/providers/Microsoft.ContainerRegistry/registries/acrshared'
    $refusals = foreach ($assignment in @(@($storageScope, '1'), @($storageScope, '2'), @($registryScope, '3'))) {
        "Authorization failed for template resource '$($assignment[1])' of type 'Microsoft.Authorization/roleAssignments'. The client 'deployer@example.com' with object id '00000000-0000-0000-0000-00000000000$($assignment[1])' does not have permission to perform action 'Microsoft.Authorization/roleAssignments/write' at scope '$($assignment[0])/providers/Microsoft.Authorization/roleAssignments/0000000$($assignment[1])-0000-0000-0000-000000000000'."
    }
    $refused = "ERROR: {`"status`":`"Failed`",`"error`":{`"code`":`"DeploymentFailed`",`"details`":[{`"code`":`"InvalidTemplateDeployment`",`"message`":`"Deployment failed with multiple errors: '$($refusals -join ':')'`"}]}}"
    function Get-HintScopes([string]$Message) {
        $hint = $Message.Substring($Message.IndexOf("isn't allowed to create role assignments at:"))
        return @([regex]::Matches($hint, '(?m)^  (/subscriptions/\S+)$') | ForEach-Object { $_.Groups[1].Value })
    }

    $fakeAzRules = $commonRules + @(
        (New-Rule 'deployment sub validate*' '{}')
        (New-Rule 'deployment sub create*' $refused 1)
    )
    $failure = $null
    try {
        Invoke-WithIsolatedTemp { & $deployScript -ParametersFile $parametersFile -SkipWhatIf -Confirm:$false 6> $null 2> $null }
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True ($null -ne $failure -and $failure.Contains("isn't allowed to create role assignments at:")) "deploy.ps1 did not explain the refused role assignments: $failure"
    $hintScopes = Get-HintScopes $failure
    Assert-True ($hintScopes.Count -eq 2 -and $hintScopes -contains $storageScope -and $hintScopes -contains $registryScope) "deploy.ps1 did not list each refused scope once: $($hintScopes -join '; ')"
    Assert-True ($failure.Contains('reuses the resources it already created')) 'deploy.ps1 did not say that a rerun is safe'
    Assert-True (@($azCalls | Where-Object { $_ -like 'deployment sub create*' }).Count -eq 1 -and @($azCalls | Where-Object { $_ -like 'acr *' }).Count -eq 0) 'deploy.ps1 continued after the bootstrap deployment failed'

    $fakeAzRules = @(
        (New-Rule 'containerapp job list*' (ConvertTo-Json -InputObject $jobs -Depth 5 -Compress))
        (New-Rule 'containerapp job execution list*' '0')
        (New-Rule 'deployment sub create*' $refused 1)
    )
    $failure = $null
    try {
        Invoke-WithIsolatedTemp { & $switchScript -ActiveRegion secondary -WritesFenced -ParametersFile $parametersFile -Confirm:$false 6> $null 2> $null }
    } catch {
        $failure = $_.Exception.Message
    }
    Assert-True ($null -ne $failure -and $failure.Contains("the replication direction didn't change")) "switch-direction.ps1 did not explain the refused role assignments: $failure"
    Assert-True ((Get-HintScopes $failure).Count -eq 2) "switch-direction.ps1 did not list each refused scope once: $((Get-HintScopes $failure) -join '; ')"
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Deployment script checks passed.'
