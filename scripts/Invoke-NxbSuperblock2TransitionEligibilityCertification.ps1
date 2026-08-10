[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$L1ReviewZipPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedL1ReviewSha256 = 'f612b0e07348b883ffb0b84035de87942f7a67eb9fc1e9bb46f05b2b9dc788e5'
$ExpectedL1RuntimeHead = '5da20feddb654ffb5c3e94a115c376a362f37e11'
$ExpectedBindingFingerprint = '491e6797eeb1aa1d2b66d1b5d90e3087c52d68cedeae529b75d054f673ea01b7'
$ExpectedProviderMetadataFingerprint = '540635297b3bea77ef403620309f08149fc784cb2698ac238e154ccafaa3fecc'

function Test-NxbTransitionAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-NxbTransitionCertificationJson {
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

function Invoke-NxbTransitionPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Executable,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TestPath,
        [Parameter(Mandatory)][ValidateRange(1,1000)][int]$ExpectedCount,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-transition-pester-$([guid]::NewGuid().ToString('N'))")
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

function Get-NxbTransitionCertificationZipJson {
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

function Invoke-NxbTransitionAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PythonPath,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$AnalyzerPath,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$InputPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath
    )
    $output = @(& $PythonPath $AnalyzerPath --input $InputPath --output $OutputPath 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    foreach ($line in $output) { Write-Information -MessageData ([string]$line) -InformationAction Continue }
    if ($exitCode -ne 0) { throw "Controlled transition analysis failed: exit=$exitCode" }
    return (Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json)
}

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK 2 L2 transition certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK 2 L2 transition certification requires PowerShell 7.' }
if (-not (Test-NxbTransitionAdministrator)) { throw 'SUPERBLOCK 2 L2 transition certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Transition exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Transition certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Transition output must remain outside the repository.' }
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }
$reviewRoot = Join-Path $outputFull 'review'
$localRoot = Join-Path $outputFull 'local'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
[IO.Directory]::CreateDirectory($localRoot) | Out-Null

$runtimePath = Join-Path $PSScriptRoot 'Invoke-NxbPlatformControlledTransitionsV2.ps1'
$testPath = Join-Path $repositoryRoot 'tests\PlatformControlledTransitions.Tests.ps1'
$analyzerPath = Join-Path $repositoryRoot 'tools\analyze_platform_transition_eligibility.py'
$requiredPaths = @($runtimePath,$testPath,$analyzerPath,$PSCommandPath)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "Transition component missing: $requiredPath" }
}

Write-Information -MessageData '=== NXB IRL-004 SUPERBLOCK 2 L2 CONTROLLED TRANSITION ELIGIBILITY ===' -InformationAction Continue
Write-Information -MessageData '[1/6] Parser/analyzer + dual-runtime 20-test contract' -InformationAction Continue
$analyzerPaths = @($runtimePath,$testPath,$PSCommandPath)
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
    throw ("L2 PSScriptAnalyzer findings: $($findings.Count)`n" + (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n"))
}
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
& $pythonCommand.Source -m py_compile $analyzerPath
if ($LASTEXITCODE -ne 0) { throw 'L2 Python syntax check failed.' }

$previousRoot = [Environment]::GetEnvironmentVariable('NXB_PLATFORM_TRANSITION_REPOSITORY_ROOT','Process')
$env:NXB_PLATFORM_TRANSITION_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7 = Invoke-NxbTransitionPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 20 -Label 'PowerShell 7 L2'
    $ps51 = Invoke-NxbTransitionPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 20 -Label 'Windows PowerShell 5.1 L2'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_PLATFORM_TRANSITION_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_PLATFORM_TRANSITION_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -MessageData '[2/6] Bind canonical SUPERBLOCK 2 L1 native evidence' -InformationAction Continue
$l1Full = [IO.Path]::GetFullPath($L1ReviewZipPath)
$l1Sha = (Get-FileHash -LiteralPath $l1Full -Algorithm SHA256).Hash.ToLowerInvariant()
if ($l1Sha -cne $ExpectedL1ReviewSha256) { throw "L1 review ZIP hash mismatch: $l1Sha" }
$l1Receipt = Get-NxbTransitionCertificationZipJson -ZipPath $l1Full -EntryName 'platform-event-certification-receipt.json'
if ([string]$l1Receipt.status -cne 'passed') { throw 'L1 receipt is not passed.' }
if ([string]$l1Receipt.head_sha -cne $ExpectedL1RuntimeHead) { throw 'L1 runtime head mismatch.' }
if ([string]$l1Receipt.l0_binding.binding_fingerprint_sha256 -cne $ExpectedBindingFingerprint) { throw 'L1 binding fingerprint mismatch.' }
if ([string]$l1Receipt.metadata.provider_metadata_fingerprint_sha256 -cne $ExpectedProviderMetadataFingerprint) { throw 'L1 metadata fingerprint mismatch.' }

Write-Information -MessageData '[3/6] Execute two PnP rescans + two reversible power transitions with matched idle controls' -InformationAction Continue
$observationPath = Join-Path $reviewRoot 'platform-transition-observations.json'
& $runtimePath `
    -OutputPath $observationPath `
    -L1ReviewZipPath $l1Full `
    -BindingFingerprintSha256 $ExpectedBindingFingerprint `
    -ProviderMetadataFingerprintSha256 $ExpectedProviderMetadataFingerprint | Out-Null

Write-Information -MessageData '[4/6] Deterministic differential analysis + replay' -InformationAction Continue
$analysisPath = Join-Path $reviewRoot 'platform-transition-eligibility.json'
$replayPath = Join-Path $localRoot 'platform-transition-eligibility-replay.json'
$analysisA = Invoke-NxbTransitionAnalysis -PythonPath $pythonCommand.Source -AnalyzerPath $analyzerPath -InputPath $observationPath -OutputPath $analysisPath
$analysisB = Invoke-NxbTransitionAnalysis -PythonPath $pythonCommand.Source -AnalyzerPath $analyzerPath -InputPath $observationPath -OutputPath $replayPath
$analysisSha = (Get-FileHash -LiteralPath $analysisPath -Algorithm SHA256).Hash.ToLowerInvariant()
$replaySha = (Get-FileHash -LiteralPath $replayPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($analysisSha -cne $replaySha) { throw 'L2 differential analysis replay is not byte-identical.' }
if ([string]$analysisA.status -cne 'passed' -or [string]$analysisB.status -cne 'passed') { throw 'L2 differential analysis did not pass.' }
if ([int]$analysisA.scenario_count -ne 8) { throw 'L2 scenario count is not eight.' }

Write-Information -MessageData '[5/6] Conservative controlled-transition receipt' -InformationAction Continue
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
    predecessor = [ordered]@{
        l1_review_zip_sha256 = $l1Sha
        l1_runtime_head = $ExpectedL1RuntimeHead
        binding_fingerprint_sha256 = $ExpectedBindingFingerprint
        provider_metadata_fingerprint_sha256 = $ExpectedProviderMetadataFingerprint
    }
    execution = [ordered]@{
        scenario_count = 8
        pnp_repeats = 2
        power_repeats = 2
        matched_idle_controls = 4
        analysis_replay_identical = $true
        observation_sha256 = (Get-FileHash -LiteralPath $observationPath -Algorithm SHA256).Hash.ToLowerInvariant()
        analysis_sha256 = $analysisSha
    }
    eligibility = [ordered]@{
        pnp_repeated_positive_delta_shape_count = [int]$analysisA.pnp.repeated_positive_delta_shape_count
        pnp_mapping_eligible = [bool]$analysisA.pnp.mapping_eligible
        power_repeated_positive_delta_shape_count = [int]$analysisA.power.repeated_positive_delta_shape_count
        power_mapping_eligible = [bool]$analysisA.power.mapping_eligible
    }
    claims = [ordered]@{
        controlled_transition_observation_validated = $true
        event_id_semantics = $false
        event_task_opcode_semantics = $false
        device_lifecycle_semantics = $false
        power_causality = $false
        firmware_causality = $false
        root_cause_validated = $false
        continuous_trace_completeness = 'not_claimed'
    }
}
$receiptPath = Join-Path $reviewRoot 'platform-transition-certification-receipt.json'
Write-NxbTransitionCertificationJson -Path $receiptPath -InputObject $receipt

Write-Information -MessageData '[6/6] Bounded review ZIP + raw/system-state boundary audit' -InformationAction Continue
$reviewZipPath = Join-Path $outputFull 'platform-transition-review.zip'
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZipPath -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
try {
    foreach ($entry in $archive.Entries) {
        $lowerName = $entry.FullName.ToLowerInvariant()
        if ($lowerName.EndsWith('.etl') -or $lowerName.EndsWith('.evtx') -or $lowerName.EndsWith('.xml') -or $lowerName.EndsWith('.jsonl') -or $lowerName.EndsWith('.log') -or $lowerName.Contains('raw-event') -or $lowerName.Contains('powercfg-output') -or $lowerName.Contains('pnputil-output')) {
            throw "Forbidden transition review artifact: $($entry.FullName)"
        }
        if ($entry.FullName.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase)) {
            $stream = $entry.Open()
            $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$true)
            try {
                $text = $reader.ReadToEnd()
                foreach ($forbiddenText in @('"message":','"xml":','"payload":','"properties":','"event_data":','"user_data":','"original_scheme_guid":')) {
                    if ($text.IndexOf($forbiddenText,[StringComparison]::OrdinalIgnoreCase) -ge 0) {
                        throw "Forbidden transition review content: entry=$($entry.FullName) token=$forbiddenText"
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
    scenario_count = 8
    pnp_repeats = 2
    power_repeats = 2
    analysis_replay_identical = $true
    pnp_repeated_positive_delta_shape_count = [int]$analysisA.pnp.repeated_positive_delta_shape_count
    pnp_mapping_eligible = [bool]$analysisA.pnp.mapping_eligible
    power_repeated_positive_delta_shape_count = [int]$analysisA.power.repeated_positive_delta_shape_count
    power_mapping_eligible = [bool]$analysisA.power.mapping_eligible
    event_id_semantics = $false
    device_lifecycle_semantics = $false
    power_causality = $false
    firmware_causality = $false
    continuous_trace_completeness = 'not_claimed'
    observation_sha256 = (Get-FileHash -LiteralPath $observationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    analysis_sha256 = $analysisSha
    receipt_sha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    review_zip_sha256 = $reviewSha
    review_zip_path = [IO.Path]::GetFullPath($reviewZipPath)
    local_evidence_root = $outputFull
}
Write-Information -MessageData "SUPERBLOCK 2 L2 transition eligibility passed: pnp_candidates=$($result.pnp_repeated_positive_delta_shape_count) power_candidates=$($result.power_repeated_positive_delta_shape_count)" -InformationAction Continue
if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 16
