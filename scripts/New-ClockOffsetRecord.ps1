[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter(Mandatory)]
    [ValidateRange(0, 9223372036854775807)]
    [int64]$ControllerSendUtcNs,

    [Parameter(Mandatory)]
    [ValidateRange(0, 9223372036854775807)]
    [int64]$TargetReceiveMonotonicNs,

    [Parameter(Mandatory)]
    [ValidateRange(0, 9223372036854775807)]
    [int64]$TargetSendMonotonicNs,

    [Parameter(Mandatory)]
    [ValidateRange(0, 9223372036854775807)]
    [int64]$ControllerReceiveUtcNs,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SessionId,

    [Parameter()]
    [ValidateSet('four_timestamp_midpoint_v1')]
    [string]$MeasurementMethod = 'four_timestamp_midpoint_v1',

    [Parameter()]
    [DateTime]$CapturedUtc = [DateTime]::UtcNow,

    [Parameter()]
    [ValidateRange(-1, 9223372036854775807)]
    [int64]$MonotonicNs = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ControllerReceiveUtcNs -lt $ControllerSendUtcNs) {
    throw 'Controller receive timestamp send timestamp değerinden küçük olamaz.'
}
if ($TargetSendMonotonicNs -lt $TargetReceiveMonotonicNs) {
    throw 'Target send timestamp receive timestamp değerinden küçük olamaz.'
}

$controllerElapsed = [decimal]$ControllerReceiveUtcNs - [decimal]$ControllerSendUtcNs
$targetElapsed = [decimal]$TargetSendMonotonicNs - [decimal]$TargetReceiveMonotonicNs
$roundTrip = $controllerElapsed - $targetElapsed
if ($roundTrip -lt 0) {
    throw 'Controller elapsed süresi target işlem süresinden küçük; clock measurement geçersiz.'
}

$offsetNumerator = (
    [decimal]$ControllerSendUtcNs +
    [decimal]$ControllerReceiveUtcNs -
    [decimal]$TargetReceiveMonotonicNs -
    [decimal]$TargetSendMonotonicNs
)
$estimatedOffset = [decimal]::Truncate($offsetNumerator / [decimal]2)
$uncertainty = [decimal]::Ceiling($roundTrip / [decimal]2)

$boundedValues = [ordered]@{
    controller_elapsed_ns = $controllerElapsed
    target_elapsed_ns = $targetElapsed
    round_trip_ns = $roundTrip
    estimated_offset_ns = $estimatedOffset
    uncertainty_ns = $uncertainty
}
foreach ($boundedValue in $boundedValues.GetEnumerator()) {
    if ($boundedValue.Value -lt [decimal][int64]::MinValue -or
        $boundedValue.Value -gt [decimal][int64]::MaxValue) {
        throw "Clock evidence int64 sınırını aşıyor: $($boundedValue.Key)"
    }
}

$payload = [ordered]@{
    clock_offset_version = 1
    measurement_method = $MeasurementMethod
    controller_send_utc_ns = $ControllerSendUtcNs
    target_receive_monotonic_ns = $TargetReceiveMonotonicNs
    target_send_monotonic_ns = $TargetSendMonotonicNs
    controller_receive_utc_ns = $ControllerReceiveUtcNs
    controller_elapsed_ns = [int64]$controllerElapsed
    target_elapsed_ns = [int64]$targetElapsed
    estimated_offset_ns = [int64]$estimatedOffset
    round_trip_ns = [int64]$roundTrip
    uncertainty_ns = [int64]$uncertainty
    offset_rounding = 'toward_zero'
}

& (Join-Path $PSScriptRoot 'New-EvidenceStoreRecord.ps1') `
    -ExperimentPath $ExperimentPath `
    -RecordType clock_offset `
    -Payload $payload `
    -SessionId $SessionId `
    -CapturedUtc $CapturedUtc `
    -MonotonicNs $MonotonicNs
