# Verifies private TCP reachability and PostgreSQL authentication from both
# backend EC2 instances. It does not change Terraform resources.
param(
    [string]$ProjectDir = 'D:\dev\lucent',
    [string]$TerraformDir = '',
    [SecureString]$DatabasePassword
)

$ErrorActionPreference = 'Stop'
$region = 'us-east-1'

if (-not $TerraformDir) {
    $TerraformDir = Join-Path $ProjectDir 'infrastructure'
}

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)

    $output = & $Exe @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$Exe failed (exit $LASTEXITCODE): $($output -join [Environment]::NewLine)"
    }

    return ($output -join [Environment]::NewLine).Trim()
}

function Get-TerraformOutput {
    param([string]$Name)

    return Invoke-Native -Exe 'terraform' -Arguments @("-chdir=$TerraformDir", 'output', '-raw', $Name)
}

function Get-TerraformJsonOutput {
    param([string]$Name)

    return Invoke-Native -Exe 'terraform' -Arguments @("-chdir=$TerraformDir", 'output', '-json', $Name)
}

if (-not $DatabasePassword) {
    $DatabasePassword = Read-Host 'PostgreSQL master password' -AsSecureString
}

$databaseEndpoint = Get-TerraformOutput 'database_endpoint'
$databasePort = Get-TerraformOutput 'database_port'
$databaseName = Get-TerraformOutput 'database_name'
$databaseUsername = Get-TerraformOutput 'database_username'
$backendInstanceIds = @(Get-TerraformJsonOutput 'application_instance_ids' | ConvertFrom-Json)
$databasePasswordPlainText = ConvertFrom-SecureString -SecureString $DatabasePassword -AsPlainText
$databasePasswordBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($databasePasswordPlainText))

$remoteCommands = @(
    'set -euo pipefail',
    "DB_HOST=$databaseEndpoint",
    "DB_PORT=$databasePort",
    "DB_NAME=$databaseName",
    "DB_USERNAME=$databaseUsername",
    "DB_PASSWORD_BASE64=$databasePasswordBase64",
    'DB_PASSWORD="$(echo "$DB_PASSWORD_BASE64" | base64 -d)"',
    'timeout 5 bash -c "</dev/tcp/$DB_HOST/$DB_PORT"',
    'docker run --rm -e PGPASSWORD="$DB_PASSWORD" postgres:16-alpine psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USERNAME" -d "$DB_NAME" -c "SELECT 1"'
)

$parameters = @{ commands = $remoteCommands } | ConvertTo-Json -Compress
$commandId = Invoke-Native -Exe 'aws' -Arguments @(
    'ssm', 'send-command',
    '--region', $region,
    '--document-name', 'AWS-RunShellScript',
    '--instance-ids'
) + $backendInstanceIds + @(
    '--parameters', $parameters,
    '--query', 'Command.CommandId',
    '--output', 'text'
)

Write-Host "Database verification command: $commandId"
Write-Host 'Each backend instance must finish with Success. The output includes SELECT 1 when authentication succeeds.'
