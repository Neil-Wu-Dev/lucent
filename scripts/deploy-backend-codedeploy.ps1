
# Lucent Backend deployment through AWS CodeDeploy. This script deliberately
# uses SSM only to bootstrap CodeDeploy Agent on existing ASG instances; it
# never starts or replaces the Backend Docker container through SSM.
[CmdletBinding()]
param(
    [string]$ProjectDir = 'D:\dev\lucent',
    [string]$TerraformDir = '',
    [string]$BackendDir = '',
    [string]$RevisionId = ''
)

$ErrorActionPreference = 'Stop'
$region = 'eu-west-1'

$AwsExe = 'aws'
$awsCandidates = @(
    'D:\Stuff\AWS CLI\aws.exe',
    'C:\Program Files\Amazon\AWSCLIV2\aws.exe'
)

foreach ($candidate in $awsCandidates) {
    if (Test-Path -LiteralPath $candidate) {
        $AwsExe = $candidate
        break
    }
}

if (-not $BackendDir) { $BackendDir = Join-Path $ProjectDir 'backend' }
if (-not $TerraformDir) { $TerraformDir = Join-Path $ProjectDir 'infrastructure' }

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)

    $errorFile = Join-Path $env:TEMP ('lucent-codedeploy-' + [guid]::NewGuid().ToString() + '.err')

    try {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'

        try {
            $output = & $Exe @Arguments 2> $errorFile
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($exitCode -ne 0) {
            $standardError = if (Test-Path -LiteralPath $errorFile) {
                Get-Content -LiteralPath $errorFile -Raw
            }
            else {
                ''
            }
            throw "$Exe $($Arguments -join ' ') failed (exit $exitCode): $standardError"
        }

        return ($output -join "`n")
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-TfValue {
    param([Parameter(Mandatory = $true)][string]$Name)

    $raw = Invoke-Native -Exe 'terraform' -Arguments @(
        "-chdir=$TerraformDir", 'output', '-json', $Name
    )
    return ($raw | ConvertFrom-Json)
}

function Get-AsgInServiceInstanceIds {
    param([Parameter(Mandatory = $true)][string]$AutoScalingGroupName)

    $raw = Invoke-Native -Exe $AwsExe -Arguments @(
        'autoscaling', 'describe-auto-scaling-groups', '--region', $region,
        '--auto-scaling-group-names', $AutoScalingGroupName,
        '--query', "AutoScalingGroups[0].Instances[?LifecycleState=='InService'].InstanceId",
        '--output', 'json'
    )
    return @(($raw | ConvertFrom-Json) | ForEach-Object { [string]$_ })
}

function Test-SameInstanceIdSet {
    param([string[]]$Left, [string[]]$Right)

    return ((@($Left | Sort-Object) -join ',') -eq (@($Right | Sort-Object) -join ','))
}

function Wait-ForSsmManagedInstances {
    param([string[]]$InstanceIds, [int]$TimeoutSeconds = 600)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pending = @($InstanceIds)

    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $raw = Invoke-Native -Exe $AwsExe -Arguments @(
            'ssm', 'describe-instance-information', '--region', $region,
            '--filters', ('Key=InstanceIds,Values=' + ($pending -join ',')),
            '--output', 'json'
        )
        $online = @((($raw | ConvertFrom-Json).InstanceInformationList |
                Where-Object { $_.PingStatus -eq 'Online' } |
                ForEach-Object { [string]$_.InstanceId }))
        $pending = @($pending | Where-Object { $_ -notin $online })

        if ($pending.Count -gt 0) {
            Write-Host "Waiting for SSM Online: $($pending -join ', ')"
            Start-Sleep -Seconds 10
        }
    }

    if ($pending.Count -gt 0) {
        throw "Timed out waiting for SSM Online: $($pending -join ', ')"
    }
}

function Invoke-SsmBootstrap {
    param([string[]]$InstanceIds, [string[]]$Commands)

    $parameterFile = Join-Path $env:TEMP ('lucent-codedeploy-bootstrap-' + [guid]::NewGuid().ToString() + '.json')
    try {
        [IO.File]::WriteAllText(
            $parameterFile,
            (@{ commands = $Commands } | ConvertTo-Json -Compress -Depth 8),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $ssmArguments = @(
            'ssm', 'send-command', '--region', $region,
            '--instance-ids'
        ) + @($InstanceIds) + @(
            '--document-name', 'AWS-RunShellScript',
            '--parameters', ('file://' + $parameterFile.Replace('\', '/')),
            '--query', 'Command.CommandId', '--output', 'text'
        )

        $commandId = (Invoke-Native -Exe $AwsExe -Arguments $ssmArguments).Trim()

        if ([string]::IsNullOrWhiteSpace($commandId)) {
            throw 'CodeDeploy Agent bootstrap did not return an SSM Command ID.'
        }

        foreach ($instanceId in $InstanceIds) {
            $result = $null
            for ($attempt = 0; $attempt -lt 90; $attempt++) {
                Start-Sleep -Seconds 3
                try {
                    $raw = Invoke-Native -Exe $AwsExe -Arguments @(
                        'ssm', 'get-command-invocation', '--region', $region,
                        '--command-id', $commandId, '--instance-id', $instanceId,
                        '--output', 'json'
                    )
                }
                catch {
                    # SendCommand is eventually consistent. Retry only its
                    # temporary missing-invocation response; all other SSM
                    # failures must stop the deployment.
                    if ($_.Exception.Message -match 'InvocationDoesNotExist') { continue }
                    throw
                }
                $result = $raw | ConvertFrom-Json
                if ($result.Status -in @('Success', 'Failed', 'Cancelled', 'TimedOut', 'Cancelling')) { break }
            }

            if ($null -eq $result) {
                throw "Timed out waiting for SSM CodeDeploy Agent bootstrap invocation on $instanceId."
            }

            Write-Host "[CODEDEPLOY AGENT] $instanceId : $($result.Status) / code $($result.ResponseCode)"
            if ($result.StandardOutputContent) { Write-Host $result.StandardOutputContent }
            if ($result.StandardErrorContent) { Write-Host $result.StandardErrorContent }

            if ($null -eq $result -or $result.Status -ne 'Success' -or $result.ResponseCode -ne 0) {
                throw "CodeDeploy Agent bootstrap failed on $instanceId."
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-SsmBootstrapForCurrentAsg {
    param(
        [Parameter(Mandatory = $true)][string]$AutoScalingGroupName,
        [Parameter(Mandatory = $true)][string[]]$Commands,
        [int]$TimeoutSeconds = 1200
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $candidateIds = @(Get-AsgInServiceInstanceIds -AutoScalingGroupName $AutoScalingGroupName)
        if ($candidateIds.Count -lt 2) {
            Write-Host "Waiting for Backend ASG $AutoScalingGroupName to have two InService instances."
            Start-Sleep -Seconds 10
            continue
        }

        try {
            Wait-ForSsmManagedInstances -InstanceIds $candidateIds -TimeoutSeconds 600
            Invoke-SsmBootstrap -InstanceIds $candidateIds -Commands $Commands
        }
        catch {
            $currentIds = @(Get-AsgInServiceInstanceIds -AutoScalingGroupName $AutoScalingGroupName)
            if (-not (Test-SameInstanceIdSet -Left $candidateIds -Right $currentIds)) {
                Write-Warning "Backend ASG membership changed during CodeDeploy Agent bootstrap; retrying only current InService instances."
                Start-Sleep -Seconds 10
                continue
            }
            throw
        }

        $currentIds = @(Get-AsgInServiceInstanceIds -AutoScalingGroupName $AutoScalingGroupName)
        if (Test-SameInstanceIdSet -Left $candidateIds -Right $currentIds) {
            return $currentIds
        }

        Write-Warning "Backend ASG membership changed after CodeDeploy Agent bootstrap; reconciling the current InService instances."
        Start-Sleep -Seconds 10
    }

    throw "Timed out reconciling CodeDeploy Agent bootstrap with the current Backend ASG membership."
}

function Login-EcrDocker {
    param([Parameter(Mandatory = $true)][string]$Registry)

    $command = "`"$AwsExe`" ecr get-login-password --region $region | docker login --username AWS --password-stdin $Registry"
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        cmd.exe /d /s /c $command
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw 'Docker ECR login failed.'
    }
}

function Get-EcrImageDigestForTagOrNull {
    param(
        [Parameter(Mandatory = $true)][string]$RepositoryName,
        [Parameter(Mandatory = $true)][string]$ImageTag
    )

    $errorFile = Join-Path $env:TEMP ('lucent-ecr-digest-' + [guid]::NewGuid().ToString() + '.err')
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $AwsExe ecr describe-images --region $region `
                --repository-name $RepositoryName `
                --image-ids "imageTag=$ImageTag" `
                --query 'imageDetails[0].imageDigest' --output text 2> $errorFile
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        if ($exitCode -ne 0) {
            $details = if (Test-Path -LiteralPath $errorFile) {
                Get-Content -LiteralPath $errorFile -Raw
            }
            else {
                ''
            }
            if ($details -match 'ImageNotFoundException') { return $null }
            throw "Unable to resolve ECR tag ${RepositoryName}:${ImageTag}: $details"
        }

        $digest = ($output -join "`n").Trim()
        if ($digest -notmatch '^sha256:[0-9a-f]{64}$') {
            throw "ECR returned an invalid digest for ${RepositoryName}:${ImageTag}."
        }
        return $digest
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function New-CodeDeployRevisionArchive {
    param(
        [Parameter(Mandatory = $true)][string]$SourceDirectory,
        [Parameter(Mandatory = $true)][string]$ArchivePath
    )

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem

    # Do not calculate an archive name by slicing absolute Windows paths. TEMP
    # can be surfaced as a short path (for example SONICR~1) while child files
    # use their long path. URI relative paths remain correct in either form.
    $sourceRoot = [System.IO.Path]::GetFullPath($SourceDirectory).TrimEnd([char[]]@('\', '/')) + [System.IO.Path]::DirectorySeparatorChar
    $sourceUri = New-Object System.Uri($sourceRoot)

    $archive = [System.IO.Compression.ZipFile]::Open(
        $ArchivePath,
        [System.IO.Compression.ZipArchiveMode]::Create
    )

    try {
        Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse | ForEach-Object {
            $fileUri = New-Object System.Uri([System.IO.Path]::GetFullPath($_.FullName))
            $relativePath = [System.Uri]::UnescapeDataString($sourceUri.MakeRelativeUri($fileUri).ToString()).Replace('\', '/')
            if ([string]::IsNullOrWhiteSpace($relativePath) -or $relativePath.StartsWith('../', [System.StringComparison]::Ordinal)) {
                throw "Cannot derive a ZIP-relative path for $($_.FullName) from $SourceDirectory."
            }
            $entry = $archive.CreateEntry(
                $relativePath,
                [System.IO.Compression.CompressionLevel]::Optimal
            )

            $isShellHook = $relativePath -like 'scripts/*.sh'

            # 0100755 in the ZIP external attributes makes Linux CodeDeploy hook
            # scripts executable even though this archive is built on Windows.
            if ($isShellHook) {
                $entry.ExternalAttributes = -2115174400
            }

            $entryStream = $entry.Open()
            try {
                if ($isShellHook) {
                    $normalizedBytes = Get-NormalizedShellHookBytes -Path $_.FullName
                    $entryStream.Write($normalizedBytes, 0, $normalizedBytes.Length)
                }
                else {
                    $inputStream = [System.IO.File]::OpenRead($_.FullName)
                    try {
                        $inputStream.CopyTo($entryStream)
                    }
                    finally {
                        $inputStream.Dispose()
                    }
                }
            }
            finally {
                $entryStream.Dispose()
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Get-NormalizedShellHookBytes {
    param([Parameter(Mandatory = $true)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "CodeDeploy Shell hook source contains a UTF-8 BOM: $Path"
    }

    try {
        $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    }
    catch {
        throw "CodeDeploy Shell hook is not valid UTF-8: $Path"
    }

    $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
    if (-not $text.StartsWith("#!/bin/bash`n", [StringComparison]::Ordinal)) {
        throw "CodeDeploy Shell hook must start with #!/bin/bash: $Path"
    }
    if (-not $text.EndsWith("`n", [StringComparison]::Ordinal)) {
        $text += "`n"
    }

    return (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
}

function Get-CodeDeployZipEntryBytes {
    param([Parameter(Mandatory = $true)]$Entry)

    $stream = $Entry.Open()
    $memory = New-Object System.IO.MemoryStream
    try {
        $stream.CopyTo($memory)
        $bytes = $memory.ToArray()
    }
    finally {
        $memory.Dispose()
        $stream.Dispose()
    }

    return $bytes
}

function Get-CodeDeployZipEntryText {
    param([Parameter(Mandatory = $true)]$Entry)

    $bytes = Get-CodeDeployZipEntryBytes -Entry $Entry

    try {
        return (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes)
    }
    catch {
        throw "CodeDeploy ZIP entry is not valid UTF-8: $($Entry.FullName)"
    }
}

function Test-CodeDeployRevisionArchive {
    param([Parameter(Mandatory = $true)][string]$ArchivePath)

    $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        $requiredHookPaths = @(
            'scripts/application_stop.sh',
            'scripts/before_install.sh',
            'scripts/after_install.sh',
            'scripts/application_start.sh',
            'scripts/validate_service.sh'
        )
        $requiredPaths = @('appspec.yml', 'deployment.env') + $requiredHookPaths
        $entryNames = @($archive.Entries | ForEach-Object { $_.FullName })

        foreach ($entryName in ($entryNames | Sort-Object)) {
            Write-Host "CodeDeploy ZIP entry: $entryName"
        }

        foreach ($requiredPath in $requiredPaths) {
            if ($requiredPath -notin $entryNames) {
                throw "CodeDeploy revision ZIP is missing required root entry: $requiredPath"
            }
        }

        $appSpec = $archive.GetEntry('appspec.yml')
        $appSpecText = Get-CodeDeployZipEntryText -Entry $appSpec
        if ($appSpecText -notmatch '(?m)^version:\s*0\.0\s*$' -or $appSpecText -notmatch '(?m)^os:\s*linux\s*$') {
            throw 'CodeDeploy revision ZIP appspec.yml is not a Linux CodeDeploy AppSpec document.'
        }
        foreach ($requiredHookPath in $requiredHookPaths) {
            if ($appSpecText -notmatch [regex]::Escape("location: $requiredHookPath")) {
                throw "CodeDeploy AppSpec does not reference required hook: $requiredHookPath"
            }
        }

        $deploymentEnvironment = $archive.GetEntry('deployment.env')
        $deploymentEnvironmentText = Get-CodeDeployZipEntryText -Entry $deploymentEnvironment
        foreach ($requiredEnvironmentKey in @('LUCENT_AWS_REGION', 'LUCENT_BACKEND_IMAGE', 'LUCENT_DATABASE_SECRET_ARN', 'LUCENT_REVISION_ID')) {
            if ($deploymentEnvironmentText -notmatch "(?m)^$requiredEnvironmentKey=.+$") {
                throw "CodeDeploy revision ZIP deployment.env is missing $requiredEnvironmentKey."
            }
        }

        foreach ($requiredHookPath in $requiredHookPaths) {
            $hook = $archive.GetEntry($requiredHookPath)
            $hookBytes = Get-CodeDeployZipEntryBytes -Entry $hook
            if ($hookBytes.Length -eq 0 -or $hookBytes[0] -ne 0x23) {
                throw "CodeDeploy Shell hook must start with byte # (0x23): $($hook.FullName)"
            }
            if ($hookBytes.Length -ge 3 -and $hookBytes[0] -eq 0xEF -and $hookBytes[1] -eq 0xBB -and $hookBytes[2] -eq 0xBF) {
                throw "CodeDeploy Shell hook contains a UTF-8 BOM: $($hook.FullName)"
            }
            $externalAttributes = [BitConverter]::ToUInt32(
                [BitConverter]::GetBytes([int]$hook.ExternalAttributes),
                0
            )
            $mode = (($externalAttributes -shr 16) -band 0x1FF)
            if ($mode -ne 493) { throw "CodeDeploy Shell hook is not executable (0755): $($hook.FullName)" }

            $content = Get-CodeDeployZipEntryText -Entry $hook

            if ($content.Contains("`r")) { throw "CodeDeploy Shell hook contains CRLF or CR: $($hook.FullName)" }
            if (-not $content.StartsWith("#!/bin/bash`n", [StringComparison]::Ordinal)) { throw "CodeDeploy Shell hook has an invalid Bash shebang: $($hook.FullName)" }
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Write-CodeDeployFailureDetails {
    param([Parameter(Mandatory = $true)][string]$DeploymentId)

    Write-Host "=== CodeDeploy failure details: $DeploymentId ==="
    try {
        Invoke-Native -Exe $AwsExe -Arguments @(
            'deploy', 'get-deployment', '--region', $region,
            '--deployment-id', $DeploymentId, '--output', 'json'
        ) | Out-Host

        $instanceIds = @((Invoke-Native -Exe $AwsExe -Arguments @(
                    'deploy', 'list-deployment-instances', '--region', $region,
                    '--deployment-id', $DeploymentId, '--output', 'json'
                ) | ConvertFrom-Json).instancesList)

        foreach ($instanceId in $instanceIds) {
            Invoke-Native -Exe $AwsExe -Arguments @(
                'deploy', 'get-deployment-instance', '--region', $region,
                '--deployment-id', $DeploymentId, '--instance-id', $instanceId,
                '--output', 'json'
            ) | Out-Host
        }
    }
    catch {
        Write-Warning "Unable to collect complete CodeDeploy diagnostics: $($_.Exception.Message)"
    }
}

$accountVerifier = Join-Path $PSScriptRoot 'assert-aws-account.ps1'
& $accountVerifier -AwsExe $AwsExe

if (-not (Test-Path -LiteralPath (Join-Path $BackendDir 'Dockerfile'))) {
    throw "Missing Backend Dockerfile: $BackendDir"
}

$sourceDirectory = Join-Path $ProjectDir 'deployment\codedeploy'
if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory 'appspec.yml'))) {
    throw "Missing CodeDeploy revision source: $sourceDirectory"
}

$autoScalingGroup = [string](Get-TfValue -Name 'backend_autoscaling_group_name')
$ecrRepository = [string](Get-TfValue -Name 'backend_ecr_repository_url')
$artifactBucket = [string](Get-TfValue -Name 'deployment_artifact_bucket_name')
$applicationName = [string](Get-TfValue -Name 'backend_codedeploy_application_name')
$deploymentGroupName = [string](Get-TfValue -Name 'backend_codedeploy_deployment_group_name')
$databaseSecretArn = [string](Get-TfValue -Name 'backend_database_runtime_secret_arn')

if (@($autoScalingGroup, $ecrRepository, $artifactBucket, $applicationName, $deploymentGroupName, $databaseSecretArn) -match '^$') {
    throw 'Terraform outputs are incomplete; refusing to guess CodeDeploy configuration.'
}

if ([string]::IsNullOrWhiteSpace($RevisionId)) {
    $RevisionId = if ($env:GITHUB_SHA) { $env:GITHUB_SHA } else { (Get-Date -Format 'yyyyMMddHHmmss') }
}
if ($RevisionId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
    throw "RevisionId contains unsupported characters: $RevisionId"
}

$agentBootstrap = @(
    'set -euo pipefail',
    "REGION=$region",
    'LUCENT_PACKAGE_LOCK="/var/lock/lucent-package-bootstrap.lock"',
    'fail() { echo "LUCENT_CODEDEPLOY_BOOTSTRAP_ERROR: $*" >&2; exit 1; }',
    'if ! command -v cloud-init >/dev/null 2>&1; then fail "cloud-init is required on the Backend AMI"; fi',
    'if ! timeout 900 cloud-init status --wait; then cloud-init status --long || true; fail "cloud-init did not complete successfully within 900 seconds"; fi',
    'if ! command -v flock >/dev/null 2>&1; then fail "flock is required to serialize Lucent package installation"; fi',
    'exec 9>"$LUCENT_PACKAGE_LOCK"',
    'flock -w 900 9 || fail "timed out waiting for the Lucent package-installation lock"',
    'package_manager_busy() { pgrep -x dnf >/dev/null 2>&1 || pgrep -x yum >/dev/null 2>&1 || pgrep -x rpm >/dev/null 2>&1 || fuser /var/lib/rpm/Packages /var/cache/dnf >/dev/null 2>&1; }',
    'wait_for_package_manager() { local deadline=$((SECONDS + 600)); while package_manager_busy; do if (( SECONDS >= deadline )); then return 1; fi; echo "Waiting for an existing DNF/RPM transaction to finish..."; sleep 5; done; return 0; }',
    'dnf_install() { local attempt=1 max_attempts=3 log_file; while (( attempt <= max_attempts )); do if ! wait_for_package_manager; then echo "LUCENT_CODEDEPLOY_BOOTSTRAP_ERROR: timed out waiting for DNF/RPM before installing: $*" >&2; return 1; fi; log_file=$(mktemp /tmp/lucent-dnf.XXXXXX); if dnf install -y "$@" 2>&1 | tee "$log_file"; then rm -f "$log_file"; return 0; fi; if grep -Eq ''No such file or directory|Cannot open.*\.rpm|Failed to open.*\.rpm'' "$log_file"; then if ! wait_for_package_manager; then rm -f "$log_file"; return 1; fi; echo "Recovering a missing cached RPM before retry $attempt/$max_attempts..."; dnf clean all || { rm -f "$log_file"; return 1; }; dnf makecache --refresh || { rm -f "$log_file"; return 1; }; fi; rm -f "$log_file"; if (( attempt == max_attempts )); then echo "LUCENT_CODEDEPLOY_BOOTSTRAP_ERROR: DNF failed after $max_attempts attempts while installing: $*" >&2; return 1; fi; attempt=$((attempt + 1)); sleep 5; done; }',
    'ensure_active_service() { systemctl enable --now "$1"; systemctl is-active --quiet "$1" || fail "$1 is not active"; }',
    'if ! command -v docker >/dev/null 2>&1; then dnf_install docker || fail "could not install docker"; fi',
    'ensure_active_service docker',
    'if ! command -v aws >/dev/null 2>&1; then dnf_install awscli || dnf_install awscli2 || dnf_install aws-cli || fail "could not install an AWS CLI package"; fi',
    'if ! test -x /opt/codedeploy-agent/bin/codedeploy-agent; then',
    '  dnf_install ruby wget || fail "could not install Ruby and wget for CodeDeploy Agent"',
    '  wget -q -O /tmp/codedeploy-install "https://aws-codedeploy-${REGION}.s3.${REGION}.amazonaws.com/latest/install"',
    '  chmod +x /tmp/codedeploy-install',
    '  /tmp/codedeploy-install auto',
    'fi',
    'ensure_active_service codedeploy-agent',
    'command -v docker >/dev/null 2>&1 || fail "docker executable is missing"',
    'command -v aws >/dev/null 2>&1 || fail "AWS CLI executable is missing"',
    'test -x /opt/codedeploy-agent/bin/codedeploy-agent || fail "CodeDeploy Agent executable is missing"',
    'echo CODEDEPLOY_AGENT_READY'
)
$backendIds = @(Invoke-SsmBootstrapForCurrentAsg -AutoScalingGroupName $autoScalingGroup -Commands $agentBootstrap)
Write-Host "CodeDeploy Agent readiness reconciled for current Backend ASG instances: $($backendIds -join ', ')"

$imageTag = "sha-$RevisionId"
$localImage = "lucent-backend:$imageTag"
$registry = $ecrRepository.Split('/')[0]
$remoteImageTag = "${ecrRepository}:$imageTag"
$repositoryName = $ecrRepository.Split('/')[-1]

$imageDigest = Get-EcrImageDigestForTagOrNull -RepositoryName $repositoryName -ImageTag $imageTag
if ($null -eq $imageDigest) {
    Write-Host '=== BACKEND: build and publish immutable ECR image ==='
    Push-Location $BackendDir
    try {
        Invoke-Native -Exe 'docker' -Arguments @('build', '-t', $localImage, '.') | Out-Host
    }
    finally {
        Pop-Location
    }

    Login-EcrDocker -Registry $registry
    Invoke-Native -Exe 'docker' -Arguments @('tag', $localImage, $remoteImageTag) | Out-Host
    Invoke-Native -Exe 'docker' -Arguments @('push', $remoteImageTag) | Out-Host

    $imageDigest = Get-EcrImageDigestForTagOrNull -RepositoryName $repositoryName -ImageTag $imageTag
    if ($null -eq $imageDigest) {
        throw "ECR image was not found after push: $remoteImageTag"
    }
}
else {
    Write-Host "Reusing existing immutable ECR image for revision $RevisionId."
}
$imageReference = "${ecrRepository}@$imageDigest"

$temporaryRoot = Join-Path $env:TEMP ('lucent-codedeploy-revision-' + [guid]::NewGuid().ToString())
try {
    $revisionRoot = Join-Path $temporaryRoot 'revision'
    $archivePath = Join-Path $temporaryRoot 'lucent-backend.zip'
    New-Item -ItemType Directory -Path $revisionRoot -Force | Out-Null
    Copy-Item -Path (Join-Path $sourceDirectory '*') -Destination $revisionRoot -Recurse -Force

    $deploymentEnvironment = @(
        "LUCENT_AWS_REGION=$region",
        "LUCENT_BACKEND_IMAGE=$imageReference",
        "LUCENT_DATABASE_SECRET_ARN=$databaseSecretArn",
        "LUCENT_REVISION_ID=$RevisionId"
    ) -join "`n"
    [IO.File]::WriteAllText(
        (Join-Path $revisionRoot 'deployment.env'),
        $deploymentEnvironment + "`n",
        (New-Object System.Text.UTF8Encoding($false))
    )

    New-CodeDeployRevisionArchive -SourceDirectory $revisionRoot -ArchivePath $archivePath
    Test-CodeDeployRevisionArchive -ArchivePath $archivePath

    $revisionKey = "codedeploy/backend/$RevisionId/lucent-backend-$RevisionId.zip"
    Invoke-Native -Exe $AwsExe -Arguments @(
        's3', 'cp', $archivePath, "s3://$artifactBucket/$revisionKey",
        '--region', $region, '--sse', 'AES256'
    ) | Out-Host

    $deploymentId = (Invoke-Native -Exe $AwsExe -Arguments @(
            'deploy', 'create-deployment', '--region', $region,
            '--application-name', $applicationName,
            '--deployment-group-name', $deploymentGroupName,
            '--s3-location', "bucket=$artifactBucket,key=$revisionKey,bundleType=zip",
            '--description', "Lucent Backend $RevisionId ($imageDigest)",
            '--query', 'deploymentId', '--output', 'text'
        )).Trim()
    if ([string]::IsNullOrWhiteSpace($deploymentId)) {
        throw 'CodeDeploy did not return a Deployment ID.'
    }

    Write-Host "CodeDeploy Deployment ID: $deploymentId"
    try {
        Invoke-Native -Exe $AwsExe -Arguments @(
            'deploy', 'wait', 'deployment-successful', '--region', $region,
            '--deployment-id', $deploymentId
        ) | Out-Host
    }
    catch {
        Write-CodeDeployFailureDetails -DeploymentId $deploymentId
        throw
    }

    Write-Host "CodeDeploy deployment succeeded: $deploymentId"
    Write-Host "Immutable Backend image: $imageReference"
}
finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}
