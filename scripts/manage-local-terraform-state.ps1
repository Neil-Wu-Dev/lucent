[CmdletBinding()]
param(
    [ValidateSet('Initialize', 'Backup', 'Verify', 'Restore', 'SelfTest')]
    [string]$Action = 'Initialize',
    [string]$StatePath = 'D:\TerraformState\lucent\terraform.tfstate',
    [string]$BackupDirectory = 'D:\TerraformStateBackups\lucent',
    [ValidateRange(1, 365)]
    [int]$RetentionCount = 30,
    [string]$RestoreBackup = ''
)

$ErrorActionPreference = 'Stop'

function Get-FileHashValue {
    param([Parameter(Mandatory = $true)][string]$Path)

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StateMetadata {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Terraform state does not exist: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($content)) {
        throw "Terraform state is empty: $Path"
    }

    try {
        $state = $content | ConvertFrom-Json
    }
    catch {
        throw "Terraform state is not valid JSON: $Path"
    }

    if ($state.version -ne 4 -or [string]::IsNullOrWhiteSpace($state.lineage)) {
        throw "Terraform state has an invalid schema: $Path"
    }

    return [pscustomobject]@{
        Path          = (Resolve-Path -LiteralPath $Path).Path
        Hash          = Get-FileHashValue -Path $Path
        Serial        = [long]$state.serial
        Lineage       = [string]$state.lineage
        ResourceCount = @($state.resources).Count
    }
}

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    # icacls changes the DACL only. Unlike Set-Acl with a newly constructed
    # descriptor, it does not require SeSecurityPrivilege for the SACL.
    & icacls.exe $Path /inheritance:r /grant:r "${currentIdentity}:(OI)(CI)F" 'SYSTEM:(OI)(CI)F' 'Administrators:(OI)(CI)F' /t /c | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set the private NTFS ACL for $Path"
    }
}

function Set-PrivateFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    & icacls.exe $Path /inheritance:r /grant:r "${currentIdentity}:F" 'SYSTEM:F' 'Administrators:F' /c | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "Could not set the private NTFS ACL for $Path"
    }
}

function Enable-DirectoryEncryption {
    param([Parameter(Mandatory = $true)][string]$Path)

    # EFS protects this data at rest without enabling or changing BitLocker.
    $cipherOutput = & cipher.exe /e /s:$Path 2>&1
    if ($LASTEXITCODE -ne 0 -or ($cipherOutput -join "`n") -match 'not supported|not support') {
        Write-Warning "EFS is unavailable for $Path. The private NTFS ACL remains active; no BitLocker setting was changed."
        return $false
    }

    return $true
}

function Initialize-StateStorage {
    $stateDirectory = Split-Path -Parent $StatePath

    foreach ($directory in @($stateDirectory, $BackupDirectory)) {
        if (-not (Test-Path -LiteralPath $directory)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }

        Set-PrivateDirectoryAcl -Path $directory
        $null = Enable-DirectoryEncryption -Path $directory
    }
}

function Write-BackupManifest {
    param(
        [Parameter(Mandatory = $true)][string]$BackupPath,
        [Parameter(Mandatory = $true)]$Metadata
    )

    $manifest = [ordered]@{
        stateFile     = Split-Path -Leaf $BackupPath
        sha256        = $Metadata.Hash
        serial        = $Metadata.Serial
        lineage       = $Metadata.Lineage
        resourceCount = $Metadata.ResourceCount
        createdAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json

    [IO.File]::WriteAllText(
        "$BackupPath.sha256.json",
        $manifest,
        [Text.UTF8Encoding]::new($false)
    )
    Set-PrivateFileAcl -Path "$BackupPath.sha256.json"
}

function New-StateBackup {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [string]$DestinationDirectory = $BackupDirectory,
        [int]$KeepCount = $RetentionCount
    )

    $source = Get-StateMetadata -Path $SourcePath
    if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
        New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
        Set-PrivateDirectoryAcl -Path $DestinationDirectory
        Enable-DirectoryEncryption -Path $DestinationDirectory
    }

    $name = 'terraform-' + (Get-Date -Format 'yyyyMMdd-HHmmssfff') + '-serial-' + $source.Serial + '.tfstate'
    $destination = Join-Path $DestinationDirectory $name
    Copy-Item -LiteralPath $SourcePath -Destination $destination -ErrorAction Stop
    Set-PrivateFileAcl -Path $destination
    $copy = Get-StateMetadata -Path $destination

    if ($source.Hash -ne $copy.Hash -or $source.Lineage -ne $copy.Lineage -or $source.Serial -ne $copy.Serial) {
        Remove-Item -LiteralPath $destination -Force -ErrorAction SilentlyContinue
        throw "Terraform state backup integrity check failed: $destination"
    }

    Write-BackupManifest -BackupPath $destination -Metadata $copy

    $backups = @(Get-ChildItem -LiteralPath $DestinationDirectory -Filter 'terraform-*.tfstate' -File |
        Sort-Object LastWriteTimeUtc -Descending)
    if ($backups.Count -gt $KeepCount) {
        foreach ($expired in $backups[$KeepCount..($backups.Count - 1)]) {
            Remove-Item -LiteralPath $expired.FullName, "$($expired.FullName).sha256.json" -Force -ErrorAction Stop
        }
    }

    return $destination
}

function Test-StateBackup {
    param([Parameter(Mandatory = $true)][string]$BackupPath)

    $metadata = Get-StateMetadata -Path $BackupPath
    $manifestPath = "$BackupPath.sha256.json"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Terraform state backup manifest does not exist: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.sha256 -ne $metadata.Hash -or $manifest.lineage -ne $metadata.Lineage -or [long]$manifest.serial -ne $metadata.Serial) {
        throw "Terraform state backup manifest does not match its state file: $BackupPath"
    }
}

function Restore-StateBackup {
    if ([string]::IsNullOrWhiteSpace($RestoreBackup)) {
        throw 'RestoreBackup is required when Action is Restore.'
    }

    $resolvedBackup = (Resolve-Path -LiteralPath $RestoreBackup -ErrorAction Stop).Path
    $resolvedBackupDirectory = (Resolve-Path -LiteralPath $BackupDirectory -ErrorAction Stop).Path.TrimEnd('\')
    if (-not $resolvedBackup.StartsWith($resolvedBackupDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'RestoreBackup must be inside the protected Terraform backup directory.'
    }

    Test-StateBackup -BackupPath $resolvedBackup
    if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
        $null = New-StateBackup -SourcePath $StatePath
    }

    Copy-Item -LiteralPath $resolvedBackup -Destination $StatePath -Force
    Set-PrivateFileAcl -Path $StatePath
    $restored = Get-StateMetadata -Path $StatePath
    $expected = Get-StateMetadata -Path $resolvedBackup
    if ($restored.Hash -ne $expected.Hash) {
        throw 'Terraform state restore integrity check failed.'
    }
}

function Invoke-RestoreSelfTest {
    $testRoot = Join-Path $env:TEMP ('lucent-state-self-test-' + [guid]::NewGuid())
    $testState = Join-Path $testRoot 'active\terraform.tfstate'
    $testBackups = Join-Path $testRoot 'backups'

    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $testState), $testBackups -Force | Out-Null
        $lineage = [guid]::NewGuid().ToString()
        $original = @{ version = 4; terraform_version = '1.16.4'; serial = 1; lineage = $lineage; outputs = @{}; resources = @() } | ConvertTo-Json
        [IO.File]::WriteAllText($testState, $original, [Text.UTF8Encoding]::new($false))
        $null = New-StateBackup -SourcePath $testState -DestinationDirectory $testBackups -KeepCount 2

        $changed = @{ version = 4; terraform_version = '1.16.4'; serial = 2; lineage = $lineage; outputs = @{}; resources = @() } | ConvertTo-Json
        [IO.File]::WriteAllText($testState, $changed, [Text.UTF8Encoding]::new($false))
        $backup = New-StateBackup -SourcePath $testState -DestinationDirectory $testBackups -KeepCount 1

        Test-StateBackup -BackupPath $backup
        if (@(Get-ChildItem -LiteralPath $testBackups -Filter 'terraform-*.tfstate' -File).Count -ne 1) {
            throw 'Terraform state retention self-test did not prune the expired backup.'
        }

        $changedAgain = @{ version = 4; terraform_version = '1.16.4'; serial = 3; lineage = $lineage; outputs = @{}; resources = @() } | ConvertTo-Json
        [IO.File]::WriteAllText($testState, $changedAgain, [Text.UTF8Encoding]::new($false))
        Copy-Item -LiteralPath $backup -Destination $testState -Force
        if ((Get-StateMetadata -Path $testState).Serial -ne 2) {
            throw 'Terraform state restore self-test did not restore the expected state.'
        }
    }
    finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Initialize-StateStorage

switch ($Action) {
    'Initialize' {
        Write-Host "Protected Local State directories are ready: $(Split-Path -Parent $StatePath), $BackupDirectory"
    }
    'Backup' {
        $backup = New-StateBackup -SourcePath $StatePath
        Write-Host "Terraform state backup verified: $backup"
    }
    'Verify' {
        $active = Get-StateMetadata -Path $StatePath
        $backups = @(Get-ChildItem -LiteralPath $BackupDirectory -Filter 'terraform-*.tfstate' -File)
        if ($backups.Count -eq 0) {
            throw "No Terraform state backups exist in $BackupDirectory"
        }
        foreach ($backup in $backups) {
            Test-StateBackup -BackupPath $backup.FullName
        }
        Write-Host "Terraform state and $($backups.Count) backup(s) passed integrity verification. Serial=$($active.Serial), Resources=$($active.ResourceCount)"
    }
    'Restore' {
        Restore-StateBackup
        Write-Host 'Terraform state restore passed integrity verification.'
    }
    'SelfTest' {
        Invoke-RestoreSelfTest
        Write-Host 'Terraform state backup and restore self-test passed.'
    }
}
