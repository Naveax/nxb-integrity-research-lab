[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NxbPart5CertificationNative {
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
    return [pscustomobject][ordered]@{
        exit_code = $nativeExitCode
        output = (@($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
    }
}

function Invoke-NxbPart5CertificationPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-part5-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
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
        $native = Invoke-NxbPart5CertificationNative -Executable $Executable -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,'-TestPath',$TestPath,'-ResultPath',$resultPath,'-ExpectedCount',[string]$ExpectedCount)
        if ($native.exit_code -ne 0) { throw ('{0} Pester failed: exit={1}`n{2}' -f $Label,$native.exit_code,$native.output) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Copy-NxbPart5ReviewFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination)
    $sourceFull = [IO.Path]::GetFullPath($Source)
    $destinationFull = [IO.Path]::GetFullPath($Destination)
    if ($sourceFull -ceq $destinationFull) { throw ('Part 5 review copy source equals destination: {0}' -f $sourceFull) }
    [IO.File]::Copy($sourceFull,$destinationFull,$true)
}

if ($env:OS -cne 'Windows_NT') { throw 'Part 5 signed closure certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Part 5 signed closure certification requires PowerShell 7.' }
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Part 5 requires elevated PowerShell 7 because inherited Part 2 native authority is mandatory.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Part 5 exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Part 5 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$workRoot = $outputFull + '-work'
$part234Output = $outputFull + '-part234'
$reviewZip = $outputFull + '-review.zip'
foreach ($reserved in @($outputFull,$workRoot,$part234Output,$reviewZip)) {
    if (Test-Path -LiteralPath $reserved) { throw ('Part 5 reserved output already exists: {0}' -f $reserved) }
}
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$policyPath = Join-Path $repositoryRoot 'config\nxb-part5-signed-closure-policy.json'
$schemaPath = Join-Path $repositoryRoot 'schemas\nxb-part5-signed-closure.schema.json'
$commonPath = Join-Path $PSScriptRoot 'NxbPart5Crypto.Common.ps1'
$testPath = Join-Path $repositoryRoot 'tests\Part5SignedClosure.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_part5_signed_closure.py'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$signaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$part4CombinedPath = Join-Path $PSScriptRoot 'Invoke-NxbPart4CombinedCertification.ps1'
$authorityPaths = @($PSCommandPath,$commonPath,$testPath)
foreach ($requiredPath in @($policyPath,$schemaPath,$validatorPath,$scannerPath,$signaturePath,$part4CombinedPath) + $authorityPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Part 5 component missing: {0}' -f $requiredPath) }
}
. $commonPath

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-006 PART 2 + PART 3 + PART 4 + PART 5 SIGNED CLOSURE CERTIFICATION ==='
Write-Information -InformationAction Continue -MessageData '[1/7] Part 5 parser/analyzer + JSON/Python syntax + exact-tree known-error gate'
foreach ($scriptPath in $authorityPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('Part 5 parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine)) }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$analyzerFinding = @(foreach ($scriptPath in $authorityPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFinding.Count -gt 0) {
    $detail = @($analyzerFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join [Environment]::NewLine
    throw ('Part 5 PSScriptAnalyzer findings: {0}`n{1}' -f $analyzerFinding.Count,$detail)
}
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
[void](Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json)
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = [string]$pythonCommand.Source
$compile = Invoke-NxbPart5CertificationNative -Executable $pythonPath -ArgumentList @('-m','py_compile',$validatorPath)
if ($compile.exit_code -ne 0) { throw ('Part 5 Python validator syntax failed: {0}' -f $compile.output) }
$scanPath = Join-Path $workRoot 'known-error-scan.json'
$scan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -OutputPath $scanPath -NoThrow -PassThru
if ([string]$scan.status -cne 'passed' -or [int]$scan.finding_count -ne 0 -or [int]$scan.rule_count -lt 18) {
    $detail = @($scan.findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
    throw ('Part 5 known-error preflight failed: rules={0} findings={1}{2}{3}' -f [int]$scan.rule_count,[int]$scan.finding_count,[Environment]::NewLine,$detail)
}

Write-Information -InformationAction Continue -MessageData '[2/7] Dual-runtime 16-test Part 5 source contract'
$previousRoot = [Environment]::GetEnvironmentVariable('NXB_PART5_REPOSITORY_ROOT','Process')
$env:NXB_PART5_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Contract = Invoke-NxbPart5CertificationPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 16 -Label 'Part 5 PS7'
    $ps51Contract = Invoke-NxbPart5CertificationPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 16 -Label 'Part 5 PS5.1'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_PART5_REPOSITORY_ROOT -ErrorAction SilentlyContinue } else { $env:NXB_PART5_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -InformationAction Continue -MessageData '[3/7] Re-certify combined Part 2 + Part 3 + Part 4 on the same exact Part 5 head'
$part234Pipeline = @(& $part4CombinedPath -ExpectedHead $ExpectedHead -OutputDirectory $part234Output -PassThru)
$part234Result = $null
foreach ($item in $part234Pipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $part234Result = $item }
}
if ($null -eq $part234Result -or [string]$part234Result.head_sha -cne $currentHead) { throw 'Inherited Part 2+3+4 combined authority did not pass on the exact Part 5 head.' }
if ([int]$part234Result.part2_requested -ne 8 -or [int]$part234Result.part2_validated -ne 8) { throw 'Inherited Part 2 is not 8/8.' }
if ([string]$part234Result.part3_ps7 -cne '16/16' -or [string]$part234Result.part3_ps51 -cne '16/16' -or [int]$part234Result.part3_negative_controls -ne 9) { throw 'Inherited Part 3 contract is incomplete.' }
if ([string]$part234Result.part4_ps7 -cne '16/16' -or [string]$part234Result.part4_ps51 -cne '16/16' -or [int]$part234Result.part4_requirements_validated -ne 10 -or [int]$part234Result.part4_negative_controls -ne 10) { throw 'Inherited Part 4 contract is incomplete.' }

Write-Information -InformationAction Continue -MessageData '[4/7] Re-hash nested Part 2/3/4 evidence and create ephemeral RSA-3072 signed closure'
$part234ReviewPath = [IO.Path]::GetFullPath([string]$part234Result.review_zip_path)
$part234ReceiptPath = [IO.Path]::GetFullPath([string]$part234Result.receipt_path)
$part2ReviewPath = [IO.Path]::GetFullPath([string]$part234Result.part2_review_zip_path)
$part2ReceiptPath = [IO.Path]::GetFullPath([string]$part234Result.part2_receipt_path)
$part3ReviewPath = [IO.Path]::GetFullPath([string]$part234Result.part3_review_zip_path)
$part3ReceiptPath = [IO.Path]::GetFullPath([string]$part234Result.part3_receipt_path)
$part4ReviewPath = [IO.Path]::GetFullPath([string]$part234Result.part4_review_zip_path)
$part4ReceiptPath = [IO.Path]::GetFullPath([string]$part234Result.part4_receipt_path)
foreach ($path in @($part234ReviewPath,$part234ReceiptPath,$part2ReviewPath,$part2ReceiptPath,$part3ReviewPath,$part3ReceiptPath,$part4ReviewPath,$part4ReceiptPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Part 5 nested evidence missing: {0}' -f $path) }
}
$part234ReviewSha = Get-NxbPart5FileSha256 -Path $part234ReviewPath
$part234ReceiptSha = Get-NxbPart5FileSha256 -Path $part234ReceiptPath
$part2ReviewSha = Get-NxbPart5FileSha256 -Path $part2ReviewPath
$part2ReceiptSha = Get-NxbPart5FileSha256 -Path $part2ReceiptPath
$part3ReviewSha = Get-NxbPart5FileSha256 -Path $part3ReviewPath
$part3ReceiptSha = Get-NxbPart5FileSha256 -Path $part3ReceiptPath
$part4ReviewSha = Get-NxbPart5FileSha256 -Path $part4ReviewPath
$part4ReceiptSha = Get-NxbPart5FileSha256 -Path $part4ReceiptPath
foreach ($binding in @(
    @($part234ReviewSha,[string]$part234Result.review_zip_sha256,'part234 review'),
    @($part234ReceiptSha,[string]$part234Result.receipt_sha256,'part234 receipt'),
    @($part2ReviewSha,[string]$part234Result.part2_review_zip_sha256,'part2 review'),
    @($part2ReceiptSha,[string]$part234Result.part2_receipt_sha256,'part2 receipt'),
    @($part3ReviewSha,[string]$part234Result.part3_review_zip_sha256,'part3 review'),
    @($part3ReceiptSha,[string]$part234Result.part3_receipt_sha256,'part3 receipt'),
    @($part4ReviewSha,[string]$part234Result.part4_review_zip_sha256,'part4 review'),
    @($part4ReceiptSha,[string]$part234Result.part4_receipt_sha256,'part4 receipt')
)) {
    if ([string]$binding[0] -cne [string]$binding[1]) { throw ('Part 5 nested evidence hash mismatch: {0}' -f [string]$binding[2]) }
}

$reviewRoot = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
$signedReceiptPath = Join-Path $reviewRoot 'part5-signed-closure-receipt.json'
$authority = Get-NxbPart5EphemeralAuthority -KeySizeBits ([int]$policy.key_size_bits)
try {
    if ([int]$authority.actual_key_size_bits -lt 3072) { throw 'Part 5 ephemeral RSA key is below 3072 bits.' }
    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        status = 'passed'
        authority = 'nxb-irl006-part5-signed-closure-v1'
        head_sha = $currentHead
        closure_sequence = [int]$policy.closure_sequence
        algorithm = [string]$policy.algorithm
        key_size_bits = [int]$authority.actual_key_size_bits
        private_key_persisted = $false
        production_signer_claimed = $false
        public_key = [pscustomobject][ordered]@{
            modulus_b64 = [string]$authority.modulus_b64
            exponent_b64 = [string]$authority.exponent_b64
            fingerprint_sha256 = [string]$authority.fingerprint_sha256
        }
        nested_evidence = [pscustomobject][ordered]@{
            part234_review_zip_sha256 = $part234ReviewSha
            part234_receipt_sha256 = $part234ReceiptSha
            part2_review_zip_sha256 = $part2ReviewSha
            part2_receipt_sha256 = $part2ReceiptSha
            part3_review_zip_sha256 = $part3ReviewSha
            part3_receipt_sha256 = $part3ReceiptSha
            part4_review_zip_sha256 = $part4ReviewSha
            part4_receipt_sha256 = $part4ReceiptSha
        }
        nonce_b64 = Get-NxbPart5Nonce
        created_utc = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        canonical_sha256 = ''
        signature_b64 = ''
    }
    $canonicalMaterial = Get-NxbPart5CanonicalMaterial -Receipt $receipt
    $receipt.canonical_sha256 = Get-NxbPart5Sha256Text -Text $canonicalMaterial
    $receipt.signature_b64 = Invoke-NxbPart5RsaSignature -Rsa $authority.rsa -CanonicalMaterial $canonicalMaterial
    Write-NxbPart5AtomicJson -Path $signedReceiptPath -InputObject $receipt
}
finally {
    if ($null -ne $authority -and $null -ne $authority.rsa) { $authority.rsa.Dispose() }
}

Write-Information -InformationAction Continue -MessageData '[5/7] Independent Python RSA verification + ten fail-closed mutations'
$validationPath = Join-Path $reviewRoot 'part5-independent-validation.json'
$validationRun = Invoke-NxbPart5CertificationNative -Executable $pythonPath -ArgumentList @(
    $validatorPath,
    '--receipt',$signedReceiptPath,
    '--policy',$policyPath,
    '--expected-head',$currentHead,
    '--output',$validationPath
)
if ($validationRun.exit_code -ne 0) { throw ('Part 5 independent validator failed: {0}' -f $validationRun.output) }
$validation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
if ([string]$validation.status -cne 'passed' -or [int]$validation.requirements_validated -ne 10 -or [int]$validation.negative_controls_validated -ne 10) {
    throw 'Part 5 independent validation did not reach 10/10 requirements and 10/10 negatives.'
}

Write-Information -InformationAction Continue -MessageData '[6/7] Build seven-JSON Part 2+3+4+5 review closure'
$reviewScanPath = Join-Path $reviewRoot 'known-error-scan.json'
[IO.File]::Copy($scanPath,$reviewScanPath,$true)
Copy-NxbPart5ReviewFile -Source $part234ReceiptPath -Destination (Join-Path $reviewRoot 'part234-combined-certification-receipt.json')
Copy-NxbPart5ReviewFile -Source $part2ReceiptPath -Destination (Join-Path $reviewRoot 'part2-semantic-hardening-certification-receipt.json')
Copy-NxbPart5ReviewFile -Source $part3ReceiptPath -Destination (Join-Path $reviewRoot 'part3-transport-certification-receipt.json')
Copy-NxbPart5ReviewFile -Source $part4ReceiptPath -Destination (Join-Path $reviewRoot 'part4-runner-certification-receipt.json')
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($reviewZip)
try {
    $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName.Replace('\','/') } | Sort-Object)
}
finally { $zip.Dispose() }
$expectedEntries = @(
    'known-error-scan.json',
    'part234-combined-certification-receipt.json',
    'part2-semantic-hardening-certification-receipt.json',
    'part3-transport-certification-receipt.json',
    'part4-runner-certification-receipt.json',
    'part5-independent-validation.json',
    'part5-signed-closure-receipt.json'
) | Sort-Object
if ($entries.Count -ne 7 -or ($entries -join "`n") -cne ($expectedEntries -join "`n")) { throw ('Part 5 review ZIP content mismatch: {0}' -f ($entries -join ', ')) }
if (@($entries | Where-Object { -not $_.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { throw 'Part 5 review ZIP contains non-JSON content.' }

Write-Information -InformationAction Continue -MessageData '[7/7] Final exact-tree scan and signed closure result'
$finalScan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -NoThrow -PassThru
if ([string]$finalScan.status -cne 'passed' -or [int]$finalScan.finding_count -ne 0 -or [int]$finalScan.rule_count -lt 18) { throw 'Part 5 final exact-tree known-error scan failed.' }
$finalReceipt = Get-Content -LiteralPath $signedReceiptPath -Raw | ConvertFrom-Json
$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    ps7_tests = ('{0}/{1}' -f [int]$ps7Contract.passed,[int]$ps7Contract.total)
    ps51_tests = ('{0}/{1}' -f [int]$ps51Contract.passed,[int]$ps51Contract.total)
    psscriptanalyzer_findings = 0
    known_error_rule_count = [int]$finalScan.rule_count
    known_error_finding_count = [int]$finalScan.finding_count
    part2_requested = [int]$part234Result.part2_requested
    part2_validated = [int]$part234Result.part2_validated
    part3_ps7 = [string]$part234Result.part3_ps7
    part3_ps51 = [string]$part234Result.part3_ps51
    part3_negative_controls = [int]$part234Result.part3_negative_controls
    part4_ps7 = [string]$part234Result.part4_ps7
    part4_ps51 = [string]$part234Result.part4_ps51
    part4_requirements_validated = [int]$part234Result.part4_requirements_validated
    part4_negative_controls = [int]$part234Result.part4_negative_controls
    part5_requirements_validated = [int]$validation.requirements_validated
    part5_negative_controls = [int]$validation.negative_controls_validated
    rsa_signature_valid = [bool]$validation.requirements.rsa_signature_valid
    public_key_fingerprint_binding = [bool]$validation.requirements.public_key_fingerprint_binding
    private_key_persisted = [bool]$finalReceipt.private_key_persisted
    production_signer_claimed = [bool]$finalReceipt.production_signer_claimed
    signed_receipt_path = $signedReceiptPath
    signed_receipt_sha256 = Get-NxbPart5FileSha256 -Path $signedReceiptPath
    review_zip_path = $reviewZip
    review_zip_sha256 = Get-NxbPart5FileSha256 -Path $reviewZip
    part234_review_zip_path = $part234ReviewPath
    part234_review_zip_sha256 = $part234ReviewSha
    part234_receipt_path = $part234ReceiptPath
    part234_receipt_sha256 = $part234ReceiptSha
    part2_review_zip_path = $part2ReviewPath
    part2_review_zip_sha256 = $part2ReviewSha
    part2_receipt_path = $part2ReceiptPath
    part2_receipt_sha256 = $part2ReceiptSha
    part3_review_zip_path = $part3ReviewPath
    part3_review_zip_sha256 = $part3ReviewSha
    part3_receipt_path = $part3ReceiptPath
    part3_receipt_sha256 = $part3ReceiptSha
    part4_review_zip_path = $part4ReviewPath
    part4_review_zip_sha256 = $part4ReviewSha
    part4_receipt_path = $part4ReceiptPath
    part4_receipt_sha256 = $part4ReceiptSha
}
Write-Information -InformationAction Continue -MessageData 'NXB Part 2+3+4+5 signed closure passed: Part2=8/8 Part3=9/9+9/9 Part4=10/10+10/10 Part5=10/10+10/10.'
if ($PassThru) { return $result }
Write-Output $reviewZip
