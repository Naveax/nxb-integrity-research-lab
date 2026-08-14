[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$L3ReviewZipPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ExpectedL3ReviewSha256 = '2a8ef6942285af0df07cb2e124eaa7edda8dac746a5c756b1a0b133d3a5446b4'
$ExpectedL3RuntimeHead = '9f418cbb5aee79cb88093a5894ed2f68b165a344'
$ExpectedBindingFingerprint = '491e6797eeb1aa1d2b66d1b5d90e3087c52d68cedeae529b75d054f673ea01b7'
$ExpectedProviderMetadataFingerprint = '540635297b3bea77ef403620309f08149fc784cb2698ac238e154ccafaa3fecc'

function Test-NxbL4Administrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-NxbL4CertificationJson {
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

function Invoke-NxbL4Pester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Executable,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TestPath,
        [Parameter(Mandatory)][ValidateRange(1,1000)][int]$ExpectedCount,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-l4-pester-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $childPath = Join-Path $tempRoot 'run.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
$ErrorActionPreference = 'Stop'
Import-Module Pester -ErrorAction Stop
$result = Invoke-Pester -Path $TestPath -PassThru
$summary = [pscustomobject]@{ passed=[int]$result.PassedCount; failed=[int]$result.FailedCount; skipped=[int]$result.SkippedCount; total=[int]$result.TotalCount }
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

function Get-NxbL4ZipJson {
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

function Invoke-NxbL4PythonValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PythonPath,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$ToolPath,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$InputPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath
    )
    $toolOutput = @(& $PythonPath $ToolPath --input $InputPath --output $OutputPath 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    foreach ($line in $toolOutput) { Write-Information -MessageData ([string]$line) -InformationAction Continue }
    if ($exitCode -ne 0) { throw "L4 Python validation failed: exit=$exitCode" }
    return (Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json)
}

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK 2 L4 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK 2 L4 certification requires PowerShell 7.' }
if (-not (Test-NxbL4Administrator)) { throw 'SUPERBLOCK 2 L4 certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw "L4 exact-head mismatch. Expected=$ExpectedHead actual=$currentHead" }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'L4 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'L4 output must remain outside the repository.' }
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }
$reviewRoot = Join-Path $outputFull 'review'
$localRoot = Join-Path $outputFull 'local'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
[IO.Directory]::CreateDirectory($localRoot) | Out-Null

$runtimePath = Join-Path $PSScriptRoot 'Invoke-NxbPlatformDirectStateTransitions.ps1'
$testPath = Join-Path $repositoryRoot 'tests\PlatformDirectStateTransitions.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_platform_direct_state_transitions.py'
foreach ($requiredPath in @($runtimePath,$testPath,$validatorPath,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw "L4 component missing: $requiredPath" }
}

Write-Information -MessageData '=== NXB IRL-004 SUPERBLOCK 2 L4 DIRECT-STATE TRANSITION CERTIFICATION ===' -InformationAction Continue
Write-Information -MessageData '[1/6] Parser/analyzer + dual-runtime 20-test contract' -InformationAction Continue
$analyzerPaths = @($runtimePath,$testPath,$PSCommandPath)
foreach ($scriptPath in $analyzerPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ("PowerShell parser failed: $scriptPath`n" + (@($parseErrors | ForEach-Object { $_.Message }) -join "`n")) }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(foreach ($scriptPath in $analyzerPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($findings.Count -gt 0) { throw ("L4 PSScriptAnalyzer findings: $($findings.Count)`n" + (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")) }
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
& $pythonCommand.Source -m py_compile $validatorPath
if ($LASTEXITCODE -ne 0) { throw 'L4 Python syntax check failed.' }

$previousRoot = [Environment]::GetEnvironmentVariable('NXB_PLATFORM_L4_REPOSITORY_ROOT','Process')
$env:NXB_PLATFORM_L4_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7 = Invoke-NxbL4Pester -Executable $pwshPath -TestPath $testPath -ExpectedCount 20 -Label 'PowerShell 7 L4'
    $ps51 = Invoke-NxbL4Pester -Executable $ps51Path -TestPath $testPath -ExpectedCount 20 -Label 'Windows PowerShell 5.1 L4'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_PLATFORM_L4_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_PLATFORM_L4_REPOSITORY_ROOT = $previousRoot }
}
$ps7Summary = ('{0}/{1}' -f [int]$ps7.passed,[int]$ps7.total)
$ps51Summary = ('{0}/{1}' -f [int]$ps51.passed,[int]$ps51.total)

Write-Information -MessageData '[2/6] Bind canonical SUPERBLOCK 2 L3 native evidence' -InformationAction Continue
$l3Full = [IO.Path]::GetFullPath($L3ReviewZipPath)
$l3Sha = (Get-FileHash -LiteralPath $l3Full -Algorithm SHA256).Hash.ToLowerInvariant()
if ($l3Sha -cne $ExpectedL3ReviewSha256) { throw "L3 review ZIP hash mismatch: $l3Sha" }
$l3Receipt = Get-NxbL4ZipJson -ZipPath $l3Full -EntryName 'transition-surface-certification-receipt.json'
if ([string]$l3Receipt.status -cne 'passed') { throw 'L3 predecessor receipt is not passed.' }
if ([string]$l3Receipt.head_sha -cne $ExpectedL3RuntimeHead) { throw 'L3 runtime head mismatch.' }
if ([string]$l3Receipt.predecessor.binding_fingerprint_sha256 -cne $ExpectedBindingFingerprint) { throw 'L3 binding fingerprint mismatch.' }
if ([string]$l3Receipt.predecessor.provider_metadata_fingerprint_sha256 -cne $ExpectedProviderMetadataFingerprint) { throw 'L3 provider metadata fingerprint mismatch.' }

Write-Information -MessageData '[3/6] Execute two PnP rescans + two direct-state power transitions' -InformationAction Continue
$observationPath = Join-Path $reviewRoot 'platform-direct-state-observations.json'
& $runtimePath `
    -OutputPath $observationPath `
    -BindingFingerprintSha256 $ExpectedBindingFingerprint `
    -ProviderMetadataFingerprintSha256 $ExpectedProviderMetadataFingerprint `
    -L3ReviewZipSha256 $ExpectedL3ReviewSha256 | Out-Null

Write-Information -MessageData '[4/6] Independently validate direct-state evidence' -InformationAction Continue
$validationPath = Join-Path $reviewRoot 'platform-direct-state-validation.json'
$validation = Invoke-NxbL4PythonValidation -PythonPath $pythonCommand.Source -ToolPath $validatorPath -InputPath $observationPath -OutputPath $validationPath
if ([string]$validation.status -cne 'passed') { throw 'L4 validation status is not passed.' }
if (-not [bool]$validation.power_policy_transition_mapping) { throw 'L4 direct power-policy mapping was not validated.' }

Write-Information -MessageData '[5/6] Conservative L4 certification receipt' -InformationAction Continue
$observation = Get-Content -LiteralPath $observationPath -Raw | ConvertFrom-Json
$observationSha = (Get-FileHash -LiteralPath $observationPath -Algorithm SHA256).Hash.ToLowerInvariant()
$validationSha = (Get-FileHash -LiteralPath $validationPath -Algorithm SHA256).Hash.ToLowerInvariant()
$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $ExpectedHead.ToLowerInvariant()
    static_validation = [pscustomobject][ordered]@{
        ps7_tests = $ps7Summary
        ps51_tests = $ps51Summary
        psscriptanalyzer_findings = [int]$findings.Count
        python_syntax = 'passed'
    }
    predecessor = [pscustomobject][ordered]@{
        l3_runtime_head = $ExpectedL3RuntimeHead
        l3_review_zip_sha256 = $ExpectedL3ReviewSha256
        binding_fingerprint_sha256 = $ExpectedBindingFingerprint
        provider_metadata_fingerprint_sha256 = $ExpectedProviderMetadataFingerprint
    }
    pnp = [pscustomobject][ordered]@{
        repeats = 2
        execution_validated = [bool]$observation.pnp.execution_validated
        inventory_stable_both = [bool]$observation.pnp.inventory_stable_both
    }
    power = [pscustomobject][ordered]@{
        repeats = 2
        direct_state_mapping_validated = [bool]$observation.power.direct_state_mapping_validated
    }
    claims = $observation.claims
    observation_sha256 = $observationSha
    validation_sha256 = $validationSha
}
$receiptPath = Join-Path $reviewRoot 'platform-direct-state-certification-receipt.json'
Write-NxbL4CertificationJson -Path $receiptPath -InputObject $receipt
$receiptSha = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Information -MessageData '[6/6] Bounded review ZIP + content boundary audit' -InformationAction Continue
$forbiddenExtensions = '(?i)\.(etl|evtx|xml|jsonl|exe|obj|pdb)$'
$forbiddenContent = '(?i)(PCI\\VEN_|USB\\VID_|ACPI\\[A-Z0-9_]|PNPDeviceID|DeviceID\s*[=:]|"(message|xml|payload|properties|event_data|user_data|raw_event)"\s*:)' 
foreach ($file in @(Get-ChildItem -LiteralPath $reviewRoot -File -Recurse)) {
    if ($file.Name -match $forbiddenExtensions) { throw "Forbidden L4 review artifact: $($file.FullName)" }
    if ($file.Extension -ieq '.json') {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        if ($text -match $forbiddenContent) { throw "Forbidden L4 review artifact content: $($file.FullName)" }
    }
}
$reviewZipPath = "$outputFull-review.zip"
if (Test-Path -LiteralPath $reviewZipPath) { Remove-Item -LiteralPath $reviewZipPath -Force }
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZipPath -CompressionLevel Optimal
$reviewZipSha = (Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $ExpectedHead.ToLowerInvariant()
    ps7_tests = $ps7Summary
    ps51_tests = $ps51Summary
    psscriptanalyzer_findings = [int]$findings.Count
    pnp_repeats = 2
    pnp_execution_validated = [bool]$observation.pnp.execution_validated
    pnp_inventory_stable_both = [bool]$observation.pnp.inventory_stable_both
    power_repeats = 2
    power_policy_transition_mapping = [bool]$observation.power.direct_state_mapping_validated
    pnp_lifecycle_semantics = [bool]$observation.claims.pnp_lifecycle_semantics
    power_causality = [bool]$observation.claims.power_causality
    firmware_causality = [bool]$observation.claims.firmware_causality
    continuous_trace_completeness = [string]$observation.claims.continuous_trace_completeness
    observation_sha256 = $observationSha
    validation_sha256 = $validationSha
    receipt_sha256 = $receiptSha
    review_zip_path = $reviewZipPath
    review_zip_sha256 = $reviewZipSha
}

Write-Information -MessageData ("SUPERBLOCK 2 L4 passed: pnp_stable={0} power_mapping={1}" -f $result.pnp_inventory_stable_both,$result.power_policy_transition_mapping) -InformationAction Continue
if ($PassThru) { return $result }
Write-Output $reviewZipPath