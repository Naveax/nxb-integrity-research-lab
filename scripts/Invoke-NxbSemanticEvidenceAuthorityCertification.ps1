[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbSemanticAuthorityJson {
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

function Invoke-NxbSemanticAuthorityPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-semantic-authority-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
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
        $childOutput = @(& $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath -ExpectedCount $ExpectedCount 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($lineItem in $childOutput) {
            Write-Information -InformationAction Continue -MessageData ([string]$lineItem)
        }
        if ($exitCode -ne 0) { throw ('{0} Pester failed: exit={1}' -f $Label,$exitCode) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Semantic evidence authority certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Semantic evidence authority certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitPath = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $gitPath -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw ('Semantic authority exact-head mismatch. Expected={0} actual={1}' -f $ExpectedHead,$currentHead)
}
$dirtyItem = @(& $gitPath -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirtyItem.Count -gt 0) { throw 'Semantic authority certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$foundationOutput = '{0}-foundation-v5' -f $outputFull
$reviewZip = '{0}-review.zip' -f $outputFull
foreach ($reservedPath in @($outputFull,$foundationOutput,$reviewZip)) {
    if (Test-Path -LiteralPath $reservedPath) { throw ('Semantic authority output path already exists: {0}' -f $reservedPath) }
}

$ledgerPath = Join-Path $repositoryRoot 'docs\NXB-KNOWN-ERROR-LEDGER.md'
$signaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$schemaPath = Join-Path $repositoryRoot 'schemas\nxb-semantic-evidence-receipt.schema.json'
$validatorPath = Join-Path $PSScriptRoot 'Test-NxbSemanticEvidenceReceipt.ps1'
$pythonValidatorPath = Join-Path $repositoryRoot 'tools\validate_semantic_evidence_receipt.py'
$fixturePath = Join-Path $repositoryRoot 'tests\fixtures\semantic-evidence\valid-semantic-receipt.json'
$testPath = Join-Path $repositoryRoot 'tests\SemanticEvidenceAuthority.Tests.ps1'
$foundationRunner = Join-Path $PSScriptRoot 'Invoke-NxbAdaptiveObservabilityCertificationV5.ps1'
$authorityDoc = Join-Path $repositoryRoot 'docs\NXB-IRL-006-SEMANTIC-EVIDENCE-AUTHORITY.md'
foreach ($requiredPath in @(
    $ledgerPath,$signaturePath,$scannerPath,$schemaPath,$validatorPath,$pythonValidatorPath,
    $fixturePath,$testPath,$foundationRunner,$authorityDoc,$PSCommandPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Semantic authority component missing: {0}' -f $requiredPath) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-006 PART 1 SEMANTIC EVIDENCE AUTHORITY CERTIFICATION ==='
Write-Information -InformationAction Continue -MessageData '[1/6] Parser + PSScriptAnalyzer + schema/Python syntax preflight'
$analyzerPath = @($validatorPath,$testPath,$PSCommandPath)
foreach ($scriptPath in $analyzerPath) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw ('Semantic authority parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join "`n"))
    }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$analyzerFinding = @(foreach ($scriptPath in $analyzerPath) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFinding.Count -gt 0) {
    throw ('Semantic authority PSScriptAnalyzer findings: {0}`n{1}' -f $analyzerFinding.Count,(@($analyzerFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n"))
}
[void](Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json)
[void](Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json)
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = $pythonCommand.Source
& $pythonPath -m py_compile $pythonValidatorPath
if ($LASTEXITCODE -ne 0) { throw 'Semantic authority Python syntax check failed.' }

Write-Information -InformationAction Continue -MessageData '[2/6] Mandatory inherited known-error exact-tree scan'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-semantic-authority-{0}' -f [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$tempScanPath = Join-Path $tempRoot 'known-error-scan.json'
try {
    $scanResult = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -OutputPath $tempScanPath -PassThru
    if ([string]$scanResult.status -cne 'passed' -or [int]$scanResult.finding_count -ne 0) {
        $detail = @($scanResult.findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
        throw ('Semantic authority known-error scan failed: findings={0}{1}{2}' -f [int]$scanResult.finding_count,[Environment]::NewLine,$detail)
    }

    Write-Information -InformationAction Continue -MessageData '[3/6] Dual-runtime 18-test semantic contract'
    $previousRoot = [Environment]::GetEnvironmentVariable('NXB_SEMANTIC_REPOSITORY_ROOT','Process')
    $env:NXB_SEMANTIC_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
    try {
        $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
        $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
        $ps7Contract = Invoke-NxbSemanticAuthorityPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 18 -Label 'PowerShell 7 semantic authority'
        $ps51Contract = Invoke-NxbSemanticAuthorityPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 18 -Label 'Windows PowerShell 5.1 semantic authority'
    }
    finally {
        if ($null -eq $previousRoot) { Remove-Item Env:NXB_SEMANTIC_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
        else { $env:NXB_SEMANTIC_REPOSITORY_ROOT = $previousRoot }
    }

    Write-Information -InformationAction Continue -MessageData '[4/6] Independent Python reference validation parity'
    $fixtureHead = '1111111111111111111111111111111111111111'
    $fixturePolicy = '2222222222222222222222222222222222222222222222222222222222222222'
    $fixtureMachine = '3333333333333333333333333333333333333333333333333333333333333333'
    $pythonOutput = @(& $pythonPath $pythonValidatorPath $fixturePath --expected-head $fixtureHead --expected-policy-sha256 $fixturePolicy --expected-machine-id-sha256 $fixtureMachine 2>&1)
    $pythonExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($pythonExitCode -ne 0) { throw ('Independent semantic Python validation failed: exit={0}`n{1}' -f $pythonExitCode,($pythonOutput -join "`n")) }
    $pythonResult = ($pythonOutput -join "`n") | ConvertFrom-Json
    if ([string]$pythonResult.status -cne 'passed' -or -not [bool]$pythonResult.promotable) {
        throw 'Independent semantic Python validator did not return passed/promotable for the canonical fixture.'
    }

    Write-Information -InformationAction Continue -MessageData '[5/6] Re-run inherited IRL-005 V5 foundation on the exact Part 1 head'
    $foundationPipeline = @(& $foundationRunner -ExpectedHead $ExpectedHead -OutputDirectory $foundationOutput -PassThru)
    $foundationResult = $null
    foreach ($pipelineItem in $foundationPipeline) {
        if ($null -eq $pipelineItem) { continue }
        $statusProperty = $pipelineItem.PSObject.Properties['status']
        if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $foundationResult = $pipelineItem }
    }
    if ($null -eq $foundationResult) { throw 'Inherited IRL-005 V5 foundation returned no passed result.' }
    if ([string]$foundationResult.head_sha -cne $currentHead) { throw 'Inherited IRL-005 V5 foundation head mismatch.' }
    if ([string]$foundationResult.ps7_tests -cne '48/48' -or [string]$foundationResult.ps51_tests -cne '48/48') {
        throw 'Inherited IRL-005 V5 foundation test contract mismatch.'
    }
    if ([int]$foundationResult.psscriptanalyzer_findings -ne 0) { throw 'Inherited IRL-005 V5 foundation analyzer findings were nonzero.' }
    if ([int]$foundationResult.known_error_finding_count -ne 0) { throw 'Inherited IRL-005 V5 foundation known-error findings were nonzero.' }

    Write-Information -InformationAction Continue -MessageData '[6/6] Build bounded Part 1 review evidence'
    [IO.Directory]::CreateDirectory($outputFull) | Out-Null
    $reviewRoot = Join-Path $outputFull 'review'
    [IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
    $scanReviewPath = Join-Path $reviewRoot 'known-error-scan.json'
    Copy-Item -LiteralPath $tempScanPath -Destination $scanReviewPath

    $schemaSha = (Get-FileHash -LiteralPath $schemaPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $validatorSha = (Get-FileHash -LiteralPath $validatorPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $pythonValidatorSha = (Get-FileHash -LiteralPath $pythonValidatorPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $fixtureSha = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $ledgerSha = (Get-FileHash -LiteralPath $ledgerPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $signatureSha = (Get-FileHash -LiteralPath $signaturePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $scanSha = (Get-FileHash -LiteralPath $scanReviewPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $ps7ContractText = '{0}/{1}' -f [int]$ps7Contract.passed,[int]$ps7Contract.total
    $ps51ContractText = '{0}/{1}' -f [int]$ps51Contract.passed,[int]$ps51Contract.total
    if ($ps7ContractText -cne '18/18' -or $ps51ContractText -cne '18/18') { throw 'Semantic authority test contract mismatch.' }

    $receiptPath = Join-Path $reviewRoot 'semantic-evidence-authority-part1-receipt.json'
    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        status = 'passed'
        head_sha = $currentHead
        semantic_authority = [pscustomobject][ordered]@{
            claim_count = 8
            ps7_tests = $ps7ContractText
            ps51_tests = $ps51ContractText
            psscriptanalyzer_findings = 0
            independent_python_validation = $true
            canonical_fixture_promotable = [bool]$pythonResult.promotable
            canonical_fixture_fingerprint_sha256 = [string]$pythonResult.receipt_fingerprint_sha256
            schema_sha256 = $schemaSha
            powershell_validator_sha256 = $validatorSha
            python_validator_sha256 = $pythonValidatorSha
            fixture_sha256 = $fixtureSha
        }
        known_error_gate = [pscustomobject][ordered]@{
            rule_count = [int]$scanResult.rule_count
            finding_count = [int]$scanResult.finding_count
            scan_status = [string]$scanResult.status
            ledger_sha256 = $ledgerSha
            signature_sha256 = $signatureSha
            scan_sha256 = $scanSha
        }
        inherited_foundation = [pscustomobject][ordered]@{
            status = [string]$foundationResult.status
            head_sha = [string]$foundationResult.head_sha
            ps7_tests = [string]$foundationResult.ps7_tests
            ps51_tests = [string]$foundationResult.ps51_tests
            psscriptanalyzer_findings = [int]$foundationResult.psscriptanalyzer_findings
            known_error_findings = [int]$foundationResult.known_error_finding_count
            hysteresis_validated = [bool]$foundationResult.hysteresis_validated
            capture_manifest_validated = [bool]$foundationResult.capture_manifest_validated
            policy_fingerprint_sha256 = [string]$foundationResult.policy_fingerprint_sha256
            review_zip_sha256 = [string]$foundationResult.review_zip_sha256
        }
        promotion_rule = [pscustomobject][ordered]@{
            exact_head_required = $true
            policy_binding_required = $true
            optional_machine_binding_supported = $true
            positive_evidence_required = $true
            negative_controls_required = $true
            cleanup_verification_required = $true
            independent_validation_required = $true
            canonical_fingerprint_required = $true
            receipt_file_sha256_required_for_claim_binding = $true
        }
    }
    Write-NxbSemanticAuthorityJson -Path $receiptPath -InputObject $receipt

    foreach ($reviewFile in @(Get-ChildItem -LiteralPath $reviewRoot -File -Recurse)) {
        if ($reviewFile.Extension.ToLowerInvariant() -ne '.json') {
            throw ('Semantic authority review contains a non-JSON artifact: {0}' -f $reviewFile.FullName)
        }
    }

    Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
    $receiptSha = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $reviewZipSha = (Get-FileHash -LiteralPath $reviewZip -Algorithm SHA256).Hash.ToLowerInvariant()

    Write-Information -InformationAction Continue -MessageData ('NXB IRL-006 Part 1 semantic evidence authority passed: PS7={0} PS5.1={1} known_errors=0 inherited_v5={2}+{3}' -f $ps7ContractText,$ps51ContractText,$foundationResult.ps7_tests,$foundationResult.ps51_tests)

    $result = [pscustomobject][ordered]@{
        status = 'passed'
        head_sha = $currentHead
        semantic_claim_count = 8
        semantic_ps7_tests = $ps7ContractText
        semantic_ps51_tests = $ps51ContractText
        psscriptanalyzer_findings = 0
        known_error_rule_count = [int]$scanResult.rule_count
        known_error_finding_count = [int]$scanResult.finding_count
        independent_python_validation = $true
        inherited_v5_ps7_tests = [string]$foundationResult.ps7_tests
        inherited_v5_ps51_tests = [string]$foundationResult.ps51_tests
        inherited_v5_known_error_findings = [int]$foundationResult.known_error_finding_count
        policy_fingerprint_sha256 = [string]$foundationResult.policy_fingerprint_sha256
        receipt_sha256 = $receiptSha
        review_zip_path = $reviewZip
        review_zip_sha256 = $reviewZipSha
        foundation_output_path = $foundationOutput
    }
    if ($PassThru) { return $result }
    $result | ConvertTo-Json -Depth 20
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
