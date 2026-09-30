$ErrorActionPreference = 'Stop'

$terraform = Get-Command terraform -ErrorAction SilentlyContinue
if (-not $terraform) {
    Write-Host 'Terraform not found on PATH; skipping Terraform checks.'
    exit 0
}

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$terraformDirectory = Join-Path $repositoryRoot 'deploy\terraform'
$tfDataDir = Join-Path $terraformDirectory '.terraform-test'
$previousTfDataDir = $env:TF_DATA_DIR

try {
    $env:TF_DATA_DIR = $tfDataDir
    & terraform "-chdir=$terraformDirectory" fmt -check -recursive
    if ($LASTEXITCODE -ne 0) { throw 'terraform fmt failed.' }
    & terraform "-chdir=$terraformDirectory" init -backend=false -input=false -no-color
    if ($LASTEXITCODE -ne 0) { throw 'terraform init failed.' }
    & terraform "-chdir=$terraformDirectory" validate -no-color
    if ($LASTEXITCODE -ne 0) { throw 'terraform validate failed.' }
    & terraform "-chdir=$terraformDirectory" test -no-color
    if ($LASTEXITCODE -ne 0) { throw 'terraform test failed.' }
} finally {
    $env:TF_DATA_DIR = $previousTfDataDir
}

Write-Host 'Terraform checks passed.'
