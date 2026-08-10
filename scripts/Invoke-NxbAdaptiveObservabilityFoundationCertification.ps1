[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Write-NxbAdaptiveCertificationJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-NxbAdaptiveCertificationPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Executable,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TestPath,
        [Parameter(Mandatory)][ValidateRange(1,1000)][int]$ExpectedCount,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-adaptive-pester-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $childPath = Join-Path $tempRoot 'run.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
$ErrorActionPreference = 'Stop'
Import-Module Pester -ErrorAction Stop
$result = Invoke-Pester -Path $TestPath -PassThru
$summary = [pscustomobject]@{ passed=[int]$result.PassedCount; failed=[int]$result.FailedCount; skipped=[int]$result.SkippedCount; total=[int]$result.TotalCount }
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($summary.passed -ne $ExpectedCount -or $summary.total -ne $ExpectedCount -or $summary.failed -ne 0 -or $summary.skipped -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8
    try {
        $childOutput = @(& $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath -ExpectedCount $ExpectedCount 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $childOutput) { Write-Information -MessageData ([string]$line) -InformationAction Continue }
        if ($exitCode -ne 0) { throw "$Label Pester run failed: exit=$exitCode" }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Adaptive observability foundation certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Adaptive observability foundation certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw "Adaptive exact-head mismatch. Expected=$ExpectedHead actual=$currentHead" }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Adaptive foundation certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Adaptive certification output must remain outside the repository.' }
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }
$reviewRoot = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null

$policyPath = Join-Path $repositoryRoot 'config\adaptive-observability.default.json'
$claimsPath = Join-Path $repositoryRoot 'config\semantic-claim-targets.json'
$plannerPath = Join-Path $PSScriptRoot 'Get-NxbAdaptiveObservabilityPlan.ps1'
$panelPath = Join-Path $PSScriptRoot 'New-NxbAdaptiveObservabilityPanel.ps1'
$controllerPath = Join-Path $PSScriptRoot 'Invoke-NxbAdaptiveObservabilityControlPlane.ps1'
$testPath = Join-Path $repositoryRoot 'tests\AdaptiveObservabilityControl.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_adaptive_observability.py'
foreach ($required in @($policyPath,$claimsPath,$plannerPath,$panelPath,$controllerPath,$testPath,$validatorPath,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Adaptive foundation component missing: $required" }
}

Write-Information '=== NXB IRL-005 ADAPTIVE OBSERVABILITY FOUNDATION CERTIFICATION ==='
Write-Information '[1/6] Parser/analyzer + dual-runtime 20-test contract'
$analyzerPaths = @($plannerPath,$panelPath,$controllerPath,$testPath,$PSCommandPath)
foreach ($scriptPath in $analyzerPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ("PowerShell parser failed: $scriptPath`n" + (@($parseErrors | ForEach-Object { $_.Message }) -join "`n")) }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(foreach ($scriptPath in $analyzerPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($findings.Count -gt 0) { throw ("Adaptive PSScriptAnalyzer findings: $($findings.Count)`n" + (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")) }

$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
& $pythonCommand.Source -m py_compile $validatorPath
if ($LASTEXITCODE -ne 0) { throw 'Adaptive Python syntax check failed.' }

$previousRoot = [Environment]::GetEnvironmentVariable('NXB_ADAPTIVE_REPOSITORY_ROOT','Process')
$env:NXB_ADAPTIVE_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Summary = Invoke-NxbAdaptiveCertificationPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 20 -Label 'PowerShell 7 adaptive foundation'
    $ps51Summary = Invoke-NxbAdaptiveCertificationPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 20 -Label 'Windows PowerShell 5.1 adaptive foundation'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_ADAPTIVE_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_ADAPTIVE_REPOSITORY_ROOT = $previousRoot }
}
$ps7Contract = '{0}/{1}' -f [int]$ps7Summary.passed,[int]$ps7Summary.total
$ps51Contract = '{0}/{1}' -f [int]$ps51Summary.passed,[int]$ps51Summary.total

Write-Information '[2/6] Independent policy + semantic-target validation'
& $pythonCommand.Source $validatorPath --policy $policyPath --claims $claimsPath
if ($LASTEXITCODE -ne 0) { throw 'Adaptive independent policy validation failed.' }

Write-Information '[3/6] Generate deterministic high-contention signal bundle'
$signalsPath = Join-Path $reviewRoot 'adaptive-foundation-signals.json'
$signals = [pscustomobject][ordered]@{
    signals = @(
        [pscustomobject][ordered]@{ signal='manual_forensic'; captured_utc='2026-08-10T15:30:00Z' },
        [pscustomobject][ordered]@{ signal='frame_latency_spike'; captured_utc='2026-08-10T15:30:05Z' },
        [pscustomobject][ordered]@{ signal='device_transition'; captured_utc='2026-08-10T15:30:10Z'; domains=@('pnp_device','pcie','kernel_driver') }
    )
}
Write-NxbAdaptiveCertificationJson -Path $signalsPath -InputObject $signals

Write-Information '[4/6] Execute control plane + generate plan/panel/receipt'
$controlRoot = Join-Path $outputFull 'control-plane'
$evaluationUtc = [DateTime]::Parse('2026-08-10T15:30:20Z').ToUniversalTime()
$controlReceipt = & $controllerPath -PolicyPath $policyPath -ClaimTargetsPath $claimsPath -SignalsPath $signalsPath -OutputDirectory $controlRoot -EvaluationUtc $evaluationUtc -PassThru
if ($null -eq $controlReceipt) { throw 'Adaptive control plane returned no receipt.' }
if ([bool]$controlReceipt.capture_adapters_executed) { throw 'Adaptive foundation unexpectedly executed capture adapters.' }

$planPath = Join-Path $controlRoot 'adaptive-observability-plan.json'
$panelOutputPath = Join-Path $controlRoot 'adaptive-observability-panel.html'
$controlReceiptPath = Join-Path $controlRoot 'adaptive-observability-receipt.json'
foreach ($generated in @($planPath,$panelOutputPath,$controlReceiptPath)) {
    if (-not (Test-Path -LiteralPath $generated -PathType Leaf)) { throw "Adaptive generated artifact missing: $generated" }
}

Write-Information '[5/6] Functional budget/TTL/claim-boundary acceptance'
$plan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
$elevatedDomains = @($plan.domains.PSObject.Properties | Where-Object { [bool]$_.Value.elevated })
$suppressedDomains = @($plan.domains.PSObject.Properties | Where-Object { [bool]$_.Value.budget_suppressed })
if ($elevatedDomains.Count -gt [int]$plan.budgets.max_concurrent_elevated_domains) { throw 'Adaptive plan exceeded elevated-domain budget.' }
if ($elevatedDomains.Count -ne 4) { throw "Expected exactly four elevated domains in contention fixture; actual=$($elevatedDomains.Count)" }
if ($suppressedDomains.Count -lt 1) { throw 'Contention fixture did not exercise budget suppression.' }
foreach ($property in @($plan.domains.PSObject.Properties)) {
    if ([string]$property.Value.level -cne 'forensic' -and [bool]$property.Value.raw_payload_allowed) { throw "Raw payload escaped forensic level: $($property.Name)" }
}

$controlReceiptLoaded = Get-Content -LiteralPath $controlReceiptPath -Raw | ConvertFrom-Json
if ([string]$controlReceiptLoaded.strategy -cne 'policy_driven_adaptive') { throw 'Adaptive receipt strategy mismatch.' }
if (-not [bool]$controlReceiptLoaded.raw_identifier_hashing_required) { throw 'Adaptive receipt lost raw identifier hashing requirement.' }
if (-not [bool]$controlReceiptLoaded.panel_is_read_only) { throw 'Adaptive panel is not recorded read-only.' }
if ([string]$controlReceiptLoaded.plan_sha256 -cne (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Adaptive plan hash mismatch.' }
if ([string]$controlReceiptLoaded.panel_sha256 -cne (Get-FileHash -LiteralPath $panelOutputPath -Algorithm SHA256).Hash.ToLowerInvariant()) { throw 'Adaptive panel hash mismatch.' }

Write-Information '[6/6] Bounded review evidence + foundation receipt'
Copy-Item -LiteralPath $planPath -Destination (Join-Path $reviewRoot 'adaptive-observability-plan.json') -Force
Copy-Item -LiteralPath $controlReceiptPath -Destination (Join-Path $reviewRoot 'adaptive-observability-receipt.json') -Force
Copy-Item -LiteralPath $panelOutputPath -Destination (Join-Path $reviewRoot 'adaptive-observability-panel.html') -Force

$foundationReceipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $ExpectedHead.ToLowerInvariant()
    ps7_tests = $ps7Contract
    ps51_tests = $ps51Contract
    psscriptanalyzer_findings = [int]$findings.Count
    python_syntax = 'passed'
    policy_validation = 'passed'
    plan_validation = 'passed'
    active_signal_count = [int]$plan.active_signal_count
    elevated_domain_count = [int]$elevatedDomains.Count
    budget_suppressed_domain_count = [int]$suppressedDomains.Count
    max_concurrent_elevated_domains = [int]$plan.budgets.max_concurrent_elevated_domains
    panel_generated = $true
    panel_is_read_only = $true
    capture_adapters_executed = $false
    desired_claims_true_count = 8
    promoted_claims_count = 0
    plan_sha256 = (Get-FileHash -LiteralPath (Join-Path $reviewRoot 'adaptive-observability-plan.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    control_receipt_sha256 = (Get-FileHash -LiteralPath (Join-Path $reviewRoot 'adaptive-observability-receipt.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    panel_sha256 = (Get-FileHash -LiteralPath (Join-Path $reviewRoot 'adaptive-observability-panel.html') -Algorithm SHA256).Hash.ToLowerInvariant()
}
$foundationReceiptPath = Join-Path $reviewRoot 'adaptive-foundation-certification-receipt.json'
Write-NxbAdaptiveCertificationJson -Path $foundationReceiptPath -InputObject $foundationReceipt

$reviewZip = "$outputFull-review.zip"
if (Test-Path -LiteralPath $reviewZip) { Remove-Item -LiteralPath $reviewZip -Force }
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
$reviewSha = (Get-FileHash -LiteralPath $reviewZip -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Information -MessageData ("NXB IRL-005 adaptive foundation passed: elevated={0} suppressed={1} review={2}" -f $elevatedDomains.Count,$suppressedDomains.Count,$reviewSha) -InformationAction Continue
if ($PassThru) {
    return [pscustomobject][ordered]@{
        status = 'passed'
        head_sha = $ExpectedHead.ToLowerInvariant()
        ps7_tests = $ps7Contract
        ps51_tests = $ps51Contract
        psscriptanalyzer_findings = [int]$findings.Count
        elevated_domain_count = [int]$elevatedDomains.Count
        budget_suppressed_domain_count = [int]$suppressedDomains.Count
        capture_adapters_executed = $false
        review_zip_path = [IO.Path]::GetFullPath($reviewZip)
        review_zip_sha256 = $reviewSha
        receipt_path = [IO.Path]::GetFullPath($foundationReceiptPath)
    }
}
Write-Output ([IO.Path]::GetFullPath($reviewZip))
