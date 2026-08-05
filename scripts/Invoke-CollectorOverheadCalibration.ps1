[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [ValidateRange(1, 20)]
    [int]$RepetitionCount = 3,

    [Parameter()]
    [ValidateRange(0, 5)]
    [int]$WarmupCount = 0,

    [Parameter()]
    [ValidateSet(
        'alternating_control_first',
        'alternating_capture_first',
        'control_then_capture',
        'capture_then_control'
    )]
    [string]$Ordering = 'alternating_control_first',

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [int]$Iterations = 1000,

    [Parameter()]
    [ValidateRange(1, 255)]
    [int]$Seed = 73,

    [Parameter()]
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 120,

    [Parameter()]
    [ValidateRange(10, 1000)]
    [int]$SampleIntervalMilliseconds = 50,

    [Parameter()]
    [ValidateRange(0, 3600)]
    [int]$CooldownSeconds = 0,

    [Parameter()]
    [string]$WprExecutablePath,

    [Parameter()]
    [string]$PowerShellExecutablePath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

function New-NxbOverheadMeasurement {
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
            value  = $Value
            unit   = $Unit
            reason = $null
        }
    }

    return [ordered]@{
        status = $Status
        value  = $null
        unit   = $Unit
        reason = $Reason
    }
}

function Get-NxbActivePowerPolicy {
    [CmdletBinding()]
    param()

    $powerCfg = Get-Command powercfg.exe -ErrorAction SilentlyContinue
    if (-not $powerCfg) {
        return [ordered]@{
            status      = 'unavailable'
            scheme_guid = $null
            name         = $null
            source       = 'powercfg.exe unavailable'
        }
    }

    $output = & $powerCfg.Source /getactivescheme 2>&1
    if ($LASTEXITCODE -ne 0) {
        return [ordered]@{
            status      = 'unavailable'
            scheme_guid = $null
            name         = $null
            source       = "powercfg.exe exit $LASTEXITCODE"
        }
    }

    $text = $output -join ' '
    $match = [regex]::Match(
        $text,
        '(?i)([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:\s+\(([^)]*)\))?'
    )
    if (-not $match.Success) {
        return [ordered]@{
            status      = 'partial'
            scheme_guid = $null
            name         = $null
            source       = $powerCfg.Source
        }
    }

    return [ordered]@{
        status      = 'available'
        scheme_guid = $match.Groups[1].Value.ToLowerInvariant()
        name         = if ($match.Groups[2].Success) {
            $match.Groups[2].Value
        }
        else {
            $null
        }
        source       = $powerCfg.Source
    }
}

function Get-NxbCalibrationIdentity {
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

function Get-NxbFirstArm {
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
            return if (($Ordinal % 2) -eq 1) { 'control' } else { 'capture' }
        }
        'alternating_capture_first' {
            return if (($Ordinal % 2) -eq 1) { 'capture' } else { 'control' }
        }
        default { throw "Desteklenmeyen trial ordering: $ProtocolOrdering" }
    }
}

function New-NxbChildExperimentContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$LabRoot,

        [Parameter(Mandatory)]
        [ValidateRange(1, 100)]
        [int]$Ordinal,

        [Parameter(Mandatory)]
        [ValidateSet('control', 'capture', 'warmup')]
        [string]$Arm,

        [Parameter(Mandatory)]
        [string]$ParentMachineId,

        [Parameter(Mandatory)]
        [string]$ParentBootId
    )

    $childPath = & (Join-Path $PSScriptRoot 'New-Experiment.ps1') `
        -Root $LabRoot `
        -Name ("Overhead-{0:D4}-{1}" -f $Ordinal, $Arm) `
        -Hypothesis 'Paired collector overhead arm preserves identity and workload equivalence'
    $childManifest = Read-NxbJson -Path (Join-Path $childPath 'manifest.json')
    $identity = Get-NxbCalibrationIdentity -Path $childPath

    if ([string]$identity.machine_id -cne $ParentMachineId) {
        throw "Child experiment machine_id değişti: $childPath"
    }
    if ([string]$identity.boot_id -cne $ParentBootId) {
        throw "Child experiment boot_id değişti: $childPath"
    }
    if ([string]$identity.experiment_id -cne [string]$childManifest.experiment_id) {
        throw "Child observation identity experiment_id uyuşmuyor: $childPath"
    }

    return [pscustomobject]@{
        Path = $childPath
        ExperimentId = [string]$childManifest.experiment_id
        RelativePath = "experiments/$([string]$childManifest.experiment_id)"
        Identity = $identity
    }
}

function Invoke-NxbChildFailureTransition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ChildPath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason
    )

    $manifest = Read-NxbJson -Path (Join-Path $ChildPath 'manifest.json')
    if ([string]$manifest.status -notin @('failed', 'finalized')) {
        & (Join-Path $PSScriptRoot 'Set-ExperimentFailed.ps1') `
            -ExperimentPath $ChildPath `
            -Reason $Reason `
            -Confirm:$false
    }
}

function ConvertTo-NxbArmEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Measurement,

        [Parameter(Mandatory)]
        [object]$Context
    )

    return [ordered]@{
        experiment_id            = [string]$Context.ExperimentId
        experiment_relative_path = [string]$Context.RelativePath
        status                   = [string]$Measurement.status
        started_utc              = [string]$Measurement.started_utc
        stopped_utc              = [string]$Measurement.stopped_utc
        duration_ms              = [double]$Measurement.duration_ms
        exit_code                = if ($null -eq $Measurement.exit_code) {
            $null
        }
        else {
            [int]$Measurement.exit_code
        }
        timed_out                = [bool]$Measurement.timed_out
        result                   = $Measurement.result
        process_metrics          = $Measurement.process_metrics
        diagnostics              = @($Measurement.diagnostics)
    }
}

function New-NxbFailedArmEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason
    )

    $timestamp = [DateTime]::UtcNow.ToString('o')
    return [ordered]@{
        experiment_id            = [string]$Context.ExperimentId
        experiment_relative_path = [string]$Context.RelativePath
        status                   = 'failed'
        started_utc              = $timestamp
        stopped_utc              = $timestamp
        duration_ms              = 0.0
        exit_code                = $null
        timed_out                = $false
        result                   = [ordered]@{
            status = 'failed'
            value  = $null
            unit   = 'sha256'
            reason = $Reason
        }
        process_metrics          = [ordered]@{
            cpu_time_ms = New-NxbOverheadMeasurement `
                -Status failed -Unit 'ms' -Reason $Reason
            peak_working_set_bytes = New-NxbOverheadMeasurement `
                -Status failed -Unit 'bytes' -Reason $Reason
            peak_private_bytes = New-NxbOverheadMeasurement `
                -Status failed -Unit 'bytes' -Reason $Reason
        }
        diagnostics              = @($Reason)
    }
}

function Invoke-NxbControlArm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context,

        [Parameter(Mandatory)]
        [int]$WorkloadIterations,

        [Parameter(Mandatory)]
        [int]$WorkloadSeed,

        [Parameter(Mandatory)]
        [int]$WorkloadTimeoutSeconds,

        [Parameter(Mandatory)]
        [int]$SamplingMilliseconds,

        [Parameter()]
        [string]$PowerShellPath
    )

    $measurement = & (Join-Path $PSScriptRoot 'Invoke-NxbMeasuredWorkload.ps1') `
        -ExperimentPath $Context.Path `
        -Iterations $WorkloadIterations `
        -Seed $WorkloadSeed `
        -TimeoutSeconds $WorkloadTimeoutSeconds `
        -SampleIntervalMilliseconds $SamplingMilliseconds `
        -PowerShellExecutablePath $PowerShellPath `
        -PassThru
    $arm = ConvertTo-NxbArmEvidence -Measurement $measurement -Context $Context

    if ([string]$arm.status -eq 'measured') {
        & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $Context.Path
    }
    else {
        Invoke-NxbChildFailureTransition `
            -ChildPath $Context.Path `
            -Reason 'Control workload arm failed.'
    }

    return $arm
}

function Invoke-NxbCaptureArm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Context,

        [Parameter(Mandatory)]
        [int]$WorkloadIterations,

        [Parameter(Mandatory)]
        [int]$WorkloadSeed,

        [Parameter(Mandatory)]
        [int]$WorkloadTimeoutSeconds,

        [Parameter(Mandatory)]
        [int]$SamplingMilliseconds,

        [Parameter()]
        [string]$WprPath,

        [Parameter()]
        [string]$PowerShellPath
    )

    $startLatency = $null
    $stopLatency = $null
    $baseArm = $null
    $etlEvidence = $null
    $captureStarted = $false
    $captureError = $null

    $startStopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        & (Join-Path $PSScriptRoot 'Start-PerformanceTrace.ps1') `
            -ExperimentPath $Context.Path `
            -WprExecutablePath $WprPath
        $captureStarted = $true
        $startLatency = New-NxbOverheadMeasurement `
            -Value $startStopwatch.Elapsed.TotalMilliseconds `
            -Unit 'ms'
    }
    catch {
        $captureError = "WPR start başarısız: $($_.Exception.Message)"
        $startLatency = New-NxbOverheadMeasurement `
            -Status failed `
            -Unit 'ms' `
            -Reason $captureError
    }
    finally {
        $startStopwatch.Stop()
    }

    if ($captureStarted) {
        try {
            $measurement = & (Join-Path $PSScriptRoot 'Invoke-NxbMeasuredWorkload.ps1') `
                -ExperimentPath $Context.Path `
                -Iterations $WorkloadIterations `
                -Seed $WorkloadSeed `
                -TimeoutSeconds $WorkloadTimeoutSeconds `
                -SampleIntervalMilliseconds $SamplingMilliseconds `
                -PowerShellExecutablePath $PowerShellPath `
                -PassThru
            $baseArm = ConvertTo-NxbArmEvidence `
                -Measurement $measurement `
                -Context $Context
        }
        catch {
            $captureError = "Capture workload runner başarısız: $($_.Exception.Message)"
            $baseArm = New-NxbFailedArmEvidence `
                -Context $Context `
                -Reason $captureError
        }

        $stopStopwatch = [Diagnostics.Stopwatch]::StartNew()
        try {
            & (Join-Path $PSScriptRoot 'Stop-PerformanceTrace.ps1') `
                -ExperimentPath $Context.Path `
                -WprExecutablePath $WprPath
            $stopLatency = New-NxbOverheadMeasurement `
                -Value $stopStopwatch.Elapsed.TotalMilliseconds `
                -Unit 'ms'

            $etlMetadata = Read-NxbJson -Path (
                Join-Path $Context.Path 'traces\performance.etl.json'
            )
            if ([string]$etlMetadata.profile_integrity.status -cne 'valid' -or
                [string]$etlMetadata.profile_provenance_sha256 -notmatch '^[0-9a-f]{64}$') {
                throw 'ETL profile provenance integrity valid değil.'
            }

            $durationSeconds = [double]$baseArm.duration_ms / 1000.0
            if ($durationSeconds -le 0) {
                throw 'ETL effective byte rate için capture duration sıfırdan büyük olmalıdır.'
            }
            $etlEvidence = [ordered]@{
                status = 'measured'
                path = 'traces/performance.etl'
                sha256 = [string]$etlMetadata.sha256
                length = [int64]$etlMetadata.length
                effective_bytes_per_second = [Math]::Round(
                    ([double]$etlMetadata.length / $durationSeconds),
                    6
                )
                profile_provenance_sha256 = [string]$etlMetadata.profile_provenance_sha256
                reason = $null
            }
        }
        catch {
            $captureError = "WPR stop/finalization başarısız: $($_.Exception.Message)"
            $stopLatency = New-NxbOverheadMeasurement `
                -Status failed `
                -Unit 'ms' `
                -Reason $captureError
            $etlEvidence = [ordered]@{
                status = 'failed'
                path = $null
                sha256 = $null
                length = $null
                effective_bytes_per_second = $null
                profile_provenance_sha256 = $null
                reason = $captureError
            }

            try {
                $resolvedWpr = Resolve-NxbExecutablePath `
                    -Name 'wpr.exe' `
                    -ExplicitPath $WprPath
                $cancelOutput = & $resolvedWpr -cancel 2>&1
                if ($LASTEXITCODE -ne 0) {
                    $captureError += "; WPR cancel exit $LASTEXITCODE`: $($cancelOutput -join ' ')"
                }
            }
            catch {
                $captureError += "; WPR cancel başarısız: $($_.Exception.Message)"
            }
        }
        finally {
            $stopStopwatch.Stop()
        }
    }
    else {
        $baseArm = New-NxbFailedArmEvidence -Context $Context -Reason $captureError
        $stopLatency = New-NxbOverheadMeasurement `
            -Status unsupported `
            -Unit 'ms' `
            -Reason 'WPR başlamadığı için stop latency ölçülmedi.'
        $etlEvidence = [ordered]@{
            status = 'failed'
            path = $null
            sha256 = $null
            length = $null
            effective_bytes_per_second = $null
            profile_provenance_sha256 = $null
            reason = $captureError
        }
    }

    if ([string]$baseArm.status -ne 'measured' -or
        [string]$etlEvidence.status -ne 'measured' -or
        [string]$startLatency.status -ne 'measured' -or
        [string]$stopLatency.status -ne 'measured') {
        $baseArm.status = 'failed'
        if (-not [string]::IsNullOrWhiteSpace($captureError)) {
            $baseArm.diagnostics = @($baseArm.diagnostics) + @($captureError)
        }
        Invoke-NxbChildFailureTransition `
            -ChildPath $Context.Path `
            -Reason 'Capture overhead arm failed.'
    }
    else {
        & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $Context.Path
    }

    $captureArm = [ordered]@{}
    foreach ($property in $baseArm.Keys) {
        $captureArm[$property] = $baseArm[$property]
    }
    $captureArm.wpr_start_latency_ms = $startLatency
    $captureArm.wpr_stop_latency_ms = $stopLatency
    $captureArm.etl = $etlEvidence
    return $captureArm
}

function New-NxbDeltaEvidence {
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
        $reason = "$Label source metric measured değil."
        return [pscustomobject]@{
            Absolute = New-NxbOverheadMeasurement `
                -Status failed -Unit $AbsoluteUnit -Reason $reason
            Relative = New-NxbOverheadMeasurement `
                -Status failed -Unit 'percent' -Reason $reason
            RelativeValue = $null
        }
    }

    if ([string]$Control.unit -cne $SourceUnit -or
        [string]$Capture.unit -cne $SourceUnit) {
        throw "$Label source unit uyuşmuyor."
    }

    $controlValue = [double]$Control.value
    $captureValue = [double]$Capture.value
    $absoluteValue = $captureValue - $controlValue
    $absolute = New-NxbOverheadMeasurement `
        -Value $absoluteValue `
        -Unit $AbsoluteUnit

    if ($controlValue -eq 0) {
        $relative = New-NxbOverheadMeasurement `
            -Status unsupported `
            -Unit 'percent' `
            -Reason "$Label control denominator sıfır."
        $relativeValue = $null
    }
    else {
        $relativeValue = ($absoluteValue / $controlValue) * 100.0
        $relative = New-NxbOverheadMeasurement `
            -Value $relativeValue `
            -Unit 'percent'
    }

    return [pscustomobject]@{
        Absolute = $absolute
        Relative = $relative
        RelativeValue = $relativeValue
    }
}

function New-NxbPairDeltas {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$ControlArm,

        [Parameter(Mandatory)]
        [object]$CaptureArm
    )

    $durationControl = if ([string]$ControlArm.status -eq 'measured') {
        New-NxbOverheadMeasurement -Value ([double]$ControlArm.duration_ms) -Unit 'ms'
    }
    else {
        New-NxbOverheadMeasurement `
            -Status failed -Unit 'ms' -Reason 'Control arm failed.'
    }
    $durationCapture = if ([string]$CaptureArm.status -eq 'measured') {
        New-NxbOverheadMeasurement -Value ([double]$CaptureArm.duration_ms) -Unit 'ms'
    }
    else {
        New-NxbOverheadMeasurement `
            -Status failed -Unit 'ms' -Reason 'Capture arm failed.'
    }

    $duration = New-NxbDeltaEvidence `
        -Control $durationControl `
        -Capture $durationCapture `
        -SourceUnit 'ms' `
        -AbsoluteUnit 'ms' `
        -Label 'duration'
    $cpu = New-NxbDeltaEvidence `
        -Control $ControlArm.process_metrics.cpu_time_ms `
        -Capture $CaptureArm.process_metrics.cpu_time_ms `
        -SourceUnit 'ms' `
        -AbsoluteUnit 'ms' `
        -Label 'cpu_time'
    $workingSet = New-NxbDeltaEvidence `
        -Control $ControlArm.process_metrics.peak_working_set_bytes `
        -Capture $CaptureArm.process_metrics.peak_working_set_bytes `
        -SourceUnit 'bytes' `
        -AbsoluteUnit 'bytes' `
        -Label 'peak_working_set'
    $privateBytes = New-NxbDeltaEvidence `
        -Control $ControlArm.process_metrics.peak_private_bytes `
        -Capture $CaptureArm.process_metrics.peak_private_bytes `
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

function New-NxbDistributionEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Values,

        [Parameter(Mandatory)]
        [string]$Unit,

        [Parameter(Mandatory)]
        [string]$UnavailableReason
    )

    $numericValues = @($Values | Where-Object { $null -ne $_ } | ForEach-Object {
        [double]$_
    })
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
        $sum += [double]$value
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

$parentFull = Get-NxbFullPath -Path $ExperimentPath
$parentManifestPath = Join-Path $parentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $parentManifestPath -PathType Leaf)) {
    throw "Parent calibration manifest bulunamadı: $parentManifestPath"
}
$parentManifest = Read-NxbJson -Path $parentManifestPath
if ([string]$parentManifest.status -ne 'prepared') {
    throw "Calibration parent experiment prepared olmalıdır: $($parentManifest.status)"
}

$analysisRoot = Join-Path $parentFull 'analysis'
$resultPath = Join-Path $analysisRoot 'collector-overhead-calibration.json'
$warmupPath = Join-Path $analysisRoot 'collector-overhead-warmups.json'
if (Test-Path -LiteralPath $resultPath) {
    throw "Calibration result zaten var: $resultPath"
}

$experimentsRoot = Split-Path -Parent $parentFull
if ((Split-Path -Leaf $experimentsRoot) -cne 'experiments') {
    throw "Parent experiment beklenen experiments kökü altında değil: $parentFull"
}
$labRoot = Split-Path -Parent $experimentsRoot
$parentExperimentId = [string]$parentManifest.experiment_id
if ((Split-Path -Leaf $parentFull) -cne $parentExperimentId) {
    throw 'Parent manifest experiment_id ile dizin adı uyuşmuyor.'
}

if (-not $PSCmdlet.ShouldProcess(
    $parentFull,
    "Run $RepetitionCount paired control/capture overhead trials"
)) {
    return
}

New-Item -ItemType Directory -Path $analysisRoot -Force | Out-Null
$parentIdentity = Get-NxbCalibrationIdentity -Path $parentFull
if ([string]$parentIdentity.experiment_id -cne $parentExperimentId) {
    throw 'Parent observation identity experiment_id uyuşmuyor.'
}

$powerPolicy = Get-NxbActivePowerPolicy
if ([string]$powerPolicy.status -ne 'available') {
    throw "Active power policy güvenilir biçimde çözümlenemedi: $($powerPolicy.source)"
}
$powerPolicyFingerprint = Get-NxbCanonicalJsonHash -InputObject $powerPolicy

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$workloadPath = Join-Path $repositoryRoot 'tools\Invoke-NxbCpuWorkload.ps1'
$workloadItem = Get-Item -LiteralPath $workloadPath
$workload = [ordered]@{
    id = 'nxb.cpu.sha256-chain.v1'
    name = 'NXB deterministic SHA-256 CPU workload'
    command = [ordered]@{
        path = 'tools/Invoke-NxbCpuWorkload.ps1'
        arguments = @(
            '-Iterations',
            [string]$Iterations,
            '-Seed',
            [string]$Seed
        )
        sha256 = (Get-FileHash -LiteralPath $workloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        length = [int64]$workloadItem.Length
    }
    parameters = [ordered]@{
        iterations = $Iterations
        seed = $Seed
        buffer_bytes = 4096
        algorithm = 'SHA-256 chain'
    }
    timeout_seconds = $TimeoutSeconds
}
$workloadFingerprint = Get-NxbCanonicalJsonHash -InputObject $workload

$warmups = [Collections.Generic.List[object]]::new()
try {
    for ($warmupOrdinal = 1; $warmupOrdinal -le $WarmupCount; $warmupOrdinal++) {
        $context = New-NxbChildExperimentContext `
            -LabRoot $labRoot `
            -Ordinal $warmupOrdinal `
            -Arm warmup `
            -ParentMachineId ([string]$parentIdentity.machine_id) `
            -ParentBootId ([string]$parentIdentity.boot_id)
        $currentPower = Get-NxbActivePowerPolicy
        $currentFingerprint = Get-NxbCanonicalJsonHash -InputObject $currentPower
        if ($currentFingerprint -cne $powerPolicyFingerprint) {
            throw "Power policy warmup öncesinde değişti: $warmupOrdinal"
        }

        $warmupMeasurement = & (Join-Path $PSScriptRoot 'Invoke-NxbMeasuredWorkload.ps1') `
            -ExperimentPath $context.Path `
            -Iterations $Iterations `
            -Seed $Seed `
            -TimeoutSeconds $TimeoutSeconds `
            -SampleIntervalMilliseconds $SampleIntervalMilliseconds `
            -PowerShellExecutablePath $PowerShellExecutablePath `
            -PassThru
        $warmups.Add([ordered]@{
            ordinal = $warmupOrdinal
            experiment_id = $context.ExperimentId
            experiment_relative_path = $context.RelativePath
            status = [string]$warmupMeasurement.status
            duration_ms = [double]$warmupMeasurement.duration_ms
            result = $warmupMeasurement.result
        })

        if ([string]$warmupMeasurement.status -ne 'measured') {
            Invoke-NxbChildFailureTransition `
                -ChildPath $context.Path `
                -Reason 'Calibration warmup failed.'
            throw "Calibration warmup başarısız: $warmupOrdinal"
        }
        & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $context.Path

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

    $pairs = [Collections.Generic.List[object]]::new()
    $durationRelative = [Collections.Generic.List[object]]::new()
    $cpuRelative = [Collections.Generic.List[object]]::new()
    $workingSetRelative = [Collections.Generic.List[object]]::new()
    $privateBytesRelative = [Collections.Generic.List[object]]::new()
    $successfulPairCount = 0

    for ($ordinal = 1; $ordinal -le $RepetitionCount; $ordinal++) {
        $firstArm = Get-NxbFirstArm -ProtocolOrdering $Ordering -Ordinal $ordinal
        $contexts = @{
            control = New-NxbChildExperimentContext `
                -LabRoot $labRoot `
                -Ordinal $ordinal `
                -Arm control `
                -ParentMachineId ([string]$parentIdentity.machine_id) `
                -ParentBootId ([string]$parentIdentity.boot_id)
            capture = New-NxbChildExperimentContext `
                -LabRoot $labRoot `
                -Ordinal $ordinal `
                -Arm capture `
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
            $currentPower = Get-NxbActivePowerPolicy
            $currentFingerprint = Get-NxbCanonicalJsonHash -InputObject $currentPower
            if ($currentFingerprint -cne $powerPolicyFingerprint) {
                throw "Power policy pair $ordinal $armName öncesinde değişti."
            }

            if ($armName -eq 'control') {
                $arms.control = Invoke-NxbControlArm `
                    -Context $contexts.control `
                    -WorkloadIterations $Iterations `
                    -WorkloadSeed $Seed `
                    -WorkloadTimeoutSeconds $TimeoutSeconds `
                    -SamplingMilliseconds $SampleIntervalMilliseconds `
                    -PowerShellPath $PowerShellExecutablePath
            }
            else {
                $arms.capture = Invoke-NxbCaptureArm `
                    -Context $contexts.capture `
                    -WorkloadIterations $Iterations `
                    -WorkloadSeed $Seed `
                    -WorkloadTimeoutSeconds $TimeoutSeconds `
                    -SamplingMilliseconds $SampleIntervalMilliseconds `
                    -WprPath $WprExecutablePath `
                    -PowerShellPath $PowerShellExecutablePath
            }

            $afterPower = Get-NxbActivePowerPolicy
            $afterFingerprint = Get-NxbCanonicalJsonHash -InputObject $afterPower
            if ($afterFingerprint -cne $powerPolicyFingerprint) {
                $arms[$armName].status = 'failed'
                $arms[$armName].diagnostics = @($arms[$armName].diagnostics) + @(
                    "Power policy $armName arm sırasında değişti."
                )
                Invoke-NxbChildFailureTransition `
                    -ChildPath $contexts[$armName].Path `
                    -Reason 'Power policy changed during overhead arm.'
            }

            if ($CooldownSeconds -gt 0) {
                Start-Sleep -Seconds $CooldownSeconds
            }
        }

        $deltas = New-NxbPairDeltas `
            -ControlArm $arms.control `
            -CaptureArm $arms.capture
        foreach ($entry in @(
            @($durationRelative, $deltas.RelativeValues.duration),
            @($cpuRelative, $deltas.RelativeValues.cpu_time),
            @($workingSetRelative, $deltas.RelativeValues.peak_working_set),
            @($privateBytesRelative, $deltas.RelativeValues.peak_private_bytes)
        )) {
            if ($null -ne $entry[1]) {
                $entry[0].Add($entry[1])
            }
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
            pair_id = ("pair-{0:D4}" -f $ordinal)
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
        calibration_id = "overhead-$parentExperimentId"
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
            duration_delta_percent = New-NxbDistributionEvidence `
                -Values @($durationRelative) `
                -Unit 'percent' `
                -UnavailableReason 'Measured duration deltas bulunamadı.'
            cpu_time_delta_percent = New-NxbDistributionEvidence `
                -Values @($cpuRelative) `
                -Unit 'percent' `
                -UnavailableReason 'Measured CPU-time deltas bulunamadı.'
            peak_working_set_delta_percent = New-NxbDistributionEvidence `
                -Values @($workingSetRelative) `
                -Unit 'percent' `
                -UnavailableReason 'Measured working-set deltas bulunamadı.'
            peak_private_bytes_delta_percent = New-NxbDistributionEvidence `
                -Values @($privateBytesRelative) `
                -Unit 'percent' `
                -UnavailableReason 'Measured private-bytes deltas bulunamadı.'
            threshold_policy = [ordered]@{
                status = 'not_declared'
                reason = 'Thresholds require measured representative evidence and are not declared by this runner.'
            }
        }
    }

    Write-NxbJsonAtomic -Path $resultPath -InputObject $calibration -Depth 32
    & (Join-Path $PSScriptRoot 'Test-CollectorOverheadCalibration.ps1') `
        -Path $resultPath
    & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
        -ExperimentPath $parentFull

    Write-Host "Collector overhead calibration tamamlandı: $resultPath"
    if ($failedPairCount -gt 0) {
        throw "Calibration evidence yazıldı ancak $failedPairCount pair başarısız oldu: $resultPath"
    }

    if ($PassThru) {
        return [pscustomobject]$calibration
    }
    Write-Output $resultPath
}
catch {
    $failure = $_.Exception.Message
    try {
        $currentParent = Read-NxbJson -Path $parentManifestPath
        if ([string]$currentParent.status -notin @('failed', 'finalized')) {
            & (Join-Path $PSScriptRoot 'Set-ExperimentFailed.ps1') `
                -ExperimentPath $parentFull `
                -Reason "Collector overhead calibration failed: $failure" `
                -Confirm:$false
        }
    }
    catch {
        Write-Warning "Parent calibration failed durumu yazılamadı: $($_.Exception.Message)"
    }
    throw
}
