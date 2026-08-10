[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$L0ReviewZipPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedL0ReviewSha256 = '6cb9ddfcd607b8aa98c7f7667201b21611bef2d86147146cce9cc39235083a2b'
$ExpectedL0RuntimeHead = '4ea3343b24d041cb417e110565230c5a19bd1773'
$ExpectedBindingFingerprint = '491e6797eeb1aa1d2b66d1b5d90e3087c52d68cedeae529b75d054f673ea01b7'

function Test-NxbPlatformEventAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-NxbPlatformEventCertificationJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        (($InputObject | ConvertTo-Json -Depth 32) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-NxbPlatformEventPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Executable,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TestPath,
        [Parameter(Mandatory)][ValidateRange(1,1000)][int]$ExpectedCount,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-platform-event-pester-$([guid]::NewGuid().ToString('N'))")
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
        foreach ($line in $childOutput) { Write-Information -MessageData ([string]$line) -InformationAction Continue }
        if ($exitCode -ne 0) { throw "$Label Pester run failed: exit=$exitCode" }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) { throw "$Label produced no Pester summary." }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Get-NxbPlatformEventZipJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ZipPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$EntryName
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead([IO.Path]::GetFullPath($ZipPath))
    try {
        $entry = $archive.Entries | Where-Object { $_.FullName -ceq $EntryName } | Select-Object -First 1
        if ($null -eq $entry) { throw "Required ZIP entry missing: $EntryName" }
        $stream = $entry.Open()
        $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$true)
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
        finally { $reader.Dispose(); $stream.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Invoke-NxbPlatformEventValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$ValidatorPath,
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $output = @(& $PythonPath $ValidatorPath --input $InputPath --output $OutputPath 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    foreach ($line in $output) { Write-Information -MessageData ([string]$line) -InformationAction Continue }
    if ($exitCode -ne 0) { throw "Platform event baseline validation failed: exit=$exitCode" }
    return (Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json)
}

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK 2 L1 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK 2 L1 certification requires PowerShell 7.' }
if (-not (Test-NxbPlatformEventAdministrator)) { throw 'SUPERBLOCK 2 L1 certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Platform event exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Platform event certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'L1 output must remain outside the repository.' }
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }
$reviewRoot = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null

$collectorPath = Join-Path $PSScriptRoot 'Get-NxbPlatformEventBaseline.ps1'
$testPath = Join-Path $repositoryRoot 'tests\PlatformEventBaseline.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_platform_event_baseline.py'
$requiredPaths = @($collectorPath,$testPath,$validatorPath,$PSCommandPath)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "L1 component missing: $requiredPath" }
}

Write-Information -MessageData '=== NXB IRL-004 SUPERBLOCK 2 L1 PLATFORM EVENT BASELINE ===' -InformationAction Continue
Write-Information -MessageData '[1/7] Parser/analyzer + dual-runtime 20-test contract' -InformationAction Continue
$analyzerPaths = @($collectorPath,$testPath,$PSCommandPath)
foreach ($scriptPath in $analyzerPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw ("PowerShell parser failed: $scriptPath`n" + (@($parseErrors | ForEach-Object { $_.Message }) -join "`n"))
    }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($scriptPath in $analyzerPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error }
)
if ($findings.Count -gt 0) {
    throw ("L1 PSScriptAnalyzer findings: $($findings.Count)`n" + (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n"))
}
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
& $pythonCommand.Source -m py_compile $validatorPath
if ($LASTEXITCODE -ne 0) { throw 'L1 Python syntax check failed.' }

$previousRoot = [Environment]::GetEnvironmentVariable('NXB_PLATFORM_EVENT_REPOSITORY_ROOT','Process')
$env:NXB_PLATFORM_EVENT_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7 = Invoke-NxbPlatformEventPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 20 -Label 'PowerShell 7 L1'
    $ps51 = Invoke-NxbPlatformEventPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 20 -Label 'Windows PowerShell 5.1 L1'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_PLATFORM_EVENT_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_PLATFORM_EVENT_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -MessageData '[2/7] Bind canonical SUPERBLOCK 2 L0 native evidence' -InformationAction Continue
$l0Full = [IO.Path]::GetFullPath($L0ReviewZipPath)
$l0Sha = (Get-FileHash -LiteralPath $l0Full -Algorithm SHA256).Hash.ToLowerInvariant()
if ($l0Sha -cne $ExpectedL0ReviewSha256) { throw "L0 review ZIP hash mismatch: $l0Sha" }
$l0Receipt = Get-NxbPlatformEventZipJson -ZipPath $l0Full -EntryName 'platform-binding-certification-receipt.json'
if ([string]$l0Receipt.status -cne 'passed') { throw 'L0 receipt is not passed.' }
if ([string]$l0Receipt.head_sha -cne $ExpectedL0RuntimeHead) { throw 'L0 runtime head mismatch.' }
if ([string]$l0Receipt.binding.binding_fingerprint_sha256 -cne $ExpectedBindingFingerprint) { throw 'L0 binding fingerprint mismatch.' }

Write-Information -MessageData '[3/7] Collect and validate bounded platform event baseline A' -InformationAction Continue
$baselineAPath = Join-Path $reviewRoot 'platform-event-baseline-a.json'
$validationAPath = Join-Path $reviewRoot 'platform-event-validation-a.json'
$baselineA = & $collectorPath -OutputPath $baselineAPath -BindingFingerprintSha256 $ExpectedBindingFingerprint -LookbackDays 7 -MaxEventsPerLog 128 -PassThru
$validationA = Invoke-NxbPlatformEventValidation -PythonPath $pythonCommand.Source -ValidatorPath $validatorPath -InputPath $baselineAPath -OutputPath $validationAPath

Start-Sleep -Milliseconds 500
Write-Information -MessageData '[4/7] Collect and validate bounded platform event baseline B' -InformationAction Continue
$baselineBPath = Join-Path $reviewRoot 'platform-event-baseline-b.json'
$validationBPath = Join-Path $reviewRoot 'platform-event-validation-b.json'
$baselineB = & $collectorPath -OutputPath $baselineBPath -BindingFingerprintSha256 $ExpectedBindingFingerprint -LookbackDays 7 -MaxEventsPerLog 128 -PassThru
$validationB = Invoke-NxbPlatformEventValidation -PythonPath $pythonCommand.Source -ValidatorPath $validatorPath -InputPath $baselineBPath -OutputPath $validationBPath

Write-Information -MessageData '[5/7] Stable provider metadata + bounded baseline acceptance' -InformationAction Continue
$metadataA = [string]$validationA.provider_metadata_fingerprint_sha256
$metadataB = [string]$validationB.provider_metadata_fingerprint_sha256
if ($metadataA -cne $metadataB) { throw 'provider metadata fingerprint changed between baselines' }
if ($metadataA -notmatch '^[0-9a-f]{64}$') { throw 'provider metadata fingerprint malformed.' }
if ([int]$validationA.provider_count -ne 8 -or [int]$validationB.provider_count -ne 8) { throw 'L1 provider count is not exactly eight.' }
if ([int]$validationA.event_definition_count -le 0) { throw 'L1 provider event-definition inventory is empty.' }
if ([int]$validationA.attached_log_count -le 0) { throw 'L1 attached-log inventory is empty.' }
if ([int]$validationA.available_log_query_count -le 0) { throw 'L1 has no readable recent-event log query.' }

Write-Information -MessageData '[6/7] Conservative L1 certification receipt' -InformationAction Continue
$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    static_validation = [ordered]@{
        ps7 = [ordered]@{ passed=[int]$ps7.passed; total=[int]$ps7.total }
        ps51 = [ordered]@{ passed=[int]$ps51.passed; total=[int]$ps51.total }
        psscriptanalyzer_findings = $findings.Count
        python_syntax = 'passed'
    }
    l0_binding = [ordered]@{
        review_zip_sha256 = $l0Sha
        runtime_head = $ExpectedL0RuntimeHead
        binding_fingerprint_sha256 = $ExpectedBindingFingerprint
    }
    metadata = [ordered]@{
        provider_metadata_fingerprint_sha256 = $metadataA
        stable_across_two_baselines = $true
        provider_count = [int]$validationA.provider_count
        event_definition_count = [int]$validationA.event_definition_count
        attached_log_count = [int]$validationA.attached_log_count
    }
    baseline_a = [ordered]@{
        available_log_query_count = [int]$validationA.available_log_query_count
        sampled_event_count = [int]$validationA.sampled_event_count
        sha256 = (Get-FileHash -LiteralPath $baselineAPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    baseline_b = [ordered]@{
        available_log_query_count = [int]$validationB.available_log_query_count
        sampled_event_count = [int]$validationB.sampled_event_count
        sha256 = (Get-FileHash -LiteralPath $baselineBPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    claims = [ordered]@{
        provider_metadata_inventory = $true
        bounded_recent_event_shape_inventory = $true
        provider_metadata_stable = $true
        event_id_semantics = $false
        event_task_opcode_semantics = $false
        device_lifecycle_semantics = $false
        power_causality = $false
        firmware_causality = $false
        root_cause_validated = $false
        continuous_trace_completeness = 'not_claimed'
    }
}
$receiptPath = Join-Path $reviewRoot 'platform-event-certification-receipt.json'
Write-NxbPlatformEventCertificationJson -Path $receiptPath -InputObject $receipt

Write-Information -MessageData '[7/7] Bounded review ZIP + raw-event boundary audit' -InformationAction Continue
$reviewZipPath = Join-Path $outputFull 'platform-event-review.zip'
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZipPath -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
try {
    foreach ($entry in $archive.Entries) {
        $lowerName = $entry.FullName.ToLowerInvariant()
        if ($lowerName.EndsWith('.etl') -or $lowerName.EndsWith('.evtx') -or $lowerName.EndsWith('.xml') -or $lowerName.EndsWith('.jsonl') -or $lowerName.Contains('raw-event')) {
            throw "Forbidden platform event review artifact: $($entry.FullName)"
        }
        if ($entry.FullName.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)) {
            $stream = $entry.Open()
            $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$true)
            try {
                $text = $reader.ReadToEnd()
                foreach ($forbiddenText in @('"message":','"xml":','"payload":','"properties":','"event_data":','"user_data":')) {
                    if ($text.IndexOf($forbiddenText,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        throw "Forbidden platform event review content: entry=$($entry.FullName) token=$forbiddenText"
                    }
                }
            }
            finally { $reader.Dispose(); $stream.Dispose() }
        }
    }
}
finally { $archive.Dispose() }

$reviewSha = (Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    ps7_tests = '20/20'
    ps51_tests = '20/20'
    psscriptanalyzer_findings = $findings.Count
    l0_binding_fingerprint_sha256 = $ExpectedBindingFingerprint
    provider_metadata_fingerprint_sha256 = $metadataA
    provider_metadata_stable = $true
    provider_count = [int]$validationA.provider_count
    event_definition_count = [int]$validationA.event_definition_count
    attached_log_count = [int]$validationA.attached_log_count
    baseline_a_available_log_queries = [int]$validationA.available_log_query_count
    baseline_a_sampled_events = [int]$validationA.sampled_event_count
    baseline_b_available_log_queries = [int]$validationB.available_log_query_count
    baseline_b_sampled_events = [int]$validationB.sampled_event_count
    event_id_semantics = $false
    device_lifecycle_semantics = $false
    power_causality = $false
    firmware_causality = $false
    continuous_trace_completeness = 'not_claimed'
    receipt_sha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    review_zip_sha256 = $reviewSha
    review_zip_path = [IO.Path]::GetFullPath($reviewZipPath)
    local_evidence_root = $outputFull
}
Write-Information -MessageData "SUPERBLOCK 2 L1 platform event baseline passed: definitions=$($result.event_definition_count) logs=$($result.attached_log_count) sampledA=$($result.baseline_a_sampled_events) sampledB=$($result.baseline_b_sampled_events) metadata=$metadataA" -InformationAction Continue
if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 16
