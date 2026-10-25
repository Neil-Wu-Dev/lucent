# Lucent verification: read-only; never modifies AWS resources.
param(
    [string]$ProjectDir = 'D:\dev\lucent',
    [string]$TerraformDir = '',
    [switch]$RequireBackendHttp
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

function Ssm-Check(
    [string[]]$Ids,
    [string[]]$Commands,
    [string]$Label
) {
    $path = Join-Path $env:TEMP (
        'lucent-verify-' + [guid]::NewGuid().ToString() + '.json'
    )

    try {
        [IO.File]::WriteAllText(
            $path,
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
            ('file://' + $path.Replace('\', '/')),
            '--query',
            'Command.CommandId',
            '--output',
            'text'
        )

        $cmd = (Invoke-Native $AwsExe $args).Trim()

        if (-not $cmd) {
            throw "No SSM command ID for $Label"
        }

        $ok = $true

        foreach ($id in $Ids) {
            $result = $null

            for ($i = 0; $i -lt 60; $i++) {
                Start-Sleep -Seconds 3

                try {
                    $result = (
                        Invoke-Native $AwsExe @(
                            'ssm',
                            'get-command-invocation',
                            '--region',
                            $region,
                            '--command-id',
                            $cmd,
                            '--instance-id',
                            $id,
                            '--output',
                            'json'
                        )
                    ) | ConvertFrom-Json

                    if ($result.Status -in @(
                        'Success',
                        'Failed',
                        'TimedOut',
                        'Cancelled',
                        'Cancelling'
                    )) {
                        break
                    }
                }
                catch {
                    if ($i -eq 59) {
                        Write-Host "[$Label] $id query failed: $_"
                    }
                }
            }

            $passed = (
                $null -ne $result -and
                $result.Status -eq 'Success' -and
                $result.ResponseCode -eq 0
            )

            Write-Host "[$Label] $id : $(if ($passed) { 'PASS' } else { 'FAIL' })"

            if ($result -and $result.StandardOutputContent) {
                Write-Host $result.StandardOutputContent
            }

            if ($result -and $result.StandardErrorContent) {
                Write-Host $result.StandardErrorContent
            }

            if (-not $passed) {
                $ok = $false
            }
        }

        return $ok
    }
    finally {
        Remove-Item $path -ErrorAction SilentlyContinue
    }
}

$frontends = @(Get-Tf 'frontend_instance_ids')
$backends = @(Get-Tf 'application_instance_ids')
$frontTg = [string](Get-Tf 'frontend_target_group_arn')
$backTg = [string](Get-Tf 'backend_target_group_arn')
$url = [string](Get-Tf 'lucent_alb_url')
$ecr = [string](Get-Tf 'backend_ecr_repository_url')

if ($frontends.Count -ne 2 -or $backends.Count -ne 2) {
    throw 'Terraform did not return exactly 2 frontend and 2 backend IDs.'
}

Write-Host '=== FRONTEND ==='

$frontOK = Ssm-Check $frontends @(
    'set -e',
    'nginx -t',
    'systemctl is-active --quiet nginx',
    'test -s /usr/share/nginx/html/index.html',
    'asset=$(grep -oE ''assets/index-[^" ]+\.js'' /usr/share/nginx/html/index.html | head -n 1)',
    'test -n "$asset"',
    '! grep -q ''http://localhost:8080'' "/usr/share/nginx/html/$asset"',
    'curl -fsS http://127.0.0.1/ -o /dev/null',
    'echo FRONTEND_OK'
) 'FRONTEND'

Write-Host '=== BACKEND CONTAINER ==='

$backContainerOK = Ssm-Check $backends @(
    'set -e',
    "docker image inspect ${ecr}:latest >/dev/null",
    'docker container inspect lucent-backend >/dev/null',
    'docker inspect lucent-backend --format "running={{.State.Running}} restarting={{.State.Restarting}} restartCount={{.RestartCount}}"',
    'docker logs --tail 15 lucent-backend',
    'echo BACKEND_CONTAINER_PRESENT'
) 'BACKEND_CONTAINER'

$backHttpOK = $false

if ($RequireBackendHttp) {
    Write-Host '=== BACKEND HTTP ==='

    $backHttpOK = Ssm-Check $backends @(
        'set -e',
        'curl -fsS --max-time 5 http://127.0.0.1:8080/api/v1/notes -o /dev/null',
        'echo BACKEND_HTTP_OK'
    ) 'BACKEND_HTTP'
}
else {
    Write-Host '=== BACKEND HTTP ==='
    Write-Host 'SKIPPED. Use -RequireBackendHttp after database configuration exists.'
}

Write-Host '=== TARGET GROUPS ==='

foreach ($entry in @(
        @('FRONTEND', $frontTg),
        @('BACKEND', $backTg)
    )) {
    Write-Host "[$($entry[0])] target health:"

    Invoke-Native $AwsExe @(
        'elbv2',
        'describe-target-health',
        '--region',
        $region,
        '--target-group-arn',
        $entry[1],
        '--query',
        'TargetHealthDescriptions[].{Instance:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason}',
        '--output',
        'table'
    ) | Out-Host
}

Write-Host '=== PUBLIC HTTP ==='

$webOK = $false
$apiOK = $false

try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15
    Write-Host "ALB HTTP status: $($response.StatusCode)"
    $webOK = ($response.StatusCode -eq 200)
}
catch {
    Write-Host "ALB HTTP FAIL: $_"
}

try {
    $apiResponse = Invoke-WebRequest -Uri ($url + '/api/v1/notes') -UseBasicParsing -TimeoutSec 15
    Write-Host "ALB API status: $($apiResponse.StatusCode)"
    $apiOK = ($apiResponse.StatusCode -eq 200)
}
catch {
    Write-Host "ALB API FAIL: $_"
}

Write-Host '=== SUMMARY ==='
Write-Host "Frontend local: $(if ($frontOK) { 'PASS' } else { 'FAIL' })"
Write-Host "Backend container: $(if ($backContainerOK) { 'PASS' } else { 'FAIL' })"
Write-Host "Backend HTTP: $(if ($RequireBackendHttp) { if ($backHttpOK) { 'PASS' } else { 'FAIL' } } else { 'SKIPPED' })"
Write-Host "Public website HTTP: $(if ($webOK) { 'PASS' } else { 'FAIL' })"
Write-Host "Public API routing: $(if ($apiOK) { 'PASS' } else { 'FAIL' })"
Write-Host "Website: $url"

if (-not $frontOK -or -not $webOK -or -not $apiOK -or -not $backContainerOK) {
    exit 1
}

if ($RequireBackendHttp -and -not $backHttpOK) {
    exit 1
}
