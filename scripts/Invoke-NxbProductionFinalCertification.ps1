[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Invoke-NxbFinalCertificationNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )
    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativePreferenceAvailable = ($null -ne $nativePreferenceVariable)
    $previousNativePreference = if ($nativePreferenceAvailable) { [bool]$nativePreferenceVariable.Value } else { $null }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceAvailable) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local
        }
        $nativeOutput = @(& $Executable @ArgumentList 2>&1)
        $nativeExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceAvailable) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local
        }
    }
    return [pscustomobject][ordered]@{
        exit_code = $nativeExitCode
        output = (@($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }
}

function Invoke-NxbFinalCertificationPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-final-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $runnerPath = Join-Path $tempRoot 'run.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
$ErrorActionPreference = 'Stop'
Import-Module Pester -ErrorAction Stop
$result = Invoke-Pester -Path $TestPath -PassThru
$summary = [pscustomobject]@{ passed=[int]$result.PassedCount; failed=[int]$result.FailedCount; skipped=[int]$result.SkippedCount; total=[int]$result.TotalCount }
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($summary.passed -ne $ExpectedCount -or $summary.total -ne $ExpectedCount -or $summary.failed -ne 0 -or $summary.skipped -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $runnerPath -Encoding UTF8
    try {
        $native = Invoke-NxbFinalCertificationNative -Executable $Executable -ArgumentList @(
            '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,
            '-TestPath',$TestPath,'-ResultPath',$resultPath,'-ExpectedCount',[string]$ExpectedCount
        )
        if ($native.exit_code -ne 0) {
            throw ('{0} Pester failed: exit={1}{2}{3}' -f $Label,$native.exit_code,[Environment]::NewLine,$native.output)
        }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Get-NxbFinalPassedResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Pipeline)
    $result = $null
    foreach ($item in @($Pipeline)) {
        if ($null -eq $item) { continue }
        $property = $item.PSObject.Properties['status']
        if ($null -ne $property -and [string]$property.Value -ceq 'passed') { $result = $item }
    }
    return $result
}

if ($env:OS -cne 'Windows_NT') { throw 'Production final certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Production final certification requires PowerShell 7.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Production final certification requires elevated PowerShell 7 because inherited Part 2 native authority is mandatory.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'NxbProductionFinalization.Common.ps1')
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw ('Production final exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead)
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Production final certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$workRoot = $outputFull + '-work'
$part5Output = $outputFull + '-part5'
$reviewRoot = $outputFull + '-review'
$reviewZip = $outputFull + '-review.zip'
foreach ($reserved in @($outputFull,$workRoot,$part5Output,$reviewRoot,$reviewZip)) {
    if (Test-Path -LiteralPath $reserved) { throw ('Production final reserved output already exists: {0}' -f $reserved) }
}
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$policyPath = Join-Path $repositoryRoot 'config\nxb-production-finalization-policy.json'
$commonPath = Join-Path $PSScriptRoot 'NxbProductionFinalization.Common.ps1'
$part6Path = Join-Path $PSScriptRoot 'Invoke-NxbPart6FindingEngineCertification.ps1'
$part7Path = Join-Path $PSScriptRoot 'Invoke-NxbPart7BoundedActiveValidationCertification.ps1'
$part8Path = Join-Path $PSScriptRoot 'Invoke-NxbPart8EvidenceHardeningCertification.ps1'
$part9Path = Join-Path $PSScriptRoot 'Invoke-NxbPart9SupplyChainCertification.ps1'
$part10Path = Join-Path $PSScriptRoot 'Invoke-NxbPart10ProductionFreezeCertification.ps1'
$cliPath = Join-Path $PSScriptRoot 'nxb.ps1'
$testPath = Join-Path $repositoryRoot 'tests\ProductionFinalization.Tests.ps1'
$prefreezeValidatorPath = Join-Path $repositoryRoot 'tools\validate_production_prefreeze.py'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_production_finalization.py'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$signaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$part5Runner = Join-Path $PSScriptRoot 'Invoke-NxbPart5SignedClosureCertificationV2.ps1'
$authorityPaths = @($PSCommandPath,$commonPath,$part6Path,$part7Path,$part8Path,$part9Path,$part10Path,$cliPath,$testPath)
foreach ($requiredPath in @($policyPath,$prefreezeValidatorPath,$validatorPath,$scannerPath,$signaturePath,$part5Runner) + $authorityPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Production final component missing: {0}' -f $requiredPath) }
}

Write-Information '=== NXB IRL-006 PART 6 + PART 7 + PART 8 + PART 9 + PART 10 PRODUCTION FINAL CERTIFICATION ==='
Write-Information '[1/10] Exact-tree parser, analyzer, Python syntax and permanent known-error gate'
foreach ($scriptPath in $authorityPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw ('Production final parser failed: {0}{1}{2}' -f $scriptPath,[Environment]::NewLine,(@($parseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine))
    }
}
if (-not (Get-Module -Name PSScriptAnalyzer)) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
}
$analyzerFinding = @(foreach ($scriptPath in $authorityPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFinding.Count -gt 0) {
    throw ('Production final PSScriptAnalyzer findings: {0}{1}{2}' -f $analyzerFinding.Count,[Environment]::NewLine,(@($analyzerFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join [Environment]::NewLine))
}
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
if ([string]$policy.certified_predecessor_head -cne '7dad7f15eccf074078573f8bbe2d89877218672d') { throw 'Production final predecessor authority drift.' }
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = [string]$pythonCommand.Source
foreach ($pythonFile in @($prefreezeValidatorPath,$validatorPath)) {
    $compile = Invoke-NxbFinalCertificationNative -Executable $pythonPath -ArgumentList @('-m','py_compile',$pythonFile)
    if ($compile.exit_code -ne 0) { throw ('Production final Python syntax failed: {0}{1}{2}' -f $pythonFile,[Environment]::NewLine,$compile.output) }
}
$scanPath = Join-Path $workRoot 'known-error-scan.json'
$scan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -OutputPath $scanPath -NoThrow -PassThru
if ([string]$scan.status -cne 'passed' -or [int]$scan.finding_count -ne 0 -or [int]$scan.rule_count -lt [int]$policy.known_error_minimum_rules) {
    $detail = @($scan.findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
    throw ('Production final known-error gate failed: rules={0} findings={1}{2}{3}' -f [int]$scan.rule_count,[int]$scan.finding_count,[Environment]::NewLine,$detail)
}

Write-Information '[2/10] Dual-runtime 20-test Part 6-10 contract'
$previousRoot = [Environment]::GetEnvironmentVariable('NXB_FINAL_REPOSITORY_ROOT','Process')
$env:NXB_FINAL_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Contract = Invoke-NxbFinalCertificationPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 20 -Label 'Part 6-10 PS7'
    $ps51Contract = Invoke-NxbFinalCertificationPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 20 -Label 'Part 6-10 PS5.1'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_FINAL_REPOSITORY_ROOT -ErrorAction SilentlyContinue } else { $env:NXB_FINAL_REPOSITORY_ROOT = $previousRoot }
}

Write-Information '[3/10] Re-certify native-certified Part 2+3+4+5 predecessor on the new exact head'
$part5Pipeline = @(& $part5Runner -ExpectedHead $ExpectedHead -OutputDirectory $part5Output -PassThru)
$part5Result = Get-NxbFinalPassedResult -Pipeline $part5Pipeline
if ($null -eq $part5Result) { throw 'Production final inherited Part 5 authority returned no passed result.' }
if ([string]$part5Result.head_sha -cne $currentHead) { throw 'Production final inherited Part 5 exact-head binding mismatch.' }
if ([int]$part5Result.known_error_finding_count -ne 0 -or [int]$part5Result.psscriptanalyzer_findings -ne 0) {
    throw 'Production final inherited Part 5 zero-error gate failed.'
}

Write-Information '[4/10] Part 6 finding engine, root-cause correlation and target/session orchestration'
$part6Pipeline = @(& $part6Path -RepositoryRoot $repositoryRoot -ExpectedHead $currentHead -OutputDirectory $outputFull -PassThru)
$part6Result = Get-NxbFinalPassedResult -Pipeline $part6Pipeline
if ($null -eq $part6Result -or [int]$part6Result.requirements_validated -ne 8) { throw 'Part 6 certification failed.' }

Write-Information '[5/10] Part 7 bounded active validation, scope permits, secrets and loopback native probe'
$part7Pipeline = @(& $part7Path -RepositoryRoot $repositoryRoot -ExpectedHead $currentHead -OutputDirectory $outputFull -PassThru)
$part7Result = Get-NxbFinalPassedResult -Pipeline $part7Pipeline
if ($null -eq $part7Result -or [int]$part7Result.requirements_validated -ne 10 -or -not [bool]$part7Result.loopback_native_probe) { throw 'Part 7 certification failed.' }

Write-Information '[6/10] Part 8 fault injection, performance bounds and dual-runtime compatibility'
$part8Pipeline = @(& $part8Path -RepositoryRoot $repositoryRoot -ExpectedHead $currentHead -OutputDirectory $outputFull -PriorReceiptPath @([string]$part5Result.signed_receipt_path,[string]$part6Result.receipt_path,[string]$part7Result.receipt_path) -Ps7ContractPassed $true -Ps51ContractPassed $true -PassThru)
$part8Result = Get-NxbFinalPassedResult -Pipeline $part8Pipeline
if ($null -eq $part8Result -or [int]$part8Result.requirements_validated -ne 10 -or [int]$part8Result.fault_count -lt 5) { throw 'Part 8 certification failed.' }

Write-Information '[7/10] Part 9 supply chain, staged update manifest and unified CLI'
$part9Pipeline = @(& $part9Path -RepositoryRoot $repositoryRoot -ExpectedHead $currentHead -OutputDirectory $outputFull -PassThru)
$part9Result = Get-NxbFinalPassedResult -Pipeline $part9Pipeline
if ($null -eq $part9Result -or [int]$part9Result.requirements_validated -ne 10) { throw 'Part 9 certification failed.' }

Write-Information '[8/10] Independent Python pre-freeze replay for Part 6-9'
$prefreezePath = Join-Path $outputFull 'part6-9-independent-prefreeze-validation.json'
$prefreezeRun = Invoke-NxbFinalCertificationNative -Executable $pythonPath -ArgumentList @(
    $prefreezeValidatorPath,
    '--expected-head',$currentHead,
    '--part6',[string]$part6Result.receipt_path,
    '--part7',[string]$part7Result.receipt_path,
    '--part8',[string]$part8Result.receipt_path,
    '--part9',[string]$part9Result.receipt_path,
    '--output',$prefreezePath
)
if ($prefreezeRun.exit_code -ne 0) { throw ('Part 6-9 independent pre-freeze replay failed: {0}' -f $prefreezeRun.output) }
$prefreeze = Get-Content -LiteralPath $prefreezePath -Raw | ConvertFrom-Json
if ([string]$prefreeze.status -cne 'passed' -or [int]$prefreeze.parts_validated -ne 4 -or [int]$prefreeze.requirements_validated -ne 38) {
    throw 'Part 6-9 independent pre-freeze receipt failed.'
}

Write-Information '[9/10] Part 10 report engine, production safety gate and v1 freeze candidate'
$part10Pipeline = @(& $part10Path -RepositoryRoot $repositoryRoot -ExpectedHead $currentHead -OutputDirectory $outputFull -Part5SignedReceiptPath ([string]$part5Result.signed_receipt_path) -Part5ReviewZipPath ([string]$part5Result.review_zip_path) -Part6To9ReceiptPath @([string]$part6Result.receipt_path,[string]$part7Result.receipt_path,[string]$part8Result.receipt_path,[string]$part9Result.receipt_path) -KnownErrorRuleCount ([int]$scan.rule_count) -KnownErrorFindingCount ([int]$scan.finding_count) -AnalyzerFindingCount $analyzerFinding.Count -IndependentValidationPassed $true -PassThru)
$part10Result = Get-NxbFinalPassedResult -Pipeline $part10Pipeline
if ($null -eq $part10Result -or [int]$part10Result.requirements_validated -ne 10) { throw 'Part 10 certification failed.' }

Write-Information '[10/10] Full independent Part 6-10 replay, final zero-error scan and bounded review ZIP'
$finalValidationPath = Join-Path $outputFull 'part6-10-independent-final-validation.json'
$finalValidationRun = Invoke-NxbFinalCertificationNative -Executable $pythonPath -ArgumentList @(
    $validatorPath,
    '--expected-head',$currentHead,
    '--part6',[string]$part6Result.receipt_path,
    '--part7',[string]$part7Result.receipt_path,
    '--part8',[string]$part8Result.receipt_path,
    '--part9',[string]$part9Result.receipt_path,
    '--part10',[string]$part10Result.receipt_path,
    '--package',[string]$part9Result.manifest_path,
    '--evidence-index',[string]$part10Result.evidence_index_path,
    '--report',[string]$part10Result.report_path,
    '--output',$finalValidationPath
)
if ($finalValidationRun.exit_code -ne 0) { throw ('Part 6-10 independent final replay failed: {0}' -f $finalValidationRun.output) }
$finalValidation = Get-Content -LiteralPath $finalValidationPath -Raw | ConvertFrom-Json
if ([string]$finalValidation.status -cne 'passed' -or [int]$finalValidation.requirements_validated -ne 48 -or [int]$finalValidation.negative_controls_validated -ne 12) {
    throw 'Part 6-10 independent final validation receipt failed.'
}

$finalScanPath = Join-Path $outputFull 'known-error-final-scan.json'
$finalScan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -OutputPath $finalScanPath -NoThrow -PassThru
if ([string]$finalScan.status -cne 'passed' -or [int]$finalScan.finding_count -ne 0 -or [int]$finalScan.rule_count -lt [int]$policy.known_error_minimum_rules) {
    throw 'Production final exact-tree known-error re-scan failed.'
}

$finalReceipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    authority = 'nxb-irl006-part6-10-production-final-v1'
    head_sha = $currentHead
    release_version = [string]$policy.part10.release_version
    predecessor_part5_signed_receipt_sha256 = Get-NxbFinalFileSha256 -Path ([string]$part5Result.signed_receipt_path)
    predecessor_part5_review_zip_sha256 = Get-NxbFinalFileSha256 -Path ([string]$part5Result.review_zip_path)
    ps7_contract = ('{0}/{1}' -f [int]$ps7Contract.passed,[int]$ps7Contract.total)
    ps51_contract = ('{0}/{1}' -f [int]$ps51Contract.passed,[int]$ps51Contract.total)
    part6_requirements = [int]$part6Result.requirements_validated
    part7_requirements = [int]$part7Result.requirements_validated
    part8_requirements = [int]$part8Result.requirements_validated
    part9_requirements = [int]$part9Result.requirements_validated
    part10_requirements = [int]$part10Result.requirements_validated
    independent_requirements = [int]$finalValidation.requirements_validated
    independent_negative_controls = [int]$finalValidation.negative_controls_validated
    known_error_rules = [int]$finalScan.rule_count
    known_error_findings = [int]$finalScan.finding_count
    analyzer_findings = $analyzerFinding.Count
    production_merge_performed = $false
    v1_freeze_candidate = $true
    part6_receipt_sha256 = Get-NxbFinalFileSha256 -Path ([string]$part6Result.receipt_path)
    part7_receipt_sha256 = Get-NxbFinalFileSha256 -Path ([string]$part7Result.receipt_path)
    part8_receipt_sha256 = Get-NxbFinalFileSha256 -Path ([string]$part8Result.receipt_path)
    part9_receipt_sha256 = Get-NxbFinalFileSha256 -Path ([string]$part9Result.receipt_path)
    part10_receipt_sha256 = Get-NxbFinalFileSha256 -Path ([string]$part10Result.receipt_path)
    evidence_index_sha256 = Get-NxbFinalFileSha256 -Path ([string]$part10Result.evidence_index_path)
    report_sha256 = Get-NxbFinalFileSha256 -Path ([string]$part10Result.report_path)
    final_validation_sha256 = Get-NxbFinalFileSha256 -Path $finalValidationPath
}
$finalReceiptPath = Join-Path $outputFull 'production-final-certification-receipt.json'
Write-NxbFinalAtomicJson -Path $finalReceiptPath -InputObject $finalReceipt

[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
$reviewSources = @(
    $scanPath,
    $finalScanPath,
    [string]$part6Result.receipt_path,
    [string]$part7Result.receipt_path,
    [string]$part8Result.receipt_path,
    [string]$part9Result.receipt_path,
    [string]$part9Result.manifest_path,
    $prefreezePath,
    [string]$part10Result.receipt_path,
    [string]$part10Result.evidence_index_path,
    [string]$part10Result.report_path,
    $finalValidationPath,
    $finalReceiptPath
)
foreach ($sourcePath in $reviewSources) {
    $destinationPath = Join-Path $reviewRoot ([IO.Path]::GetFileName($sourcePath))
    if (Test-Path -LiteralPath $destinationPath) { throw ('Duplicate production review evidence name: {0}' -f $destinationPath) }
    [IO.File]::Copy([IO.Path]::GetFullPath($sourcePath),$destinationPath,$false)
}
$reviewFiles = @(Get-ChildItem -LiteralPath $reviewRoot -File | Sort-Object Name)
if ($reviewFiles.Count -ne 13) { throw ('Production final review evidence count mismatch: {0}' -f $reviewFiles.Count) }
foreach ($reviewFile in $reviewFiles) {
    if ($reviewFile.Extension -cne '.json') { throw ('Production final review evidence must be JSON-only: {0}' -f $reviewFile.Name) }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($reviewRoot,$reviewZip,[IO.Compression.CompressionLevel]::Optimal,$false)

Write-Information ('NXB production final candidate passed: head={0} Part6=8/8 Part7=10/10 Part8=10/10 Part9=10/10 Part10=10/10 independent=48/48 negatives=12/12 known_errors=0.' -f $currentHead)
if ($PassThru) {
    return [pscustomobject][ordered]@{
        status = 'passed'
        head_sha = $currentHead
        release_version = [string]$policy.part10.release_version
        ps7 = [string]$finalReceipt.ps7_contract
        ps51 = [string]$finalReceipt.ps51_contract
        part6_requirements = 8
        part7_requirements = 10
        part8_requirements = 10
        part9_requirements = 10
        part10_requirements = 10
        independent_requirements = 48
        independent_negative_controls = 12
        known_error_rules = [int]$finalScan.rule_count
        known_error_findings = 0
        analyzer_findings = 0
        production_merge_performed = $false
        v1_freeze_candidate = $true
        receipt_path = $finalReceiptPath
        receipt_sha256 = Get-NxbFinalFileSha256 -Path $finalReceiptPath
        review_zip_path = $reviewZip
        review_zip_sha256 = Get-NxbFinalFileSha256 -Path $reviewZip
    }
}
Write-Output $reviewZip
