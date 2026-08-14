[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbAdaptiveV3Json {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-NxbAdaptiveV3Pester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-adaptive-v3-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $childPath = Join-Path $tempRoot 'run.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
$ErrorActionPreference = 'Stop'
Import-Module Pester -ErrorAction Stop
$result = Invoke-Pester -Path $TestPath -PassThru
$summary = [pscustomobject]@{
    passed = [int]$result.PassedCount
    failed = [int]$result.FailedCount
    skipped = [int]$result.SkippedCount
    total = [int]$result.TotalCount
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($summary.passed -ne $ExpectedCount -or $summary.total -ne $ExpectedCount -or $summary.failed -ne 0 -or $summary.skipped -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8
    try {
        $output = @(& $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath -ExpectedCount $ExpectedCount 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $output) { Write-Information -InformationAction Continue -MessageData ([string]$line) }
        if ($exitCode -ne 0) { throw ('{0} Pester failed: exit={1}' -f $Label,$exitCode) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Adaptive observability V3 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Adaptive observability V3 certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Adaptive V3 exact-head mismatch. Expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Adaptive V3 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) { throw ('OutputDirectory already exists: {0}' -f $outputFull) }

$stateScript = Join-Path $PSScriptRoot 'Update-NxbAdaptiveObservabilityState.ps1'
$hysteresisTest = Join-Path $repositoryRoot 'tests\AdaptiveObservabilityHysteresis.Tests.ps1'
$v2Runner = Join-Path $PSScriptRoot 'Invoke-NxbAdaptiveObservabilityCertificationV2.ps1'
foreach ($requiredPath in @($stateScript,$hysteresisTest,$v2Runner,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Adaptive V3 component missing: {0}' -f $requiredPath) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-005 ADAPTIVE OBSERVABILITY CONTROL-PLANE CERTIFICATION V3 ==='
Write-Information -InformationAction Continue -MessageData '[1/3] Stateful hysteresis parser/analyzer + dual-runtime 8-test contract'
$stateAnalyzerPaths = @($stateScript,$hysteresisTest,$PSCommandPath)
foreach ($scriptPath in $stateAnalyzerPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('Adaptive V3 parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join "`n")) }
}
if (-not (Get-Module -Name PSScriptAnalyzer)) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
}
$stateFindings = @(foreach ($scriptPath in $stateAnalyzerPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($stateFindings.Count -gt 0) { throw ('Adaptive V3 PSScriptAnalyzer findings: {0}`n{1}' -f $stateFindings.Count,(@($stateFindings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")) }

$previousRoot = [Environment]::GetEnvironmentVariable('NXB_ADAPTIVE_REPOSITORY_ROOT','Process')
$env:NXB_ADAPTIVE_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Hysteresis = Invoke-NxbAdaptiveV3Pester -Executable $pwshPath -TestPath $hysteresisTest -ExpectedCount 8 -Label 'PowerShell 7 adaptive hysteresis'
    $ps51Hysteresis = Invoke-NxbAdaptiveV3Pester -Executable $ps51Path -TestPath $hysteresisTest -ExpectedCount 8 -Label 'Windows PowerShell 5.1 adaptive hysteresis'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_ADAPTIVE_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_ADAPTIVE_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -InformationAction Continue -MessageData '[2/3] Run hardened V2 core + panel-security certification'
$v2Pipeline = @(& $v2Runner -ExpectedHead $ExpectedHead -OutputDirectory $outputFull -PassThru)
$v2Result = $null
foreach ($item in $v2Pipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $v2Result = $item }
}
if ($null -eq $v2Result) { throw 'Adaptive V2 child certification returned no passed result.' }
if ([string]$v2Result.head_sha -cne $currentHead) { throw 'Adaptive V2 child head mismatch.' }
if ([string]$v2Result.ps7_tests -cne '30/30' -or [string]$v2Result.ps51_tests -cne '30/30') { throw 'Adaptive V2 child test contract mismatch.' }
if ([int]$v2Result.psscriptanalyzer_findings -ne 0) { throw 'Adaptive V2 child analyzer findings were nonzero.' }
if (-not [bool]$v2Result.deterministic_empty_replay) { throw 'Adaptive V2 deterministic replay failed.' }
if ([int]$v2Result.semantic_targets_requested -ne 8 -or [int]$v2Result.semantic_targets_validated -ne 0) { throw 'Adaptive V2 claim-target boundary mismatch.' }

Write-Information -InformationAction Continue -MessageData '[3/3] Bind hysteresis validation into final V3 review evidence'
$reviewRoot = Join-Path $outputFull 'review'
if (-not (Test-Path -LiteralPath $reviewRoot -PathType Container)) { throw 'Adaptive V2 review directory is missing.' }
$hysteresisPath = Join-Path $reviewRoot 'adaptive-hysteresis-validation.json'
$hysteresisReceipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    ps7_tests = '{0}/{1}' -f [int]$ps7Hysteresis.passed,[int]$ps7Hysteresis.total
    ps51_tests = '{0}/{1}' -f [int]$ps51Hysteresis.passed,[int]$ps51Hysteresis.total
    psscriptanalyzer_findings = [int]$stateFindings.Count
    hold_semantics = $true
    cooldown_semantics = $true
    trigger_state_authoritative = $true
    stateless_cooldown_bypass_prevented = $true
}
Write-NxbAdaptiveV3Json -Path $hysteresisPath -InputObject $hysteresisReceipt

$ps7CombinedPassed = [int]30 + [int]$ps7Hysteresis.passed
$ps7CombinedTotal = [int]30 + [int]$ps7Hysteresis.total
$ps51CombinedPassed = [int]30 + [int]$ps51Hysteresis.passed
$ps51CombinedTotal = [int]30 + [int]$ps51Hysteresis.total
$ps7Contract = '{0}/{1}' -f $ps7CombinedPassed,$ps7CombinedTotal
$ps51Contract = '{0}/{1}' -f $ps51CombinedPassed,$ps51CombinedTotal
if ($ps7Contract -cne '38/38' -or $ps51Contract -cne '38/38') { throw 'Adaptive V3 combined contract mismatch.' }

$v3ReceiptPath = Join-Path $reviewRoot 'adaptive-control-plane-certification-v3-receipt.json'
$v3Receipt = [pscustomobject][ordered]@{
    schema_version = 3
    status = 'passed'
    head_sha = $currentHead
    static_validation = [pscustomobject][ordered]@{
        ps7_tests = $ps7Contract
        ps51_tests = $ps51Contract
        psscriptanalyzer_findings = 0
        child_v2_tests_per_runtime = 30
        hysteresis_tests_per_runtime = 8
    }
    policy_fingerprint_sha256 = [string]$v2Result.policy_fingerprint_sha256
    scenario_count = [int]$v2Result.scenario_count
    deterministic_empty_replay = [bool]$v2Result.deterministic_empty_replay
    semantic_targets = [pscustomobject][ordered]@{
        requested = [int]$v2Result.semantic_targets_requested
        validated = [int]$v2Result.semantic_targets_validated
        evidence_required_for_validation = $true
    }
    control_plane = [pscustomobject][ordered]@{
        local_only_panel = [bool]$v2Result.panel_local_only
        mutation_token = [bool]$v2Result.panel_mutation_token
        stateful_hold = $true
        stateful_cooldown = $true
        automatic_deescalation = $true
        trigger_state_authoritative = $true
    }
}
Write-NxbAdaptiveV3Json -Path $v3ReceiptPath -InputObject $v3Receipt

$forbiddenExtensions = @('.etl','.evtx','.xml','.jsonl','.exe','.obj','.pdb')
foreach ($file in @(Get-ChildItem -LiteralPath $reviewRoot -File -Recurse)) {
    if ($forbiddenExtensions -contains $file.Extension.ToLowerInvariant()) { throw ('Forbidden adaptive V3 review artifact: {0}' -f $file.FullName) }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in @('PCI\VEN_','USB\VID_','PNPDeviceID','DeviceID','X-NXB-Panel-Token')) {
        if ($text -match [regex]::Escape($pattern)) { throw ('Forbidden adaptive V3 review content in {0}: {1}' -f $file.Name,$pattern) }
    }
}

$reviewZip = [IO.Path]::GetFullPath([string]$v2Result.review_zip_path)
if (Test-Path -LiteralPath $reviewZip) { Remove-Item -LiteralPath $reviewZip -Force }
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
$reviewZipSha = (Get-FileHash -LiteralPath $reviewZip -Algorithm SHA256).Hash.ToLowerInvariant()
$v3ReceiptSha = (Get-FileHash -LiteralPath $v3ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
$hysteresisSha = (Get-FileHash -LiteralPath $hysteresisPath -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Information -InformationAction Continue -MessageData ('NXB adaptive V3 certification passed: PS7={0} PS5.1={1} hysteresis=true targets=8/validated=0' -f $ps7Contract,$ps51Contract)

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    ps7_tests = $ps7Contract
    ps51_tests = $ps51Contract
    psscriptanalyzer_findings = 0
    policy_fingerprint_sha256 = [string]$v2Result.policy_fingerprint_sha256
    scenario_count = [int]$v2Result.scenario_count
    deterministic_empty_replay = [bool]$v2Result.deterministic_empty_replay
    semantic_targets_requested = 8
    semantic_targets_validated = 0
    panel_local_only = [bool]$v2Result.panel_local_only
    panel_mutation_token = [bool]$v2Result.panel_mutation_token
    hysteresis_validated = $true
    hysteresis_validation_sha256 = $hysteresisSha
    receipt_sha256 = $v3ReceiptSha
    review_zip_sha256 = $reviewZipSha
    review_zip_path = $reviewZip
}
if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 20
