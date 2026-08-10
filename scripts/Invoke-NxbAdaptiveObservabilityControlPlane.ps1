[CmdletBinding()]
param(
    [Parameter()][string]$PolicyPath,
    [Parameter()][string]$ClaimTargetsPath,
    [Parameter()][string]$SignalsPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][datetime]$EvaluationUtc = [DateTime]::UtcNow,
    [Parameter()][switch]$OpenPanel,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PolicyPath)) { $PolicyPath = Join-Path $repoRoot 'config\adaptive-observability.default.json' }
if ([string]::IsNullOrWhiteSpace($ClaimTargetsPath)) { $ClaimTargetsPath = Join-Path $repoRoot 'config\semantic-claim-targets.json' }

function Get-NxbControlPlaneSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    return (Get-FileHash -LiteralPath ([IO.Path]::GetFullPath($Path)) -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-NxbControlPlaneJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($full,(($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

$python = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $python) { $python = Get-Command python -ErrorAction SilentlyContinue }
if ($null -eq $python) { throw 'Python is required for independent adaptive-observability validation.' }

$fullOutput = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($fullOutput) | Out-Null
$planPath = Join-Path $fullOutput 'adaptive-observability-plan.json'
$panelPath = Join-Path $fullOutput 'adaptive-observability-panel.html'
$receiptPath = Join-Path $fullOutput 'adaptive-observability-receipt.json'

$planner = Join-Path $PSScriptRoot 'Get-NxbAdaptiveObservabilityPlan.ps1'
$panel = Join-Path $PSScriptRoot 'New-NxbAdaptiveObservabilityPanel.ps1'
$validator = Join-Path $repoRoot 'tools\validate_adaptive_observability.py'
foreach ($required in @($planner,$panel,$validator,$PolicyPath,$ClaimTargetsPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Adaptive control-plane dependency missing: $required" }
}

Write-Information '[1/4] Validate policy + semantic claim targets'
& $python.Source $validator --policy $PolicyPath --claims $ClaimTargetsPath
if ($LASTEXITCODE -ne 0) { throw "Adaptive policy validation failed: exit=$LASTEXITCODE" }

Write-Information '[2/4] Build deterministic adaptive capture plan'
$plannerArgs = @{
    PolicyPath = $PolicyPath
    ClaimTargetsPath = $ClaimTargetsPath
    EvaluationUtc = $EvaluationUtc
    OutputPath = $planPath
}
if (-not [string]::IsNullOrWhiteSpace($SignalsPath)) { $plannerArgs.SignalsPath = $SignalsPath }
& $planner @plannerArgs | Out-Null
if (-not (Test-Path -LiteralPath $planPath -PathType Leaf)) { throw 'Adaptive planner did not produce plan JSON.' }

Write-Information '[3/4] Independently validate generated plan'
& $python.Source $validator --policy $PolicyPath --claims $ClaimTargetsPath --plan $planPath
if ($LASTEXITCODE -ne 0) { throw "Adaptive plan validation failed: exit=$LASTEXITCODE" }

Write-Information '[4/4] Render read-only local panel + receipt'
$panelArgs = @{
    PlanPath = $planPath
    ClaimTargetsPath = $ClaimTargetsPath
    OutputPath = $panelPath
}
if ($OpenPanel) { $panelArgs.Open = $true }
& $panel @panelArgs | Out-Null
if (-not (Test-Path -LiteralPath $panelPath -PathType Leaf)) { throw 'Adaptive panel was not produced.' }

$signalSha = $null
if (-not [string]::IsNullOrWhiteSpace($SignalsPath) -and (Test-Path -LiteralPath $SignalsPath -PathType Leaf)) {
    $signalSha = Get-NxbControlPlaneSha256 -Path $SignalsPath
}
$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    evaluation_utc = $EvaluationUtc.ToUniversalTime().ToString('o')
    strategy = 'policy_driven_adaptive'
    policy_sha256 = Get-NxbControlPlaneSha256 -Path $PolicyPath
    claim_targets_sha256 = Get-NxbControlPlaneSha256 -Path $ClaimTargetsPath
    signals_sha256 = $signalSha
    plan_sha256 = Get-NxbControlPlaneSha256 -Path $planPath
    panel_sha256 = Get-NxbControlPlaneSha256 -Path $panelPath
    raw_payload_default = $false
    raw_identifier_hashing_required = $true
    panel_is_read_only = $true
    capture_adapters_executed = $false
    outputs = [pscustomobject][ordered]@{
        plan = [IO.Path]::GetFullPath($planPath)
        panel = [IO.Path]::GetFullPath($panelPath)
    }
}
Write-NxbControlPlaneJson -Path $receiptPath -InputObject $receipt

Write-Information -MessageData ("NXB adaptive observability control plane passed: plan={0} panel={1}" -f $planPath,$panelPath) -InformationAction Continue
if ($PassThru) { return $receipt }
Write-Output ([IO.Path]::GetFullPath($receiptPath))
