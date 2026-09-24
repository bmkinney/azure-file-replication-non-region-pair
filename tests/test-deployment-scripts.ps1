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
    $fakeAzRules = $commonRules + @(
        (New-Rule 'deployment sub validate*' '{}')
        (New-Rule 'deployment sub what-if*' 'Resource changes: 1 to create.')
    )
    $output = Invoke-WithIsolatedTemp { & $deployScript -ParametersFile $parametersFile -WhatIf 6>&1 | Out-String }
    Assert-True ($output.Contains('Resource changes: 1 to create.')) 'deploy.ps1 -WhatIf did not print the what-if result'
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
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Deployment script checks passed.'
