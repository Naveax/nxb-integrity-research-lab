[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NxbSemanticHardeningV2Native {
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
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local }
        $nativeOutput = @(& $Executable @ArgumentList 2>&1)
        $nativeExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local }
    }
    return [pscustomobject][ordered]@{
        exit_code = $nativeExitCode
        output = (@($nativeOutput | ForEach-Object { [string]$_ }) -join "`n")
    }
}

function Write-NxbSemanticHardeningV2Json {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),(($InputObject | ConvertTo-Json -Depth 32) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

if ($env:OS -cne 'Windows_NT') { throw 'Part 2 V2 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Part 2 V2 certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw ('Part 2 V2 exact-head mismatch. Expected={0} actual={1}' -f $ExpectedHead,$currentHead)
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Part 2 V2 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$topReviewZip = $outputFull + '-v2-review.zip'
if (Test-Path -LiteralPath $topReviewZip) { throw ('Part 2 V2 review ZIP already exists: {0}' -f $topReviewZip) }

$preflightPath = Join-Path $PSScriptRoot 'Test-NxbSemanticHardeningHostCapability.ps1'
$childPath = Join-Path $PSScriptRoot 'Invoke-NxbSemanticHardeningCertification.ps1'
$deepValidatorPath = Join-Path $repositoryRoot 'tools\validate_semantic_root_trace_evidence.py'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$signaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
foreach ($requiredPath in @($preflightPath,$childPath,$deepValidatorPath,$scannerPath,$signaturePath,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Part 2 V2 component missing: {0}' -f $requiredPath) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-006 PART 2 8/8 SEMANTIC HARDENING CERTIFICATION V2 ==='
Write-Information -InformationAction Continue -MessageData '[top 1/5] Parser/analyzer + Python syntax + inherited known-error scan'
foreach ($scriptPath in @($preflightPath,$PSCommandPath)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw ('Part 2 V2 parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join "`n"))
    }
}
if (-not (Get-Module -Name PSScriptAnalyzer)) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
}
$analyzerFinding = @(foreach ($scriptPath in @($preflightPath,$PSCommandPath)) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFinding.Count -gt 0) {
    throw ('Part 2 V2 PSScriptAnalyzer findings: {0}`n{1}' -f $analyzerFinding.Count,(@($analyzerFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n"))
}
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = [string]$pythonCommand.Source
$compile = Invoke-NxbSemanticHardeningV2Native -Executable $pythonPath -ArgumentList @('-m','py_compile',$deepValidatorPath)
if ($compile.exit_code -ne 0) { throw ('Part 2 deep validator Python syntax failed: {0}' -f $compile.output) }
$scan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -NoThrow -PassThru
if ([string]$scan.status -cne 'passed' -or [int]$scan.finding_count -ne 0) {
    $detail = @($scan.findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
    throw ('Part 2 V2 known-error preflight failed: findings={0}{1}{2}' -f [int]$scan.finding_count,[Environment]::NewLine,$detail)
}

Write-Information -InformationAction Continue -MessageData '[top 2/5] Fail-fast native host capability gate'
$hostCapability = & $preflightPath -PassThru
if ([string]$hostCapability.status -cne 'passed') { throw 'Part 2 V2 host capability gate did not pass.' }

Write-Information -InformationAction Continue -MessageData '[top 3/5] Run complete Part 2 child authority'
$childPipeline = @(& $childPath -ExpectedHead $ExpectedHead -OutputDirectory $outputFull -PassThru)
$child = $null
foreach ($item in $childPipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $child = $item }
}
if ($null -eq $child) { throw 'Part 2 V2 child authority returned no passed result.' }
if ([string]$child.head_sha -cne $currentHead -or [int]$child.requested -ne 8 -or [int]$child.validated -ne 8) {
    throw 'Part 2 V2 child authority result contract mismatch.'
}

Write-Information -InformationAction Continue -MessageData '[top 4/5] Deep independent root-cause + trace evidence replay'
$rootTraceRoot = [IO.Path]::GetFullPath([string]$child.root_trace_output)
$deepAuditPath = Join-Path $outputFull 'review\deep-root-trace-audit.json'
$deepArguments = @(
    $deepValidatorPath,
    '--experiment',(Join-Path $rootTraceRoot 'review\root-trace-experiment.json'),
    '--summary',(Join-Path $rootTraceRoot 'review\semantic-control-summary.json'),
    '--summary-replay',(Join-Path $rootTraceRoot 'raw-local\semantic-control-summary-replay.json'),
    '--coverage',(Join-Path $rootTraceRoot 'review\coverage.json'),
    '--coverage-replay',(Join-Path $rootTraceRoot 'raw-local\coverage-replay.json'),
    '--events',(Join-Path $rootTraceRoot 'raw-local\normalized-events.jsonl'),
    '--events-replay',(Join-Path $rootTraceRoot 'raw-local\normalized-events-replay.jsonl'),
    '--trace-statistics',(Join-Path $rootTraceRoot 'raw-local\capture\analysis\etl-trace-statistics.json'),
    '--etl',(Join-Path $rootTraceRoot 'raw-local\capture\traces\performance.etl'),
    '--output',$deepAuditPath
)
$deepRun = Invoke-NxbSemanticHardeningV2Native -Executable $pythonPath -ArgumentList $deepArguments
if ($deepRun.exit_code -ne 0) { throw ('Part 2 deep root/trace validation failed: {0}' -f $deepRun.output) }
$deepAudit = Get-Content -LiteralPath $deepAuditPath -Raw | ConvertFrom-Json
if ([string]$deepAudit.status -cne 'passed' -or -not [bool]$deepAudit.root_cause_validated -or -not [bool]$deepAudit.continuous_trace_completeness) {
    throw 'Part 2 deep root/trace audit did not validate both bounded claims.'
}

Write-Information -InformationAction Continue -MessageData '[top 5/5] Build top review evidence + final zero-error scan'
$topReceiptPath = Join-Path $outputFull 'review\semantic-hardening-part2-v2-certification-receipt.json'
$deepAuditSha = (Get-FileHash -LiteralPath $deepAuditPath -Algorithm SHA256).Hash.ToLowerInvariant()
$childReviewSha = [string]$child.review_zip_sha256
$childReceiptSha = [string]$child.receipt_sha256
$topReceipt = [pscustomobject][ordered]@{
    schema_version = 2
    status = 'passed'
    head_sha = $currentHead
    requested = 8
    validated = 8
    host_capability = 'passed'
    child_authority = 'Invoke-NxbSemanticHardeningCertification.ps1'
    child_review_zip_sha256 = $childReviewSha
    child_receipt_sha256 = $childReceiptSha
    deep_root_trace_audit_sha256 = $deepAuditSha
    deep_root_cause_validated = [bool]$deepAudit.root_cause_validated
    deep_continuous_trace_completeness = [bool]$deepAudit.continuous_trace_completeness
    inherited_part1_status = [string]$child.inherited_part1_status
    policy_fingerprint_sha256 = [string]$child.policy_fingerprint_sha256
    known_error_findings = [int]$child.known_error_finding_count
    psscriptanalyzer_findings = [int]$child.psscriptanalyzer_findings
}
Write-NxbSemanticHardeningV2Json -Path $topReceiptPath -InputObject $topReceipt

$reviewRoot = Join-Path $outputFull 'review'
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $topReviewZip -CompressionLevel Optimal
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($topReviewZip)
try {
    $zipEntries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName.Replace('\','/') })
}
finally { $zip.Dispose() }
if ($zipEntries.Count -ne 25) { throw ('Part 2 V2 review ZIP expected 25 JSON files, observed {0}.' -f $zipEntries.Count) }
if (@($zipEntries | Where-Object { -not $_.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) {
    throw 'Part 2 V2 review ZIP contains a non-JSON artifact.'
}
if (@($zipEntries | Where-Object { $_ -ceq 'deep-root-trace-audit.json' }).Count -ne 1 -or
    @($zipEntries | Where-Object { $_ -ceq 'semantic-hardening-part2-v2-certification-receipt.json' }).Count -ne 1) {
    throw 'Part 2 V2 review ZIP is missing top-level deep-audit evidence.'
}
$finalScan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -NoThrow -PassThru
if ([string]$finalScan.status -cne 'passed' -or [int]$finalScan.finding_count -ne 0) {
    throw ('Part 2 V2 final known-error scan failed: findings={0}' -f [int]$finalScan.finding_count)
}

$result = [pscustomobject][ordered]@{
    schema_version = 2
    status = 'passed'
    head_sha = $currentHead
    requested = [int]$child.requested
    validated = [int]$child.validated
    host_capability = 'passed'
    ps7_tests = [string]$child.ps7_tests
    ps51_tests = [string]$child.ps51_tests
    psscriptanalyzer_findings = [int]$child.psscriptanalyzer_findings
    known_error_rule_count = [int]$finalScan.rule_count
    known_error_finding_count = [int]$finalScan.finding_count
    independent_validation = [bool]$child.independent_validation
    deep_root_trace_validation = $true
    inherited_part1_status = [string]$child.inherited_part1_status
    inherited_part1_head = [string]$child.inherited_part1_head
    policy_fingerprint_sha256 = [string]$child.policy_fingerprint_sha256
    review_zip_path = $topReviewZip
    review_zip_sha256 = (Get-FileHash -LiteralPath $topReviewZip -Algorithm SHA256).Hash.ToLowerInvariant()
    receipt_path = $topReceiptPath
    receipt_sha256 = (Get-FileHash -LiteralPath $topReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    child_review_zip_path = [string]$child.review_zip_path
    child_review_zip_sha256 = $childReviewSha
    child_receipt_path = [string]$child.receipt_path
    child_receipt_sha256 = $childReceiptSha
    deep_audit_path = $deepAuditPath
    deep_audit_sha256 = $deepAuditSha
    work_root = [string]$child.work_root
    part1_output = [string]$child.part1_output
    root_trace_output = [string]$child.root_trace_output
}
Write-Information -InformationAction Continue -MessageData ('NXB IRL-006 Part 2 V2 passed: requested={0} validated={1} deep_root_trace=true' -f $result.requested,$result.validated)
if ($PassThru) { return $result }
Write-Output ([string]$result.review_zip_path)
