[CmdletBinding()]
param(
    [string]$ProjectDir = 'D:\dev\lucent',
    [string]$TerraformDir = '',
    [string]$StatePath = 'D:\TerraformState\lucent-sandbox\terraform.tfstate',
    [string]$BackupDirectory = 'D:\TerraformStateBackups\lucent-sandbox',
    [switch]$SkipTerraformInit
)

$ErrorActionPreference = 'Stop'

if (-not $TerraformDir) {
    $TerraformDir = Join-Path $ProjectDir 'infrastructure'
}

if (-not (Test-Path -LiteralPath $TerraformDir -PathType Container)) {
    throw "Terraform directory not found: $TerraformDir"
}

$stateManager = Join-Path $PSScriptRoot 'manage-local-terraform-state.ps1'
& $stateManager -Action Initialize -StatePath $StatePath -BackupDirectory $BackupDirectory

$targetExists = Test-Path -LiteralPath $StatePath -PathType Leaf
if ($targetExists) {
    # A Sandbox state is never replaced with the retired Academy state. If it
    # already exists, preserve and validate only that Sandbox ledger.
    & $stateManager -Action Backup -StatePath $StatePath -BackupDirectory $BackupDirectory
    & $stateManager -Action Verify -StatePath $StatePath -BackupDirectory $BackupDirectory
    Write-Host "Existing Sandbox Terraform State was preserved and verified: $StatePath"
}
else {
    # This is the intentional first-run path for a separate AWS Sandbox. Do
    # not discover, copy, migrate, or alter the Academy state.
    Write-Host "No Sandbox Terraform State exists yet. Terraform will initialize a new empty Sandbox state at: $StatePath"
}

if (-not $SkipTerraformInit) {
    & terraform "-chdir=$TerraformDir" init -reconfigure
    if ($LASTEXITCODE -ne 0) {
        throw 'Terraform Local Backend initialization failed.'
    }

    $null = & terraform "-chdir=$TerraformDir" state pull | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'Terraform could not read the protected Local State after initialization.'
    }
}

Write-Host "Terraform Local State is ready: $StatePath"
