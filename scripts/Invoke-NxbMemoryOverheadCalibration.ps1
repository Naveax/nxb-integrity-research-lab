[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$LabRoot = 'C:\NXB-Lab',

    [Parameter()]
    [ValidateRange(1, 20)]
    [int]$RepetitionCount = 3,

    [Parameter()]
    [ValidateRange(0, 5)]
    [int]$WarmupCount = 1,

    [Parameter()]
    [ValidateSet(
        'alternating_control_first',
        'alternating_capture_first',
        'control_then_capture',
        'capture_then_control'
    )]
    [string]$Ordering = 'alternating_control_first',

    [Parameter()]
    [ValidateRange(4, 128)]
    [int]$PrivateMemoryMiB = 32,

    [Parameter()]
    [ValidateRange(1, 64)]
    [int]$MappedFileMiB = 8,

    [Parameter()]
    [ValidateRange(0, 3000)]
    [int]$HoldMilliseconds = 1000,

    [Parameter()]
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 30,

    [Parameter()]
    [ValidateRange(10, 1000)]
    [int]$SampleIntervalMilliseconds = 25,

    [Parameter()]
    [ValidateRange(0, 60)]
    [int]$CooldownSeconds = 1,

    [Parameter()]
    [string]$WprExecutablePath,

    [Parameter()]
    [string]$PowerShellExecutablePath,

    [Parameter()]
    [string]$PowerCfgExecutablePath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

function Get-NxbMemoryCalibrationMetric {
    [CmdletBinding(DefaultParameterSetName = 'Measured')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Measured')]
        [double]$Value,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Unit,

        [Parameter(Mandatory, ParameterSetName = 'Unavailable')]
        [ValidateSet('unsupported', 'failed')]
        [string]$Status,

        [Parameter(Mandatory, ParameterSetName = 'Unavailable')]
        [ValidateNotNullOrEmpty()]
        [string]$Reason
    )

    if ($PSCmdlet.ParameterSetName -eq 'Measured') {
        return [ordered]@{
            status = 'measured'
            value = $Value
            unit = $Unit
            reason = $null
        }
    }

    return [ordered]@{
        status = $Status
        value = $null
        unit = $Unit
        reason = $Reason
    }
}

function Get-NxbMemoryCalibrationIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$Path
    )

    $capabilityPath = Join-Path $Path 'baseline\system-capabilities.json'
    if (-not (Test-Path -LiteralPath $capabilityPath -PathType Leaf)) {
        [void](& (Join-Path $PSScriptRoot 'Get-SystemCapabilities.ps1') `
            -ExperimentPath $Path)
    }

    $identityPath = Join-Path $Path 'baseline\observation-identity.json'
    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        [void](& (Join-Path $PSScriptRoot 'Get-ObservationIdentity.ps1') `
            -ExperimentPath $Path)
    }

    & (Join-Path $PSScriptRoot 'Test-ObservationIdentity.ps1') `
        -ExperimentPath $Path

    return Read-NxbJson -Path $identityPath
}

function Get-NxbMemoryCalibrationPowerPolicy {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ExplicitPath
    )

    return & (Join-Path $PSScriptRoot 'Get-NxbActivePowerPolicy.ps1') `
        -PowerCfgExecutablePath $ExplicitPath `
        -PassThru
}

function Get-NxbMemoryCalibrationFirstArm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProtocolOrdering,

        [Parameter(Mandatory)]
        [ValidateRange(1, 100)]
        [int]$Ordinal
    )

    switch ($ProtocolOrdering) {
        'control_then_capture' { return 'control' }
        'capture_then_control' { return 'capture' }
        'alternating_control_first' {
            if (($Ordinal % 2) -eq 1) { return 'control' }
            return 'capture'
        }
        'alternating_capture_first' {
            if (($Ordinal % 2) -eq 1) { return 'capture' }
            return 'control'
        }
        default { throw "Unsupported calibration ordering: $ProtocolOrdering" }
    }
}

function Initialize-NxbMemoryCalibrationContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Root,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [string]$ParentMachineId,

        [Parameter(Mandatory)]
        [string]$ParentBootId
    )

    $path = & (Join-Path $PSScriptRoot 'New-Experiment.ps1') `
        -Root $Root `
        -Name $Name `
        -Hypothesis 'Paired memory capture overhead preserves workload and host identity'
    $manifest = Read-NxbJson -Path (Join-Path $path 'manifest.json')
    $identity = Get-NxbMemoryCalibrationIdentity -Path $path

    if ([string]$identity.machine_id -cne $ParentMachineId) {
        throw "Child calibration machine_id changed: $path"
    }
    if ([string]$identity.boot_id -cne $ParentBootId) {
        throw "Child calibration boot_id changed: $path"
    }
    if ([string]$identity.experiment_id -cne [string]$manifest.experiment_id) {
        throw "Child calibration experiment_id binding failed: $path"
    }

    return [pscustomobject]@{
        Path = [string]$path
        ExperimentId = [string]$manifest.experiment_id
        RelativePath = "experiments/$([string]$manifest.experiment_id)"
    }
}

function ConvertTo-NxbMemoryCalibrationArmEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Measurement,

        [Parameter(Mandatory)]
        [object]$Context
    )

    return [ordered]@{
        experiment_id = [string]$Context.ExperimentId
        experiment_relative_path = [string]$Context.RelativePath
        status = [string]$Measurement.status
        started_utc = [string]$Measurement.started_utc
        stopped_utc = [string]$Measurement.stopped_utc
        duration_ms = [double]$Measurement.duration_ms
        exit_code = if ($null -eq $Measurement.exit_code) {
            $null
        }
        else {
            [int]$Measurement.exit_code
        }
        timed_out = [bool]$Measurement.timed_out
        result = $Measurement.result
        process_metrics = $Measurement.process_metrics
        diagnostics = @($Measurement.diagnostics)
    }
}

function Get-NxbMemoryCalibrationFailedArm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context,

        [Parameter(Mandatory)]
        [string]$Reason
    )

    $timestamp = [DateTime]::UtcNow.ToString('o')
    return [ordered]@{
        experiment_id = [string]$Context.ExperimentId
        experiment_relative_path = [string]$Context.RelativePath
        status = 'failed'
        started_utc = $timestamp
        stopped_utc = $timestamp
        duration_ms = 0.0
        exit_code = $null
        timed_out = $false
        result = [ordered]@{
            status = 'failed'
            value = $null
            unit = 'checksum'
            reason = $Reason
        }
        process_metrics = [ordered]@{
            cpu_time_ms = $(Get-NxbMemoryCalibrationMetric `
                -Status failed -Unit 'ms' -Reason $Reason)
            peak_working_set_bytes = $(Get-NxbMemoryCalibrationMetric `
                -Status failed -Unit 'bytes' -Reason $Reason)
            peak_private_bytes = $(Get-NxbMemoryCalibrationMetric `
                -Status failed -Unit 'bytes' -Reason $Reason)
        }
        diagnostics = @($Reason)
    }
}

function Invoke-NxbMemoryCalibrationControlArm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context,

        [Parameter(Mandatory)]
        [int]$PrivateMiB,

        [Parameter(Mandatory)]
        [int]$MappedMiB,

        [Parameter(Mandatory)]
        [int]$HoldMs,

        [Parameter(Mandatory)]
        [int]$Timeout,

        [Parameter(Mandatory)]
        [int]$SampleInterval,

        [Parameter()]
        [string]$PowerShellPath
    )

    try {
        $measurement = & (Join-Path $PSScriptRoot 'Invoke-NxbMeasuredMemoryWorkload.ps1') `
            -ExperimentPath $Context.Path `
            -PrivateMemoryMiB $PrivateMiB `
            -MappedFileMiB $MappedMiB `
            -HoldMilliseconds $HoldMs `
            -TimeoutSeconds $Timeout `
            -SampleIntervalMilliseconds $SampleInterval `
            -PowerShellExecutablePath $PowerShellPath `
            -PassThru
        return ConvertTo-NxbMemoryCalibrationArmEvidence `
            -Measurement $measurement `
            -Context $Context
    }
    catch {
        return Get-NxbMemoryCalibrationFailedArm `
            -Context $Context `
            -Reason "Control memory workload failed: $($_.Exception.Message)"
    }
}

function Invoke-NxbMemoryCalibrationCaptureArm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context,

        [Parameter(Mandatory)]
        [object]$MemoryProfile,

        [Parameter(Mandatory)]
        [string]$ProfileProvenanceSha256,

        [Parameter(Mandatory)]
        [string]$WprPath,

        [Parameter(Mandatory)]
        [int]$PrivateMiB,

        [Parameter(Mandatory)]
        [int]$MappedMiB,

        [Parameter(Mandatory)]
        [int]$HoldMs,

        [Parameter(Mandatory)]
        [int]$Timeout,

        [Parameter(Mandatory)]
        [int]$SampleInterval,

        [Parameter()]
        [string]$PowerShellPath
    )

    $profileReference = "$($MemoryProfile.Path)!NxbMemoryWorkingSet.Verbose"
    $captureStarted = $false
    $captureError = $null
    $baseArm = $null
    $startLatency = $null
    $stopLatency = $null
    $etlEvidence = $null
    $etlPath = Join-Path $Context.Path 'traces\memory-overhead.etl'

    $startWatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $startOutput = @(& $WprPath -start $profileReference -filemode 2>&1)
        $startExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        if ($startExit -ne 0) {
            throw "wpr start exit=$startExit output=$($startOutput -join ' ')"
        }
        $captureStarted = $true
        $startLatency = Get-NxbMemoryCalibrationMetric `
            -Value $startWatch.Elapsed.TotalMilliseconds `
            -Unit 'ms'
    }
    catch {
        $captureError = "WPR memory capture start failed: $($_.Exception.Message)"
        $startLatency = Get-NxbMemoryCalibrationMetric `
            -Status failed `
            -Unit 'ms' `
            -Reason $captureError
    }
    finally {
        $startWatch.Stop()
    }

    if ($captureStarted) {
        try {
            $measurement = & (Join-Path $PSScriptRoot 'Invoke-NxbMeasuredMemoryWorkload.ps1') `
                -ExperimentPath $Context.Path `
                -PrivateMemoryMiB $PrivateMiB `
                -MappedFileMiB $MappedMiB `
                -HoldMilliseconds $HoldMs `
                -TimeoutSeconds $Timeout `
                -SampleIntervalMilliseconds $SampleInterval `
                -PowerShellExecutablePath $PowerShellPath `
                -PassThru
            $baseArm = ConvertTo-NxbMemoryCalibrationArmEvidence `
                -Measurement $measurement `
                -Context $Context
        }
        catch {
            $captureError = "Capture memory workload failed: $($_.Exception.Message)"
            $baseArm = Get-NxbMemoryCalibrationFailedArm `
                -Context $Context `
                -Reason $captureError
        }

        $stopWatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $stopOutput = @(& $WprPath -stop $etlPath 2>&1)
            $stopExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
            if ($stopExit -ne 0) {
                throw "wpr stop exit=$stopExit output=$($stopOutput -join ' ')"
            }
            if (-not (Test-Path -LiteralPath $etlPath -PathType Leaf)) {
                throw "WPR did not produce calibration ETL: $etlPath"
            }

            $stopLatency = Get-NxbMemoryCalibrationMetric `
                -Value $stopWatch.Elapsed.TotalMilliseconds `
                -Unit 'ms'
            $etlItem = Get-Item -LiteralPath $etlPath
            $durationSeconds = [double]$baseArm.duration_ms / 1000.0
            if ($durationSeconds -le 0) {
                throw 'Capture duration must be positive for ETL byte-rate calculation.'
            }
            $etlEvidence = [ordered]@{
                status = 'measured'
                path = 'traces/memory-overhead.etl'
                sha256 = (
                    Get-FileHash -LiteralPath $etlPath -Algorithm SHA256
                ).Hash.ToLowerInvariant()
                length = [int64]$etlItem.Length
                effective_bytes_per_second = [Math]::Round(
                    ([double]$etlItem.Length / $durationSeconds),
                    6
                )
                profile_provenance_sha256 = $ProfileProvenanceSha256
                reason = $null
            }
        }
        catch {
            $captureError = "WPR memory capture stop/finalization failed: $($_.Exception.Message)"
            $stopLatency = Get-NxbMemoryCalibrationMetric `
                -Status failed -Unit 'ms' -Reason $captureError
            $etlEvidence = [ordered]@{
                status = 'failed'
                path = $null
                sha256 = $null
                length = $null
                effective_bytes_per_second = $null
                profile_provenance_sha256 = $ProfileProvenanceSha256
                reason = $captureError
            }
            try {
                [void](& $WprPath -cancel 2>&1)
            }
            catch {
                $captureError += "; WPR cleanup cancel failed: $($_.Exception.Message)"
            }
        }
        finally {
            $stopWatch.Stop()
        }
    }
    else {
        $baseArm = Get-NxbMemoryCalibrationFailedArm `
            -Context $Context `
            -Reason $captureError
        $stopLatency = Get-NxbMemoryCalibrationMetric `
            -Status unsupported `
            -Unit 'ms' `
            -Reason 'WPR did not start; stop latency was not measured.'
        $etlEvidence = [ordered]@{
            status = 'failed'
            path = $null
            sha256 = $null
            length = $null
            effective_bytes_per_second = $null
            profile_provenance_sha256 = $ProfileProvenanceSha256
            reason = $captureError
        }
    }

    if ([string]$baseArm.status -ne 'measured' -or
        [string]$startLatency.status -ne 'measured' -or
        [string]$stopLatency.status -ne 'measured' -or
        [string]$etlEvidence.status -ne 'measured') {
        $baseArm.status = 'failed'
        if (-not [string]::IsNullOrWhiteSpace($captureError)) {
            $baseArm.diagnostics = @($baseArm.diagnostics) + @($captureError)
        }
    }

    $captureArm = [ordered]@{}
    foreach ($key in $baseArm.Keys) {
        $captureArm[$key] = $baseArm[$key]
    }
    $captureArm.wpr_start_latency_ms = $startLatency
    $captureArm.wpr_stop_latency_ms = $stopLatency
    $captureArm.etl = $etlEvidence
    return $captureArm
}

function Get-NxbMemoryCalibrationArmMetric {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Arm,

        [Parameter(Mandatory)]
        [string]$MetricName,

        [Parameter(Mandatory)]
        [string]$Unit
    )

    if ([string]$Arm.status -ne 'measured') {
        return Get-NxbMemoryCalibrationMetric `
            -Status failed -Unit $Unit -Reason 'Arm is not measured.'
    }
    return $Arm.process_metrics.$MetricName
}

function Get-NxbMemoryCalibrationDelta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Control,

        [Parameter(Mandatory)]
        [object]$Capture,

        [Parameter(Mandatory)]
        [string]$SourceUnit,

        [Parameter(Mandatory)]
        [string]$AbsoluteUnit,

        [Parameter(Mandatory)]
        [string]$Label
    )

    if ([string]$Control.status -ne 'measured' -or
        [string]$Capture.status -ne 'measured') {
        $reason = "$Label source metric is not measured."
        return [pscustomobject]@{
            Absolute = $(Get-NxbMemoryCalibrationMetric `
                -Status failed -Unit $AbsoluteUnit -Reason $reason)
            Relative = $(Get-NxbMemoryCalibrationMetric `
                -Status failed -Unit 'percent' -Reason $reason)
            RelativeValue = $null
        }
    }

    if ([string]$Control.unit -cne $SourceUnit -or
        [string]$Capture.unit -cne $SourceUnit) {
        throw "$Label source unit mismatch."
    }

    $controlValue = [double]$Control.value
    $captureValue = [double]$Capture.value
    $absoluteValue = $captureValue - $controlValue
    $absolute = Get-NxbMemoryCalibrationMetric `
        -Value $absoluteValue -Unit $AbsoluteUnit

    if ($controlValue -eq 0) {
        $relative = Get-NxbMemoryCalibrationMetric `
            -Status unsupported `
            -Unit 'percent' `
            -Reason "$Label control denominator is zero."
        $relativeValue = $null
    }
    else {
        $relativeValue = ($absoluteValue / $controlValue) * 100.0
        $relative = Get-NxbMemoryCalibrationMetric `
            -Value $relativeValue -Unit 'percent'
    }

    return [pscustomobject]@{
        Absolute = $absolute
        Relative = $relative
        RelativeValue = $relativeValue
    }
}

function Get-NxbMemoryCalibrationPairDelta {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ControlArm,

        [Parameter(Mandatory)]
        [object]$CaptureArm
    )

    $controlDuration = if ([string]$ControlArm.status -eq 'measured') {
        Get-NxbMemoryCalibrationMetric `
            -Value ([double]$ControlArm.duration_ms) -Unit 'ms'
    }
    else {
        Get-NxbMemoryCalibrationMetric `
            -Status failed -Unit 'ms' -Reason 'Control arm failed.'
    }
    $captureDuration = if ([string]$CaptureArm.status -eq 'measured') {
        Get-NxbMemoryCalibrationMetric `
            -Value ([double]$CaptureArm.duration_ms) -Unit 'ms'
    }
    else {
        Get-NxbMemoryCalibrationMetric `
            -Status failed -Unit 'ms' -Reason 'Capture arm failed.'
    }

    $duration = Get-NxbMemoryCalibrationDelta `
        -Control $controlDuration `
        -Capture $captureDuration `
        -SourceUnit 'ms' `
        -AbsoluteUnit 'ms' `
        -Label 'duration'
    $cpu = Get-NxbMemoryCalibrationDelta `
        -Control (Get-NxbMemoryCalibrationArmMetric `
            -Arm $ControlArm -MetricName 'cpu_time_ms' -Unit 'ms') `
        -Capture (Get-NxbMemoryCalibrationArmMetric `
            -Arm $CaptureArm -MetricName 'cpu_time_ms' -Unit 'ms') `
        -SourceUnit 'ms' `
        -AbsoluteUnit 'ms' `
        -Label 'cpu_time'
    $workingSet = Get-NxbMemoryCalibrationDelta `
        -Control (Get-NxbMemoryCalibrationArmMetric `
            -Arm $ControlArm -MetricName 'peak_working_set_bytes' -Unit 'bytes') `
        -Capture (Get-NxbMemoryCalibrationArmMetric `
            -Arm $CaptureArm -MetricName 'peak_working_set_bytes' -Unit 'bytes') `
        -SourceUnit 'bytes' `
        -AbsoluteUnit 'bytes' `
        -Label 'peak_working_set'
    $privateBytes = Get-NxbMemoryCalibrationDelta `
        -Control (Get-NxbMemoryCalibrationArmMetric `
            -Arm $ControlArm -MetricName 'peak_private_bytes' -Unit 'bytes') `
        -Capture (Get-NxbMemoryCalibrationArmMetric `
            -Arm $CaptureArm -MetricName 'peak_private_bytes' -Unit 'bytes') `
        -SourceUnit 'bytes' `
        -AbsoluteUnit 'bytes' `
        -Label 'peak_private_bytes'

    return [pscustomobject]@{
        Evidence = [ordered]@{
            duration_absolute_ms = $duration.Absolute
            duration_relative_percent = $duration.Relative
            cpu_time_absolute_ms = $cpu.Absolute
            cpu_time_relative_percent = $cpu.Relative
            peak_working_set_absolute_bytes = $workingSet.Absolute
            peak_working_set_relative_percent = $workingSet.Relative
            peak_private_bytes_absolute_bytes = $privateBytes.Absolute
            peak_private_bytes_relative_percent = $privateBytes.Relative
        }
        RelativeValues = [ordered]@{
            duration = $duration.RelativeValue
            cpu_time = $cpu.RelativeValue
            peak_working_set = $workingSet.RelativeValue
            peak_private_bytes = $privateBytes.RelativeValue
        }
    }
}

function Get-NxbMemoryCalibrationDistribution {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [double[]]$Values,

        [Parameter(Mandatory)]
        [string]$Unit,

        [Parameter(Mandatory)]
        [string]$UnavailableReason
    )

    $numericValues = @($Values)
    if ($numericValues.Count -eq 0) {
        return [ordered]@{
            status = 'failed'
            count = 0
            minimum = $null
            median = $null
            mean = $null
            maximum = $null
            unit = $Unit
            reason = $UnavailableReason
        }
    }

    $sorted = @($numericValues | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    $median = if (($sorted.Count % 2) -eq 1) {
        [double]$sorted[$middle]
    }
    else {
        ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
    }
    $sum = [double]0
    foreach ($value in $numericValues) {
        $sum += $value
    }

    return [ordered]@{
        status = 'measured'
        count = $numericValues.Count
        minimum = [double]$sorted[0]
        median = $median
        mean = $sum / $numericValues.Count
        maximum = [double]$sorted[-1]
        unit = $Unit
        reason = $null
    }
}

function Complete-NxbMemoryCalibrationArm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context,

        [Parameter(Mandatory)]
        [object]$Arm,

        [Parameter(Mandatory)]
        [ValidateSet('control', 'capture', 'warmup')]
        [string]$ArmName
    )

    $valid = [string]$Arm.status -eq 'measured'
    if ($ArmName -eq 'capture') {
        $valid = $valid -and [string]$Arm.etl.status -eq 'measured'
    }

    if ($valid) {
        & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $Context.Path
        return
    }

    $manifest = Read-NxbJson -Path (Join-Path $Context.Path 'manifest.json')
    if ([string]$manifest.status -notin @('failed', 'finalized')) {
        & (Join-Path $PSScriptRoot 'Set-ExperimentFailed.ps1') `
            -ExperimentPath $Context.Path `
            -Reason "$ArmName memory calibration arm failed." `
            -Confirm:$false
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Memory overhead calibration requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Memory overhead calibration must run in PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or
    $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$workingTree = @(
    & $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all
)
if ($LASTEXITCODE -ne 0 -or $workingTree.Count -gt 0) {
    throw 'Memory overhead calibration requires a clean exact-head worktree.'
}

$experimentsRoot = Join-Path $LabRoot 'experiments'
if (-not (Test-Path -LiteralPath $experimentsRoot -PathType Container)) {
    throw "NXB lab is not initialized: $experimentsRoot"
}

$wprPath = Resolve-NxbExecutablePath `
    -Name 'wpr.exe' `
    -ExplicitPath $WprExecutablePath
$memoryProfile = & (Join-Path $PSScriptRoot 'Test-NxbMemoryWprProfile.ps1') -PassThru
$profileProvenance = [ordered]@{
    relative_path = [string]$memoryProfile.RelativePath
    sha256 = [string]$memoryProfile.Sha256
    length = [int64]$memoryProfile.Length
    profile_name = [string]$memoryProfile.Name
    file_profile_id = [string]$memoryProfile.FileProfileId
    buffer_size_kib = [int]$memoryProfile.BufferSizeKiB
    buffers = [int]$memoryProfile.Buffers
    maximum_file_size_mib = [int]$memoryProfile.MaximumFileSizeMiB
    file_mode = [string]$memoryProfile.FileMode
}
$profileProvenanceSha256 = Get-NxbCanonicalJsonHash -InputObject $profileProvenance

$parentPath = & (Join-Path $PSScriptRoot 'New-Experiment.ps1') `
    -Root $LabRoot `
    -Name 'Memory-Overhead-Calibration' `
    -Hypothesis 'Bounded memory WPR overhead can be measured by paired control and capture arms'
$parentManifest = Read-NxbJson -Path (Join-Path $parentPath 'manifest.json')
$parentIdentity = Get-NxbMemoryCalibrationIdentity -Path $parentPath
$parentExperimentId = [string]$parentManifest.experiment_id
if ([string]$parentIdentity.experiment_id -cne $parentExperimentId) {
    throw 'Parent memory calibration experiment identity mismatch.'
}

$powerPolicy = Get-NxbMemoryCalibrationPowerPolicy `
    -ExplicitPath $PowerCfgExecutablePath
$powerPolicyFingerprint = Get-NxbCanonicalJsonHash -InputObject $powerPolicy
$workloadPath = Join-Path $PSScriptRoot 'Invoke-NxbMemoryProbeWorkload.ps1'
$workloadItem = Get-Item -LiteralPath $workloadPath
$workload = [ordered]@{
    id = 'nxb.memory.probe.v1'
    name = 'NXB bounded private and mapped memory probe'
    command = [ordered]@{
        path = 'scripts/Invoke-NxbMemoryProbeWorkload.ps1'
        arguments = @(
            '-PrivateMemoryMiB', [string]$PrivateMemoryMiB,
            '-MappedFileMiB', [string]$MappedFileMiB,
            '-HoldMilliseconds', [string]$HoldMilliseconds
        )
        sha256 = (
            Get-FileHash -LiteralPath $workloadPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        length = [int64]$workloadItem.Length
    }
    parameters = [ordered]@{
        private_memory_mib = $PrivateMemoryMiB
        mapped_file_mib = $MappedFileMiB
        hold_milliseconds = $HoldMilliseconds
        page_stride_bytes = 4096
        capture_profile_sha256 = [string]$memoryProfile.Sha256
        capture_profile_id = [string]$memoryProfile.FileProfileId
    }
    timeout_seconds = $TimeoutSeconds
}
$workloadFingerprint = Get-NxbCanonicalJsonHash -InputObject $workload

$analysisRoot = Join-Path $parentPath 'analysis'
[IO.Directory]::CreateDirectory($analysisRoot) | Out-Null
$resultPath = Join-Path $analysisRoot 'collector-overhead-calibration.json'
$warmupPath = Join-Path $analysisRoot 'memory-overhead-warmups.json'
$profilePath = Join-Path $analysisRoot 'memory-overhead-profile-provenance.json'
Write-NxbJsonAtomic -Path $profilePath -InputObject $profileProvenance -Depth 16

$warmups = [Collections.Generic.List[object]]::new()
$pairs = [Collections.Generic.List[object]]::new()
$durationRelative = [Collections.Generic.List[double]]::new()
$cpuRelative = [Collections.Generic.List[double]]::new()
$workingSetRelative = [Collections.Generic.List[double]]::new()
$privateBytesRelative = [Collections.Generic.List[double]]::new()
$successfulPairCount = 0

try {
    for ($warmupOrdinal = 1; $warmupOrdinal -le $WarmupCount; $warmupOrdinal++) {
        $context = Initialize-NxbMemoryCalibrationContext `
            -Root $LabRoot `
            -Name ("Memory-Overhead-Warmup-{0:D2}" -f $warmupOrdinal) `
            -ParentMachineId ([string]$parentIdentity.machine_id) `
            -ParentBootId ([string]$parentIdentity.boot_id)

        $beforePolicy = Get-NxbMemoryCalibrationPowerPolicy `
            -ExplicitPath $PowerCfgExecutablePath
        if ((Get-NxbCanonicalJsonHash -InputObject $beforePolicy) -cne
            $powerPolicyFingerprint) {
            throw "Power policy changed before warmup $warmupOrdinal."
        }

        $measurement = & (Join-Path $PSScriptRoot 'Invoke-NxbMeasuredMemoryWorkload.ps1') `
            -ExperimentPath $context.Path `
            -PrivateMemoryMiB $PrivateMemoryMiB `
            -MappedFileMiB $MappedFileMiB `
            -HoldMilliseconds $HoldMilliseconds `
            -TimeoutSeconds $TimeoutSeconds `
            -SampleIntervalMilliseconds $SampleIntervalMilliseconds `
            -PowerShellExecutablePath $PowerShellExecutablePath `
            -PassThru

        $afterPolicy = Get-NxbMemoryCalibrationPowerPolicy `
            -ExplicitPath $PowerCfgExecutablePath
        $validWarmup = (
            [string]$measurement.status -eq 'measured' -and
            (Get-NxbCanonicalJsonHash -InputObject $afterPolicy) -ceq
                $powerPolicyFingerprint
        )
        $warmups.Add([ordered]@{
            ordinal = $warmupOrdinal
            experiment_id = $context.ExperimentId
            experiment_relative_path = $context.RelativePath
            status = [string]$measurement.status
            duration_ms = [double]$measurement.duration_ms
            result = $measurement.result
        })
        if (-not $validWarmup) {
            $failedWarmup = ConvertTo-NxbMemoryCalibrationArmEvidence `
                -Measurement $measurement `
                -Context $context
            Complete-NxbMemoryCalibrationArm `
                -Context $context -Arm $failedWarmup -ArmName warmup
            throw "Memory calibration warmup failed: $warmupOrdinal"
        }
        $warmupArm = ConvertTo-NxbMemoryCalibrationArmEvidence `
            -Measurement $measurement `
            -Context $context
        Complete-NxbMemoryCalibrationArm `
            -Context $context -Arm $warmupArm -ArmName warmup

        if ($CooldownSeconds -gt 0) {
            Start-Sleep -Seconds $CooldownSeconds
        }
    }

    Write-NxbJsonAtomic `
        -Path $warmupPath `
        -InputObject ([ordered]@{
            schema_version = 1
            count = $warmups.Count
            warmups = @($warmups)
        }) `
        -Depth 16

    for ($ordinal = 1; $ordinal -le $RepetitionCount; $ordinal++) {
        $firstArm = Get-NxbMemoryCalibrationFirstArm `
            -ProtocolOrdering $Ordering `
            -Ordinal $ordinal
        $contexts = @{
            control = Initialize-NxbMemoryCalibrationContext `
                -Root $LabRoot `
                -Name ("Memory-Overhead-{0:D2}-Control" -f $ordinal) `
                -ParentMachineId ([string]$parentIdentity.machine_id) `
                -ParentBootId ([string]$parentIdentity.boot_id)
            capture = Initialize-NxbMemoryCalibrationContext `
                -Root $LabRoot `
                -Name ("Memory-Overhead-{0:D2}-Capture" -f $ordinal) `
                -ParentMachineId ([string]$parentIdentity.machine_id) `
                -ParentBootId ([string]$parentIdentity.boot_id)
        }
        $arms = @{}
        $executionOrder = if ($firstArm -eq 'control') {
            @('control', 'capture')
        }
        else {
            @('capture', 'control')
        }

        foreach ($armName in $executionOrder) {
            $beforePolicy = Get-NxbMemoryCalibrationPowerPolicy `
                -ExplicitPath $PowerCfgExecutablePath
            if ((Get-NxbCanonicalJsonHash -InputObject $beforePolicy) -cne
                $powerPolicyFingerprint) {
                throw "Power policy changed before pair $ordinal $armName."
            }

            if ($armName -eq 'control') {
                $arms.control = Invoke-NxbMemoryCalibrationControlArm `
                    -Context $contexts.control `
                    -PrivateMiB $PrivateMemoryMiB `
                    -MappedMiB $MappedFileMiB `
                    -HoldMs $HoldMilliseconds `
                    -Timeout $TimeoutSeconds `
                    -SampleInterval $SampleIntervalMilliseconds `
                    -PowerShellPath $PowerShellExecutablePath
            }
            else {
                $arms.capture = Invoke-NxbMemoryCalibrationCaptureArm `
                    -Context $contexts.capture `
                    -MemoryProfile $memoryProfile `
                    -ProfileProvenanceSha256 $profileProvenanceSha256 `
                    -WprPath $wprPath `
                    -PrivateMiB $PrivateMemoryMiB `
                    -MappedMiB $MappedFileMiB `
                    -HoldMs $HoldMilliseconds `
                    -Timeout $TimeoutSeconds `
                    -SampleInterval $SampleIntervalMilliseconds `
                    -PowerShellPath $PowerShellExecutablePath
            }

            $afterPolicy = Get-NxbMemoryCalibrationPowerPolicy `
                -ExplicitPath $PowerCfgExecutablePath
            if ((Get-NxbCanonicalJsonHash -InputObject $afterPolicy) -cne
                $powerPolicyFingerprint) {
                $arms[$armName].status = 'failed'
                $arms[$armName].diagnostics = @($arms[$armName].diagnostics) + @(
                    "Power policy changed during pair $ordinal $armName."
                )
            }

            Complete-NxbMemoryCalibrationArm `
                -Context $contexts[$armName] `
                -Arm $arms[$armName] `
                -ArmName $armName

            if ($CooldownSeconds -gt 0) {
                Start-Sleep -Seconds $CooldownSeconds
            }
        }

        $deltas = Get-NxbMemoryCalibrationPairDelta `
            -ControlArm $arms.control `
            -CaptureArm $arms.capture
        if ($null -ne $deltas.RelativeValues.duration) {
            $durationRelative.Add([double]$deltas.RelativeValues.duration)
        }
        if ($null -ne $deltas.RelativeValues.cpu_time) {
            $cpuRelative.Add([double]$deltas.RelativeValues.cpu_time)
        }
        if ($null -ne $deltas.RelativeValues.peak_working_set) {
            $workingSetRelative.Add([double]$deltas.RelativeValues.peak_working_set)
        }
        if ($null -ne $deltas.RelativeValues.peak_private_bytes) {
            $privateBytesRelative.Add([double]$deltas.RelativeValues.peak_private_bytes)
        }

        $pairSuccessful = (
            [string]$arms.control.status -eq 'measured' -and
            [string]$arms.capture.status -eq 'measured' -and
            [string]$arms.capture.etl.status -eq 'measured'
        )
        if ($pairSuccessful) {
            $successfulPairCount++
        }

        $pairs.Add([ordered]@{
            ordinal = $ordinal
            pair_id = ("memory-pair-{0:D4}" -f $ordinal)
            machine_id = [string]$parentIdentity.machine_id
            boot_id = [string]$parentIdentity.boot_id
            power_policy_fingerprint = $powerPolicyFingerprint
            workload_fingerprint = $workloadFingerprint
            first_arm = $firstArm
            control = $arms.control
            capture = $arms.capture
            deltas = $deltas.Evidence
        })
    }

    $failedPairCount = $RepetitionCount - $successfulPairCount
    $calibration = [ordered]@{
        schema_version = 1
        calibration_id = "memory-overhead-$([guid]::NewGuid().ToString('N'))"
        experiment_id = $parentExperimentId
        experiment_relative_path = "experiments/$parentExperimentId"
        machine_id = [string]$parentIdentity.machine_id
        boot_id = [string]$parentIdentity.boot_id
        captured_utc = [DateTime]::UtcNow.ToString('o')
        power_policy = $powerPolicy
        power_policy_fingerprint = $powerPolicyFingerprint
        workload = $workload
        workload_fingerprint = $workloadFingerprint
        protocol = [ordered]@{
            repetition_count = $RepetitionCount
            warmup_count = $WarmupCount
            ordering = $Ordering
            require_same_machine = $true
            require_same_boot = $true
            require_same_power_policy = $true
            require_same_workload = $true
            cooldown_seconds = $CooldownSeconds
        }
        pairs = @($pairs)
        summary = [ordered]@{
            pair_count = $RepetitionCount
            successful_pair_count = $successfulPairCount
            failed_pair_count = $failedPairCount
            duration_delta_percent = $(Get-NxbMemoryCalibrationDistribution `
                -Values @($durationRelative) `
                -Unit 'percent' `
                -UnavailableReason 'Measured duration deltas are unavailable.')
            cpu_time_delta_percent = $(Get-NxbMemoryCalibrationDistribution `
                -Values @($cpuRelative) `
                -Unit 'percent' `
                -UnavailableReason 'Measured CPU-time deltas are unavailable.')
            peak_working_set_delta_percent = $(Get-NxbMemoryCalibrationDistribution `
                -Values @($workingSetRelative) `
                -Unit 'percent' `
                -UnavailableReason 'Measured working-set deltas are unavailable.')
            peak_private_bytes_delta_percent = $(Get-NxbMemoryCalibrationDistribution `
                -Values @($privateBytesRelative) `
                -Unit 'percent' `
                -UnavailableReason 'Measured private-byte deltas are unavailable.')
            threshold_policy = [ordered]@{
                status = 'not_declared'
                reason = 'Memory capture overhead thresholds require representative evidence and are not declared by this calibration.'
            }
        }
    }

    Write-NxbJsonAtomic -Path $resultPath -InputObject $calibration -Depth 32
    & (Join-Path $PSScriptRoot 'Test-CollectorOverheadCalibration.ps1') `
        -Path $resultPath

    if ($failedPairCount -gt 0) {
        throw "Memory overhead calibration recorded $failedPairCount failed pair(s): $resultPath"
    }

    & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
        -ExperimentPath $parentPath

    $reviewDirectory = Join-Path $analysisRoot 'review'
    [IO.Directory]::CreateDirectory($reviewDirectory) | Out-Null
    Copy-Item -LiteralPath $resultPath -Destination $reviewDirectory -Force
    Copy-Item -LiteralPath $warmupPath -Destination $reviewDirectory -Force
    Copy-Item -LiteralPath $profilePath -Destination $reviewDirectory -Force
    Copy-Item `
        -LiteralPath (Join-Path $parentPath 'baseline\observation-identity.json') `
        -Destination $reviewDirectory `
        -Force
    $reviewZip = Join-Path `
        (Join-Path $HOME 'Downloads') `
        (
            'nxb-memory-overhead-calibration-' +
            $currentHead.Substring(0, 12) + '-' +
            [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') +
            '-review.zip'
        )
    Compress-Archive `
        -Path (Join-Path $reviewDirectory '*') `
        -DestinationPath $reviewZip `
        -Force

    Write-Information `
        -MessageData "Memory overhead calibration completed: $resultPath" `
        -InformationAction Continue
    Write-Information `
        -MessageData "Memory overhead calibration review ZIP: $reviewZip" `
        -InformationAction Continue
    Write-Information `
        -MessageData 'Calibration ETL files remain local in child experiments and are not included in the review ZIP.' `
        -InformationAction Continue

    if ($PassThru) {
        return [pscustomobject]@{
            status = 'passed'
            head_sha = $currentHead
            parent_experiment_path = $parentPath
            result_path = $resultPath
            review_zip_path = $reviewZip
            profile_provenance_sha256 = $profileProvenanceSha256
            calibration = [pscustomobject]$calibration
        }
    }

    Write-Output $resultPath
}
catch {
    $failure = $_.Exception.Message
    try {
        $currentParent = Read-NxbJson -Path (Join-Path $parentPath 'manifest.json')
        if ([string]$currentParent.status -notin @('failed', 'finalized')) {
            & (Join-Path $PSScriptRoot 'Set-ExperimentFailed.ps1') `
                -ExperimentPath $parentPath `
                -Reason "Memory overhead calibration failed: $failure" `
                -Confirm:$false
        }
    }
    catch {
        Write-Warning "Parent memory calibration failed state could not be recorded: $($_.Exception.Message)"
    }
    throw
}