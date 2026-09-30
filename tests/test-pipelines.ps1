$ErrorActionPreference = 'Stop'

# Checks the GitHub Actions workflows and Azure DevOps pipelines against the repository's deployment safety rules; no
# Azure or GitHub calls are made.

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$failures = [System.Collections.Generic.List[string]]::new()

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        $failures.Add($Message)
    }
}

function Read-Text([string]$RelativePath) {
    $path = Join-Path $repositoryRoot $RelativePath
    Assert-True (Test-Path -LiteralPath $path) "$RelativePath is missing"
    if (Test-Path -LiteralPath $path) { [IO.File]::ReadAllText($path) -replace "`r`n", "`n" } else { '' }
}

# Every YAML file must parse when a parser is available. PyYAML is optional, so the structural checks below use text.
$yamlFiles = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.github'), (Join-Path $repositoryRoot 'pipelines') -Recurse -File -Include '*.yml', '*.yaml')
Assert-True ($yamlFiles.Count -ge 9) "expected at least nine pipeline and template YAML files, found $($yamlFiles.Count)"
$python = Get-Command python3, python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($python) {
    & $python.Source -c 'import yaml' 2>$null
    if ($LASTEXITCODE -eq 0) {
        foreach ($file in $yamlFiles) {
            & $python.Source -c 'import sys, yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' $file.FullName 2>$null
            Assert-True ($LASTEXITCODE -eq 0) "$($file.Name) isn't valid YAML"
        }
    }
}

# GitHub Actions: third-party actions are pinned to a commit, and CI has read-only access.
foreach ($workflow in Get-ChildItem -LiteralPath (Join-Path $repositoryRoot '.github/workflows') -File -Filter '*.yml') {
    $text = [IO.File]::ReadAllText($workflow.FullName)
    foreach ($use in [regex]::Matches($text, '(?m)^\s*(?:-\s*)?uses:\s*(\S+)')) {
        $reference = $use.Groups[1].Value
        Assert-True ($reference -match '^[\w.-]+/[\w./-]+@[0-9a-f]{40}$') "$($workflow.Name): '$reference' isn't pinned to a full commit SHA"
    }
    Assert-True ($text -match '(?m)^permissions:') "$($workflow.Name) doesn't set top-level permissions"
    Assert-True ($text -notmatch 'pull_request_target') "$($workflow.Name) uses pull_request_target"
}

$ci = Read-Text '.github/workflows/ci.yml'
Assert-True ($ci -match '(?ms)^permissions:\n\s+contents: read\s*\n(?!\s)') 'ci.yml must grant only contents: read'
Assert-True ($ci -notmatch 'id-token') 'ci.yml must not request an Azure token'
Assert-True ($ci -match 'tests/|test-\*\.ps1|''tests''') 'ci.yml must run the tests'

$deployments = @(
    @{ Path = '.github/workflows/deploy-bicep.yml'; Files = @('deploy/bicep/pipeline.local.bicepparam') }
    @{ Path = '.github/workflows/deploy-terraform.yml'; Files = @('deploy/terraform/pipeline.local.tfvars', 'deploy/terraform/backend.hcl', 'deploy/terraform/backend_override.tf') }
)
foreach ($deployment in $deployments) {
    $name = Split-Path $deployment.Path -Leaf
    $text = Read-Text $deployment.Path
    $triggers = [regex]::Match($text, '(?ms)^on:\n(.*?)^\S').Groups[1].Value
    $events = @([regex]::Matches($triggers, '(?m)^  (\w+):') | ForEach-Object { $_.Groups[1].Value })
    Assert-True ($events.Count -eq 1 -and $events[0] -eq 'workflow_dispatch') "$name must run only on workflow_dispatch; found $($events -join ', ')"
    Assert-True ($text -match '(?m)^\s+id-token: write') "$name must request id-token: write for OpenID Connect"
    Assert-True ($text -match '(?m)^\s+environment: \$\{\{ inputs\.environment \}\}') "$name must run in the selected environment"
    Assert-True ($text -match 'azure/login@') "$name must sign in with azure/login"
    Assert-True ($text -notmatch 'client-secret|AZURE_CREDENTIALS|creds:') "$name must not use a client secret"
    Assert-True ($text -match 'writes_fenced' -and $text -match "WRITES_FENCED -ne 'true'") "$name must require fenced writes for switch-direction"
    Assert-True ($text -match '(?ms)if: always\(\)\s+run: \|.*') "$name must clean up generated files in an always() step"
    foreach ($file in $deployment.Files) {
        Assert-True ($text.Contains($file)) "$name doesn't write or clean up $file"
        git -C $repositoryRoot check-ignore -q $file
        Assert-True ($LASTEXITCODE -eq 0) "$file, which $name writes, isn't git-ignored"
    }
    # Inputs reach scripts through environment variables, not by expression injection into the script text.
    foreach ($run in [regex]::Matches($text, '(?ms)run: \|\n(.*?)(?=\n\s*- name:|\z)')) {
        Assert-True ($run.Groups[1].Value -notmatch '\$\{\{\s*inputs\.') "$name interpolates an input directly into a script"
    }
}

# Azure DevOps: deployments are manual, gated by an environment, and use a service connection.
$adoCi = Read-Text 'pipelines/azure-devops/ci.yml'
Assert-True ($adoCi -notmatch 'AzureCLI@|azureSubscription') 'pipelines/azure-devops/ci.yml must not use Azure credentials'
foreach ($name in 'deploy-bicep.yml', 'deploy-terraform.yml') {
    $text = Read-Text "pipelines/azure-devops/$name"
    Assert-True ($text -match '(?m)^trigger: none\s*$') "$name must set trigger: none"
    Assert-True ($text -match '(?m)^pr: none\s*$') "$name must set pr: none"
    Assert-True ($text -notmatch '(?m)^schedules:') "$name must not have schedules"
    Assert-True ($text -match '(?m)^\s+- deployment:' -and $text -match 'environment: \$\{\{ parameters\.environment \}\}') "$name must use a deployment job in the selected environment"
    Assert-True ($text -match 'azureSubscription: \$\(serviceConnection\)') "$name must sign in with the service connection"
    Assert-True ($text -match 'DownloadSecureFile@1') "$name must read its configuration from a secure file"
    Assert-True ($text -match 'writesFenced') "$name must require fenced writes for switch-direction"
    Assert-True ($text -match 'condition: always\(\)') "$name must clean up generated files in an always() step"
}
$adoTerraform = Read-Text 'pipelines/azure-devops/deploy-terraform.yml'
Assert-True ($adoTerraform -match 'ARM_ADO_PIPELINE_SERVICE_CONNECTION_ID' -and $adoTerraform -match 'SYSTEM_ACCESSTOKEN: \$\(System\.AccessToken\)') 'deploy-terraform.yml must configure Terraform for workload identity federation'

if ($failures.Count -gt 0) {
    throw "pipeline check failed:`n$($failures -join "`n")"
}
Write-Host 'Pipeline checks passed.'
