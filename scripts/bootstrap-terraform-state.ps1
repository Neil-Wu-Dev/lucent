# Creates the shared Terraform state bucket and optionally migrates the local state.
# Run this once from a developer machine before the GitHub Actions pipelines run.

param(
    [string]$ProjectDir = "D:\dev\lucent",
    [string]$TerraformDir = "",
    [switch]$MigrateState
)

$ErrorActionPreference = "Stop"
$region = "us-east-1"

if (-not $TerraformDir) {
    $TerraformDir = Join-Path $ProjectDir "infrastructure"
}

if (-not (Test-Path -LiteralPath $TerraformDir)) {
    throw "Terraform directory not found: $TerraformDir"
}

$accountId = aws sts get-caller-identity --query Account --output text
if ($LASTEXITCODE -ne 0 -or -not $accountId) {
    throw "Could not determine the AWS account ID. Refresh AWS Academy credentials and try again."
}

$bucket = "lucent-terraform-state-$accountId"

# A missing bucket is expected during the first run. Do not let PowerShell
# turn the AWS CLI non-zero exit code into a terminating error.
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = "Continue"
try {
    & aws s3api head-bucket --bucket $bucket 2>$null
    $headBucketExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

if ($headBucketExitCode -ne 0) {
    aws s3api create-bucket --bucket $bucket --region $region
    if ($LASTEXITCODE -ne 0) {
        throw "Could not create Terraform state bucket: $bucket"
    }
}

aws s3api put-bucket-versioning --bucket $bucket --versioning-configuration Status=Enabled
if ($LASTEXITCODE -ne 0) { throw "Could not enable versioning for $bucket" }

# Pass JSON by file rather than directly on the PowerShell command line, which
# can otherwise remove JSON quotation marks before the AWS CLI receives them.
$temporaryDirectory = [System.IO.Path]::GetTempPath()
$encryptionFile = Join-Path $temporaryDirectory ("lucent-s3-encryption-" + [guid]::NewGuid() + ".json")
$publicAccessBlockFile = Join-Path $temporaryDirectory ("lucent-s3-public-access-" + [guid]::NewGuid() + ".json")

try {
    [System.IO.File]::WriteAllText(
        $encryptionFile,
        '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}',
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::WriteAllText(
        $publicAccessBlockFile,
        '{"BlockPublicAcls":true,"IgnorePublicAcls":true,"BlockPublicPolicy":true,"RestrictPublicBuckets":true}',
        [System.Text.UTF8Encoding]::new($false)
    )

    aws s3api put-bucket-encryption --bucket $bucket --server-side-encryption-configuration "file://$encryptionFile"
    if ($LASTEXITCODE -ne 0) { throw "Could not enable encryption for $bucket" }

    aws s3api put-public-access-block --bucket $bucket --public-access-block-configuration "file://$publicAccessBlockFile"
    if ($LASTEXITCODE -ne 0) { throw "Could not block public access for $bucket" }
} finally {
    Remove-Item -LiteralPath $encryptionFile, $publicAccessBlockFile -Force -ErrorAction SilentlyContinue
}

Push-Location $TerraformDir
try {
    $initArguments = @(
        "init",
        "-backend-config=bucket=$bucket",
        "-backend-config=key=lucent/terraform.tfstate",
        "-backend-config=region=$region",
        "-backend-config=encrypt=true",
        "-backend-config=use_lockfile=true"
    )

    if ($MigrateState) {
        # This script only adds -force-copy when migration was explicitly
        # requested, so it remains usable from non-interactive CI sessions.
        $initArguments += "-migrate-state", "-force-copy"
    } else {
        $initArguments += "-reconfigure"
    }

    & terraform @initArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Terraform remote state initialization failed."
    }
} finally {
    Pop-Location
}

Write-Host "Terraform remote state is ready: s3://$bucket/lucent/terraform.tfstate"
