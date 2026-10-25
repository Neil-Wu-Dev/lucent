# Lucent security verification: read-only AWS configuration and connectivity checks.
# This script never deploys, changes Terraform, restarts services, or prints secrets.
param(
    [string]$ProjectDir = 'D:\dev\lucent',
    [string]$TerraformDir = '',
    [switch]$Ci,
    [switch]$InfrastructureOnly
)

$ErrorActionPreference = 'Stop'
$region = 'us-east-1'
$results = [System.Collections.Generic.List[object]]::new()

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
    $TerraformDir = Join-Path $ProjectDir 'infrastructure'
}

function Invoke-Native {
    param(
        [string]$Exe,
        [string[]]$Arguments
    )

    $output = & $Exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe failed (exit $LASTEXITCODE): $($output -join [Environment]::NewLine)"
    }

    return ($output -join [Environment]::NewLine).Trim()
}

function Get-Tf {
    param([string]$Name)

    $raw = Invoke-Native -Exe 'terraform' -Arguments @(
        "-chdir=$TerraformDir",
        'output',
        '-json',
        $Name
    )

    return $raw | ConvertFrom-Json
}

function Get-TfStringList {
    param([string]$Name)

    $value = Get-Tf $Name

    # Decode an extra JSON string layer emitted by the GitHub Action wrapper,
    # then return one string per Terraform list item.
    if ($value -is [string]) {
        $value = $value | ConvertFrom-Json
    }

    return @($value | ForEach-Object { [string]$_ })
}

function Add-Result {
    param(
        [string]$Name,
        [bool]$Passed,
        [string]$Detail
    )

    $results.Add([pscustomobject]@{
            Name   = $Name
            Passed = $Passed
            Detail = $Detail
        })

    $status = if ($Passed) { 'PASS' } else { 'FAIL' }
    Write-Host "[$status] $Name - $Detail"
}

function Get-ExitCode {
    param(
        [string]$Exe,
        [string[]]$Arguments
    )

    & $Exe @Arguments *> $null
    return $LASTEXITCODE
}

function Get-SecurityGroupPermission {
    param(
        [object]$SecurityGroup,
        [int]$Port
    )

    return @(
        $SecurityGroup.IpPermissions | Where-Object {
            $_.IpProtocol -eq 'tcp' -and
            $_.FromPort -eq $Port -and
            $_.ToPort -eq $Port
        }
    )
}

function Test-OnlySecurityGroupSource {
    param(
        [object[]]$Permissions,
        [string]$ExpectedSourceGroupId
    )

    if ($Permissions.Count -ne 1) {
        return $false
    }

    $permission = $Permissions[0]
    $groupPairs = @($permission.UserIdGroupPairs)

    return (
        $groupPairs.Count -eq 1 -and
        $groupPairs[0].GroupId -eq $ExpectedSourceGroupId -and
        @($permission.IpRanges).Count -eq 0 -and
        @($permission.Ipv6Ranges).Count -eq 0 -and
        @($permission.PrefixListIds).Count -eq 0
    )
}

function Invoke-ReadOnlySsmCheck {
    param(
        [string[]]$InstanceIds,
        [string[]]$Commands,
        [string]$Label
    )

    $parameterFile = Join-Path $env:TEMP (
        'lucent-security-' + [guid]::NewGuid().ToString() + '.json'
    )

    try {
        [IO.File]::WriteAllText(
            $parameterFile,
            (@{ commands = $Commands } | ConvertTo-Json -Compress -Depth 8),
            (New-Object System.Text.UTF8Encoding($false))
        )

        $arguments = @(
            'ssm',
            'send-command',
            '--region',
            $region,
            '--document-name',
            'AWS-RunShellScript',
            '--instance-ids'
        ) + $InstanceIds + @(
            '--parameters',
            ('file://' + $parameterFile.Replace('\', '/')),
            '--query',
            'Command.CommandId',
            '--output',
            'text'
        )

        $commandId = (Invoke-Native -Exe $AwsExe -Arguments $arguments).Trim()
        $allPassed = $true

        foreach ($instanceId in $InstanceIds) {
            $invocation = $null

            for ($attempt = 0; $attempt -lt 60; $attempt++) {
                Start-Sleep -Seconds 2

                try {
                    $raw = Invoke-Native -Exe $AwsExe -Arguments @(
                        'ssm',
                        'get-command-invocation',
                        '--region',
                        $region,
                        '--command-id',
                        $commandId,
                        '--instance-id',
                        $instanceId,
                        '--output',
                        'json'
                    )

                    $invocation = $raw | ConvertFrom-Json

                    if ($invocation.Status -in @(
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
                    if ($attempt -eq 59) {
                        throw
                    }
                }
            }

            $passed = (
                $null -ne $invocation -and
                $invocation.Status -eq 'Success' -and
                $invocation.ResponseCode -eq 0
            )

            $probeDetail = if ($passed) {
                'Read-only SSM probe succeeded.'
            }
            else {
                'Read-only SSM probe failed.'
            }

            Add-Result -Name "$Label on $instanceId" -Passed $passed -Detail $probeDetail

            if ($invocation.StandardOutputContent) {
                Write-Host $invocation.StandardOutputContent
            }

            if ($invocation.StandardErrorContent) {
                Write-Host $invocation.StandardErrorContent
            }

            if (-not $passed) {
                $allPassed = $false
            }
        }

        return $allPassed
    }
    finally {
        Remove-Item -LiteralPath $parameterFile -ErrorAction SilentlyContinue
    }
}

Write-Host '=== SECRET HYGIENE ==='

$secretPath = Join-Path $TerraformDir 'secrets.auto.tfvars'
$secretRelativePath = 'infrastructure/secrets.auto.tfvars'

if ($Ci) {
    # CI receives the password from GitHub Actions; it must never receive
    # the developer-only secrets.auto.tfvars file.
    Add-Result -Name 'CI database password is injected as a protected environment variable' -Passed (
        -not [string]::IsNullOrWhiteSpace($env:TF_VAR_database_password)
    ) -Detail 'TF_VAR_database_password is present without exposing its value.'
} else {
    Add-Result -Name 'Local secrets file exists' -Passed (Test-Path -LiteralPath $secretPath) -Detail $secretRelativePath

    $ignored = (Get-ExitCode -Exe 'git' -Arguments @(
            'check-ignore',
            '--quiet',
            '--',
            $secretRelativePath
        )) -eq 0
    Add-Result -Name 'Local secrets file is Git ignored' -Passed $ignored -Detail $secretRelativePath

    $tracked = (Get-ExitCode -Exe 'git' -Arguments @(
            'ls-files',
            '--error-unmatch',
            '--',
            $secretRelativePath
        )) -eq 0
    Add-Result -Name 'Local secrets file is not Git tracked' -Passed (-not $tracked) -Detail $secretRelativePath
}

$secretPattern = 'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|aws_secret_access_key|aws_session_token|-----BEGIN [A-Z ]*PRIVATE KEY-----'
# Exclude this script because it necessarily contains the credential patterns
# that it uses to scan every other tracked source file.
$matches = & git grep -n -I -E $secretPattern -- . ':!infrastructure/secrets.auto.tfvars' ':!scripts/security-verify.ps1'
$gitGrepExitCode = $LASTEXITCODE

if ($gitGrepExitCode -gt 1) {
    throw "git grep failed while scanning tracked files (exit $gitGrepExitCode)."
}

$credentialScanDetail = if ($gitGrepExitCode -eq 1) {
    'No credential patterns found.'
} else {
    'Credential pattern found in tracked source.'
}
Add-Result -Name 'Tracked source contains no AWS credentials or private keys' -Passed ($gitGrepExitCode -eq 1) -Detail $credentialScanDetail

Write-Host '=== AWS IDENTITY ==='
$identity = Invoke-Native -Exe $AwsExe -Arguments @(
    'sts',
    'get-caller-identity',
    '--region',
    $region,
    '--output',
    'json'
) | ConvertFrom-Json
Add-Result -Name 'Temporary AWS credentials are usable' -Passed ([bool]$identity.Account) -Detail "Account $($identity.Account), ARN $($identity.Arn)"

Write-Host '=== TERRAFORM OUTPUTS ==='
$backendIds = @(Get-TfStringList 'application_instance_ids')
$frontendIds = @(Get-TfStringList 'frontend_instance_ids')
$allInstanceIds = @($backendIds + $frontendIds)
$albSecurityGroupId = [string](Get-Tf 'alb_security_group_id')
$applicationSecurityGroupId = [string](Get-Tf 'application_security_group_id')
$databaseSecurityGroupId = [string](Get-Tf 'database_security_group_id')
$frontendSecurityGroupId = [string](Get-Tf 'frontend_security_group_id')
$backendTargetGroupArn = [string](Get-Tf 'backend_target_group_arn')
$albUrl = [string](Get-Tf 'lucent_alb_url')
$databaseEndpoint = [string](Get-Tf 'database_endpoint')
$databasePort = [string](Get-Tf 'database_port')

Add-Result -Name 'Expected private EC2 inventory exists' -Passed (
    $backendIds.Count -eq 2 -and $frontendIds.Count -eq 2
) -Detail "Backend=$($backendIds.Count), Frontend=$($frontendIds.Count)"

Write-Host '=== INTERNET INBOUND BOUNDARY ==='
$instances = @(
    (
        Invoke-Native -Exe $AwsExe -Arguments @(
            'ec2',
            'describe-instances',
            '--region',
            $region,
            '--instance-ids'
        ) + $allInstanceIds + @(
            '--output',
            'json'
        )
    ) | ConvertFrom-Json
).Reservations.Instances

$publicInstances = @($instances | Where-Object { $_.PublicIpAddress })
Add-Result -Name 'Backend and frontend EC2 instances have no public IP' -Passed (
    $instances.Count -eq $allInstanceIds.Count -and $publicInstances.Count -eq 0
) -Detail "Checked $($instances.Count) instances."

$rdsInstances = @(
    (
        Invoke-Native -Exe $AwsExe -Arguments @(
            'rds',
            'describe-db-instances',
            '--region',
            $region,
            '--output',
            'json'
        )
    ) | ConvertFrom-Json
).DBInstances
$rds = $rdsInstances | Where-Object { $_.Endpoint.Address -eq $databaseEndpoint } | Select-Object -First 1

$rdsPrivacyDetail = if ($rds) {
    "PubliclyAccessible=$($rds.PubliclyAccessible)"
} else {
    'RDS endpoint was not found.'
}
Add-Result -Name 'RDS is private' -Passed (
    $null -ne $rds -and $rds.PubliclyAccessible -eq $false
) -Detail $rdsPrivacyDetail

Write-Host '=== SECURITY GROUP POLICY ==='
$groups = @(
    (
        Invoke-Native -Exe $AwsExe -Arguments @(
            'ec2',
            'describe-security-groups',
            '--region',
            $region,
            '--group-ids',
            $albSecurityGroupId,
            $applicationSecurityGroupId,
            $databaseSecurityGroupId,
            $frontendSecurityGroupId,
            '--output',
            'json'
        )
    ) | ConvertFrom-Json
).SecurityGroups

$groupsById = @{}
foreach ($group in $groups) {
    $groupsById[$group.GroupId] = $group
}

$albPermissions = Get-SecurityGroupPermission -SecurityGroup $groupsById[$albSecurityGroupId] -Port 80
$albInternetIngress = @(
    $albPermissions | Where-Object {
        @($_.IpRanges | Where-Object { $_.CidrIp -eq '0.0.0.0/0' }).Count -gt 0
    }
).Count -eq 1
Add-Result -Name 'Internet can reach ALB HTTP only' -Passed $albInternetIngress -Detail 'ALB port 80 accepts 0.0.0.0/0.'

$appPermissions = Get-SecurityGroupPermission -SecurityGroup $groupsById[$applicationSecurityGroupId] -Port 8080
Add-Result -Name 'Only ALB can reach Backend EC2 TCP 8080' -Passed (
    Test-OnlySecurityGroupSource -Permissions $appPermissions -ExpectedSourceGroupId $albSecurityGroupId
) -Detail 'Backend ingress source must be the ALB security group.'

$frontendPermissions = Get-SecurityGroupPermission -SecurityGroup $groupsById[$frontendSecurityGroupId] -Port 80
Add-Result -Name 'Only ALB can reach Frontend EC2 TCP 80' -Passed (
    Test-OnlySecurityGroupSource -Permissions $frontendPermissions -ExpectedSourceGroupId $albSecurityGroupId
) -Detail 'Frontend ingress source must be the ALB security group.'

$databasePermissions = Get-SecurityGroupPermission -SecurityGroup $groupsById[$databaseSecurityGroupId] -Port 5432
Add-Result -Name 'Only Backend EC2 can reach PostgreSQL TCP 5432' -Passed (
    Test-OnlySecurityGroupSource -Permissions $databasePermissions -ExpectedSourceGroupId $applicationSecurityGroupId
) -Detail 'Database ingress source must be the Backend EC2 security group.'

if ($InfrastructureOnly) {
    Write-Host '=== SECURITY SUMMARY ==='
    $results | Format-Table -AutoSize

    if (@($results | Where-Object { -not $_.Passed }).Count -gt 0) {
        Write-Host 'INFRASTRUCTURE SECURITY VERIFICATION FAILED'
        exit 1
    }

    Write-Host 'INFRASTRUCTURE SECURITY VERIFICATION PASSED'
    exit 0
}

Write-Host '=== ALB TO BACKEND ==='
$targetHealth = @(
    (
        Invoke-Native -Exe $AwsExe -Arguments @(
            'elbv2',
            'describe-target-health',
            '--region',
            $region,
            '--target-group-arn',
            $backendTargetGroupArn,
            '--output',
            'json'
        )
    ) | ConvertFrom-Json
).TargetHealthDescriptions

$healthyBackendIds = @(
    $targetHealth |
    Where-Object { $_.TargetHealth.State -eq 'healthy' } |
    ForEach-Object { $_.Target.Id }
)
Add-Result -Name 'ALB reaches both Backend EC2 targets' -Passed (
    @($backendIds | Where-Object { $_ -notin $healthyBackendIds }).Count -eq 0
) -Detail "Healthy targets: $($healthyBackendIds -join ', ')"

try {
    $apiResponse = Invoke-WebRequest -Uri ($albUrl + '/api/v1/notes') -UseBasicParsing -TimeoutSec 15
    Add-Result -Name 'Public ALB API route reaches Backend' -Passed ($apiResponse.StatusCode -eq 200) -Detail "HTTP $($apiResponse.StatusCode)"
}
catch {
    Add-Result -Name 'Public ALB API route reaches Backend' -Passed $false -Detail $_.Exception.Message
}

Write-Host '=== PRIVATE RUNTIME CONNECTIVITY ==='
$backendCommands = @(
    'set -euo pipefail',
    "DB_HOST=$databaseEndpoint",
    "DB_PORT=$databasePort",
    'timeout 5 bash -c "</dev/tcp/$DB_HOST/$DB_PORT"',
    'curl -fsS --max-time 10 http://127.0.0.1:8080/api/v1/notes -o /dev/null',
    'echo BACKEND_TO_DATABASE_OK'
)
Invoke-ReadOnlySsmCheck -InstanceIds $backendIds -Commands $backendCommands -Label 'Backend EC2 to PostgreSQL and local API'

$frontendCommands = @(
    'set -euo pipefail',
    "DB_HOST=$databaseEndpoint",
    "DB_PORT=$databasePort",
    'if timeout 5 bash -c "</dev/tcp/$DB_HOST/$DB_PORT"; then echo FRONTEND_DATABASE_ACCESS_UNEXPECTED; exit 1; fi',
    'echo FRONTEND_TO_DATABASE_BLOCKED'
)
Invoke-ReadOnlySsmCheck -InstanceIds $frontendIds -Commands $frontendCommands -Label 'Frontend EC2 denied PostgreSQL'

Write-Host '=== SECURITY SUMMARY ==='
$results | Format-Table -AutoSize

if (@($results | Where-Object { -not $_.Passed }).Count -gt 0) {
    Write-Host 'SECURITY VERIFICATION FAILED'
    exit 1
}

Write-Host 'SECURITY VERIFICATION PASSED'
exit 0
