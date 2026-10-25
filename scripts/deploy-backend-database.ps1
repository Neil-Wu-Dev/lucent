# Configures the already-deployed backend containers with the private RDS
# connection. Run this after Terraform has created the RDS instance.
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
$repositoryUrl = Get-TerraformOutput 'backend_ecr_repository_url'
$backendInstanceIds = @(Get-TerraformJsonOutput 'backend_instance_ids' | ConvertFrom-Json)

$databasePasswordPlainText = ConvertFrom-SecureString -SecureString $DatabasePassword -AsPlainText
$databaseUrl = 'jdbc:postgresql://' + $databaseEndpoint + ':' + $databasePort + '/' + $databaseName

$databaseUrlBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($databaseUrl))
$databaseUsernameBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($databaseUsername))
$databasePasswordBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($databasePasswordPlainText))

$remoteCommands = @(
    'set -euo pipefail',
    "DB_URL_BASE64=$databaseUrlBase64",
    "DB_USERNAME_BASE64=$databaseUsernameBase64",
    "DB_PASSWORD_BASE64=$databasePasswordBase64",
    'DB_URL="$(echo "$DB_URL_BASE64" | base64 -d)"',
    'DB_USERNAME="$(echo "$DB_USERNAME_BASE64" | base64 -d)"',
    'DB_PASSWORD="$(echo "$DB_PASSWORD_BASE64" | base64 -d)"',
    "aws ecr get-login-password --region $region | docker login --username AWS --password-stdin $($repositoryUrl.Split('/')[0])",
    'docker pull ' + $repositoryUrl + ':latest',
    'docker rm -f lucent-backend 2>/dev/null || true',
    'docker run -d --name lucent-backend --restart unless-stopped -p 8080:8080 -e DB_URL="$DB_URL" -e DB_USERNAME="$DB_USERNAME" -e DB_PASSWORD="$DB_PASSWORD" ' + $repositoryUrl + ':latest',
    'sleep 15',
    'docker ps --filter name=lucent-backend --format "{{.Names}} {{.Status}}"',
    'docker logs --tail 100 lucent-backend'
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

Write-Host "Backend database configuration command: $commandId"
Write-Host 'Wait for both invocations to succeed, then run scripts\verify-database.ps1.'
