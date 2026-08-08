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

function Test-NxbSourceDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Document,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExperimentId,

        [Parameter(Mandatory)]
        [ValidateSet('pre_stop', 'post_stop')]
        [string]$SourceType
    )

    if ([string]$Document.experiment_id -cne $ExperimentId) {
        throw "$SourceType source experiment_id ile deney dizini uyuşmuyor."
    }

    $hashValue = if ($SourceType -eq 'pre_stop') {
        [string]$Document.raw_output_sha256
    }
    else {
        [string]$Document.statistics_sha256
    }
    if ($hashValue -notmatch '^[0-9a-f]{64}$') {
        throw "$SourceType source SHA-256 alanı geçersiz."
    }
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
[void](Test-NxbPathSafety -Path $experimentFull -RootPath $experimentFull)
$experimentId = [string](Split-Path -Leaf $experimentFull)
$analysisRoot = Join-Path $experimentFull 'analysis'

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

foreach ($existingInput in @($preStopFull, $postStopFull)) {
    if (Test-Path -LiteralPath $existingInput -PathType Leaf) {
        [void](Test-NxbPathSafety -Path $existingInput -RootPath $experimentFull)
    }
}

if (-not $PSCmdlet.ShouldProcess(
    $experimentFull,
    'Collect, merge and validate trace-loss accounting sources'
)) {
    return
}

if (-not (Test-Path -LiteralPath $analysisRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $analysisRoot -Force | Out-Null
}
[void](Test-NxbPathSafety -Path $analysisRoot -RootPath $experimentFull)

if (-not (Test-Path -LiteralPath $postStopFull -PathType Leaf)) {
    $postStopFull = & (Join-Path $PSScriptRoot 'Get-NxbEtlTraceStatistics.ps1') `
        -ExperimentPath $experimentFull `
        -XperfExecutablePath $XperfExecutablePath `
        -OutputPath $postStopFull `
        -Confirm:$false
}

$preStop = if (Test-Path -LiteralPath $preStopFull -PathType Leaf) {
    $document = Read-NxbJson -Path $preStopFull
    Test-NxbSourceDocument `
        -Document $document `
        -ExperimentId $experimentId `
        -SourceType pre_stop
    $document
}
else {
    $null
}
$postStop = if (Test-Path -LiteralPath $postStopFull -PathType Leaf) {
    $document = Read-NxbJson -Path $postStopFull
    Test-NxbSourceDocument `
        -Document $document `
        -ExperimentId $experimentId `
        -SourceType post_stop
    $document
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
    experiment_id = $experimentId
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
Write-NxbJsonAtomic -Path $mergedPath -InputObject $mergedSnapshot -Depth 24

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
