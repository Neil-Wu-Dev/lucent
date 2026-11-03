# Verifies the AWS identity selected for Lucent Sandbox operations.
# This script is read-only and never prints credentials or tokens.
[CmdletBinding()]
param(
    [string]$ExpectedAccountId = '228755392058',
    [string]$AwsExe = 'aws'
)

$ErrorActionPreference = 'Stop'

$errorFile = Join-Path $env:TEMP ('lucent-aws-identity-' + [guid]::NewGuid().ToString() + '.err')

try {
    # PowerShell 5.1 turns a native command's stderr into NativeCommandError
    # when 2>&1 is combined with ErrorActionPreference=Stop. Capture stderr in
    # a file instead, retain the native exit code, then report both streams.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'

    try {
        $identityJson = & $AwsExe sts get-caller-identity --output json 2> $errorFile
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        $errorText = if (Test-Path -LiteralPath $errorFile) {
            Get-Content -LiteralPath $errorFile -Raw
        }
        else {
            ''
        }

        throw "Unable to determine the current AWS identity (exit $exitCode): $errorText"
    }
}
finally {
    Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
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
