[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NxbPart4CertificationNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string[]]$ArgumentList)
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
    return [pscustomobject][ordered]@{ exit_code=$nativeExitCode; output=(@($nativeOutput | ForEach-Object { [string]$_ }) -join "`n") }
}

function Invoke-NxbPart4CertificationPester {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string]$TestPath,[Parameter(Mandatory)][int]$ExpectedCount,[Parameter(Mandatory)][string]$Label)
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-part4-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
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
        $native = Invoke-NxbPart4CertificationNative -Executable $Executable -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,'-TestPath',$TestPath,'-ResultPath',$resultPath,'-ExpectedCount',[string]$ExpectedCount)
        if ($native.exit_code -ne 0) { throw ('{0} Pester failed: exit={1}`n{2}' -f $Label,$native.exit_code,$native.output) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force } }
}

function Write-NxbPart4CertificationJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($fullPath,(($InputObject | ConvertTo-Json -Depth 48) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

if ($env:OS -cne 'Windows_NT') { throw 'Part 4 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Part 4 certification requires PowerShell 7.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Part 4 combined certification requires elevated PowerShell 7 because inherited Part 2 native authority is mandatory.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Part 4 exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Part 4 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$workRoot = $outputFull + '-work'
$part3Output = $outputFull + '-part3'
$experimentOutput = $outputFull + '-runner'
$reviewZip = $outputFull + '-review.zip'
foreach ($reserved in @($outputFull,$workRoot,$part3Output,$experimentOutput,$reviewZip)) {
    if (Test-Path -LiteralPath $reserved) { throw ('Part 4 reserved output already exists: {0}' -f $reserved) }
}
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$policyPath = Join-Path $repositoryRoot 'config\nxb-part4-runner-policy.json'
$schemaPath = Join-Path $repositoryRoot 'schemas\nxb-part4-run-manifest.schema.json'
$commonPath = Join-Path $PSScriptRoot 'NxbPart4Runner.Common.ps1'
$workerPath = Join-Path $PSScriptRoot 'Invoke-NxbPart4RunnerWorker.ps1'
$experimentPath = Join-Path $PSScriptRoot 'Invoke-NxbPart4ResumableRunnerExperiment.ps1'
$testPath = Join-Path $repositoryRoot 'tests\Part4ResumableRunner.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_part4_runner.py'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$signaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$part3Runner = Join-Path $PSScriptRoot 'Invoke-NxbControllerTargetTransportCertification.ps1'
$authorityPaths = @($PSCommandPath,$commonPath,$workerPath,$experimentPath,$testPath)
foreach ($requiredPath in @($policyPath,$schemaPath,$validatorPath,$scannerPath,$signaturePath,$part3Runner) + $authorityPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Part 4 component missing: {0}' -f $requiredPath) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-006 PART 2 + PART 3 + PART 4 COMBINED CERTIFICATION ==='
Write-Information -InformationAction Continue -MessageData '[1/7] Part 4 parser/analyzer + JSON/Python syntax + exact-tree known-error gate'
foreach ($scriptPath in $authorityPaths) {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('Part 4 parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join "`n")) }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$analyzerFinding = @(foreach ($scriptPath in $authorityPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFinding.Count -gt 0) { throw ('Part 4 PSScriptAnalyzer findings: {0}`n{1}' -f $analyzerFinding.Count,(@($analyzerFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")) }
[void](Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json)
[void](Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json)
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = [string]$pythonCommand.Source
$compile = Invoke-NxbPart4CertificationNative -Executable $pythonPath -ArgumentList @('-m','py_compile',$validatorPath)
if ($compile.exit_code -ne 0) { throw ('Part 4 Python validator syntax failed: {0}' -f $compile.output) }
$scanPath = Join-Path $workRoot 'known-error-scan.json'
$scan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -OutputPath $scanPath -NoThrow -PassThru
if ([string]$scan.status -cne 'passed' -or [int]$scan.finding_count -ne 0) {
    $detail = @($scan.findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
    throw ('Part 4 known-error preflight failed: findings={0}{1}{2}' -f [int]$scan.finding_count,[Environment]::NewLine,$detail)
}

Write-Information -InformationAction Continue -MessageData '[2/7] Dual-runtime 16-test Part 4 source contract'
$previousRoot = [Environment]::GetEnvironmentVariable('NXB_PART4_REPOSITORY_ROOT','Process')
$env:NXB_PART4_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Contract = Invoke-NxbPart4CertificationPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 16 -Label 'Part 4 PS7'
    $ps51Contract = Invoke-NxbPart4CertificationPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 16 -Label 'Part 4 PS5.1'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_PART4_REPOSITORY_ROOT -ErrorAction SilentlyContinue } else { $env:NXB_PART4_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -InformationAction Continue -MessageData '[3/7] Re-certify Part 3 and inherited Part 2 on the same exact Part 4 head'
$part3Pipeline = @(& $part3Runner -ExpectedHead $ExpectedHead -OutputDirectory $part3Output -PassThru)
$part3Result = $null
foreach ($item in $part3Pipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $part3Result = $item }
}
if ($null -eq $part3Result -or [string]$part3Result.head_sha -cne $currentHead) { throw 'Inherited Part 3 authority did not pass on the exact Part 4 head.' }
if ([int]$part3Result.inherited_part2_requested -ne 8 -or [int]$part3Result.inherited_part2_validated -ne 8) { throw 'Inherited Part 2 authority did not reach 8/8.' }
foreach ($requirement in @('authenticated_channel','monotonic_sequence','duplicate_detection','loss_detection','bounded_queue','backpressure','local_spool','emergency_stop','interrupted_transfer_recovery')) {
    if (-not [bool]$part3Result.PSObject.Properties[$requirement].Value) { throw ('Inherited Part 3 requirement failed: {0}' -f $requirement) }
}
if ([int]$part3Result.negative_controls_validated -ne 9) { throw 'Inherited Part 3 independent negatives did not reach 9/9.' }

Write-Information -InformationAction Continue -MessageData '[4/7] Real child-process crash/resume + graceful/emergency runner experiment'
$experimentPipeline = @(& $experimentPath -ExpectedHead $ExpectedHead -OutputDirectory $experimentOutput -PassThru)
$experiment = $null
foreach ($item in $experimentPipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $experiment = $item }
}
if ($null -eq $experiment) { throw 'Part 4 runner experiment returned no passed result.' }
$experimentReviewPath = Join-Path $experimentOutput 'review\part4-runner-experiment.json'

Write-Information -InformationAction Continue -MessageData '[5/7] Independent scheduler/sharding/checkpoint replay + ten negative controls'
$validationPath = Join-Path $workRoot 'part4-runner-validation.json'
$validationRun = Invoke-NxbPart4CertificationNative -Executable $pythonPath -ArgumentList @(
    $validatorPath,
    '--policy',(Join-Path $experimentOutput 'run\policy.json'),
    '--manifest',[string]$experiment.local_evidence.manifest_path,
    '--checkpoint',[string]$experiment.local_evidence.checkpoint_path,
    '--events',[string]$experiment.local_evidence.events_path,
    '--receipts',[string]$experiment.local_evidence.receipt_directory,
    '--experiment',$experimentReviewPath,
    '--output',$validationPath
)
if ($validationRun.exit_code -ne 0) { throw ('Independent Part 4 validator failed: {0}' -f $validationRun.output) }
$validation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
if ([string]$validation.status -cne 'passed' -or [int]$validation.requirements_validated -ne 10 -or [int]$validation.negative_controls_validated -ne 10) { throw 'Part 4 independent validation did not reach 10/10 requirements and 10/10 negatives.' }
foreach ($name in @('exact_run_binding','checkpoint_resume','duplicate_prevention','budget_enforcement','stop_modes','adaptive_scheduler','coverage_saturation','fairness_backoff','bounded_queue','deterministic_sharding')) {
    if (-not [bool]$validation.requirements.PSObject.Properties[$name].Value) { throw ('Part 4 requirement did not validate: {0}' -f $name) }
}

Write-Information -InformationAction Continue -MessageData '[6/7] Build bounded JSON-only Part 4 review evidence'
$reviewRoot = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
$reviewExperimentPath = Join-Path $reviewRoot 'part4-runner-experiment.json'
$reviewValidationPath = Join-Path $reviewRoot 'part4-runner-validation.json'
$reviewScanPath = Join-Path $reviewRoot 'known-error-scan.json'
Copy-Item -LiteralPath $experimentReviewPath -Destination $reviewExperimentPath
Copy-Item -LiteralPath $validationPath -Destination $reviewValidationPath
Copy-Item -LiteralPath $scanPath -Destination $reviewScanPath
$receiptPath = Join-Path $reviewRoot 'part4-runner-certification-receipt.json'
$receipt = [pscustomobject][ordered]@{
    schema_version=1; status='passed'; head_sha=$currentHead; contract_id=[string]$validation.contract_id; run_id=[string]$validation.run_id;
    part4_contract=[pscustomobject][ordered]@{ ps7=('{0}/{1}' -f $ps7Contract.passed,$ps7Contract.total); ps51=('{0}/{1}' -f $ps51Contract.passed,$ps51Contract.total); psscriptanalyzer_findings=0; known_error_rule_count=[int]$scan.rule_count; known_error_findings=[int]$scan.finding_count };
    inherited_part2=[pscustomobject][ordered]@{ status=[string]$part3Result.inherited_part2_status; head_sha=[string]$part3Result.inherited_part2_head; requested=[int]$part3Result.inherited_part2_requested; validated=[int]$part3Result.inherited_part2_validated };
    inherited_part3=[pscustomobject][ordered]@{ status=[string]$part3Result.status; head_sha=[string]$part3Result.head_sha; ps7=[string]$part3Result.ps7_tests; ps51=[string]$part3Result.ps51_tests; negative_controls_validated=[int]$part3Result.negative_controls_validated; requirements_validated=9 };
    part4=[pscustomobject][ordered]@{ requirements_validated=[int]$validation.requirements_validated; negative_controls_validated=[int]$validation.negative_controls_validated; task_count=[int]$validation.task_count; shard_count=[int]$validation.shard_count };
    experiment_sha256=(Get-FileHash -LiteralPath $reviewExperimentPath -Algorithm SHA256).Hash.ToLowerInvariant();
    validation_sha256=(Get-FileHash -LiteralPath $reviewValidationPath -Algorithm SHA256).Hash.ToLowerInvariant();
    validator_implementation_sha256=(Get-FileHash -LiteralPath $validatorPath -Algorithm SHA256).Hash.ToLowerInvariant();
    synthetic_only=$true
}
Write-NxbPart4CertificationJson -Path $receiptPath -InputObject $receipt
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($reviewZip)
try { $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName.Replace('\','/') } | Sort-Object) }
finally { $zip.Dispose() }
$expectedEntries = @('known-error-scan.json','part4-runner-certification-receipt.json','part4-runner-experiment.json','part4-runner-validation.json') | Sort-Object
if (($entries -join "`n") -cne ($expectedEntries -join "`n")) { throw ('Part 4 review ZIP content mismatch: {0}' -f ($entries -join ', ')) }
if (@($entries | Where-Object { -not $_.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { throw 'Part 4 review ZIP contains non-JSON content.' }

Write-Information -InformationAction Continue -MessageData '[7/7] Final exact-tree zero-error scan'
$finalScan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -NoThrow -PassThru
if ([string]$finalScan.status -cne 'passed' -or [int]$finalScan.finding_count -ne 0) { throw ('Part 4 final known-error scan failed: findings={0}' -f [int]$finalScan.finding_count) }

$result = [pscustomobject][ordered]@{
    schema_version=1; status='passed'; head_sha=$currentHead;
    ps7_tests=('{0}/{1}' -f $ps7Contract.passed,$ps7Contract.total); ps51_tests=('{0}/{1}' -f $ps51Contract.passed,$ps51Contract.total);
    psscriptanalyzer_findings=0; known_error_rule_count=[int]$finalScan.rule_count; known_error_finding_count=[int]$finalScan.finding_count;
    inherited_part2_requested=[int]$part3Result.inherited_part2_requested; inherited_part2_validated=[int]$part3Result.inherited_part2_validated;
    inherited_part3_ps7=[string]$part3Result.ps7_tests; inherited_part3_ps51=[string]$part3Result.ps51_tests; inherited_part3_negative_controls=[int]$part3Result.negative_controls_validated;
    inherited_part3_authenticated_channel=[bool]$part3Result.authenticated_channel; inherited_part3_monotonic_sequence=[bool]$part3Result.monotonic_sequence;
    inherited_part3_duplicate_detection=[bool]$part3Result.duplicate_detection; inherited_part3_loss_detection=[bool]$part3Result.loss_detection;
    inherited_part3_bounded_queue=[bool]$part3Result.bounded_queue; inherited_part3_backpressure=[bool]$part3Result.backpressure;
    inherited_part3_local_spool=[bool]$part3Result.local_spool; inherited_part3_emergency_stop=[bool]$part3Result.emergency_stop;
    inherited_part3_interrupted_transfer_recovery=[bool]$part3Result.interrupted_transfer_recovery;
    part4_requirements_validated=[int]$validation.requirements_validated; part4_negative_controls=[int]$validation.negative_controls_validated;
    exact_run_binding=[bool]$validation.requirements.exact_run_binding; checkpoint_resume=[bool]$validation.requirements.checkpoint_resume;
    duplicate_prevention=[bool]$validation.requirements.duplicate_prevention; budget_enforcement=[bool]$validation.requirements.budget_enforcement;
    stop_modes=[bool]$validation.requirements.stop_modes; adaptive_scheduler=[bool]$validation.requirements.adaptive_scheduler;
    coverage_saturation=[bool]$validation.requirements.coverage_saturation; fairness_backoff=[bool]$validation.requirements.fairness_backoff;
    bounded_queue=[bool]$validation.requirements.bounded_queue; deterministic_sharding=[bool]$validation.requirements.deterministic_sharding;
    review_zip_path=$reviewZip; review_zip_sha256=(Get-FileHash -LiteralPath $reviewZip -Algorithm SHA256).Hash.ToLowerInvariant();
    receipt_path=$receiptPath; receipt_sha256=(Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant();
    part3_output=$part3Output; runner_output=$experimentOutput; work_root=$workRoot
}
Write-Information -InformationAction Continue -MessageData 'NXB IRL-006 combined Part 2 + Part 3 + Part 4 certification passed: Part2=8/8 Part3=9/9+9/9 Part4=10/10+10/10.'
if ($PassThru) { return $result }
Write-Output $reviewZip
