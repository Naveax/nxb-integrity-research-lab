[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RecordPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

$record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json
if ([string]$record.record_type -cne 'clock_offset') {
    throw "Record clock_offset değil: $RecordPath"
}

$payloadHash = Get-NxbCanonicalJsonHash -InputObject $record.payload
if ($payloadHash -cne [string]$record.payload_sha256) {
    throw 'Clock-offset payload hash uyuşmuyor.'
}

$recordHash = Get-NxbCanonicalJsonHash `
    -InputObject $record `
    -ExcludeRootProperty record_sha256
if ($recordHash -cne [string]$record.record_sha256) {
    throw 'Clock-offset record hash uyuşmuyor.'
}

$payload = $record.payload
$controllerSend = [decimal][int64]$payload.controller_send_utc_ns
$controllerReceive = [decimal][int64]$payload.controller_receive_utc_ns
$targetReceive = [decimal][int64]$payload.target_receive_monotonic_ns
$targetSend = [decimal][int64]$payload.target_send_monotonic_ns

if ($controllerReceive -lt $controllerSend) {
    throw 'Clock-offset controller timestamp sırası geçersiz.'
}
if ($targetSend -lt $targetReceive) {
    throw 'Clock-offset target timestamp sırası geçersiz.'
}

$controllerElapsed = $controllerReceive - $controllerSend
$targetElapsed = $targetSend - $targetReceive
$roundTrip = $controllerElapsed - $targetElapsed
if ($roundTrip -lt 0) {
    throw 'Clock-offset round-trip negatif olamaz.'
}

$offsetNumerator = $controllerSend + $controllerReceive - $targetReceive - $targetSend
$estimatedOffset = [decimal]::Truncate($offsetNumerator / [decimal]2)
$uncertainty = [decimal]::Ceiling($roundTrip / [decimal]2)

$expected = [ordered]@{
    controller_elapsed_ns = $controllerElapsed
    target_elapsed_ns = $targetElapsed
    estimated_offset_ns = $estimatedOffset
    round_trip_ns = $roundTrip
    uncertainty_ns = $uncertainty
}
foreach ($entry in $expected.GetEnumerator()) {
    $actual = [decimal][int64]$payload.($entry.Key)
    if ($actual -ne $entry.Value) {
        throw "Clock-offset arithmetic uyuşmuyor: $($entry.Key)"
    }
}

if ([string]$payload.measurement_method -cne 'four_timestamp_midpoint_v1') {
    throw 'Desteklenmeyen clock-offset measurement method.'
}
if ([string]$payload.offset_rounding -cne 'toward_zero') {
    throw 'Desteklenmeyen clock-offset rounding kuralı.'
}

$result = [pscustomobject]@{
    IsValid = $true
    RecordPath = [IO.Path]::GetFullPath($RecordPath)
    EstimatedOffsetNs = [int64]$estimatedOffset
    RoundTripNs = [int64]$roundTrip
    UncertaintyNs = [int64]$uncertainty
    MeasurementMethod = [string]$payload.measurement_method
}

if ($PassThru) {
    return $result
}

Write-Host "Clock-offset evidence doğrulandı: $RecordPath"
