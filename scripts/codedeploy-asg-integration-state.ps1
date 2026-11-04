# Resolves the persistent CodeDeploy ASG-integration state without modifying
# Terraform State. The marker is written only after a verified first release;
# it is always cross-checked against the live Deployment Group before use.
[CmdletBinding()]
param(
    [ValidateSet('ResolveForInfrastructure', 'MarkSuccessfulStageA', 'VerifyStageAReady', 'VerifyEnabled')]
    [string]$Action,
    [string]$TerraformDir = 'D:\dev\lucent\infrastructure'
)

$ErrorActionPreference = 'Stop'
$region = 'eu-west-1'
$markerKey = 'codedeploy/backend/state/asg-integration-ready.json'

$AwsExe = 'aws'
foreach ($candidate in @('D:\Stuff\AWS CLI\aws.exe', 'C:\Program Files\Amazon\AWSCLIV2\aws.exe')) {
    if (Test-Path -LiteralPath $candidate) {
        $AwsExe = $candidate
        break
    }
}

function Invoke-NativeResult {
    param([Parameter(Mandatory = $true)][string]$Exe, [string[]]$Arguments)

    $errorFile = Join-Path $env:TEMP ('lucent-codedeploy-state-' + [guid]::NewGuid().ToString() + '.err')
    try {
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $Exe @Arguments 2> $errorFile
            $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }

        return [pscustomobject]@{
            ExitCode = $exitCode
            Output   = [string]($output -join "`n")
            Error    = if (Test-Path -LiteralPath $errorFile) { [string](Get-Content -LiteralPath $errorFile -Raw) } else { '' }
        }
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-NativeStrict {
    param([Parameter(Mandatory = $true)][string]$Exe, [string[]]$Arguments)

    $result = Invoke-NativeResult -Exe $Exe -Arguments $Arguments
    if ($result.ExitCode -ne 0) {
        throw "$Exe $($Arguments -join ' ') failed (exit $($result.ExitCode)): $($result.Error)"
    }
    return $result.Output
}

function Get-TerraformOutputOrNull {
    param([Parameter(Mandatory = $true)][string]$Name)

    $result = Invoke-NativeResult -Exe 'terraform' -Arguments @(
        "-chdir=$TerraformDir", 'output', '-json', $Name
    )
    if ($result.ExitCode -ne 0) { return $null }
    return ($result.Output | ConvertFrom-Json)
}

function Get-Configuration {
    $configuration = [pscustomobject]@{
        Bucket             = [string](Get-TerraformOutputOrNull -Name 'deployment_artifact_bucket_name')
        ApplicationName    = [string](Get-TerraformOutputOrNull -Name 'backend_codedeploy_application_name')
        DeploymentGroup    = [string](Get-TerraformOutputOrNull -Name 'backend_codedeploy_deployment_group_name')
        AutoScalingGroup   = [string](Get-TerraformOutputOrNull -Name 'backend_autoscaling_group_name')
    }

    if (@($configuration.Bucket, $configuration.ApplicationName, $configuration.DeploymentGroup, $configuration.AutoScalingGroup) -match '^$') {
        return $null
    }
    return $configuration
}

function Test-MarkerExists {
    param([Parameter(Mandatory = $true)][string]$Bucket)

    $result = Invoke-NativeResult -Exe $AwsExe -Arguments @(
        's3api', 'head-object', '--region', $region,
        '--bucket', $Bucket, '--key', $markerKey
    )
    if ($result.ExitCode -eq 0) { return $true }

    $details = $result.Error + $result.Output
    if ($details -match '404|Not Found|HeadObject') { return $false }
    throw "Unable to read CodeDeploy integration marker: $details"
}

function Get-DeploymentGroupOrNull {
    param($Configuration)

    $result = Invoke-NativeResult -Exe $AwsExe -Arguments @(
        'deploy', 'get-deployment-group', '--region', $region,
        '--application-name', $Configuration.ApplicationName,
        '--deployment-group-name', $Configuration.DeploymentGroup,
        '--output', 'json'
    )
    if ($result.ExitCode -eq 0) {
        return (($result.Output | ConvertFrom-Json).deploymentGroupInfo)
    }

    $details = $result.Error + $result.Output
    if ($details -match 'ApplicationDoesNotExistException|DeploymentGroupDoesNotExistException') {
        return $null
    }
    throw "Unable to read CodeDeploy Deployment Group: $details"
}

function Test-GroupHasAutoScalingIntegration {
    param($DeploymentGroup, [Parameter(Mandatory = $true)][string]$AutoScalingGroup)

    if ($null -eq $DeploymentGroup) { return $false }
    $associatedGroups = @($DeploymentGroup.autoScalingGroups | ForEach-Object { [string]$_.autoScalingGroupName })
    return $AutoScalingGroup -in $associatedGroups
}

function Get-LastSuccessfulDeploymentId {
    param($DeploymentGroup)

    if ($null -eq $DeploymentGroup -or $null -eq $DeploymentGroup.lastSuccessfulDeployment) { return '' }
    return [string]$DeploymentGroup.lastSuccessfulDeployment.deploymentId
}

function Write-Marker {
    param($Configuration, [Parameter(Mandatory = $true)][string]$DeploymentId)

    $markerFile = Join-Path $env:TEMP ('lucent-codedeploy-marker-' + [guid]::NewGuid().ToString() + '.json')
    try {
        $marker = [ordered]@{
            schemaVersion       = 1
            deploymentId        = $DeploymentId
            applicationName     = $Configuration.ApplicationName
            deploymentGroupName = $Configuration.DeploymentGroup
            autoScalingGroup    = $Configuration.AutoScalingGroup
            createdAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
        } | ConvertTo-Json
        [IO.File]::WriteAllText($markerFile, $marker, (New-Object System.Text.UTF8Encoding($false)))

        Invoke-NativeStrict -Exe $AwsExe -Arguments @(
            's3api', 'put-object', '--region', $region,
            '--bucket', $Configuration.Bucket,
            '--key', $markerKey,
            '--body', $markerFile,
            '--content-type', 'application/json',
            '--server-side-encryption', 'AES256'
        ) | Out-Null
    }
    finally {
        Remove-Item -LiteralPath $markerFile -Force -ErrorAction SilentlyContinue
    }
}

switch ($Action) {
    'ResolveForInfrastructure' {
        $configuration = Get-Configuration
        $enabled = $false

        if ($null -ne $configuration) {
            $markerExists = Test-MarkerExists -Bucket $configuration.Bucket
            $deploymentGroup = Get-DeploymentGroupOrNull -Configuration $configuration
            $deploymentId = Get-LastSuccessfulDeploymentId -DeploymentGroup $deploymentGroup
            $hasSuccessfulDeployment = -not [string]::IsNullOrWhiteSpace($deploymentId)
            $enabled = $hasSuccessfulDeployment -and (Test-GroupHasAutoScalingIntegration -DeploymentGroup $deploymentGroup -AutoScalingGroup $configuration.AutoScalingGroup)

            if ($enabled -and -not $markerExists) {
                Write-Warning 'CodeDeploy ASG integration is active but its S3 marker is missing; restoring the marker from the verified Deployment Group state.'
                Write-Marker -Configuration $configuration -DeploymentId $deploymentId
            }
            elseif ($markerExists -and -not $enabled) {
                Write-Warning 'A CodeDeploy marker exists but the current Deployment Group is not safely ASG-integrated; keeping Stage A configuration.'
            }
        }

        if ($env:GITHUB_ENV) {
            [IO.File]::AppendAllText($env:GITHUB_ENV, "TF_VAR_codedeploy_enable_asg_integration=$($enabled.ToString().ToLowerInvariant())`n", (New-Object System.Text.UTF8Encoding($false)))
        }
        Write-Host "Persistent CodeDeploy ASG integration resolved: $enabled"
    }
    'MarkSuccessfulStageA' {
        $configuration = Get-Configuration
        if ($null -eq $configuration) { throw 'Terraform outputs are unavailable; cannot mark successful CodeDeploy Stage A.' }
        $deploymentGroup = Get-DeploymentGroupOrNull -Configuration $configuration
        $deploymentId = Get-LastSuccessfulDeploymentId -DeploymentGroup $deploymentGroup
        if ([string]::IsNullOrWhiteSpace($deploymentId)) { throw 'CodeDeploy has no successful deployment; refusing to create the ASG integration marker.' }
        Write-Marker -Configuration $configuration -DeploymentId $deploymentId
        Write-Host "Successful CodeDeploy marker written for deployment $deploymentId"
    }
    'VerifyStageAReady' {
        $configuration = Get-Configuration
        if ($null -eq $configuration -or -not (Test-MarkerExists -Bucket $configuration.Bucket)) { throw 'No successful CodeDeploy marker exists; ASG integration promotion is blocked.' }
        $deploymentGroup = Get-DeploymentGroupOrNull -Configuration $configuration
        if ([string]::IsNullOrWhiteSpace((Get-LastSuccessfulDeploymentId -DeploymentGroup $deploymentGroup))) { throw 'CodeDeploy has no successful deployment; ASG integration promotion is blocked.' }
        Write-Host 'Successful CodeDeploy release verified for ASG integration promotion.'
    }
    'VerifyEnabled' {
        $configuration = Get-Configuration
        if ($null -eq $configuration -or -not (Test-MarkerExists -Bucket $configuration.Bucket)) { throw 'CodeDeploy ASG integration marker is absent.' }
        $deploymentGroup = Get-DeploymentGroupOrNull -Configuration $configuration
        if (-not (Test-GroupHasAutoScalingIntegration -DeploymentGroup $deploymentGroup -AutoScalingGroup $configuration.AutoScalingGroup)) { throw "CodeDeploy Deployment Group is not associated with ASG $($configuration.AutoScalingGroup)." }
        if ([string]::IsNullOrWhiteSpace((Get-LastSuccessfulDeploymentId -DeploymentGroup $deploymentGroup))) { throw 'CodeDeploy Deployment Group has no successful deployment.' }
        Write-Host "CodeDeploy ASG integration verified for $($configuration.AutoScalingGroup)."
    }
}

$global:LASTEXITCODE = 0
