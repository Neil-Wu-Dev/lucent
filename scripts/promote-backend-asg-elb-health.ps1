# Restores production ELB health checks only after CodeDeploy ASG integration,
# revision convergence, and full application/security verification succeeded.
[CmdletBinding()]
param([string]$TerraformDir = 'D:\dev\lucent\infrastructure')

$ErrorActionPreference = 'Stop'
$region = 'eu-west-1'
$stateScript = Join-Path $PSScriptRoot 'codedeploy-asg-integration-state.ps1'
& $stateScript -Action VerifyEnabled -TerraformDir $TerraformDir

$AwsExe = 'aws'
foreach ($candidate in @('D:\Stuff\AWS CLI\aws.exe', 'C:\Program Files\Amazon\AWSCLIV2\aws.exe')) {
    if (Test-Path -LiteralPath $candidate) {
        $AwsExe = $candidate
        break
    }
}

function Invoke-Terraform {
    param([string[]]$Arguments)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & terraform @Arguments
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw "terraform $($Arguments -join ' ') failed with exit code $exitCode."
    }
}

function Get-TerraformPlanJson {
    param([Parameter(Mandatory = $true)][string]$PlanPath)

    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & terraform "-chdir=$TerraformDir" 'show' '-json' $PlanPath
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    if ($exitCode -ne 0) {
        throw 'terraform show failed while inspecting the Backend ELB health-check promotion plan.'
    }

    return (($output -join "`n") | ConvertFrom-Json)
}

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)

    $errorFile = Join-Path $env:TEMP ('lucent-asg-health-' + [guid]::NewGuid().ToString() + '.err')
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
            $standardError = if (Test-Path -LiteralPath $errorFile) { Get-Content -LiteralPath $errorFile -Raw } else { '' }
            throw "$Exe $($Arguments -join ' ') failed (exit $exitCode): $standardError"
        }
        return ($output -join "`n")
    }
    finally {
        Remove-Item -LiteralPath $errorFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-TerraformOutput {
    param([Parameter(Mandatory = $true)][string]$Name)

    return (Invoke-Native -Exe 'terraform' -Arguments @("-chdir=$TerraformDir", 'output', '-json', $Name) | ConvertFrom-Json)
}

$accountVerifier = Join-Path $PSScriptRoot 'assert-aws-account.ps1'
& $accountVerifier -AwsExe $AwsExe

$env:TF_VAR_codedeploy_enable_asg_integration = 'true'
$env:TF_VAR_backend_asg_enable_elb_health_checks = 'true'
$planPath = Join-Path $TerraformDir 'backend-asg-elb-health.tfplan'

try {
    Invoke-Terraform -Arguments @("-chdir=$TerraformDir", 'plan', '-out', $planPath)
    $planJson = Get-TerraformPlanJson -PlanPath $planPath
    $protectedPrefixes = @(
        'aws_vpc.',
        'aws_subnet.',
        'aws_lb.',
        'aws_autoscaling_group.',
        'aws_db_instance.'
    )
    $unsafeChanges = @(
        $planJson.resource_changes | Where-Object {
            $address = [string]$_.address
            $isProtected = @($protectedPrefixes | Where-Object { $address.StartsWith($_, [StringComparison]::Ordinal) }).Count -gt 0
            $actions = @($_.change.actions | ForEach-Object { [string]$_ })
            $isProtected -and ($actions -contains 'delete')
        }
    )
    if ($unsafeChanges.Count -gt 0) {
        $details = $unsafeChanges | ForEach-Object { "$($_.address) [$($_.change.actions -join ', ')]" }
        throw "Refusing Backend ELB health-check promotion because the Terraform plan deletes or replaces protected resources: $($details -join '; ')"
    }

    Invoke-Terraform -Arguments @("-chdir=$TerraformDir", 'apply', '-auto-approve', $planPath)

    $autoScalingGroup = [string](Get-TerraformOutput -Name 'backend_autoscaling_group_name')
    $healthCheckType = (Invoke-Native -Exe $AwsExe -Arguments @(
            'autoscaling', 'describe-auto-scaling-groups', '--region', $region,
            '--auto-scaling-group-names', $autoScalingGroup,
            '--query', 'AutoScalingGroups[0].HealthCheckType', '--output', 'text'
        )).Trim()
    if ($healthCheckType -ne 'ELB') {
        throw "Backend ASG $autoScalingGroup did not enter ELB health-check mode; current mode is $healthCheckType."
    }

    Write-Host "Backend ASG $autoScalingGroup is using production ELB health checks."
}
finally {
    Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
}
