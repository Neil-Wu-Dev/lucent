# Promotes only a verified first CodeDeploy release to ASG lifecycle integration.
# It blocks the apply if the generated plan replaces or deletes core resources.
[CmdletBinding()]
param([string]$TerraformDir = 'D:\dev\lucent\infrastructure')

$ErrorActionPreference = 'Stop'
$stateScript = Join-Path $PSScriptRoot 'codedeploy-asg-integration-state.ps1'
& $stateScript -Action VerifyStageAReady -TerraformDir $TerraformDir

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
        throw 'terraform show failed while inspecting the CodeDeploy ASG integration plan.'
    }

    return (($output -join "`n") | ConvertFrom-Json)
}

$env:TF_VAR_codedeploy_enable_asg_integration = 'true'
$planPath = Join-Path $TerraformDir 'codedeploy-asg-integration.tfplan'

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
        $details = $unsafeChanges | ForEach-Object {
            "$($_.address) [$($_.change.actions -join ', ')]"
        }
        throw "Refusing CodeDeploy ASG integration promotion because the Terraform plan deletes or replaces protected resources: $($details -join '; ')"
    }

    Invoke-Terraform -Arguments @("-chdir=$TerraformDir", 'apply', '-auto-approve', $planPath)
    & $stateScript -Action VerifyEnabled -TerraformDir $TerraformDir
    Write-Host 'CodeDeploy ASG integration promotion completed and verified.'
}
finally {
    # The plan file is Git-ignored; remove it so a future promotion never uses
    # a stale local plan.
    Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
}
