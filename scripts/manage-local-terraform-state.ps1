[CmdletBinding()]
param(
    [ValidateSet('Initialize', 'Backup', 'BackupIfPresent', 'Verify', 'Restore', 'SelfTest')]
    [string]$Action = 'Initialize',
    [string]$StatePath = 'D:\TerraformState\lucent-sandbox\terraform.tfstate',
    [string]$BackupDirectory = 'D:\TerraformStateBackups\lucent-sandbox',
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

function Invoke-NativeCaptured {
    param(
        [Parameter(Mandatory = $true)][string]$Exe,
        [string[]]$Arguments
    )

    $errorFile = Join-Path $env:TEMP ('lucent-state-' + [guid]::NewGuid().ToString() + '.err')

    try {
        # In Windows PowerShell 5.1, merging stderr with 2>&1 while the error
        # preference is Stop can throw NativeCommandError before the exit code
        # is available. Keep stderr separate and always inspect the exit code.
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $standardOutput = @()
        $exitCode = 1
        $invocationFailure = $null

        try {
            $standardOutput = & $Exe @Arguments 2> $errorFile
            if ($null -eq $LASTEXITCODE) {
                $invocationFailure = "Native command did not return an exit code: $Exe"
            }
            else {
                $exitCode = [int]$LASTEXITCODE
            }
        }
        catch {
            $invocationFailure = $_.Exception.Message
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        $standardError = if (Test-Path -LiteralPath $errorFile) {
            Get-Content -LiteralPath $errorFile -Raw
        }
        else {
            ''
        }

        if ($invocationFailure) {
            $standardError = (@(
                    $standardError,
                    $invocationFailure
                ) | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_)
                }) -join [Environment]::NewLine
        }

        $standardOutputText = $standardOutput -join [Environment]::NewLine
        if ($null -eq $standardOutputText) {
            $standardOutputText = ''
        }

        if ($null -eq $standardError) {
            $standardError = ''
        }

        return [pscustomobject]@{
            ExitCode       = $exitCode
            StandardOutput = [string]$standardOutputText
            StandardError  = [string]$standardError
        }
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-PrivateAclSids {
    return @(
        [Security.Principal.WindowsIdentity]::GetCurrent().User.Value,
        'S-1-5-18',       # Local System
        'S-1-5-32-544'    # Built-in Administrators
    )
}

function Assert-PrivateAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    $expectedSids = @(Get-PrivateAclSids)
    $acl = Get-Acl -LiteralPath $Path

    if (-not $acl.AreAccessRulesProtected) {
        throw "NTFS ACL inheritance is still enabled for $Path"
    }

    $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    foreach ($sid in $expectedSids) {
        $hasFullControl = @(
            $rules | Where-Object {
                $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                $_.IdentityReference.Value -eq $sid -and
                ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -eq [Security.AccessControl.FileSystemRights]::FullControl
            }
        ).Count -gt 0

        if (-not $hasFullControl) {
            throw "Required private NTFS ACL entry is missing for SID $sid on $Path"
        }
    }

    $unexpectedAllowRules = @(
        $rules | Where-Object {
            $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $_.IdentityReference.Value -notin $expectedSids
        }
    )

    if ($unexpectedAllowRules.Count -gt 0) {
        $identities = $unexpectedAllowRules | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique
        throw "Unexpected NTFS allow rule(s) remain on ${Path}: $($identities -join ', ')"
    }
}

function Assert-PrivateAclTree {
    param([Parameter(Mandatory = $true)][string]$Path)

    Assert-PrivateAcl -Path $Path

    Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop |
        ForEach-Object {
            Assert-PrivateAcl -Path $_.FullName
        }
}

function Set-PrivateAclEntry {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][bool]$IsDirectory
    )

    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $currentGrant = if ($IsDirectory) { "${currentIdentity}:(OI)(CI)F" } else { "${currentIdentity}:F" }
    $systemGrant = if ($IsDirectory) { 'SYSTEM:(OI)(CI)F' } else { 'SYSTEM:F' }
    $administratorsGrant = if ($IsDirectory) { 'Administrators:(OI)(CI)F' } else { 'Administrators:F' }

    $result = Invoke-NativeCaptured -Exe 'icacls.exe' -Arguments @(
        $Path,
        '/inheritance:r',
        '/grant:r',
        $currentGrant,
        $systemGrant,
        $administratorsGrant,
        '/c'
    )

    if ($result.ExitCode -ne 0) {
        throw "Could not set the private NTFS ACL for $Path (exit $($result.ExitCode)): $($result.StandardError)"
    }

}

function Set-PrivateDirectoryAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    # Do not use icacls /t with (OI)(CI) grants: those directory inheritance
    # flags can leave existing files without a usable allow rule. Apply the
    # correct rule type to every existing directory and file explicitly.
    Set-PrivateAclEntry -Path $Path -IsDirectory $true

    $children = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop)
    foreach ($directory in @($children | Where-Object { $_.PSIsContainer })) {
        Set-PrivateAclEntry -Path $directory.FullName -IsDirectory $true
    }

    foreach ($file in @($children | Where-Object { -not $_.PSIsContainer })) {
        Set-PrivateAclEntry -Path $file.FullName -IsDirectory $false
    }

    Assert-PrivateAclTree -Path $Path
}

function Set-PrivateFileAcl {
    param([Parameter(Mandatory = $true)][string]$Path)

    Set-PrivateAclEntry -Path $Path -IsDirectory $false
    Assert-PrivateAcl -Path $Path
}

function Enable-DirectoryEncryption {
    param([Parameter(Mandatory = $true)][string]$Path)

    # EFS availability is determined by actually requesting encryption, rather
    # than inferring support from the Windows edition, volume type, or registry.
    $encryptResult = Invoke-NativeCaptured -Exe 'cipher.exe' -Arguments @('/e', "/s:$Path")
    if ($encryptResult.ExitCode -ne 0) {
        $details = @($encryptResult.StandardError, $encryptResult.StandardOutput) -join ' '
        Write-Warning "EFS encryption is unavailable for $Path (cipher.exe exit $($encryptResult.ExitCode)): $details State is NOT encrypted. Verified private NTFS ACL protection remains active."
        return $false
    }

    $verifyResult = Invoke-NativeCaptured -Exe 'cipher.exe' -Arguments @('/c', $Path)
    if ($verifyResult.ExitCode -ne 0) {
        $details = @($verifyResult.StandardError, $verifyResult.StandardOutput) -join ' '
        Write-Warning "EFS encryption could not be verified for $Path (cipher.exe exit $($verifyResult.ExitCode)): $details State is NOT reported as encrypted. Verified private NTFS ACL protection remains active."
        return $false
    }

    Write-Host "EFS encryption enabled and verified for $Path"
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

switch ($Action) {
    'Initialize' {
        Initialize-StateStorage
        Write-Host "Protected Local State directories are ready: $(Split-Path -Parent $StatePath), $BackupDirectory"
    }
    'Backup' {
        $backup = New-StateBackup -SourcePath $StatePath
        Write-Host "Terraform state backup verified: $backup"
    }
    'BackupIfPresent' {
        if (Test-Path -LiteralPath $StatePath -PathType Leaf) {
            $backup = New-StateBackup -SourcePath $StatePath
            Write-Host "Existing Terraform state backup verified: $backup"
        }
        else {
            Write-Host "No Sandbox Terraform state exists yet; no pre-apply backup is required."
        }
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
