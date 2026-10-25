# Lucent deployment - Windows PowerShell 5.1+.
param(
    [string]$ProjectDir = 'D:\dev\lucent',
    [string]$TerraformDir = '',
    [string]$FrontendDir = '',
    [string]$BackendDir = '',
    [switch]$ApplyInfrastructure
)

$ErrorActionPreference = 'Stop'
$region = 'us-east-1'

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

if (-not $FrontendDir) { $FrontendDir = Join-Path $ProjectDir 'frontend' }
if (-not $BackendDir) { $BackendDir = Join-Path $ProjectDir 'backend' }

if (-not $TerraformDir) {
    $dirs = @($ProjectDir) + @(
        Get-ChildItem -LiteralPath $ProjectDir -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $_.FullName -notmatch '[\\/](node_modules|\.git|build|dist|\.gradle)[\\/]'
        } |
        Select-Object -ExpandProperty FullName
    )

    $matches = @(
        $dirs | Where-Object {
            Test-Path (Join-Path $_ 'terraform.tfstate')
        }
    )

    if ($matches.Count -ne 1) {
        throw "Cannot uniquely locate Terraform state. Pass -TerraformDir 'YOUR_TERRAFORM_FOLDER'."
    }

    $TerraformDir = $matches[0]
}

function Invoke-Native {
    param(
        [string]$Exe,
        [string[]]$Arguments
    )

    $errFile = Join-Path $env:TEMP ([guid]::NewGuid().ToString() + '.err')

    try {
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'

        try {
            $out = & $Exe @Arguments 2> $errFile
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $old
        }

        if ($code -ne 0) {
            $err = if (Test-Path $errFile) {
                Get-Content $errFile -Raw
            }
            else {
                ''
            }

            throw "$Exe $($Arguments -join ' ') failed (exit $code): $err $($out -join ' ')"
        }

        return ($out -join "`n")
    }
    finally {
        Remove-Item $errFile -ErrorAction SilentlyContinue
    }
}

function Get-Tf([string]$key) {
    $raw = Invoke-Native 'terraform' @(
        "-chdir=$TerraformDir",
        'output',
        '-json',
        $key
    )

    return ($raw | ConvertFrom-Json)
}

function Get-TfStringList([string]$key) {
    $value = Get-Tf $key

    # The GitHub Action Terraform wrapper can serialize JSON output once more.
    # Decode that representation before flattening IDs for AWS CLI and SSM.
    if ($value -is [string]) {
        $value = $value | ConvertFrom-Json
    }

    return @($value | ForEach-Object { [string]$_ })
}

function Run-Remote(
    [string[]]$Ids,
    [string[]]$Commands,
    [string]$Label
) {
    $file = Join-Path $env:TEMP (
        'lucent-' + [guid]::NewGuid().ToString() + '.json'
    )

    try {
        [IO.File]::WriteAllText(
            $file,
            (@{ commands = $Commands } | ConvertTo-Json -Compress -Depth 8),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $args = @(
            'ssm',
            'send-command',
            '--region',
            $region,
            '--instance-ids'
        ) + $Ids + @(
            '--document-name',
            'AWS-RunShellScript',
            '--parameters',
            ('file://' + $file.Replace('\', '/')),
            '--query',
            'Command.CommandId',
            '--output',
            'text'
        )

        $commandId = (Invoke-Native $AwsExe $args).Trim()

        if (-not $commandId) {
            throw "No SSM command ID for $Label"
        }

        $ok = $true

        foreach ($instance in $Ids) {
            $result = $null

            for ($i = 0; $i -lt 90; $i++) {
                Start-Sleep -Seconds 3

                try {
                    $raw = Invoke-Native $AwsExe @(
                        'ssm',
                        'get-command-invocation',
                        '--region',
                        $region,
                        '--command-id',
                        $commandId,
                        '--instance-id',
                        $instance,
                        '--output',
                        'json'
                    )

                    $result = $raw | ConvertFrom-Json

                    if ($result.Status -in @(
                        'Success',
                        'Failed',
                        'Cancelled',
                        'TimedOut',
                        'Cancelling'
                    )) {
                        break
                    }
                }
                catch {
                    if ($i -eq 89) {
                        throw
                    }
                }
            }

            Write-Host "[$Label] $instance : $($result.Status) / code $($result.ResponseCode)"

            if ($result.StandardOutputContent) {
                Write-Host $result.StandardOutputContent
            }

            if ($result.StandardErrorContent) {
                Write-Host $result.StandardErrorContent
            }

            if (
                $null -eq $result -or
                $result.Status -ne 'Success' -or
                $result.ResponseCode -ne 0
            ) {
                $ok = $false
            }
        }

        return $ok
    }
    finally {
        Remove-Item $file -ErrorAction SilentlyContinue
    }
}

function Wait-ForSsmManagedInstances(
    [string[]]$Ids,
    [int]$TimeoutSeconds = 600
) {
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $pendingIds = @($Ids)

    while ($pendingIds.Count -gt 0 -and (Get-Date) -lt $deadline) {
        $instanceInformation = (
            Invoke-Native $AwsExe @(
                'ssm',
                'describe-instance-information',
                '--region',
                $region,
                '--filters',
                ('Key=InstanceIds,Values=' + ($pendingIds -join ',')),
                '--output',
                'json'
            )
        ) | ConvertFrom-Json

        $onlineIds = @(
            $instanceInformation.InstanceInformationList |
            Where-Object { $_.PingStatus -eq 'Online' } |
            ForEach-Object { $_.InstanceId }
        )
        $pendingIds = @($pendingIds | Where-Object { $_ -notin $onlineIds })

        if ($pendingIds.Count -gt 0) {
            Write-Host "Waiting for SSM Online: $($pendingIds -join ', ')"
            Start-Sleep -Seconds 10
        }
    }

    if ($pendingIds.Count -gt 0) {
        throw "Timed out waiting for EC2 instances to become SSM Online: $($pendingIds -join ', ')"
    }
}

function Login-EcrDocker(
    [string]$Registry,
    [string]$Label
) {
    Write-Host "=== ${Label}: Docker login to ECR ==="

    Invoke-Native 'docker' @('logout', $Registry) | Out-Null

    $loginCommand = "`"$AwsExe`" ecr get-login-password --region $region | docker login --username AWS --password-stdin $Registry"
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        cmd.exe /d /s /c $loginCommand
        $loginCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $old
    }

    if ($loginCode -ne 0) {
        throw "$Label Docker ECR login failed"
    }
}

if ($ApplyInfrastructure) {
    Write-Host '=== TERRAFORM: create or update infrastructure, including private RDS ==='

    & terraform @(
        "-chdir=$TerraformDir",
        'init'
    )

    if ($LASTEXITCODE -ne 0) {
        throw "terraform init failed (exit $LASTEXITCODE)."
    }

    & terraform @(
        "-chdir=$TerraformDir",
        'apply'
    )

    if ($LASTEXITCODE -ne 0) {
        throw "terraform apply failed (exit $LASTEXITCODE)."
    }
}

Write-Host '=== Terraform outputs ==='

$frontendIds = @(Get-TfStringList 'frontend_instance_ids')
$backendIds = @(Get-TfStringList 'application_instance_ids')
$ecr = [string](Get-Tf 'backend_ecr_repository_url')
$alb = [string](Get-Tf 'lucent_alb_url')
$databaseEndpoint = [string](Get-Tf 'database_endpoint')
$databasePort = [string](Get-Tf 'database_port')
$databaseName = [string](Get-Tf 'database_name')
$databaseUsername = [string](Get-Tf 'database_username')
$databasePassword = [string](Get-Tf 'database_password')

if (
    $frontendIds.Count -ne 2 -or
    $backendIds.Count -ne 2 -or
    -not $ecr -or
    -not $databaseEndpoint -or
    -not $databasePassword
) {
    throw 'Terraform outputs incomplete; refusing to guess infrastructure or database settings.'
}

$account = (
    Invoke-Native $AwsExe @(
        'sts',
        'get-caller-identity',
        '--query',
        'Account',
        '--output',
        'text'
    )
).Trim()

$bucket = "lucent-deploy-$account"

Write-Host "Frontend EC2: $($frontendIds -join ', ')"
Write-Host "Backend EC2: $($backendIds -join ', ')"
Write-Host "ALB: $alb"
Write-Host ('RDS: ' + $databaseEndpoint + ':' + $databasePort)
Write-Host '=== Waiting for EC2 management readiness ==='
Wait-ForSsmManagedInstances -Ids @($frontendIds + $backendIds)

# ==========================================================
# FRONTEND
# ==========================================================

Write-Host '=== FRONTEND: build and upload ==='

if (-not (Test-Path (Join-Path $FrontendDir 'package.json'))) {
    throw "Missing frontend package.json: $FrontendDir"
}

Push-Location $FrontendDir

try {
    if (-not (Test-Path 'node_modules')) {
        Invoke-Native 'npm.cmd' @('ci') | Out-Host
    }

    Invoke-Native 'npm.cmd' @('run', 'build') | Out-Host
}
finally {
    Pop-Location
}

$dist = Join-Path $FrontendDir 'dist'

if (-not (Test-Path (Join-Path $dist 'index.html'))) {
    throw 'React build did not produce dist/index.html'
}

$bucketFound = $false

try {
    $null = Invoke-Native $AwsExe @(
        's3api',
        'head-bucket',
        '--bucket',
        $bucket,
        '--region',
        $region
    )

    $bucketFound = $true
}
catch {
    $bucketFound = $false
}

if (-not $bucketFound) {
    Invoke-Native $AwsExe @(
        's3api',
        'create-bucket',
        '--bucket',
        $bucket,
        '--region',
        $region
    ) | Out-Host
}

Invoke-Native $AwsExe @(
    's3',
    'sync',
    $dist,
    "s3://$bucket/frontend/",
    '--region',
    $region,
    '--delete'
) | Out-Host

$ensureAwsCli = 'if ! command -v aws >/dev/null 2>&1; then dnf install -y awscli || dnf install -y awscli2 || dnf install -y aws-cli; fi'

$frontCommands = @(
    'set -e',
    $ensureAwsCli,
    'rm -f /usr/share/nginx/html/poweredby.png',
    "aws s3 sync s3://$bucket/frontend/ /usr/share/nginx/html/ --region $region --delete",
    'nginx -t',
    'systemctl restart nginx',
    'test -s /usr/share/nginx/html/index.html',
    'asset=$(grep -oE ''assets/index-[^" ]+\.js'' /usr/share/nginx/html/index.html | head -n 1)',
    'test -n "$asset"',
    '! grep -q ''http://localhost:8080'' "/usr/share/nginx/html/$asset"',
    'curl -fsS http://127.0.0.1/ -o /dev/null',
    'echo FRONTEND_OK'
)

$frontOK = Run-Remote $frontendIds $frontCommands 'FRONTEND'

if (-not $frontOK) {
    throw 'FRONTEND deployment failed. Backend deployment was not started.'
}

# ==========================================================
# BACKEND
# ==========================================================

Write-Host '=== BACKEND: build and push ==='

if (-not (Test-Path (Join-Path $BackendDir 'Dockerfile'))) {
    throw "Missing backend Dockerfile: $BackendDir. Pass -BackendDir with correct folder."
}

Push-Location $BackendDir

try {
    Invoke-Native 'docker' @(
        'build',
        '-t',
        'lucent-backend:latest',
        '.'
    ) | Out-Host
}
finally {
    Pop-Location
}

$registry = $ecr.Split('/')[0]

Login-EcrDocker $registry 'LOCAL'

$databaseUrl = 'jdbc:postgresql://' + $databaseEndpoint + ':' + $databasePort + '/' + $databaseName
$databaseUrlBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($databaseUrl))
$databaseUsernameBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($databaseUsername))
$databasePasswordBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($databasePassword))

$image = "${ecr}:latest"

Invoke-Native 'docker' @(
    'tag',
    'lucent-backend:latest',
    $image
) | Out-Host

Invoke-Native 'docker' @(
    'push',
    $image
) | Out-Host

$backCommands = @(
    'set -e',
    $ensureAwsCli,
    'if ! command -v docker >/dev/null 2>&1; then dnf install -y docker; fi',
    'systemctl enable docker',
    'systemctl start docker',
    "REGION=$region",
    "REGISTRY=$registry",
    "IMAGE=$image",
    "DB_URL_BASE64=$databaseUrlBase64",
    "DB_USERNAME_BASE64=$databaseUsernameBase64",
    "DB_PASSWORD_BASE64=$databasePasswordBase64",
    'DB_URL="$(echo "$DB_URL_BASE64" | base64 -d)"',
    'DB_USERNAME="$(echo "$DB_USERNAME_BASE64" | base64 -d)"',
    'DB_PASSWORD="$(echo "$DB_PASSWORD_BASE64" | base64 -d)"',
    'aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"',
    'docker pull "$IMAGE"',
    'docker image inspect "$IMAGE" >/dev/null',
    'if docker container inspect lucent-backend >/dev/null 2>&1; then docker rm -f lucent-backend; fi',
    'docker run -d --name lucent-backend --restart unless-stopped -p 8080:8080 -e DB_URL="$DB_URL" -e DB_USERNAME="$DB_USERNAME" -e DB_PASSWORD="$DB_PASSWORD" "$IMAGE"',
    'sleep 12',
    'docker container inspect lucent-backend >/dev/null',
    'docker ps --all --filter name=lucent-backend',
    'docker logs --tail 25 lucent-backend',
    'echo BACKEND_IMAGE_AND_CONTAINER_DEPLOYED'
)

$backOK = Run-Remote $backendIds $backCommands 'BACKEND'

if (-not $backOK) {
    throw 'Backend image/container deployment failed.'
}

Write-Host '=== DEPLOYMENT COMMANDS FINISHED ==='
Write-Host "ALB: $alb"
Write-Host ('RDS: ' + $databaseEndpoint + ':' + $databasePort)
Write-Host 'Backend containers received their private PostgreSQL connection settings.'
Write-Host 'Run .\scripts\verify.ps1 for independent health verification.'
