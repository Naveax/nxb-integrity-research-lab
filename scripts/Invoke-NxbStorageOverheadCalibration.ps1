[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateRange(2, 10)]
    [int]$PairCount = 4,

    [Parameter()]
    [ValidateRange(0, 2)]
    [int]$WarmupPairs = 1,

    [Parameter()]
    [ValidateRange(1, 16)]
    [int]$FileSizeMiB = 4,

    [Parameter()]
    [ValidateRange(64, 1024)]
    [int]$BlockSizeKiB = 256,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbStorageCalibrationAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NxbStorageCalibrationMedian {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $ordered = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($ordered.Count / 2)
    if (($ordered.Count % 2) -eq 1) { return [double]$ordered[$middle] }
    return ([double]$ordered[$middle - 1] + [double]$ordered[$middle]) / 2.0
}

function Write-NxbStorageCalibrationJson {
    param([string]$Path, [object]$InputObject)
    [IO.File]::WriteAllText(
        $Path,
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-NxbStorageCalibrationWorkload {
    param(
        [string]$PwshPath,
        [string]$WorkloadPath,
        [string]$TrialRoot,
        [int]$FileSizeMiB,
        [int]$BlockSizeKiB
    )

    [IO.Directory]::CreateDirectory($TrialRoot) | Out-Null
    $fixtureRoot = Join-Path $TrialRoot 'fixture'
    $receiptPath = Join-Path $TrialRoot 'workload-receipt.json'
    $arguments = @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$WorkloadPath,
        '-OutputDirectory',$fixtureRoot,
        '-FileSizeMiB',[string]$FileSizeMiB,
        '-BlockSizeKiB',[string]$BlockSizeKiB,
        '-ReceiptPath',$receiptPath
    )

    $wall = [Diagnostics.Stopwatch]::StartNew()
    $process = Start-Process -FilePath $PwshPath -ArgumentList $arguments -PassThru -WindowStyle Hidden
    try {
        if (-not $process.WaitForExit(15000)) {
            try {
                $process.Kill()
            }
            catch {
                Write-Warning "Timed-out calibration workload could not be killed: $($_.Exception.Message)"
            }
            throw 'Bounded storage calibration workload exceeded the 15 second timeout.'
        }
        $wall.Stop()
        if ($process.ExitCode -ne 0) {
            throw "Bounded storage calibration workload failed: exit=$($process.ExitCode)"
        }

        $cpuMs = $null
        $peakWorkingSet = $null
        try {
            $cpuMs = [Math]::Round($process.TotalProcessorTime.TotalMilliseconds, 3)
        }
        catch {
            Write-Verbose "Process CPU time unavailable: $($_.Exception.Message)"
        }
        try {
            $peakWorkingSet = [int64]$process.PeakWorkingSet64
        }
        catch {
            Write-Verbose "Peak working set unavailable: $($_.Exception.Message)"
        }
    }
    finally {
        if ($wall.IsRunning) { $wall.Stop() }
        $process.Dispose()
    }

    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw 'Storage calibration workload receipt was not produced.'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ([string]$receipt.status -cne 'passed' -or
        [int64]$receipt.bytes_written -ne ([int64]$FileSizeMiB * 1MB) -or
        [int64]$receipt.bytes_read -ne ([int64]$FileSizeMiB * 1MB) -or
        -not [bool]$receipt.renamed -or
        -not [bool]$receipt.deleted) {
        throw 'Storage calibration workload receipt failed bounded integrity checks.'
    }

    return [pscustomobject][ordered]@{
        fixture_duration_ms = [double]$receipt.duration_ms
        process_wall_ms = [Math]::Round($wall.Elapsed.TotalMilliseconds, 3)
        process_cpu_ms = $cpuMs
        peak_working_set_bytes = $peakWorkingSet
        bytes_written = [int64]$receipt.bytes_written
        bytes_read = [int64]$receipt.bytes_read
        flush_count = [int]$receipt.flush_count
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Storage overhead calibration requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Storage overhead calibration requires PowerShell 7.' }
if (-not (Test-NxbStorageCalibrationAdministrator)) { throw 'Storage overhead calibration requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Storage overhead calibration requires a clean exact-head worktree.'
}

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }
[IO.Directory]::CreateDirectory($outputFull) | Out-Null

$workloadPath = Join-Path $PSScriptRoot 'Invoke-NxbStorageHeaderProbeWorkload.ps1'
$profileValidator = Join-Path $PSScriptRoot 'Test-NxbStorageWprProfile.ps1'
$etlAccounting = Join-Path $PSScriptRoot 'Invoke-NxbStorageEtlHeaderAccounting.ps1'
foreach ($required in @($workloadPath,$profileValidator,$etlAccounting,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Storage calibration dependency missing: $required" }
}

$wpr = Get-Command wpr.exe -ErrorAction Stop
$pwsh = Get-Command pwsh.exe -ErrorAction Stop
$storageProfile = & $profileValidator -PassThru
if ([bool]$storageProfile.KernelQueueEnabled) { throw 'KernelQueue must remain disabled for storage calibration.' }
$profileReference = "$($storageProfile.Path)!NxbStorageIOQueue.Verbose"

$trials = [Collections.Generic.List[object]]::new()
$startedUtc = [DateTime]::UtcNow
$wprStarted = $false

function Invoke-NxbCalibrationTrial {
    param([string]$Mode, [int]$PairIndex, [int]$OrderIndex, [bool]$Warmup)

    $label = if ($Warmup) { "warmup-$PairIndex-$Mode" } else { "pair-$PairIndex-$Mode" }
    $trialRoot = Join-Path $outputFull $label
    [IO.Directory]::CreateDirectory($trialRoot) | Out-Null
    $etlPath = $null
    $accounting = $null

    try {
        if ($Mode -ceq 'instrumented') {
            $startOutput = @(& $wpr.Source -start $profileReference -filemode 2>&1)
            $startExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
            if ($startExit -ne 0) {
                throw ('WPR start failed. A pre-existing WPR session is never auto-cancelled. ' +
                    "exit=$startExit output=$($startOutput -join ' ')")
            }
            $script:wprStarted = $true
            Start-Sleep -Milliseconds 250
        }

        $workload = Invoke-NxbStorageCalibrationWorkload `
            -PwshPath $pwsh.Source `
            -WorkloadPath $workloadPath `
            -TrialRoot $trialRoot `
            -FileSizeMiB $FileSizeMiB `
            -BlockSizeKiB $BlockSizeKiB

        if ($Mode -ceq 'instrumented') {
            $etlPath = Join-Path $trialRoot 'storage-calibration.etl'
            $stopOutput = @(& $wpr.Source -stop $etlPath 2>&1)
            $stopExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
            $script:wprStarted = $false
            if ($stopExit -ne 0 -or -not (Test-Path -LiteralPath $etlPath -PathType Leaf)) {
                throw "WPR stop failed: exit=$stopExit output=$($stopOutput -join ' ')"
            }

            $etlSha = (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant()
            $captureReceiptPath = Join-Path $trialRoot 'calibration-capture-receipt.json'
            Write-NxbStorageCalibrationJson -Path $captureReceiptPath -InputObject ([ordered]@{
                schema_version = 1
                status = 'passed'
                head_sha = $currentHead
                profile = [ordered]@{
                    sha256 = [string]$storageProfile.Sha256
                    file_mode = [string]$storageProfile.FileMode
                    maximum_file_size_mib = [int]$storageProfile.MaximumFileSizeMiB
                }
                evidence = [ordered]@{ etl_sha256 = $etlSha }
            })
            $accountingPath = Join-Path $trialRoot 'etl-accounting.json'
            $accounting = & $etlAccounting `
                -ExpectedHead $currentHead `
                -CaptureReceiptPath $captureReceiptPath `
                -EtlPath $etlPath `
                -OutputPath $accountingPath `
                -PassThru

            if ([string]$accounting.trace_loss.state -cne 'none' -or
                [uint64]$accounting.native_header.events_lost -ne 0 -or
                [uint64]$accounting.native_header.buffers_lost -ne 0 -or
                [string]$accounting.circular.risk_classification -cne 'no_risk_observed' -or
                [string]$accounting.circular.overwrite_state -cne 'unknown' -or
                [string]$accounting.claims.capture_completeness -cne 'not_claimed') {
                throw 'Instrumented calibration trace-quality gate failed.'
            }
        }

        return [pscustomobject][ordered]@{
            mode = $Mode
            warmup = $Warmup
            pair_index = $PairIndex
            order_index = $OrderIndex
            fixture_duration_ms = [double]$workload.fixture_duration_ms
            process_wall_ms = [double]$workload.process_wall_ms
            process_cpu_ms = $workload.process_cpu_ms
            peak_working_set_bytes = $workload.peak_working_set_bytes
            trace_loss = if ($null -eq $accounting) { 'not_applicable' } else { [string]$accounting.trace_loss.state }
            events_lost = if ($null -eq $accounting) { $null } else { [uint64]$accounting.native_header.events_lost }
            buffers_lost = if ($null -eq $accounting) { $null } else { [uint64]$accounting.native_header.buffers_lost }
            circular_risk = if ($null -eq $accounting) { 'not_applicable' } else { [string]$accounting.circular.risk_classification }
            circular_utilization_ratio = if ($null -eq $accounting) { $null } else { [double]$accounting.circular.utilization_ratio }
            etl_sha256 = if ($null -eq $etlPath) { $null } else { (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant() }
        }
    }
    catch {
        if ($script:wprStarted) {
            try {
                & $wpr.Source -cancel 2>&1 | Out-Null
            }
            catch {
                Write-Warning "WPR cleanup cancel failed after calibration trial error: $($_.Exception.Message)"
            }
            $script:wprStarted = $false
        }
        throw
    }
}

try {
    for ($warmupIndex = 1; $warmupIndex -le $WarmupPairs; $warmupIndex++) {
        foreach ($mode in @('control','instrumented')) {
            $trials.Add((Invoke-NxbCalibrationTrial -Mode $mode -PairIndex $warmupIndex -OrderIndex 0 -Warmup $true))
            Start-Sleep -Milliseconds 150
        }
    }

    for ($pair = 1; $pair -le $PairCount; $pair++) {
        $order = if (($pair % 2) -eq 1) { @('control','instrumented') } else { @('instrumented','control') }
        for ($orderIndex = 0; $orderIndex -lt $order.Count; $orderIndex++) {
            $trials.Add((Invoke-NxbCalibrationTrial -Mode $order[$orderIndex] -PairIndex $pair -OrderIndex ($orderIndex + 1) -Warmup $false))
            Start-Sleep -Milliseconds 150
        }
    }
}
finally {
    if ($wprStarted) {
        try {
            & $wpr.Source -cancel 2>&1 | Out-Null
        }
        catch {
            Write-Warning "WPR final cleanup cancel failed: $($_.Exception.Message)"
        }
        $wprStarted = $false
    }
}

$measured = @($trials | Where-Object { -not [bool]$_.warmup })
$pairs = [Collections.Generic.List[object]]::new()
for ($pair = 1; $pair -le $PairCount; $pair++) {
    $control = @($measured | Where-Object { $_.pair_index -eq $pair -and $_.mode -ceq 'control' })
    $instrumented = @($measured | Where-Object { $_.pair_index -eq $pair -and $_.mode -ceq 'instrumented' })
    if ($control.Count -ne 1 -or $instrumented.Count -ne 1) { throw "Pair $pair is incomplete." }

    $durationDelta = [double]$instrumented[0].fixture_duration_ms - [double]$control[0].fixture_duration_ms
    $durationRatio = [double]$instrumented[0].fixture_duration_ms / [double]$control[0].fixture_duration_ms
    $cpuDelta = if ($null -eq $control[0].process_cpu_ms -or $null -eq $instrumented[0].process_cpu_ms) { $null } else { [double]$instrumented[0].process_cpu_ms - [double]$control[0].process_cpu_ms }
    $workingSetDelta = if ($null -eq $control[0].peak_working_set_bytes -or $null -eq $instrumented[0].peak_working_set_bytes) { $null } else { [int64]$instrumented[0].peak_working_set_bytes - [int64]$control[0].peak_working_set_bytes }

    $pairs.Add([pscustomobject][ordered]@{
        pair_index = $pair
        order = if ($control[0].order_index -lt $instrumented[0].order_index) { 'control_then_instrumented' } else { 'instrumented_then_control' }
        control_fixture_duration_ms = [double]$control[0].fixture_duration_ms
        instrumented_fixture_duration_ms = [double]$instrumented[0].fixture_duration_ms
        fixture_duration_delta_ms = [Math]::Round($durationDelta, 6)
        fixture_duration_ratio = [Math]::Round($durationRatio, 9)
        fixture_duration_overhead_percent = [Math]::Round(($durationRatio - 1.0) * 100.0, 6)
        process_cpu_delta_ms = $cpuDelta
        peak_working_set_delta_bytes = $workingSetDelta
        instrumented_events_lost = [uint64]$instrumented[0].events_lost
        instrumented_buffers_lost = [uint64]$instrumented[0].buffers_lost
        instrumented_circular_risk = [string]$instrumented[0].circular_risk
        instrumented_circular_utilization_ratio = [double]$instrumented[0].circular_utilization_ratio
    })
}

$durationDeltas = [double[]]@($pairs | ForEach-Object { [double]$_.fixture_duration_delta_ms })
$durationRatios = [double[]]@($pairs | ForEach-Object { [double]$_.fixture_duration_ratio })
$cpuDeltas = [double[]]@($pairs | Where-Object { $null -ne $_.process_cpu_delta_ms } | ForEach-Object { [double]$_.process_cpu_delta_ms })
$workingSetDeltas = [double[]]@($pairs | Where-Object { $null -ne $_.peak_working_set_delta_bytes } | ForEach-Object { [double]$_.peak_working_set_delta_bytes })

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    started_utc = $startedUtc.ToString('o')
    stopped_utc = [DateTime]::UtcNow.ToString('o')
    configuration = [ordered]@{
        warmup_pairs = $WarmupPairs
        measured_pairs = $PairCount
        alternating_order = $true
        file_size_mib = $FileSizeMiB
        block_size_kib = $BlockSizeKiB
        cache_state_controlled = $false
    }
    summary = [ordered]@{
        median_fixture_duration_delta_ms = Get-NxbStorageCalibrationMedian -Values $durationDeltas
        median_fixture_duration_ratio = Get-NxbStorageCalibrationMedian -Values $durationRatios
        median_fixture_duration_overhead_percent = ((Get-NxbStorageCalibrationMedian -Values $durationRatios) - 1.0) * 100.0
        median_process_cpu_delta_ms = if ($cpuDeltas.Count -eq 0) { $null } else { Get-NxbStorageCalibrationMedian -Values $cpuDeltas }
        median_peak_working_set_delta_bytes = if ($workingSetDeltas.Count -eq 0) { $null } else { Get-NxbStorageCalibrationMedian -Values $workingSetDeltas }
        instrumented_loss_free_pairs = @($pairs | Where-Object { $_.instrumented_events_lost -eq 0 -and $_.instrumented_buffers_lost -eq 0 }).Count
        production_threshold_policy = 'not_declared'
        representative_benchmark = $false
    }
    pairs = @($pairs)
    trials = @($trials)
    claims = [ordered]@{
        overhead_measured = $true
        production_overhead_threshold_declared = $false
        representative_throughput = $false
        representative_iops = $false
        queue_depth_semantics = $false
        queue_latency_semantics = $false
        service_time_semantics = $false
        trace_completeness = 'not_claimed'
    }
}

$resultPath = Join-Path $outputFull 'storage-overhead-calibration.json'
Write-NxbStorageCalibrationJson -Path $resultPath -InputObject $result

$postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
    throw 'Storage overhead calibration dirtied the exact-head worktree.'
}

Write-Information -MessageData "Storage overhead calibration passed: $currentHead" -InformationAction Continue
Write-Information -MessageData "Measured pairs: $PairCount" -InformationAction Continue
Write-Information -MessageData "Median fixture duration overhead: $([Math]::Round([double]$result.summary.median_fixture_duration_overhead_percent, 3))%" -InformationAction Continue
Write-Information -MessageData "Instrumented loss-free pairs: $($result.summary.instrumented_loss_free_pairs)/$PairCount" -InformationAction Continue
Write-Information -MessageData 'Production threshold policy: not_declared' -InformationAction Continue

if ($PassThru) { return $result }
