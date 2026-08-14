[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbAdaptiveV5Json {
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

function Invoke-NxbAdaptiveV5Pester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-adaptive-v5-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
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

if ($env:OS -cne 'Windows_NT') { throw 'Adaptive observability V5 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Adaptive observability V5 certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw ('Adaptive V5 exact-head mismatch. Expected={0} actual={1}' -f $ExpectedHead,$currentHead)
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Adaptive V5 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) { throw ('OutputDirectory already exists: {0}' -f $outputFull) }

$ledger = Join-Path $repositoryRoot 'docs\NXB-KNOWN-ERROR-LEDGER.md'
$signature = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$scanner = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$ledgerTest = Join-Path $repositoryRoot 'tests\KnownErrorLedger.Tests.ps1'
$v4Runner = Join-Path $PSScriptRoot 'Invoke-NxbAdaptiveObservabilityCertificationV4.ps1'
foreach ($requiredPath in @($ledger,$signature,$scanner,$ledgerTest,$v4Runner,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Adaptive V5 component missing: {0}' -f $requiredPath) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-005 ADAPTIVE OBSERVABILITY CONTROL-PLANE CERTIFICATION V5 ==='
Write-Information -InformationAction Continue -MessageData '[1/4] Known-error ledger parser/analyzer + dual-runtime 12-test contract'
$analyzerPath = @($scanner,$ledgerTest,$PSCommandPath)
foreach ($scriptPath in $analyzerPath) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw ('Adaptive V5 parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join "`n"))
    }
}
if (-not (Get-Module -Name PSScriptAnalyzer)) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
}
$analyzerFinding = @(foreach ($scriptPath in $analyzerPath) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFinding.Count -gt 0) {
    throw ('Adaptive V5 PSScriptAnalyzer findings: {0}`n{1}' -f $analyzerFinding.Count,(@($analyzerFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n"))
}
[void](Get-Content -LiteralPath $signature -Raw | ConvertFrom-Json)

$previousRoot = [Environment]::GetEnvironmentVariable('NXB_ADAPTIVE_REPOSITORY_ROOT','Process')
$env:NXB_ADAPTIVE_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Ledger = Invoke-NxbAdaptiveV5Pester -Executable $pwshPath -TestPath $ledgerTest -ExpectedCount 12 -Label 'PowerShell 7 known-error ledger'
    $ps51Ledger = Invoke-NxbAdaptiveV5Pester -Executable $ps51Path -TestPath $ledgerTest -ExpectedCount 12 -Label 'Windows PowerShell 5.1 known-error ledger'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_ADAPTIVE_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_ADAPTIVE_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -InformationAction Continue -MessageData '[2/4] Mandatory exact-tree known-error pre-final scan'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-known-error-v5-{0}' -f [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$tempScanPath = Join-Path $tempRoot 'known-error-scan.json'
try {
    $scanResult = & $scanner -RepositoryRoot $repositoryRoot -SignaturePath $signature -OutputPath $tempScanPath -PassThru
    if ([string]$scanResult.status -cne 'passed' -or [int]$scanResult.finding_count -ne 0) {
        throw 'Adaptive V5 known-error scan did not pass with zero findings.'
    }

    Write-Information -InformationAction Continue -MessageData '[3/4] Run V4 adaptive manifest + hysteresis + core/security certification'
    $v4Pipeline = @(& $v4Runner -ExpectedHead $ExpectedHead -OutputDirectory $outputFull -PassThru)
    $v4Result = $null
    foreach ($item in $v4Pipeline) {
        if ($null -eq $item) { continue }
        $statusProperty = $item.PSObject.Properties['status']
        if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $v4Result = $item }
    }
    if ($null -eq $v4Result) { throw 'Adaptive V4 child certification returned no passed result.' }
    if ([string]$v4Result.head_sha -cne $currentHead) { throw 'Adaptive V4 child head mismatch.' }
    if ([string]$v4Result.ps7_tests -cne '48/48' -or [string]$v4Result.ps51_tests -cne '48/48') { throw 'Adaptive V4 child test contract mismatch.' }
    if ([int]$v4Result.psscriptanalyzer_findings -ne 0) { throw 'Adaptive V4 child analyzer findings were nonzero.' }

    Write-Information -InformationAction Continue -MessageData '[4/4] Bind known-error scan into final V5 review evidence'
    $reviewRoot = Join-Path $outputFull 'review'
    if (-not (Test-Path -LiteralPath $reviewRoot -PathType Container)) { throw 'Adaptive V5 review root missing after V4 child.' }
    $scanReviewPath = Join-Path $reviewRoot 'known-error-scan.json'
    Copy-Item -LiteralPath $tempScanPath -Destination $scanReviewPath -Force

    $ledgerSha = (Get-FileHash -LiteralPath $ledger -Algorithm SHA256).Hash.ToLowerInvariant()
    $signatureSha = (Get-FileHash -LiteralPath $signature -Algorithm SHA256).Hash.ToLowerInvariant()
    $scanSha = (Get-FileHash -LiteralPath $scanReviewPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $v5ReceiptPath = Join-Path $reviewRoot 'adaptive-control-plane-certification-v5-receipt.json'
    $v5Receipt = [pscustomobject][ordered]@{
        schema_version = 5
        status = 'passed'
        head_sha = $currentHead
        known_error_gate = [pscustomobject][ordered]@{
            ledger_contract_ps7 = ('{0}/{1}' -f [int]$ps7Ledger.passed,[int]$ps7Ledger.total)
            ledger_contract_ps51 = ('{0}/{1}' -f [int]$ps51Ledger.passed,[int]$ps51Ledger.total)
            psscriptanalyzer_findings = 0
            rule_count = [int]$scanResult.rule_count
            finding_count = [int]$scanResult.finding_count
            scan_status = [string]$scanResult.status
            ledger_sha256 = $ledgerSha
            signature_sha256 = $signatureSha
            scan_sha256 = $scanSha
        }
        child_v4 = [pscustomobject][ordered]@{
            ps7_tests = [string]$v4Result.ps7_tests
            ps51_tests = [string]$v4Result.ps51_tests
            psscriptanalyzer_findings = [int]$v4Result.psscriptanalyzer_findings
            deterministic_empty_replay = [bool]$v4Result.deterministic_empty_replay
            panel_local_only = [bool]$v4Result.panel_local_only
            panel_mutation_token = [bool]$v4Result.panel_mutation_token
            hysteresis_validated = [bool]$v4Result.hysteresis_validated
            capture_manifest_validated = [bool]$v4Result.capture_manifest_validated
            semantic_targets_requested = [int]$v4Result.semantic_targets_requested
            semantic_targets_validated = [int]$v4Result.semantic_targets_validated
        }
    }
    Write-NxbAdaptiveV5Json -Path $v5ReceiptPath -InputObject $v5Receipt

    $forbiddenExtension = @('.etl','.evtx','.xml','.jsonl','.exe','.obj','.pdb')
    foreach ($file in @(Get-ChildItem -LiteralPath $reviewRoot -File -Recurse)) {
        if ($forbiddenExtension -contains $file.Extension.ToLowerInvariant()) { throw ('Forbidden adaptive V5 review artifact: {0}' -f $file.FullName) }
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($pattern in @('PCI\VEN_','USB\VID_','PNPDeviceID','DeviceID','X-NXB-Panel-Token','__NXB_PANEL_TOKEN__')) {
            if ($text -match [regex]::Escape($pattern)) { throw ('Forbidden adaptive V5 review content in {0}: {1}' -f $file.Name,$pattern) }
        }
    }

    $reviewZip = [IO.Path]::GetFullPath([string]$v4Result.review_zip_path)
    if (Test-Path -LiteralPath $reviewZip) { Remove-Item -LiteralPath $reviewZip -Force }
    Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
    $reviewZipSha = (Get-FileHash -LiteralPath $reviewZip -Algorithm SHA256).Hash.ToLowerInvariant()
    $v5ReceiptSha = (Get-FileHash -LiteralPath $v5ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $ledgerPs7Contract = '{0}/{1}' -f [int]$ps7Ledger.passed,[int]$ps7Ledger.total
    $ledgerPs51Contract = '{0}/{1}' -f [int]$ps51Ledger.passed,[int]$ps51Ledger.total
    if ($ledgerPs7Contract -cne '12/12' -or $ledgerPs51Contract -cne '12/12') { throw 'Adaptive V5 ledger contract mismatch.' }

    Write-Information -InformationAction Continue -MessageData ('NXB adaptive V5 certification passed: ledger={0}+{1} known_errors=0 V4={2}+{3}' -f $ledgerPs7Contract,$ledgerPs51Contract,$v4Result.ps7_tests,$v4Result.ps51_tests)

    $result = [pscustomobject][ordered]@{
        status = 'passed'
        head_sha = $currentHead
        known_error_ps7_tests = $ledgerPs7Contract
        known_error_ps51_tests = $ledgerPs51Contract
        known_error_rule_count = [int]$scanResult.rule_count
        known_error_finding_count = [int]$scanResult.finding_count
        known_error_scan = $true
        ps7_tests = [string]$v4Result.ps7_tests
        ps51_tests = [string]$v4Result.ps51_tests
        psscriptanalyzer_findings = 0
        deterministic_empty_replay = [bool]$v4Result.deterministic_empty_replay
        semantic_targets_requested = [int]$v4Result.semantic_targets_requested
        semantic_targets_validated = [int]$v4Result.semantic_targets_validated
        panel_local_only = [bool]$v4Result.panel_local_only
        panel_mutation_token = [bool]$v4Result.panel_mutation_token
        hysteresis_validated = [bool]$v4Result.hysteresis_validated
        capture_manifest_validated = [bool]$v4Result.capture_manifest_validated
        capture_manifest_ready_count = [int]$v4Result.capture_manifest_ready_count
        capture_manifest_pending_count = [int]$v4Result.capture_manifest_pending_count
        capture_manifest_unavailable_count = [int]$v4Result.capture_manifest_unavailable_count
        policy_fingerprint_sha256 = [string]$v4Result.policy_fingerprint_sha256
        domain_map_sha256 = [string]$v4Result.domain_map_sha256
        capture_manifest_sha256 = [string]$v4Result.capture_manifest_sha256
        capture_manifest_validation_sha256 = [string]$v4Result.capture_manifest_validation_sha256
        ledger_sha256 = $ledgerSha
        signature_sha256 = $signatureSha
        known_error_scan_sha256 = $scanSha
        receipt_sha256 = $v5ReceiptSha
        review_zip_path = $reviewZip
        review_zip_sha256 = $reviewZipSha
    }
    if ($PassThru) { return $result }
    $result | ConvertTo-Json -Depth 20
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
