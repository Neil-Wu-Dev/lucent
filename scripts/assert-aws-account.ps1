# Verifies the AWS identity selected for Lucent Sandbox operations.
# This script is read-only and never prints credentials or tokens.
[CmdletBinding()]
param(
    [string]$ExpectedAccountId = '228755392058',
    [string]$AwsExe = 'aws'
)

$ErrorActionPreference = 'Stop'

$identityJson = & $AwsExe sts get-caller-identity --output json 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Unable to determine the current AWS identity: $($identityJson -join [Environment]::NewLine)"
}

try {
    $identity = ($identityJson -join [Environment]::NewLine) | ConvertFrom-Json
}
catch {
    throw 'AWS returned an invalid get-caller-identity response.'
}

if ([string]$identity.Account -ne $ExpectedAccountId) {
    throw "Wrong AWS account. Expected $ExpectedAccountId but received $($identity.Account). No deployment action was performed."
}

Write-Host "AWS account verified: $ExpectedAccountId"
