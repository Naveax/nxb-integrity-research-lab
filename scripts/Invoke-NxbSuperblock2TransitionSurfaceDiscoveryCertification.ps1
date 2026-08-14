[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$L2ReviewZipPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedL2ReviewSha256 = 'd9c355d631bfa7b9248309bedd8e47d4b46b4b35b162ac3a6a7374dc354efaa4'
$ExpectedL2RuntimeHead = 'ff8bd98ba5c6aa1d223561546f362ebc215640dd'
$ExpectedBindingFingerprint = '491e6797eeb1aa1d2b66d1b5d90e3087c52d68cedeae529b75d054f673ea01b7'
$ExpectedProviderMetadataFingerprint = '540635297b3bea77ef403620309f08149fc784cb2698ac238e154ccafaa3fecc'

function Test-NxbL3Administrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-NxbL3CertificationJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-NxbL3Pester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Executable,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TestPath,
        [Parameter(Mandatory)][ValidateRange(1,1000)][int]$ExpectedCount,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-l3-pester-$([guid]::NewGuid().ToString('N'))")
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
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Get-NxbL3CertificationZipJson {
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

function Invoke-NxbL3PythonTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PythonPath,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ToolPath,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$InputPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label
    )
    $toolOutput = @(& $PythonPath $ToolPath --input $InputPath --output $OutputPath 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    foreach ($line in $toolOutput) { Write-Information -MessageData ([string]$line) -InformationAction Continue }
    if ($exitCode -ne 0) { throw "$Label failed: exit=$exitCode" }
    return (Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json)
}

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK 2 L3 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK 2 L3 certification requires PowerShell 7.' }
if (-not (Test-NxbL3Administrator)) { throw 'SUPERBLOCK 2 L3 certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw "L3 exact-head mismatch. Expected=$ExpectedHead actual=$currentHead" }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'L3 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'L3 output must remain outside the repository.' }
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }
$reviewRoot = Join-Path $outputFull 'review'
$localRoot = Join-Path $outputFull 'local'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
[IO.Directory]::CreateDirectory($localRoot) | Out-Null

$discoveryPath = Join-Path $PSScriptRoot 'Get-NxbTransitionSurfaceDiscovery.ps1'
$replayPath = Join-Path $PSScriptRoot 'Invoke-NxbPlatformSurfaceDiscoveryReplay.ps1'
$testPath = Join-Path $repositoryRoot 'tests\PlatformTransitionSurfaceDiscovery.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_transition_surface_discovery.py'
$analysisToolPath = Join-Path $repositoryRoot 'tools\analyze_platform_transition_eligibility.py'
foreach ($requiredPath in @($discoveryPath,$replayPath,$testPath,$validatorPath,$analysisToolPath,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "L3 component missing: $requiredPath" }
}

Write-Information -MessageData '=== NXB IRL-004 SUPERBLOCK 2 L3 TRANSITION SURFACE DISCOVERY ===' -InformationAction Continue
Write-Information -MessageData '[1/7] Parser/analyzer + dual-runtime 24-test contract' -InformationAction Continue
$analyzerPaths = @($discoveryPath,$replayPath,$testPath,$PSCommandPath)
foreach ($scriptPath in $analyzerPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ("PowerShell parser failed: $scriptPath`n" + (@($parseErrors | ForEach-Object { $_.Message }) -join "`n")) }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(foreach ($scriptPath in $analyzerPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($findings.Count -gt 0) { throw ("L3 PSScriptAnalyzer findings: $($findings.Count)`n" + (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")) }
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
& $pythonCommand.Source -m py_compile $validatorPath $analysisToolPath
if ($LASTEXITCODE -ne 0) { throw 'L3 Python syntax check failed.' }

$previousRoot = [Environment]::GetEnvironmentVariable('NXB_PLATFORM_L3_REPOSITORY_ROOT','Process')
$env:NXB_PLATFORM_L3_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7 = Invoke-NxbL3Pester -Executable $pwshPath -TestPath $testPath -ExpectedCount 24 -Label 'PowerShell 7 L3'
    $ps51 = Invoke-NxbL3Pester -Executable $ps51Path -TestPath $testPath -ExpectedCount 24 -Label 'Windows PowerShell 5.1 L3'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_PLATFORM_L3_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_PLATFORM_L3_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -MessageData '[2/7] Bind canonical SUPERBLOCK 2 L2 native evidence' -InformationAction Continue
$l2Full = [IO.Path]::GetFullPath($L2ReviewZipPath)
$l2Sha = (Get-FileHash -LiteralPath $l2Full -Algorithm SHA256).Hash.ToLowerInvariant()
if ($l2Sha -cne $ExpectedL2ReviewSha256) { throw "L2 review ZIP hash mismatch: $l2Sha" }
$l2Receipt = Get-NxbL3CertificationZipJson -ZipPath $l2Full -EntryName 'platform-transition-certification-receipt.json'
if ([string]$l2Receipt.status -cne 'passed') { throw 'L2 predecessor receipt is not passed.' }
if ([string]$l2Receipt.head_sha -cne $ExpectedL2RuntimeHead) { throw 'L2 runtime head mismatch.' }
if ([string]$l2Receipt.predecessor.binding_fingerprint_sha256 -cne $ExpectedBindingFingerprint) { throw 'L2 binding fingerprint mismatch.' }
if ([string]$l2Receipt.predecessor.provider_metadata_fingerprint_sha256 -cne $ExpectedProviderMetadataFingerprint) { throw 'L2 metadata fingerprint mismatch.' }
Write-Information -MessageData '[3/7] Collect + independently validate transition-surface discovery A/B' -InformationAction Continue
$discoveryAPath = Join-Path $reviewRoot 'transition-surface-discovery-a.json'
$discoveryBPath = Join-Path $reviewRoot 'transition-surface-discovery-b.json'
$validationAPath = Join-Path $reviewRoot 'transition-surface-validation-a.json'
$validationBPath = Join-Path $reviewRoot 'transition-surface-validation-b.json'
& $discoveryPath -OutputPath $discoveryAPath -BindingFingerprintSha256 $ExpectedBindingFingerprint -ProviderMetadataFingerprintSha256 $ExpectedProviderMetadataFingerprint | Out-Null
$validationA = Invoke-NxbL3PythonTool -PythonPath $pythonCommand.Source -ToolPath $validatorPath -InputPath $discoveryAPath -OutputPath $validationAPath -Label 'L3 discovery A validation'
Start-Sleep -Milliseconds 250
& $discoveryPath -OutputPath $discoveryBPath -BindingFingerprintSha256 $ExpectedBindingFingerprint -ProviderMetadataFingerprintSha256 $ExpectedProviderMetadataFingerprint | Out-Null
$validationB = Invoke-NxbL3PythonTool -PythonPath $pythonCommand.Source -ToolPath $validatorPath -InputPath $discoveryBPath -OutputPath $validationBPath -Label 'L3 discovery B validation'
if ([string]$validationA.discovery_fingerprint_sha256 -cne [string]$validationB.discovery_fingerprint_sha256) { throw 'L3 discovery fingerprint changed between snapshots.' }
if ([int]$validationA.pnp_usable_surface_count -lt 1 -or [int]$validationA.power_usable_surface_count -lt 1) { throw 'L3 discovery did not expose both PnP and power usable surfaces.' }

Write-Information -MessageData '[4/7] Replay matched controls + controlled stimuli on discovered surfaces' -InformationAction Continue
$observationPath = Join-Path $reviewRoot 'transition-surface-observations.json'
& $replayPath -OutputPath $observationPath -DiscoveryPath $discoveryAPath -L2ReviewZipPath $l2Full -BindingFingerprintSha256 $ExpectedBindingFingerprint -ProviderMetadataFingerprintSha256 $ExpectedProviderMetadataFingerprint | Out-Null

Write-Information -MessageData '[5/7] Deterministic differential analysis + replay' -InformationAction Continue
$analysisPath = Join-Path $reviewRoot 'transition-surface-analysis.json'
$analysisReplayPath = Join-Path $localRoot 'transition-surface-analysis-replay.json'
$analysisA = Invoke-NxbL3PythonTool -PythonPath $pythonCommand.Source -ToolPath $analysisToolPath -InputPath $observationPath -OutputPath $analysisPath -Label 'L3 differential analysis A'
$null = Invoke-NxbL3PythonTool -PythonPath $pythonCommand.Source -ToolPath $analysisToolPath -InputPath $observationPath -OutputPath $analysisReplayPath -Label 'L3 differential analysis B'
$analysisSha = (Get-FileHash -LiteralPath $analysisPath -Algorithm SHA256).Hash.ToLowerInvariant()
$analysisReplaySha = (Get-FileHash -LiteralPath $analysisReplayPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($analysisSha -cne $analysisReplaySha) { throw 'L3 analysis replay mismatch.' }

Write-Information -MessageData '[6/7] Conservative L3 certification receipt' -InformationAction Continue
$observation = Get-Content -LiteralPath $observationPath -Raw | ConvertFrom-Json
$powerStimuli = @($observation.scenarios | Where-Object { $_.scenario_type -ceq 'power_transition' } | ForEach-Object { $_.stimulus })
if ($powerStimuli.Count -ne 2 -or @($powerStimuli | Where-Object { -not [bool]$_.original_scheme_restored -or -not [bool]$_.temporary_scheme_deleted }).Count -ne 0) { throw 'L3 power restore/delete contract failed.' }
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
        l2_review_zip_sha256 = $l2Sha
        l2_runtime_head = $ExpectedL2RuntimeHead
        binding_fingerprint_sha256 = $ExpectedBindingFingerprint
        provider_metadata_fingerprint_sha256 = $ExpectedProviderMetadataFingerprint
    }
    discovery = [ordered]@{
        fingerprint_sha256 = [string]$validationA.discovery_fingerprint_sha256
        fingerprint_stable = $true
        provider_count = [int]$validationA.provider_count
        surface_count = [int]$validationA.surface_count
        usable_surface_count = [int]$validationA.usable_surface_count
        pnp_usable_surface_count = [int]$validationA.pnp_usable_surface_count
        power_usable_surface_count = [int]$validationA.power_usable_surface_count
    }
    execution = [ordered]@{
        scenario_count = 8
        pnp_repeats = 2
        power_repeats = 2
        power_restore_delete_validated = $true
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
        discovery_backed_transition_observation_validated = $true
        event_id_semantics = $false
        event_task_opcode_semantics = $false
        device_lifecycle_semantics = $false
        power_causality = $false
        firmware_causality = $false
        root_cause_validated = $false
        continuous_trace_completeness = 'not_claimed'
    }
}
$receiptPath = Join-Path $reviewRoot 'transition-surface-certification-receipt.json'
Write-NxbL3CertificationJson -Path $receiptPath -InputObject $receipt

Write-Information -MessageData '[7/7] Bounded review ZIP + raw/system-state boundary audit' -InformationAction Continue
$reviewFiles = @($discoveryAPath,$discoveryBPath,$validationAPath,$validationBPath,$observationPath,$analysisPath,$receiptPath)
foreach ($reviewFile in $reviewFiles) {
    $name = [IO.Path]::GetFileName($reviewFile)
    if ($name -match '(?i)\.(etl|evtx|xml|jsonl|exe|obj|pdb)$') { throw "Forbidden L3 review artifact: $name" }
    $text = Get-Content -LiteralPath $reviewFile -Raw
    if ($text -match '(?i)"(message|xml|payload|properties|event_data|user_data|raw_event)"\s*:') { throw "Forbidden L3 review artifact content: $name" }
}
$reviewZipPath = Join-Path $outputFull 'superblock2-transition-surface-discovery-review.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $reviewZipPath) { Remove-Item -LiteralPath $reviewZipPath -Force }
$archive = [IO.Compression.ZipFile]::Open($reviewZipPath,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($reviewFile in $reviewFiles) { [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$reviewFile,[IO.Path]::GetFileName($reviewFile)) | Out-Null }
}
finally { $archive.Dispose() }
$reviewZipSha = (Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
$receiptSha = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Information -MessageData ("SUPERBLOCK 2 L3 passed: providers={0} usable={1} pnp_candidates={2} power_candidates={3}" -f $validationA.provider_count,$validationA.usable_surface_count,$analysisA.pnp.repeated_positive_delta_shape_count,$analysisA.power.repeated_positive_delta_shape_count) -InformationAction Continue

if ($PassThru) {
    return [pscustomobject][ordered]@{
        status = 'passed'
        head_sha = $currentHead
        ps7_tests = ('{0}/{1}' -f $ps7.passed,$ps7.total)
        ps51_tests = ('{0}/{1}' -f $ps51.passed,$ps51.total)
        psscriptanalyzer_findings = $findings.Count
        discovery_fingerprint_sha256 = [string]$validationA.discovery_fingerprint_sha256
        discovery_fingerprint_stable = $true
        provider_count = [int]$validationA.provider_count
        surface_count = [int]$validationA.surface_count
        usable_surface_count = [int]$validationA.usable_surface_count
        pnp_usable_surface_count = [int]$validationA.pnp_usable_surface_count
        power_usable_surface_count = [int]$validationA.power_usable_surface_count
        scenario_count = 8
        pnp_repeats = 2
        power_repeats = 2
        power_restore_delete_validated = $true
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
        observation_sha256 = [string]$receipt.execution.observation_sha256
        analysis_sha256 = $analysisSha
        receipt_sha256 = $receiptSha
        review_zip_path = $reviewZipPath
        review_zip_sha256 = $reviewZipSha
    }
}