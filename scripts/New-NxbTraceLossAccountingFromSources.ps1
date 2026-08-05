[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$PreStopSnapshotPath,

    [Parameter()]
    [string]$PostStopStatisticsPath,

    [Parameter()]
    [string]$XperfExecutablePath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

function Select-NxbCounterSource {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$PostStopCounter,

        [Parameter()]
        [AllowNull()]
        [object]$PreStopCounter,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MissingReason
    )

    if ($null -ne $PostStopCounter) {
        $postStatus = [string]$PostStopCounter.status
        if ($postStatus -in @('measured', 'failed')) {
            return $PostStopCounter
        }
    }

    if ($null -ne $PreStopCounter) {
        $preStatus = [string]$PreStopCounter.status
        if ($preStatus -in @('measured', 'failed')) {
            return $PreStopCounter
        }
    }

    if ($null -ne $PostStopCounter) {
        return $PostStopCounter
    }
    if ($null -ne $PreStopCounter) {
        return $PreStopCounter
    }

    return [pscustomobject]@{
        status = 'not_assessed'
        value = $null
        source = $null
        reason = $MissingReason
    }
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$analysisRoot = Join-Path $experimentFull 'analysis'
New-Item -ItemType Directory -Path $analysisRoot -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($PreStopSnapshotPath)) {
    $PreStopSnapshotPath = Join-Path $analysisRoot 'wpr-status-pre-stop.json'
}
if ([string]::IsNullOrWhiteSpace($PostStopStatisticsPath)) {
    $PostStopStatisticsPath = Join-Path $analysisRoot 'etl-trace-statistics.json'
}
$preStopFull = Get-NxbFullPath -Path $PreStopSnapshotPath
$postStopFull = Get-NxbFullPath -Path $PostStopStatisticsPath
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $preStopFull)
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $postStopFull)

if (-not (Test-Path -LiteralPath $postStopFull -PathType Leaf)) {
    if ($PSCmdlet.ShouldProcess($postStopFull, 'Collect post-stop ETL trace statistics')) {
        $postStopFull = & (Join-Path $PSScriptRoot 'Get-NxbEtlTraceStatistics.ps1') `
            -ExperimentPath $experimentFull `
            -XperfExecutablePath $XperfExecutablePath `
            -OutputPath $postStopFull `
            -Confirm:$false
    }
}

$preStop = if (Test-Path -LiteralPath $preStopFull -PathType Leaf) {
    Read-NxbJson -Path $preStopFull
}
else {
    $null
}
$postStop = if (Test-Path -LiteralPath $postStopFull -PathType Leaf) {
    Read-NxbJson -Path $postStopFull
}
else {
    $null
}

$eventsLost = Select-NxbCounterSource `
    -PostStopCounter $(if ($null -ne $postStop) { $postStop.events_lost } else { $null }) `
    -PreStopCounter $(if ($null -ne $preStop) { $preStop.events_lost } else { $null }) `
    -MissingReason 'Pre-stop ve post-stop Events Lost kaynakları bulunamadı.'
$buffersLost = Select-NxbCounterSource `
    -PostStopCounter $(if ($null -ne $postStop) { $postStop.buffers_lost } else { $null }) `
    -PreStopCounter $(if ($null -ne $preStop) { $preStop.buffers_lost } else { $null }) `
    -MissingReason 'Pre-stop ve post-stop Buffers Lost kaynakları bulunamadı.'
$realtimeBuffersLost = Select-NxbCounterSource `
    -PostStopCounter $(if ($null -ne $postStop) { $postStop.realtime_buffers_lost } else { $null }) `
    -PreStopCounter $(if ($null -ne $preStop) { $preStop.realtime_buffers_lost } else { $null }) `
    -MissingReason 'Real-time Buffers Lost kaynağı bulunamadı.'

$selectedCounters = @($eventsLost, $buffersLost, $realtimeBuffersLost)
$mergeStatus = if (@($selectedCounters | Where-Object status -eq 'failed').Count -gt 0) {
    'failed'
}
elseif (@($selectedCounters | Where-Object status -eq 'measured').Count -gt 0) {
    'measured'
}
else {
    'unavailable'
}

$mergeMaterial = [ordered]@{
    pre_stop = if ($null -eq $preStop) { $null } else { $preStop }
    post_stop = if ($null -eq $postStop) { $null } else { $postStop }
    selected = [ordered]@{
        events_lost = $eventsLost
        buffers_lost = $buffersLost
        realtime_buffers_lost = $realtimeBuffersLost
    }
}
$mergeHash = Get-NxbCanonicalJsonHash -InputObject $mergeMaterial
$mergedSnapshot = [ordered]@{
    schema_version = 1
    captured_utc = [DateTime]::UtcNow.ToString('o')
    experiment_id = [string](Split-Path -Leaf $experimentFull)
    command = [ordered]@{
        executable = 'nxb-source-merge'
        arguments = @($preStopFull, $postStopFull)
    }
    status = $mergeStatus
    exit_code = $null
    raw_output_sha256 = $mergeHash
    raw_output = @(
        "pre_stop=$preStopFull",
        "post_stop=$postStopFull"
    )
    events_lost = $eventsLost
    buffers_lost = $buffersLost
    realtime_buffers_lost = $realtimeBuffersLost
}

$mergedPath = Join-Path $analysisRoot 'trace-loss-counter-sources.json'
if (Test-Path -LiteralPath $mergedPath) {
    throw "Merged trace-loss counter snapshot zaten var: $mergedPath"
}
if ($PSCmdlet.ShouldProcess($mergedPath, 'Write merged trace-loss counter sources')) {
    Write-NxbJsonAtomic -Path $mergedPath -InputObject $mergedSnapshot -Depth 24
}

$accountingArguments = @{
    ExperimentPath = $experimentFull
    StatusSnapshotPath = $mergedPath
    Confirm = $false
}
if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $accountingArguments.OutputPath = $OutputPath
}
if ($PassThru) {
    $accountingArguments.PassThru = $true
}

& (Join-Path $PSScriptRoot 'New-NxbTraceLossAccounting.ps1') @accountingArguments
