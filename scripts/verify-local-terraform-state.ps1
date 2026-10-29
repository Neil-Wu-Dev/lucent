[CmdletBinding()]
param(
    [string]$ProjectDir = 'D:\dev\lucent',
    [string]$StatePath = 'D:\TerraformState\lucent\terraform.tfstate',
    [string]$BackupDirectory = 'D:\TerraformStateBackups\lucent'
)

$ErrorActionPreference = 'Stop'
$stateManager = Join-Path $PSScriptRoot 'manage-local-terraform-state.ps1'
$infrastructureDirectory = Join-Path $ProjectDir 'infrastructure'
$testRoot = Join-Path $env:TEMP ('lucent-local-state-verify-' + [guid]::NewGuid())

function Assert-ExitCode {
    param([int]$ExitCode, [string]$Message)
    if ($ExitCode -ne 0) { throw $Message }
}

try {
    & $stateManager -Action Verify -StatePath $StatePath -BackupDirectory $BackupDirectory
    & $stateManager -Action SelfTest -StatePath $StatePath -BackupDirectory $BackupDirectory

    # A clean directory represents a new GitHub Actions checkout. The backend
    # remains the same because its path is absolute and outside the checkout.
    $checkoutTest = Join-Path $testRoot 'checkout\infrastructure'
    New-Item -ItemType Directory -Path $checkoutTest -Force | Out-Null
    Get-ChildItem -LiteralPath $infrastructureDirectory -Force |
        Where-Object { $_.Name -ne '.terraform' -and $_.Name -ne 'terraform.tfstate' -and $_.Name -notlike 'terraform.tfstate.*' } |
        Copy-Item -Destination $checkoutTest -Recurse -Force

    # A GitHub runner keeps provider binaries locally. Reuse those binaries for
    # this offline-safe test, while deliberately excluding backend metadata.
    $providerCache = Join-Path $infrastructureDirectory '.terraform\providers'
    if (-not (Test-Path -LiteralPath $providerCache -PathType Container)) {
        throw "Runner provider cache is missing: $providerCache"
    }
    Copy-Item -LiteralPath $providerCache -Destination (Join-Path $checkoutTest '.terraform\providers') -Recurse -Force

    Write-Host 'Checking Local State from an isolated checkout...'
    & terraform "-chdir=$checkoutTest" init -reconfigure | Out-Null
    Assert-ExitCode -ExitCode $LASTEXITCODE -Message 'A clean checkout could not initialize the fixed Local Backend.'

    $outputs = & terraform "-chdir=$checkoutTest" output -json | ConvertFrom-Json
    Assert-ExitCode -ExitCode $LASTEXITCODE -Message 'A clean checkout could not read the fixed Local State.'
    if ($null -eq $outputs) { throw 'A clean checkout returned no Terraform outputs.' }

    # Exercise Terraform's native local-backend lock in an isolated state file.
    Write-Host 'Checking Terraform Local Backend lock contention...'
    $lockTest = Join-Path $testRoot 'lock-test'
    New-Item -ItemType Directory -Path $lockTest -Force | Out-Null
    @'
terraform {
  backend "local" {
    path = "lock-test.tfstate"
  }
}

resource "terraform_data" "hold_lock" {
  provisioner "local-exec" {
    command = "ping 127.0.0.1 -n 13 > nul"
  }
}
'@ | Set-Content -LiteralPath (Join-Path $lockTest 'main.tf') -NoNewline -Encoding utf8

    & terraform "-chdir=$lockTest" init -reconfigure | Out-Null
    Assert-ExitCode -ExitCode $LASTEXITCODE -Message 'Could not initialize the isolated Local Backend lock test.'

    $firstOutput = Join-Path $lockTest 'first.out'
    $firstError = Join-Path $lockTest 'first.err'
    $first = Start-Process -FilePath terraform -ArgumentList @("-chdir=$lockTest", 'apply', '-auto-approve') -PassThru -RedirectStandardOutput $firstOutput -RedirectStandardError $firstError

    Start-Sleep -Seconds 2
    $first.Refresh()
    if ($first.HasExited) {
        $first.WaitForExit()
        $details = ((Get-Content -LiteralPath $firstOutput, $firstError -Raw -ErrorAction SilentlyContinue) -join "`n")
        throw "The first Local Backend lock test did not remain active. $details"
    }

    $secondOutput = & terraform "-chdir=$lockTest" plan '-lock-timeout=1s' 2>&1
    $secondExitCode = $LASTEXITCODE
    $first.WaitForExit()
    Assert-ExitCode -ExitCode $first.ExitCode -Message 'The first Local Backend lock test apply failed.'
    if ($secondExitCode -eq 0 -or ($secondOutput -join "`n") -notmatch 'state lock|Lock Info|Error acquiring the state lock') {
        throw 'Terraform Local Backend locking did not reject a concurrent state operation.'
    }

    Write-Host 'PASS: fixed Local State, backup/restore, checkout independence, and Terraform locking were verified.'
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}
