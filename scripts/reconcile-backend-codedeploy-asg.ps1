# Re-deploys the last successful CodeDeploy revision after the Deployment Group
# becomes associated with the Backend ASG. CodeDeploy launch hooks cover future
# instances; this one controlled deployment converges instances that were
# already InService before the association existed.
[CmdletBinding()]
param([string]$TerraformDir = 'D:\dev\lucent\infrastructure')

$ErrorActionPreference = 'Stop'
$region = 'eu-west-1'

$AwsExe = 'aws'
foreach ($candidate in @('D:\Stuff\AWS CLI\aws.exe', 'C:\Program Files\Amazon\AWSCLIV2\aws.exe')) {
    if (Test-Path -LiteralPath $candidate) {
        $AwsExe = $candidate
        break
    }
}

function Invoke-Native {
    param([Parameter(Mandatory = $true)][string]$Exe, [string[]]$Arguments)

    $errorFile = Join-Path $env:TEMP ('lucent-codedeploy-reconcile-' + [guid]::NewGuid().ToString() + '.err')
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

function Write-CodeDeployFailureDetails {
    param([Parameter(Mandatory = $true)][string]$DeploymentId)

    Write-Host "=== CodeDeploy convergence failure details: $DeploymentId ==="
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
        Write-Warning "Unable to collect complete CodeDeploy convergence diagnostics: $($_.Exception.Message)"
    }
}

$accountVerifier = Join-Path $PSScriptRoot 'assert-aws-account.ps1'
& $accountVerifier -AwsExe $AwsExe

$applicationName = [string](Get-TfValue -Name 'backend_codedeploy_application_name')
$deploymentGroupName = [string](Get-TfValue -Name 'backend_codedeploy_deployment_group_name')
$autoScalingGroupName = [string](Get-TfValue -Name 'backend_autoscaling_group_name')
if (@($applicationName, $deploymentGroupName, $autoScalingGroupName) -match '^$') {
    throw 'Terraform outputs are incomplete; refusing to guess CodeDeploy ASG convergence settings.'
}

$groupInfo = (
    Invoke-Native -Exe $AwsExe -Arguments @(
        'deploy', 'get-deployment-group', '--region', $region,
        '--application-name', $applicationName,
        '--deployment-group-name', $deploymentGroupName,
        '--output', 'json'
    ) | ConvertFrom-Json
).deploymentGroupInfo

$associatedAsgNames = @($groupInfo.autoScalingGroups | ForEach-Object { [string]$_.name })
if ($autoScalingGroupName -notin $associatedAsgNames) {
    throw "CodeDeploy Deployment Group is not associated with ASG $autoScalingGroupName."
}

$sourceDeploymentId = [string]$groupInfo.lastSuccessfulDeployment.deploymentId
if ([string]::IsNullOrWhiteSpace($sourceDeploymentId)) {
    throw 'CodeDeploy has no successful release to use for ASG convergence.'
}

$sourceDeployment = (
    Invoke-Native -Exe $AwsExe -Arguments @(
        'deploy', 'get-deployment', '--region', $region,
        '--deployment-id', $sourceDeploymentId,
        '--output', 'json'
    ) | ConvertFrom-Json
).deploymentInfo

if ($sourceDeployment.revision.revisionType -ne 'S3' -or $null -eq $sourceDeployment.revision.s3Location) {
    throw "Last successful CodeDeploy release $sourceDeploymentId is not an S3 revision."
}

$s3Location = $sourceDeployment.revision.s3Location
if ([string]::IsNullOrWhiteSpace([string]$s3Location.bucket) -or
    [string]::IsNullOrWhiteSpace([string]$s3Location.key) -or
    [string]::IsNullOrWhiteSpace([string]$s3Location.bundleType)) {
    throw "Last successful CodeDeploy release $sourceDeploymentId has an incomplete S3 revision location."
}

$s3LocationParts = @(
    "bucket=$($s3Location.bucket)",
    "key=$($s3Location.key)",
    "bundleType=$($s3Location.bundleType)"
)
if (-not [string]::IsNullOrWhiteSpace([string]$s3Location.eTag)) { $s3LocationParts += "eTag=$($s3Location.eTag)" }
if (-not [string]::IsNullOrWhiteSpace([string]$s3Location.version)) { $s3LocationParts += "version=$($s3Location.version)" }
$s3LocationArgument = $s3LocationParts -join ','

$currentBackendIds = @(Get-AsgInServiceInstanceIds -AutoScalingGroupName $autoScalingGroupName)
if ($currentBackendIds.Count -lt 2) {
    throw "Backend ASG $autoScalingGroupName has fewer than two InService instances; refusing a convergence deployment."
}

Write-Host "Converging current Backend ASG instances with successful revision from ${sourceDeploymentId}: $($currentBackendIds -join ', ')"
$convergenceDeploymentId = (Invoke-Native -Exe $AwsExe -Arguments @(
        'deploy', 'create-deployment', '--region', $region,
        '--application-name', $applicationName,
        '--deployment-group-name', $deploymentGroupName,
        '--s3-location', $s3LocationArgument,
        '--description', "Lucent ASG convergence from $sourceDeploymentId",
        '--query', 'deploymentId', '--output', 'text'
    )).Trim()

if ([string]::IsNullOrWhiteSpace($convergenceDeploymentId)) {
    throw 'CodeDeploy did not return a deployment ID for Backend ASG convergence.'
}

Write-Host "CodeDeploy convergence deployment ID: $convergenceDeploymentId"
try {
    Invoke-Native -Exe $AwsExe -Arguments @(
        'deploy', 'wait', 'deployment-successful', '--region', $region,
        '--deployment-id', $convergenceDeploymentId
    ) | Out-Host
}
catch {
    Write-CodeDeployFailureDetails -DeploymentId $convergenceDeploymentId
    throw
}

Write-Host "CodeDeploy Backend ASG convergence succeeded: $convergenceDeploymentId"
$global:LASTEXITCODE = 0
