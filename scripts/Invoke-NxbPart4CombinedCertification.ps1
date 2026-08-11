[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbPart4CombinedJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($fullPath,(($InputObject | ConvertTo-Json -Depth 48) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

function Get-NxbPart4CombinedSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

if ($env:OS -cne 'Windows_NT') { throw 'Combined Part 2 + Part 3 + Part 4 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Combined Part 2 + Part 3 + Part 4 certification requires PowerShell 7.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Combined Part 2 + Part 3 + Part 4 certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Combined exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Combined certification requires a clean exact-head worktree.' }

Import-Module PSScriptAnalyzer -ErrorAction Stop
$selfAnalyzer = @(Invoke-ScriptAnalyzer -Path $PSCommandPath -Severity Warning,Error)
if ($selfAnalyzer.Count -gt 0) {
    $detail = @($selfAnalyzer | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join [Environment]::NewLine
    throw ('Combined closure PSScriptAnalyzer findings: {0}{1}{2}' -f $selfAnalyzer.Count,[Environment]::NewLine,$detail)
}

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$part4Output = $outputFull + '-part4'
$reviewZip = $outputFull + '-review.zip'
foreach ($reserved in @($outputFull,$part4Output,$reviewZip)) {
    if (Test-Path -LiteralPath $reserved) { throw ('Combined reserved output already exists: {0}' -f $reserved) }
}

$part4Runner = Join-Path $PSScriptRoot 'Invoke-NxbPart4ResumableRunnerCertification.ps1'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$signaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
foreach ($path in @($part4Runner,$scannerPath,$signaturePath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Combined authority component missing: {0}' -f $path) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-006 PART 2 + PART 3 + PART 4 COMBINED CLOSURE ==='
Write-Information -InformationAction Continue -MessageData '[1/4] Run complete Part 4 authority including inherited Part 3 and Part 2'
$pipeline = @(& $part4Runner -ExpectedHead $ExpectedHead -OutputDirectory $part4Output -PassThru)
$part4Result = $null
foreach ($item in $pipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $part4Result = $item }
}
if ($null -eq $part4Result -or [string]$part4Result.head_sha -cne $currentHead) { throw 'Combined closure received no exact-head passed Part 4 result.' }
if ([int]$part4Result.inherited_part2_requested -ne 8 -or [int]$part4Result.inherited_part2_validated -ne 8) { throw 'Combined closure inherited Part 2 is not 8/8.' }
if ([string]$part4Result.inherited_part3_ps7 -cne '16/16' -or [string]$part4Result.inherited_part3_ps51 -cne '16/16' -or [int]$part4Result.inherited_part3_negative_controls -ne 9) { throw 'Combined closure inherited Part 3 contract is incomplete.' }
if ([string]$part4Result.ps7_tests -cne '16/16' -or [string]$part4Result.ps51_tests -cne '16/16' -or [int]$part4Result.part4_requirements_validated -ne 10 -or [int]$part4Result.part4_negative_controls -ne 10) { throw 'Combined closure Part 4 contract is incomplete.' }

Write-Information -InformationAction Continue -MessageData '[2/4] Re-hash nested Part 2 Part 3 and Part 4 evidence artifacts'
$part4ReviewZip = [IO.Path]::GetFullPath([string]$part4Result.review_zip_path)
$part4ReceiptPath = [IO.Path]::GetFullPath([string]$part4Result.receipt_path)
$part3Output = [IO.Path]::GetFullPath([string]$part4Result.part3_output)
$part3ReviewZip = $part3Output + '-review.zip'
$part3ReceiptPath = Join-Path $part3Output 'review\controller-target-transport-certification-receipt.json'
$part2Output = $part3Output + '-part2'
$part2ReviewZip = $part2Output + '-v2-review.zip'
$part2ReceiptPath = Join-Path $part2Output 'review\semantic-hardening-part2-v2-certification-receipt.json'
foreach ($path in @($part4ReviewZip,$part4ReceiptPath,$part3ReviewZip,$part3ReceiptPath,$part2ReviewZip,$part2ReceiptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Combined nested evidence missing: {0}' -f $path) }
}
$part4ReviewSha = Get-NxbPart4CombinedSha256 -Path $part4ReviewZip
$part4ReceiptSha = Get-NxbPart4CombinedSha256 -Path $part4ReceiptPath
$part3ReviewSha = Get-NxbPart4CombinedSha256 -Path $part3ReviewZip
$part3ReceiptSha = Get-NxbPart4CombinedSha256 -Path $part3ReceiptPath
$part2ReviewSha = Get-NxbPart4CombinedSha256 -Path $part2ReviewZip
$part2ReceiptSha = Get-NxbPart4CombinedSha256 -Path $part2ReceiptPath
if ($part4ReviewSha -cne [string]$part4Result.review_zip_sha256 -or $part4ReceiptSha -cne [string]$part4Result.receipt_sha256) { throw 'Combined closure Part 4 evidence hash mismatch.' }

$part4Receipt = Get-Content -LiteralPath $part4ReceiptPath -Raw | ConvertFrom-Json
$part3Receipt = Get-Content -LiteralPath $part3ReceiptPath -Raw | ConvertFrom-Json
$part2Receipt = Get-Content -LiteralPath $part2ReceiptPath -Raw | ConvertFrom-Json
if ([string]$part4Receipt.status -cne 'passed' -or [string]$part4Receipt.head_sha -cne $currentHead) { throw 'Combined closure Part 4 receipt binding mismatch.' }
if ([string]$part3Receipt.status -cne 'passed' -or [string]$part3Receipt.head_sha -cne $currentHead) { throw 'Combined closure Part 3 receipt binding mismatch.' }
if ([int]$part3Receipt.inherited_part2.requested -ne 8 -or [int]$part3Receipt.inherited_part2.validated -ne 8) { throw 'Combined closure Part 3 receipt does not bind Part 2 8/8.' }
if ([int]$part2Receipt.schema_version -ne 2 -or [string]$part2Receipt.status -cne 'passed' -or [string]$part2Receipt.head_sha -cne $currentHead -or [int]$part2Receipt.requested -ne 8 -or [int]$part2Receipt.validated -ne 8) { throw 'Combined closure Part 2 receipt binding mismatch.' }
if ([int]$part2Receipt.known_error_findings -ne 0 -or [int]$part2Receipt.psscriptanalyzer_findings -ne 0) { throw 'Combined closure Part 2 receipt static/error gate is not clean.' }

Write-Information -InformationAction Continue -MessageData '[3/4] Build cryptographically bound combined closure receipt and review ZIP'
$reviewRoot = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
$reviewScanPath = Join-Path $reviewRoot 'known-error-scan.json'
$scan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -OutputPath $reviewScanPath -NoThrow -PassThru
if ([string]$scan.status -cne 'passed' -or [int]$scan.finding_count -ne 0 -or [int]$scan.rule_count -lt 17) { throw ('Combined closure known-error gate failed: rules={0} findings={1}' -f [int]$scan.rule_count,[int]$scan.finding_count) }

$part4ReceiptCopy = Join-Path $reviewRoot 'part4-runner-certification-receipt.json'
$part3ReceiptCopy = Join-Path $reviewRoot 'part3-transport-certification-receipt.json'
$part2ReceiptCopy = Join-Path $reviewRoot 'part2-semantic-hardening-certification-receipt.json'
Copy-Item -LiteralPath $part4ReceiptPath -Destination $part4ReceiptCopy
Copy-Item -LiteralPath $part3ReceiptPath -Destination $part3ReceiptCopy
Copy-Item -LiteralPath $part2ReceiptPath -Destination $part2ReceiptCopy
$combinedReceiptPath = Join-Path $reviewRoot 'part234-combined-certification-receipt.json'
$combinedReceipt = [pscustomobject][ordered]@{
    schema_version=1
    status='passed'
    head_sha=$currentHead
    authority='nxb-irl006-part2-part3-part4-combined-v1'
    part2=[pscustomobject][ordered]@{
        requested=[int]$part4Result.inherited_part2_requested; validated=[int]$part4Result.inherited_part2_validated;
        review_zip_sha256=$part2ReviewSha; receipt_sha256=$part2ReceiptSha
    }
    part3=[pscustomobject][ordered]@{
        ps7=[string]$part4Result.inherited_part3_ps7; ps51=[string]$part4Result.inherited_part3_ps51;
        requirements_validated=9; negative_controls_validated=[int]$part4Result.inherited_part3_negative_controls;
        review_zip_sha256=$part3ReviewSha; receipt_sha256=$part3ReceiptSha
    }
    part4=[pscustomobject][ordered]@{
        ps7=[string]$part4Result.ps7_tests; ps51=[string]$part4Result.ps51_tests;
        requirements_validated=[int]$part4Result.part4_requirements_validated; negative_controls_validated=[int]$part4Result.part4_negative_controls;
        review_zip_sha256=$part4ReviewSha; receipt_sha256=$part4ReceiptSha
    }
    known_error_rule_count=[int]$scan.rule_count
    known_error_findings=[int]$scan.finding_count
    psscriptanalyzer_findings=0
    synthetic_part4_only=$true
}
Write-NxbPart4CombinedJson -Path $combinedReceiptPath -InputObject $combinedReceipt
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($reviewZip)
try { $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName.Replace('\','/') } | Sort-Object) }
finally { $zip.Dispose() }
$expectedEntries = @('known-error-scan.json','part234-combined-certification-receipt.json','part2-semantic-hardening-certification-receipt.json','part3-transport-certification-receipt.json','part4-runner-certification-receipt.json') | Sort-Object
if (($entries -join "`n") -cne ($expectedEntries -join "`n")) { throw ('Combined review ZIP content mismatch: {0}' -f ($entries -join ', ')) }
if (@($entries | Where-Object { -not $_.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { throw 'Combined review ZIP contains non-JSON content.' }

Write-Information -InformationAction Continue -MessageData '[4/4] Final combined closure validation'
$finalScan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -NoThrow -PassThru
if ([string]$finalScan.status -cne 'passed' -or [int]$finalScan.finding_count -ne 0 -or [int]$finalScan.rule_count -lt 17) { throw 'Combined final exact-tree known-error scan failed.' }

$result = [pscustomobject][ordered]@{
    schema_version=1; status='passed'; head_sha=$currentHead;
    psscriptanalyzer_findings=0; known_error_rule_count=[int]$finalScan.rule_count; known_error_finding_count=[int]$finalScan.finding_count;
    part2_requested=[int]$part4Result.inherited_part2_requested; part2_validated=[int]$part4Result.inherited_part2_validated;
    part3_ps7=[string]$part4Result.inherited_part3_ps7; part3_ps51=[string]$part4Result.inherited_part3_ps51; part3_negative_controls=[int]$part4Result.inherited_part3_negative_controls;
    part3_authenticated_channel=[bool]$part4Result.inherited_part3_authenticated_channel; part3_monotonic_sequence=[bool]$part4Result.inherited_part3_monotonic_sequence;
    part3_duplicate_detection=[bool]$part4Result.inherited_part3_duplicate_detection; part3_loss_detection=[bool]$part4Result.inherited_part3_loss_detection;
    part3_bounded_queue=[bool]$part4Result.inherited_part3_bounded_queue; part3_backpressure=[bool]$part4Result.inherited_part3_backpressure;
    part3_local_spool=[bool]$part4Result.inherited_part3_local_spool; part3_emergency_stop=[bool]$part4Result.inherited_part3_emergency_stop;
    part3_interrupted_transfer_recovery=[bool]$part4Result.inherited_part3_interrupted_transfer_recovery;
    part4_ps7=[string]$part4Result.ps7_tests; part4_ps51=[string]$part4Result.ps51_tests; part4_requirements_validated=[int]$part4Result.part4_requirements_validated; part4_negative_controls=[int]$part4Result.part4_negative_controls;
    exact_run_binding=[bool]$part4Result.exact_run_binding; checkpoint_resume=[bool]$part4Result.checkpoint_resume; duplicate_prevention=[bool]$part4Result.duplicate_prevention;
    budget_enforcement=[bool]$part4Result.budget_enforcement; stop_modes=[bool]$part4Result.stop_modes; adaptive_scheduler=[bool]$part4Result.adaptive_scheduler;
    coverage_saturation=[bool]$part4Result.coverage_saturation; fairness_backoff=[bool]$part4Result.fairness_backoff; bounded_queue=[bool]$part4Result.bounded_queue;
    deterministic_sharding=[bool]$part4Result.deterministic_sharding;
    part2_review_zip_path=$part2ReviewZip; part2_review_zip_sha256=$part2ReviewSha; part2_receipt_path=$part2ReceiptPath; part2_receipt_sha256=$part2ReceiptSha;
    part3_review_zip_path=$part3ReviewZip; part3_review_zip_sha256=$part3ReviewSha; part3_receipt_path=$part3ReceiptPath; part3_receipt_sha256=$part3ReceiptSha;
    part4_review_zip_path=$part4ReviewZip; part4_review_zip_sha256=$part4ReviewSha; part4_receipt_path=$part4ReceiptPath; part4_receipt_sha256=$part4ReceiptSha;
    review_zip_path=$reviewZip; review_zip_sha256=(Get-NxbPart4CombinedSha256 -Path $reviewZip); receipt_path=$combinedReceiptPath; receipt_sha256=(Get-NxbPart4CombinedSha256 -Path $combinedReceiptPath);
    part4_output=$part4Output
}
Write-Information -InformationAction Continue -MessageData 'NXB combined Part 2 + Part 3 + Part 4 closure passed: Part2=8/8 Part3=9/9+9/9 Part4=10/10+10/10.'
if ($PassThru) { return $result }
Write-Output $reviewZip
