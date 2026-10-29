[CmdletBinding()]
param(
    [string]$ProjectDir = 'D:\dev\lucent',
    [string]$TerraformDir = '',
    [string]$StatePath = 'D:\TerraformState\lucent\terraform.tfstate',
    [string]$BackupDirectory = 'D:\TerraformStateBackups\lucent',
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

function Get-CandidateState {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $content = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($content)) { return $null }
        $state = $content | ConvertFrom-Json
        if ($state.version -ne 4 -or [string]::IsNullOrWhiteSpace($state.lineage) -or @($state.resources).Count -eq 0) {
            return $null
        }

        return [pscustomobject]@{
            Path          = (Resolve-Path -LiteralPath $Path).Path
            Serial        = [long]$state.serial
            ResourceCount = @($state.resources).Count
            LastWriteTime = (Get-Item -LiteralPath $Path).LastWriteTimeUtc
        }
    }
    catch {
        return $null
    }
}

$targetExists = Test-Path -LiteralPath $StatePath -PathType Leaf
if ($targetExists) {
    # Never overwrite a non-empty protected state. Its validity is checked before
    # any Terraform command is allowed to use it.
    $target = Get-CandidateState -Path $StatePath
    if ($null -eq $target) {
        throw "Protected local state exists but is not a valid resource state: $StatePath. It was not changed."
    }

    & $stateManager -Action Backup -StatePath $StatePath -BackupDirectory $BackupDirectory
    & $stateManager -Action Verify -StatePath $StatePath -BackupDirectory $BackupDirectory
    Write-Host "Protected local state already exists. Serial=$($target.Serial), Resources=$($target.ResourceCount)"
}
else {
    $candidates = @(
        Get-ChildItem -LiteralPath $TerraformDir -Filter 'terraform.tfstate*' -File -ErrorAction SilentlyContinue |
        ForEach-Object { Get-CandidateState -Path $_.FullName } |
        Where-Object { $null -ne $_ } |
        Sort-Object @{ Expression = 'Serial'; Descending = $true }, @{ Expression = 'LastWriteTime'; Descending = $true }
    )

    if ($candidates.Count -eq 0) {
        throw "No recoverable local Terraform state was found in $TerraformDir. Refusing to initialize an empty state until AWS resources are checked."
    }

    $source = $candidates[0]
    $migrationBackupDirectory = Join-Path $BackupDirectory 'pre-migration'
    if (-not (Test-Path -LiteralPath $migrationBackupDirectory)) {
        New-Item -ItemType Directory -Path $migrationBackupDirectory -Force | Out-Null
    }

    $migrationBackup = Join-Path $migrationBackupDirectory ('terraform-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-serial-' + $source.Serial + '.tfstate')
    Copy-Item -LiteralPath $source.Path -Destination $migrationBackup -ErrorAction Stop
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $migrationBackup /inheritance:r /grant:r "${currentIdentity}:F" 'SYSTEM:F' 'Administrators:F' /c | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not set the private ACL on the pre-migration state backup.' }
    $sourceHash = (Get-FileHash -LiteralPath $source.Path -Algorithm SHA256).Hash
    $backupHash = (Get-FileHash -LiteralPath $migrationBackup -Algorithm SHA256).Hash
    if ($sourceHash -ne $backupHash) {
        Remove-Item -LiteralPath $migrationBackup -Force -ErrorAction SilentlyContinue
        throw 'Pre-migration state backup integrity check failed.'
    }

    Copy-Item -LiteralPath $source.Path -Destination $StatePath -ErrorAction Stop
    & icacls.exe $StatePath /inheritance:r /grant:r "${currentIdentity}:F" 'SYSTEM:F' 'Administrators:F' /c | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not set the private ACL on the migrated local state.' }
    & $stateManager -Action Backup -StatePath $StatePath -BackupDirectory $BackupDirectory
    & $stateManager -Action Verify -StatePath $StatePath -BackupDirectory $BackupDirectory
    Write-Host "Migrated the latest verified local state. Serial=$($source.Serial), Resources=$($source.ResourceCount)"
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
