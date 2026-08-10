[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Round1ReviewZipPath,
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Round2ReviewZipPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Round1Head = '2230864433890c2992b59088fe1af3db0c635808'
$Round1ReviewSha256 = '97922ba500a0f66d34a8b8cbda54b34aa7e871af3e3d68d81255bcd8bd39a150'
$Round2Head = '36d962b7c6d42aef6c5034fc42705a78b2ee8bc4'
$Round2ReviewSha256 = 'c7dc5f723af5ea28903efc04a7f45391d7856f06f3d87f43ddc0627bcfafb98a'
$Round2SemanticSummarySha256 = '4f4a55c34469dafcfde14f8fc9ae21efedf6457e19f26674bf25a4ff31eae20c'
$CanonicalCaptureHead = '57dd8a466509bd390b94ad8426b2af6dd56c1687'
$CanonicalCaptureReviewSha256 = '4dbbf73c58d6bb241e3dfb91fb859eb6b4550ef40359f246aa4bfa939a035bf5'
$CanonicalNormalizerHead = '7fd766d15faa9b2ca0197edf342a0f794f4d1f0b'
$CanonicalNormalizerReviewSha256 = 'b5009e314aeed4f20e4daec951ea661255c094638bab697cf5c3aaf0fde13480'
$CanonicalCorrelationHead = '8bb94d10b4a74629668ddee2ad2fe378f8928999'
$CanonicalCorrelationReviewSha256 = '6697c15afc7eefec460b6ae436bb0aee41c2052caabbe980d38ff618f71a1d76'

function Test-NxbFinalAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NxbFinalProperty {
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()][AllowNull()][object]$DefaultValue = $null
    )
    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $DefaultValue }
        if ($current -is [System.Collections.IDictionary]) {
            if ($current.Contains($segment)) { $current = $current[$segment]; continue }
            return $DefaultValue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $DefaultValue }
        $current = $property.Value
    }
    if ($null -eq $current) { return $DefaultValue }
    return $current
}

function ConvertTo-NxbFinalBoolean {
    param(
        [Parameter()][AllowNull()][object]$Value,
        [Parameter()][bool]$DefaultValue = $false
    )
    if ($null -eq $Value) { return $DefaultValue }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) {
        $parsed = $false
        if ([bool]::TryParse([string]$Value,[ref]$parsed)) { return $parsed }
        return $DefaultValue
    }
    try { return [Convert]::ToBoolean($Value,[Globalization.CultureInfo]::InvariantCulture) }
    catch { return $DefaultValue }
}

function Write-NxbFinalJson {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        $Path,
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-NxbFinalSha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-NxbFinalMedian {
    param([Parameter(Mandatory)][double[]]$Values)
    if ($Values.Count -eq 0) { throw 'Median requires at least one value.' }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function Get-NxbFinalIdentity {
    param([Parameter(Mandatory)][string]$PowerPolicyScript)
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $policy = & $PowerPolicyScript -PassThru
    $schemeGuid = [string](Get-NxbFinalProperty -InputObject $policy -Path 'scheme_guid')
    if ($schemeGuid -notmatch '^[0-9a-fA-F-]{36}$') { throw 'Active power-policy GUID is unavailable.' }
    return [pscustomobject][ordered]@{
        machine = [Environment]::MachineName
        boot_utc = ([DateTime]$os.LastBootUpTime).ToUniversalTime().ToString('o')
        power_scheme_guid = $schemeGuid.ToLowerInvariant()
    }
}

function Test-NxbFinalIdentityEqual {
    param(
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][object]$Actual,
        [Parameter(Mandatory)][string]$Label
    )
    foreach ($name in @('machine','boot_utc','power_scheme_guid')) {
        $expectedValue = [string](Get-NxbFinalProperty -InputObject $Expected -Path $name)
        $actualValue = [string](Get-NxbFinalProperty -InputObject $Actual -Path $name)
        if ($expectedValue -cne $actualValue) { throw "$Label identity changed: $name expected=$expectedValue actual=$actualValue" }
    }
}

function Read-NxbFinalZipJson {
    param(
        [Parameter(Mandatory)][string]$ZipPath,
        [Parameter(Mandatory)][string]$EntrySuffix
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $zipEntryMatches = @($archive.Entries | Where-Object { $_.FullName.Replace('\','/').EndsWith($EntrySuffix,[StringComparison]::OrdinalIgnoreCase) })
        if ($zipEntryMatches.Count -ne 1) { throw "Expected exactly one ZIP entry ending with '$EntrySuffix'; found=$($zipEntryMatches.Count)" }
        $stream = $zipEntryMatches[0].Open()
        $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$true)
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) }
        finally { $reader.Dispose(); $stream.Dispose() }
    }
    finally { $archive.Dispose() }
}

function Invoke-NxbFinalPester {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-superblock1-final-pester-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $runnerPath = Join-Path $tempRoot 'run.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
$ErrorActionPreference = 'Stop'
Import-Module Pester -ErrorAction Stop
$r = Invoke-Pester -Path $TestPath -PassThru
[pscustomobject]@{ passed=[int]$r.PassedCount; failed=[int]$r.FailedCount; skipped=[int]$r.SkippedCount; total=[int]$r.TotalCount } | ConvertTo-Json | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($r.PassedCount -ne $ExpectedCount -or $r.TotalCount -ne $ExpectedCount -or $r.FailedCount -ne 0 -or $r.SkippedCount -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $runnerPath -Encoding UTF8
    try {
        $output = @(& $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runnerPath -TestPath $TestPath -ResultPath $resultPath -ExpectedCount $ExpectedCount 2>&1)
        foreach ($line in $output) { Write-Information -MessageData ([string]$line) -InformationAction Continue }
        $exit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        if ($exit -ne 0) { throw "$Label failed: exit=$exit" }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Test-NxbFinalFixtureReceipt {
    param(
        [Parameter(Mandatory)][object]$Receipt,
        [Parameter(Mandatory)][int]$ExpectedPid
    )
    if ([string](Get-NxbFinalProperty -InputObject $Receipt -Path 'status') -cne 'passed') { throw 'Fixture receipt status is not passed.' }
    if ([int](Get-NxbFinalProperty -InputObject $Receipt -Path 'pid' -DefaultValue -1) -ne $ExpectedPid) { throw 'Fixture receipt PID mismatch.' }
    if (-not (ConvertTo-NxbFinalBoolean (Get-NxbFinalProperty -InputObject $Receipt -Path 'stimulus_enabled.gpu'))) { throw 'Fixture GPU stimulus unexpectedly disabled.' }
    if (-not (ConvertTo-NxbFinalBoolean (Get-NxbFinalProperty -InputObject $Receipt -Path 'stimulus_enabled.network'))) { throw 'Fixture network stimulus unexpectedly disabled.' }
    if (-not (ConvertTo-NxbFinalBoolean (Get-NxbFinalProperty -InputObject $Receipt -Path 'stimulus_enabled.explicit_kernel'))) { throw 'Fixture explicit-kernel stimulus unexpectedly disabled.' }
    if (-not (ConvertTo-NxbFinalBoolean (Get-NxbFinalProperty -InputObject $Receipt -Path 'gpu.hardware_device_created'))) { throw 'Hardware D3D11 device was not created.' }
    if ([int](Get-NxbFinalProperty -InputObject $Receipt -Path 'gpu.present_calls_attempted' -DefaultValue -1) -ne 128) { throw 'Fixture Present-attempt count is not 128.' }
    if ([int](Get-NxbFinalProperty -InputObject $Receipt -Path 'gpu.present_calls_succeeded' -DefaultValue -1) -ne 128) { throw 'Fixture Present-success count is not 128.' }
    if (-not (ConvertTo-NxbFinalBoolean (Get-NxbFinalProperty -InputObject $Receipt -Path 'network.loopback_completed'))) { throw 'Fixture loopback did not complete.' }
    if (ConvertTo-NxbFinalBoolean (Get-NxbFinalProperty -InputObject $Receipt -Path 'network.external_network_used' -DefaultValue $true) -DefaultValue $true) { throw 'Fixture used external network.' }
    if ([int64](Get-NxbFinalProperty -InputObject $Receipt -Path 'network.bytes_sent' -DefaultValue -1) -ne 65536) { throw 'Fixture bytes_sent mismatch.' }
    if ([int64](Get-NxbFinalProperty -InputObject $Receipt -Path 'network.bytes_received' -DefaultValue -1) -ne 65536) { throw 'Fixture bytes_received mismatch.' }
    if (ConvertTo-NxbFinalBoolean (Get-NxbFinalProperty -InputObject $Receipt -Path 'kernel_stimulus.registry_write_executed' -DefaultValue $true) -DefaultValue $true) { throw 'Fixture performed a registry write.' }
}

function Invoke-NxbFinalMeasuredFixture {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ReceiptPath
    )
    if (Test-Path -LiteralPath $ReceiptPath) { Remove-Item -LiteralPath $ReceiptPath -Force }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $ExecutablePath -ArgumentList @(('"' + $ReceiptPath + '"'),'all_on') -PassThru
    $peakWorkingSet = [int64]0
    $peakPrivate = [int64]0
    $cpuMilliseconds = [double]0.0
    while (-not $process.HasExited) {
        try {
            $process.Refresh()
            $peakWorkingSet = [Math]::Max($peakWorkingSet,[int64]$process.WorkingSet64)
            $peakPrivate = [Math]::Max($peakPrivate,[int64]$process.PrivateMemorySize64)
            $cpuMilliseconds = [Math]::Max($cpuMilliseconds,[double]$process.TotalProcessorTime.TotalMilliseconds)
        }
        catch { Write-Verbose "Fixture metric sample unavailable: $($_.Exception.Message)" }
        Start-Sleep -Milliseconds 10
    }
    $process.WaitForExit()
    $watch.Stop()
    try {
        $process.Refresh()
        $peakWorkingSet = [Math]::Max($peakWorkingSet,[int64]$process.PeakWorkingSet64)
        $peakPrivate = [Math]::Max($peakPrivate,[int64]$process.PrivateMemorySize64)
        $cpuMilliseconds = [Math]::Max($cpuMilliseconds,[double]$process.TotalProcessorTime.TotalMilliseconds)
    }
    catch { Write-Verbose "Final fixture metric sample unavailable: $($_.Exception.Message)" }
    if ($process.ExitCode -ne 0) { throw "Fixture failed: exit=$($process.ExitCode)" }
    if (-not (Test-Path -LiteralPath $ReceiptPath -PathType Leaf)) { throw 'Fixture produced no receipt.' }
    $receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json
    Test-NxbFinalFixtureReceipt -Receipt $receipt -ExpectedPid $process.Id
    return [pscustomobject][ordered]@{
        pid = [int]$process.Id
        duration_ms = [Math]::Round($watch.Elapsed.TotalMilliseconds,6)
        cpu_time_ms = [Math]::Round($cpuMilliseconds,6)
        peak_working_set_bytes = $peakWorkingSet
        peak_private_bytes = $peakPrivate
        receipt_sha256 = Get-NxbFinalSha256 -Path $ReceiptPath
    }
}

function Invoke-NxbFinalControlArm {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ArmRoot
    )
    [IO.Directory]::CreateDirectory($ArmRoot) | Out-Null
    $receiptPath = Join-Path $ArmRoot 'fixture-receipt.json'
    $measurement = Invoke-NxbFinalMeasuredFixture -ExecutablePath $ExecutablePath -ReceiptPath $receiptPath
    return [pscustomobject][ordered]@{
        kind = 'control'
        measurement = $measurement
        trace_quality = $null
        etl = $null
    }
}

function Invoke-NxbFinalInstrumentedArm {
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$ArmRoot,
        [Parameter(Mandatory)][string]$WprPath,
        [Parameter(Mandatory)][string]$ProfileReference,
        [Parameter(Mandatory)][string]$StatisticsScript,
        [Parameter(Mandatory)][string]$XperfPath
    )
    $tracesRoot = Join-Path $ArmRoot 'traces'
    [IO.Directory]::CreateDirectory($tracesRoot) | Out-Null
    $receiptPath = Join-Path $ArmRoot 'fixture-receipt.json'
    $stagingEtl = Join-Path ([IO.Path]::GetTempPath()) ("nxb-superblock1-overhead-$([guid]::NewGuid().ToString('N')).etl")
    $etlPath = Join-Path $tracesRoot 'performance.etl'
    $sessionOwned = $false
    try {
        $startOutput = @(& $WprPath -start $ProfileReference -filemode 2>&1)
        $startExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        if ($startExit -ne 0) { throw "WPR start failed; pre-existing session untouched. exit=$startExit output=$($startOutput -join ' ')" }
        $sessionOwned = $true
        Start-Sleep -Milliseconds 100
        $measurement = Invoke-NxbFinalMeasuredFixture -ExecutablePath $ExecutablePath -ReceiptPath $receiptPath
        $stopOutput = @(& $WprPath -stop $stagingEtl 2>&1)
        $stopExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        if ($stopExit -ne 0) { throw "WPR stop failed: exit=$stopExit output=$($stopOutput -join ' ')" }
        $sessionOwned = $false
        if (-not (Test-Path -LiteralPath $stagingEtl -PathType Leaf)) { throw 'Instrumented arm produced no ETL.' }
        Move-Item -LiteralPath $stagingEtl -Destination $etlPath -Force
        $stats = & $StatisticsScript -ExperimentPath $ArmRoot -XperfExecutablePath $XperfPath -PassThru
        foreach ($counter in @('events_lost','buffers_lost','buffers_written')) {
            if ([string](Get-NxbFinalProperty -InputObject $stats -Path "$counter.status") -cne 'measured') { throw "Trace counter not measured: $counter" }
        }
        $eventsLost = [uint64](Get-NxbFinalProperty -InputObject $stats -Path 'events_lost.value' -DefaultValue ([uint64]::MaxValue))
        $buffersLost = [uint64](Get-NxbFinalProperty -InputObject $stats -Path 'buffers_lost.value' -DefaultValue ([uint64]::MaxValue))
        $buffersWritten = [uint64](Get-NxbFinalProperty -InputObject $stats -Path 'buffers_written.value' -DefaultValue 0)
        if ($eventsLost -ne 0 -or $buffersLost -ne 0 -or $buffersWritten -eq 0) { throw "Instrumented arm trace quality failed: EventsLost=$eventsLost BuffersLost=$buffersLost BuffersWritten=$buffersWritten" }
        return [pscustomobject][ordered]@{
            kind = 'instrumented'
            measurement = $measurement
            trace_quality = [ordered]@{
                events_lost = $eventsLost
                buffers_lost = $buffersLost
                buffers_written = $buffersWritten
                circular_overwrite = 'unknown'
                trace_completeness = 'not_claimed'
            }
            etl = [ordered]@{
                sha256 = Get-NxbFinalSha256 -Path $etlPath
                length = [int64](Get-Item -LiteralPath $etlPath).Length
            }
        }
    }
    finally {
        if ($sessionOwned) {
            try { & $WprPath -cancel *> $null } catch { Write-Warning "Owned WPR cancel failed: $($_.Exception.Message)" }
        }
        if (Test-Path -LiteralPath $stagingEtl) { Remove-Item -LiteralPath $stagingEtl -Force -ErrorAction SilentlyContinue }
    }
}

function Get-NxbFinalDelta {
    param(
        [Parameter(Mandatory)][double]$Control,
        [Parameter(Mandatory)][double]$Instrumented,
        [Parameter(Mandatory)][string]$Unit
    )
    $absolute = $Instrumented - $Control
    $relative = if ($Control -eq 0.0) { $null } else { ($absolute / $Control) * 100.0 }
    return [ordered]@{
        control = $Control
        instrumented = $Instrumented
        absolute = [Math]::Round($absolute,6)
        relative_percent = if ($null -eq $relative) { $null } else { [Math]::Round([double]$relative,6) }
        unit = $Unit
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK 1 final certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK 1 final certification requires PowerShell 7.' }
if (-not (Test-NxbFinalAdministrator)) { throw 'SUPERBLOCK 1 final certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw "Final certification exact-head mismatch. Expected=$ExpectedHead actual=$currentHead" }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Final certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repoPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if ($outputFull.StartsWith($repoPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Final certification output must remain outside the repository.' }
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }
$rawRoot = Join-Path $outputFull 'raw-local'
$reviewRoot = Join-Path $outputFull 'review'
$buildRoot = Join-Path $rawRoot 'fixture-build'
[IO.Directory]::CreateDirectory($rawRoot) | Out-Null
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null

$testPath = Join-Path $repositoryRoot 'tests\Superblock1FinalCalibration.Tests.ps1'
$buildScript = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1SemanticControlFixtureBuild.ps1'
$profileScript = Join-Path $PSScriptRoot 'Test-NxbSuperblock1MultiDomainWprProfile.ps1'
$statisticsScript = Join-Path $PSScriptRoot 'Get-NxbEtlTraceStatistics.ps1'
$powerPolicyScript = Join-Path $PSScriptRoot 'Get-NxbActivePowerPolicy.ps1'
foreach ($path in @($testPath,$buildScript,$profileScript,$statisticsScript,$powerPolicyScript,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Final certification component missing: $path" }
}

Write-Information -MessageData '=== NXB IRL-004 SUPERBLOCK 1 FINAL CALIBRATION + CLAIM AUDIT ===' -InformationAction Continue
Write-Information -MessageData '[1/7] Exact-head parser/analyzer + PS7/PS5.1 final contract' -InformationAction Continue
$analyzerPaths = @($PSCommandPath,$buildScript,$profileScript,$statisticsScript,$powerPolicyScript,$testPath)
foreach ($scriptPath in $analyzerPaths) {
    $tokens = $null; $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw "PowerShell parser failed: $scriptPath" }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(foreach ($scriptPath in $analyzerPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($findings.Count -gt 0) { throw ("Final PSScriptAnalyzer findings: $($findings.Count)`n" + (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")) }
$previousRoot = [Environment]::GetEnvironmentVariable('NXB_SUPERBLOCK1_FINAL_REPOSITORY_ROOT','Process')
$env:NXB_SUPERBLOCK1_FINAL_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 unavailable.' }
    $ps7 = Invoke-NxbFinalPester -Executable $pwsh -TestPath $testPath -ExpectedCount 18 -Label 'PS7 final contract'
    $ps51 = Invoke-NxbFinalPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 18 -Label 'PS5.1 final contract'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_SUPERBLOCK1_FINAL_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_SUPERBLOCK1_FINAL_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -MessageData '[2/7] Bind canonical Round 1 + Round 2 native review evidence' -InformationAction Continue
$round1Sha = Get-NxbFinalSha256 -Path $Round1ReviewZipPath
$round2Sha = Get-NxbFinalSha256 -Path $Round2ReviewZipPath
if ($round1Sha -cne $Round1ReviewSha256) { throw "Round 1 review ZIP hash mismatch: $round1Sha" }
if ($round2Sha -cne $Round2ReviewSha256) { throw "Round 2 review ZIP hash mismatch: $round2Sha" }
$round1Receipt = Read-NxbFinalZipJson -ZipPath $Round1ReviewZipPath -EntrySuffix 'superblock1-semantic-eligibility-certification-receipt.json'
$round2Receipt = Read-NxbFinalZipJson -ZipPath $Round2ReviewZipPath -EntrySuffix 'superblock1-semantic-controls-certification-receipt.json'
if ([string](Get-NxbFinalProperty -InputObject $round1Receipt -Path 'status') -cne 'passed') { throw 'Round 1 receipt is not passed.' }
if ([string](Get-NxbFinalProperty -InputObject $round2Receipt -Path 'status') -cne 'passed') { throw 'Round 2 receipt is not passed.' }
if ([string](Get-NxbFinalProperty -InputObject $round1Receipt -Path 'head_sha') -cne $Round1Head) { throw 'Round 1 receipt head mismatch.' }
if ([string](Get-NxbFinalProperty -InputObject $round2Receipt -Path 'head_sha') -cne $Round2Head) { throw 'Round 2 receipt head mismatch.' }
if ([string](Get-NxbFinalProperty -InputObject $round2Receipt -Path 'semantic_controls.summary_sha256') -cne $Round2SemanticSummarySha256) { throw 'Round 2 semantic summary hash mismatch.' }
if (-not (ConvertTo-NxbFinalBoolean (Get-NxbFinalProperty -InputObject $round2Receipt -Path 'claims.controlled_present_count_mapping_validated'))) { throw 'Round 2 Present mapping claim missing.' }
if (-not (ConvertTo-NxbFinalBoolean (Get-NxbFinalProperty -InputObject $round2Receipt -Path 'claims.controlled_network_activity_mapping_validated'))) { throw 'Round 2 network mapping claim missing.' }
foreach ($falseClaim in @('present_event_mapping_generalized','present_pairing_semantics','present_success_semantics','tcp_connection_lifecycle_validated','network_latency_semantics','kernel_lifecycle_semantics','registry_operation_semantics','timestamp_unit_resolved','causal_relationship_validated','root_cause_validated')) {
    if (ConvertTo-NxbFinalBoolean (Get-NxbFinalProperty -InputObject $round2Receipt -Path "claims.$falseClaim" -DefaultValue $true) -DefaultValue $true) { throw "Round 2 unexpectedly promoted claim: $falseClaim" }
}

Write-Information -MessageData '[3/7] Build exact-head controlled fixture and resolve WPR profile' -InformationAction Continue
$build = & $buildScript -ExpectedHead $ExpectedHead -OutputDirectory $buildRoot -PassThru
if ([string](Get-NxbFinalProperty -InputObject $build -Path 'status') -cne 'passed') { throw 'Final fixture build did not pass.' }
$fixtureExecutable = [string](Get-NxbFinalProperty -InputObject $build -Path 'executable_path')
if (-not (Test-Path -LiteralPath $fixtureExecutable -PathType Leaf)) { throw 'Final fixture executable missing.' }
$fixtureSha = [string](Get-NxbFinalProperty -InputObject $build -Path 'executable_sha256')
$profileContract = & $profileScript -PassThru
$profilePath = [string](Get-NxbFinalProperty -InputObject $profileContract -Path 'path')
if (-not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { throw 'Final WPR profile unresolved.' }
$profileReference = "$profilePath!NxbSuperblock1MultiDomain.Verbose"
$wpr = (Get-Command wpr.exe -ErrorAction Stop).Source
$xperf = (Get-Command xperf.exe -ErrorAction Stop).Source

Write-Information -MessageData '[4/7] One warmup pair + four alternating measured control/instrumented pairs' -InformationAction Continue
Write-Information -MessageData 'Pre-existing WPR sessions are never auto-cancelled.' -InformationAction Continue
$baselineIdentity = Get-NxbFinalIdentity -PowerPolicyScript $powerPolicyScript
$pairDefinitions = @(
    [pscustomobject][ordered]@{ ordinal=0; warmup=$true; order='control_then_instrumented' },
    [pscustomobject][ordered]@{ ordinal=1; warmup=$false; order='control_then_instrumented' },
    [pscustomobject][ordered]@{ ordinal=2; warmup=$false; order='instrumented_then_control' },
    [pscustomobject][ordered]@{ ordinal=3; warmup=$false; order='control_then_instrumented' },
    [pscustomobject][ordered]@{ ordinal=4; warmup=$false; order='instrumented_then_control' }
)
$pairs = @()
foreach ($definition in $pairDefinitions) {
    $pairRoot = Join-Path $rawRoot ("pair-{0:D2}" -f [int]$definition.ordinal)
    [IO.Directory]::CreateDirectory($pairRoot) | Out-Null
    $beforePair = Get-NxbFinalIdentity -PowerPolicyScript $powerPolicyScript
    Test-NxbFinalIdentityEqual -Expected $baselineIdentity -Actual $beforePair -Label "pair $($definition.ordinal) pre"
    $control = $null
    $instrumented = $null
    if ([string]$definition.order -ceq 'control_then_instrumented') {
        $control = Invoke-NxbFinalControlArm -ExecutablePath $fixtureExecutable -ArmRoot (Join-Path $pairRoot 'control')
        Test-NxbFinalIdentityEqual -Expected $baselineIdentity -Actual (Get-NxbFinalIdentity -PowerPolicyScript $powerPolicyScript) -Label "pair $($definition.ordinal) post-control"
        $instrumented = Invoke-NxbFinalInstrumentedArm -ExecutablePath $fixtureExecutable -ArmRoot (Join-Path $pairRoot 'instrumented') -WprPath $wpr -ProfileReference $profileReference -StatisticsScript $statisticsScript -XperfPath $xperf
    }
    else {
        $instrumented = Invoke-NxbFinalInstrumentedArm -ExecutablePath $fixtureExecutable -ArmRoot (Join-Path $pairRoot 'instrumented') -WprPath $wpr -ProfileReference $profileReference -StatisticsScript $statisticsScript -XperfPath $xperf
        Test-NxbFinalIdentityEqual -Expected $baselineIdentity -Actual (Get-NxbFinalIdentity -PowerPolicyScript $powerPolicyScript) -Label "pair $($definition.ordinal) post-instrumented"
        $control = Invoke-NxbFinalControlArm -ExecutablePath $fixtureExecutable -ArmRoot (Join-Path $pairRoot 'control')
    }
    Test-NxbFinalIdentityEqual -Expected $baselineIdentity -Actual (Get-NxbFinalIdentity -PowerPolicyScript $powerPolicyScript) -Label "pair $($definition.ordinal) post"
    $durationDelta = Get-NxbFinalDelta -Control ([double]$control.measurement.duration_ms) -Instrumented ([double]$instrumented.measurement.duration_ms) -Unit 'ms'
    $cpuDelta = Get-NxbFinalDelta -Control ([double]$control.measurement.cpu_time_ms) -Instrumented ([double]$instrumented.measurement.cpu_time_ms) -Unit 'ms'
    $workingSetDelta = Get-NxbFinalDelta -Control ([double]$control.measurement.peak_working_set_bytes) -Instrumented ([double]$instrumented.measurement.peak_working_set_bytes) -Unit 'bytes'
    $privateDelta = Get-NxbFinalDelta -Control ([double]$control.measurement.peak_private_bytes) -Instrumented ([double]$instrumented.measurement.peak_private_bytes) -Unit 'bytes'
    $pairs += [pscustomobject][ordered]@{
        ordinal = [int]$definition.ordinal
        warmup = [bool]$definition.warmup
        order = [string]$definition.order
        control = $control.measurement
        instrumented = [ordered]@{
            measurement = $instrumented.measurement
            trace_quality = $instrumented.trace_quality
            etl = $instrumented.etl
        }
        deltas = [ordered]@{
            duration = $durationDelta
            cpu_time = $cpuDelta
            peak_working_set = $workingSetDelta
            peak_private_bytes = $privateDelta
        }
    }
}
$measuredPairs = @($pairs | Where-Object { -not $_.warmup })
if ($measuredPairs.Count -ne 4) { throw 'Expected exactly four measured pairs.' }
foreach ($pair in $measuredPairs) {
    if ([uint64]$pair.instrumented.trace_quality.events_lost -ne 0 -or [uint64]$pair.instrumented.trace_quality.buffers_lost -ne 0 -or [uint64]$pair.instrumented.trace_quality.buffers_written -eq 0) { throw "Measured pair $($pair.ordinal) is not loss-free." }
}
$durationAbsoluteValues = [double[]]@($measuredPairs | ForEach-Object { [double]$_.deltas.duration.absolute })
$durationRelativeValues = [double[]]@($measuredPairs | ForEach-Object { if ($null -ne $_.deltas.duration.relative_percent) { [double]$_.deltas.duration.relative_percent } })
$cpuAbsoluteValues = [double[]]@($measuredPairs | ForEach-Object { [double]$_.deltas.cpu_time.absolute })
$workingSetAbsoluteValues = [double[]]@($measuredPairs | ForEach-Object { [double]$_.deltas.peak_working_set.absolute })
$privateAbsoluteValues = [double[]]@($measuredPairs | ForEach-Object { [double]$_.deltas.peak_private_bytes.absolute })
if ($durationRelativeValues.Count -ne 4) { throw 'Duration relative overhead must be measurable for all four pairs.' }
$summary = [ordered]@{
    measured_pair_count = 4
    warmup_pair_count = 1
    successful_pair_count = 4
    failed_pair_count = 0
    ordering = 'alternating_control_instrumented'
    median_duration_delta_ms = [Math]::Round((Get-NxbFinalMedian -Values $durationAbsoluteValues),6)
    median_duration_overhead_percent = [Math]::Round((Get-NxbFinalMedian -Values $durationRelativeValues),6)
    median_cpu_delta_ms = [Math]::Round((Get-NxbFinalMedian -Values $cpuAbsoluteValues),6)
    median_peak_working_set_delta_bytes = [Math]::Round((Get-NxbFinalMedian -Values $workingSetAbsoluteValues),0)
    median_peak_private_delta_bytes = [Math]::Round((Get-NxbFinalMedian -Values $privateAbsoluteValues),0)
    instrumented_loss_free_pairs = 4
}
$calibration = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    fixture_executable_sha256 = $fixtureSha
    identity = $baselineIdentity
    protocol = [ordered]@{
        warmup_pairs = 1
        measured_pairs = 4
        ordering = @('control_then_instrumented','instrumented_then_control','control_then_instrumented','instrumented_then_control')
        workload = 'superblock1-semantic-controls all_on'
        threshold_policy = [ordered]@{
            status = 'not_declared'
            representative_benchmark = $false
            reason = 'Bounded same-machine calibration measures collector cost; it does not define a production acceptance threshold.'
        }
    }
    pairs = @($pairs)
    summary = $summary
    evidence_boundaries = [ordered]@{
        circular_overwrite = 'unknown'
        circular_overwrite_absence = $false
        trace_completeness = 'not_claimed'
        production_representativeness = $false
    }
}
$calibrationPath = Join-Path $reviewRoot 'superblock1-final-overhead-calibration.json'
Write-NxbFinalJson -Path $calibrationPath -InputObject $calibration

Write-Information -MessageData '[5/7] Final conservative claim/evidence audit' -InformationAction Continue
$claimMatrix = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    promoted = [ordered]@{
        controlled_fixture_process = $true
        exact_fixture_pid_attribution = $true
        exact_pid_three_domain_observability = $true
        controlled_present_count_mapping_validated = $true
        controlled_network_activity_mapping_validated = $true
        deterministic_normalization_replay = $true
        deterministic_correlation_replay = $true
        repeated_control_analysis_replay = $true
        bounded_paired_overhead_measured = $true
    }
    withheld = [ordered]@{
        present_event_mapping_generalized = $false
        present_pairing_semantics = $false
        present_success_semantics = $false
        gpu_queue_semantics = $false
        tcp_connection_lifecycle_validated = $false
        network_connection_semantics = $false
        network_latency_semantics = $false
        dns_payload_semantics = $false
        kernel_lifecycle_semantics = $false
        registry_operation_semantics = $false
        timestamp_unit_resolved = $false
        causal_relationship_validated = $false
        root_cause_validated = $false
        circular_overwrite_absence = $false
    }
    trace_completeness = 'not_claimed'
    rationale = [ordered]@{
        present_pairing = 'Round 2 reproduced asymmetric Present Start/Stop field shapes; exact named identifier pairing remains ineligible.'
        kernel_semantics = 'Round 2 kernel_off counts remained close to all_on, so explicit fixture kernel stimulus is not isolated enough for semantic promotion.'
        causality = 'Controlled co-occurrence and ON/OFF differential evidence do not establish causal timing or root cause.'
        overhead = 'Paired overhead is bounded calibration evidence only; no representative production threshold is declared.'
    }
}
$claimMatrixPath = Join-Path $reviewRoot 'superblock1-final-claim-matrix.json'
Write-NxbFinalJson -Path $claimMatrixPath -InputObject $claimMatrix

Write-Information -MessageData '[6/7] Bind predecessor lineage + final receipt' -InformationAction Continue
$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    static_validation = [ordered]@{
        ps7 = [ordered]@{ passed=[int]$ps7.passed; total=[int]$ps7.total }
        ps51 = [ordered]@{ passed=[int]$ps51.passed; total=[int]$ps51.total }
        psscriptanalyzer_findings = $findings.Count
    }
    canonical_predecessors = [ordered]@{
        foundation_capture = [ordered]@{ head=$CanonicalCaptureHead; review_zip_sha256=$CanonicalCaptureReviewSha256 }
        downstream_normalization = [ordered]@{ head=$CanonicalNormalizerHead; review_zip_sha256=$CanonicalNormalizerReviewSha256 }
        structural_correlation = [ordered]@{ head=$CanonicalCorrelationHead; review_zip_sha256=$CanonicalCorrelationReviewSha256 }
        round1_semantic_eligibility = [ordered]@{ head=$Round1Head; review_zip_sha256=$round1Sha; locally_hash_verified=$true; receipt_status='passed' }
        round2_semantic_controls = [ordered]@{ head=$Round2Head; review_zip_sha256=$round2Sha; semantic_summary_sha256=$Round2SemanticSummarySha256; locally_hash_verified=$true; receipt_status='passed' }
    }
    overhead = [ordered]@{
        calibration_sha256 = Get-NxbFinalSha256 -Path $calibrationPath
        summary = $summary
        threshold_policy = 'not_declared'
        representative_benchmark = $false
    }
    claim_matrix_sha256 = Get-NxbFinalSha256 -Path $claimMatrixPath
    final_boundary = [ordered]@{
        circular_overwrite = 'unknown'
        trace_completeness = 'not_claimed'
        causality = $false
        root_cause = $false
    }
}
$receiptPath = Join-Path $reviewRoot 'superblock1-final-certification-receipt.json'
Write-NxbFinalJson -Path $receiptPath -InputObject $receipt

Write-Information -MessageData '[7/7] Bounded final review ZIP + raw boundary audit' -InformationAction Continue
$reviewZipPath = Join-Path $outputFull 'superblock1-final-review.zip'
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZipPath -Force
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
try {
    foreach ($entry in $archive.Entries) {
        $lower = $entry.FullName.ToLowerInvariant()
        if ($lower.EndsWith('.etl') -or $lower.EndsWith('.exe') -or $lower.EndsWith('.obj') -or $lower.EndsWith('.pdb') -or $lower.Contains('fixture-receipt') -or $lower.Contains('xperf') -or $lower.Contains('normalized') -or $lower.Contains('manifest') -or $lower.EndsWith('.wprp')) {
            throw "Forbidden raw/local artifact entered final review ZIP: $($entry.FullName)"
        }
    }
}
finally { $archive.Dispose() }
$reviewZipSha = Get-NxbFinalSha256 -Path $reviewZipPath

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    ps7_tests = '18/18'
    ps51_tests = '18/18'
    psscriptanalyzer_findings = $findings.Count
    warmup_pairs = 1
    measured_pairs = 4
    instrumented_loss_free_pairs = 4
    median_duration_delta_ms = $summary.median_duration_delta_ms
    median_duration_overhead_percent = $summary.median_duration_overhead_percent
    median_cpu_delta_ms = $summary.median_cpu_delta_ms
    median_peak_working_set_delta_bytes = $summary.median_peak_working_set_delta_bytes
    median_peak_private_delta_bytes = $summary.median_peak_private_delta_bytes
    threshold_policy = 'not_declared'
    representative_benchmark = $false
    controlled_present_count_mapping_validated = $true
    controlled_network_activity_mapping_validated = $true
    present_pairing_semantics = $false
    kernel_lifecycle_semantics = $false
    causal_relationship_validated = $false
    root_cause_validated = $false
    circular_overwrite = 'unknown'
    trace_completeness = 'not_claimed'
    calibration_sha256 = Get-NxbFinalSha256 -Path $calibrationPath
    claim_matrix_sha256 = Get-NxbFinalSha256 -Path $claimMatrixPath
    receipt_sha256 = Get-NxbFinalSha256 -Path $receiptPath
    review_zip_sha256 = $reviewZipSha
    review_zip_path = [IO.Path]::GetFullPath($reviewZipPath)
    local_evidence_root = [IO.Path]::GetFullPath($outputFull)
}
Write-Information -MessageData "SUPERBLOCK 1 final certification passed: pairs=4 median_overhead=$($result.median_duration_overhead_percent)%" -InformationAction Continue
if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 20
