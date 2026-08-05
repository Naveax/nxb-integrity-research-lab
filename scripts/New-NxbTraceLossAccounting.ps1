[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$StatusSnapshotPath,

    [Parameter()]
    [string]$EtlMetadataPath,

    [Parameter()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function ConvertTo-NxbCounterEvidence {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Counter,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$MissingReason
    )

    if ($null -eq $Counter) {
        return [ordered]@{
            status = 'not_assessed'
            value = $null
            unit = 'count'
            source = $null
            reason = $MissingReason
        }
    }

    $status = [string]$Counter.status
    if ($status -eq 'measured') {
        return [ordered]@{
            status = 'measured'
            value = [int64]$Counter.value
            unit = 'count'
            source = [string]$Counter.source
            reason = $null
        }
    }

    if ($status -notin @('unsupported', 'unavailable', 'failed', 'not_assessed')) {
        return [ordered]@{
            status = 'failed'
            value = $null
            unit = 'count'
            source = $null
            reason = "Desteklenmeyen native counter durumu: $status"
        }
    }

    return [ordered]@{
        status = $status
        value = $null
        unit = 'count'
        source = if ([string]::IsNullOrWhiteSpace([string]$Counter.source)) {
            $null
        }
        else {
            [string]$Counter.source
        }
        reason = if ([string]::IsNullOrWhiteSpace([string]$Counter.reason)) {
            'Native counter ölçülemedi.'
        }
        else {
            [string]$Counter.reason
        }
    }
}

function Get-NxbTraceLossClassification {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object[]]$Counters
    )

    $measured = @($Counters | Where-Object status -eq 'measured')
    $total = [int64]0
    foreach ($counter in $measured) {
        $total += [int64]$counter.value
    }

    if ($total -gt 0) {
        return [ordered]@{
            classification = 'native_loss_observed'
            measured_counter_count = $measured.Count
            total_reported_loss = $total
            reason = $null
            assessed = $true
        }
    }

    if ($measured.Count -eq $Counters.Count) {
        return [ordered]@{
            classification = 'no_native_loss_reported'
            measured_counter_count = $measured.Count
            total_reported_loss = [int64]0
            reason = $null
            assessed = $true
        }
    }

    if (@($Counters | Where-Object status -eq 'failed').Count -gt 0) {
        return [ordered]@{
            classification = 'failed'
            measured_counter_count = $measured.Count
            total_reported_loss = $null
            reason = 'Bir veya daha fazla native trace-loss counter kaynağı başarısız oldu.'
            assessed = $false
        }
    }

    return [ordered]@{
        classification = 'not_assessed'
        measured_counter_count = $measured.Count
        total_reported_loss = $null
        reason = 'Tüm zorunlu native trace-loss counter alanları ölçülemedi.'
        assessed = $false
    }
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$experimentId = [string](Split-Path -Leaf $experimentFull)
$manifestPath = Join-Path $experimentFull 'manifest.json'
$identityPath = Join-Path $experimentFull 'baseline\observation-identity.json'
$sessionPath = Join-Path $experimentFull 'trace-session.json'

foreach ($requiredPath in @($manifestPath, $identityPath, $sessionPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Trace-loss accounting girdisi bulunamadı: $requiredPath"
    }
}

if ([string]::IsNullOrWhiteSpace($EtlMetadataPath)) {
    $EtlMetadataPath = Join-Path $experimentFull 'traces\performance.etl.json'
}
$etlMetadataFull = Get-NxbFullPath -Path $EtlMetadataPath
if (-not (Test-Path -LiteralPath $etlMetadataFull -PathType Leaf)) {
    throw "ETL metadata bulunamadı: $etlMetadataFull"
}

if ([string]::IsNullOrWhiteSpace($StatusSnapshotPath)) {
    $StatusSnapshotPath = Join-Path $experimentFull 'analysis\wpr-status-pre-stop.json'
}
$statusSnapshotFull = Get-NxbFullPath -Path $StatusSnapshotPath

$manifest = Read-NxbJson -Path $manifestPath
$identity = Read-NxbJson -Path $identityPath
$session = Read-NxbJson -Path $sessionPath
$etlMetadata = Read-NxbJson -Path $etlMetadataFull

if ([string]$identity.experiment_id -cne $experimentId) {
    throw 'Observation identity experiment_id ile deney dizini uyuşmuyor.'
}
if ([string]$session.profile_provenance_sha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Trace session profile provenance SHA-256 değeri geçersiz.'
}

$statusSnapshot = if (Test-Path -LiteralPath $statusSnapshotFull -PathType Leaf) {
    Read-NxbJson -Path $statusSnapshotFull
}
else {
    $null
}

$eventsLost = ConvertTo-NxbCounterEvidence `
    -Counter $(if ($null -ne $statusSnapshot) { $statusSnapshot.events_lost } else { $null }) `
    -MissingReason 'Pre-stop WPR status snapshot bulunamadı.'
$buffersLost = ConvertTo-NxbCounterEvidence `
    -Counter $(if ($null -ne $statusSnapshot) { $statusSnapshot.buffers_lost } else { $null }) `
    -MissingReason 'Pre-stop WPR status snapshot bulunamadı.'
$realtimeBuffersLost = ConvertTo-NxbCounterEvidence `
    -Counter $(if ($null -ne $statusSnapshot) { $statusSnapshot.realtime_buffers_lost } else { $null }) `
    -MissingReason 'Pre-stop WPR status snapshot bulunamadı.'

$counterSet = @($eventsLost, $buffersLost, $realtimeBuffersLost)
$traceLossState = Get-NxbTraceLossClassification -Counters $counterSet

$profileProvenance = $session.profile_provenance
$bounded = [bool]$profileProvenance.bounded
$fileMode = [string]$profileProvenance.file_mode
$maximumFileSizeMiB = if ($null -eq $profileProvenance.maximum_file_size_mib) {
    $null
}
else {
    [int64]$profileProvenance.maximum_file_size_mib
}
$etlLength = [int64]$etlMetadata.length
$etlSha256 = ([string]$etlMetadata.sha256).ToLowerInvariant()

$etlEvidence = if ($etlSha256 -match '^[0-9a-f]{64}$' -and $etlLength -ge 0) {
    [ordered]@{
        status = 'measured'
        sha256 = $etlSha256
        length = $etlLength
        reason = $null
    }
}
else {
    [ordered]@{
        status = 'failed'
        sha256 = $null
        length = $null
        reason = 'ETL metadata SHA-256 veya length alanı geçersiz.'
    }
}

$circularAssessed = $false
if (-not $bounded -or $fileMode -cne 'Circular') {
    $circularOverwrite = [ordered]@{
        classification = 'not_applicable'
        capacity_bytes = $null
        final_etl_length = $null
        utilization_ratio = $null
        risk_threshold_ratio = 0.9
        risk_reasons = @()
        reason = 'Capture bounded circular file mode kullanmıyor.'
    }
    $circularAssessed = $true
}
elseif ($null -eq $maximumFileSizeMiB -or $etlEvidence.status -ne 'measured') {
    $circularOverwrite = [ordered]@{
        classification = 'failed'
        capacity_bytes = if ($null -eq $maximumFileSizeMiB) { $null } else { $maximumFileSizeMiB * 1MB }
        final_etl_length = $null
        utilization_ratio = $null
        risk_threshold_ratio = 0.9
        risk_reasons = @()
        reason = 'Circular kapasite veya ETL uzunluğu ölçülemedi.'
    }
}
else {
    $capacityBytes = [int64]($maximumFileSizeMiB * 1MB)
    $utilizationRatio = [double]$etlLength / [double]$capacityBytes
    $riskReasons = [Collections.Generic.List[string]]::new()
    if ($utilizationRatio -ge 0.9) {
        $riskReasons.Add('capacity_threshold_reached')
    }
    if ($etlLength -gt $capacityBytes) {
        $riskReasons.Add('etl_length_exceeds_declared_capacity')
    }

    $circularOverwrite = [ordered]@{
        classification = if ($riskReasons.Count -gt 0) { 'risk_observed' } else { 'no_risk_observed' }
        capacity_bytes = $capacityBytes
        final_etl_length = $etlLength
        utilization_ratio = $utilizationRatio
        risk_threshold_ratio = 0.9
        risk_reasons = @($riskReasons)
        reason = $null
    }
    $circularAssessed = $true
}

$failed = $traceLossState.classification -eq 'failed' -or `
    $circularOverwrite.classification -eq 'failed'
$evidenceCompleteness = if ($failed) {
    'failed'
}
elseif ([bool]$traceLossState.assessed -and $circularAssessed) {
    'complete'
}
elseif ([bool]$traceLossState.assessed -or $circularAssessed) {
    'partial'
}
else {
    'unavailable'
}

$document = [ordered]@{
    schema_version = 1
    accounting_id = "trace-loss-$([guid]::NewGuid().ToString('N'))"
    experiment_id = $experimentId
    experiment_relative_path = "experiments/$experimentId"
    machine_id = [string]$identity.machine_id
    boot_id = [string]$identity.boot_id
    captured_utc = [DateTime]::UtcNow.ToString('o')
    capture = [ordered]@{
        started_utc = [string]$session.started_utc
        stopped_utc = [string]$etlMetadata.stopped_utc
        profile = [ordered]@{
            name = [string]$session.profile
            provenance_sha256 = [string]$session.profile_provenance_sha256
            bounded = $bounded
            logging_mode = [string]$profileProvenance.logging_mode
            file_mode = $fileMode
            buffer_size_kib = if ($null -eq $profileProvenance.buffer_size_kib) { $null } else { [int]$profileProvenance.buffer_size_kib }
            buffers = if ($null -eq $profileProvenance.buffers) { $null } else { [int]$profileProvenance.buffers }
            maximum_file_size_mib = $maximumFileSizeMiB
        }
        etl = $etlEvidence
    }
    native_counters = [ordered]@{
        events_lost = $eventsLost
        buffers_lost = $buffersLost
        realtime_buffers_lost = $realtimeBuffersLost
    }
    trace_loss = [ordered]@{
        classification = [string]$traceLossState.classification
        measured_counter_count = [int]$traceLossState.measured_counter_count
        total_reported_loss = $traceLossState.total_reported_loss
        reason = $traceLossState.reason
    }
    circular_overwrite = $circularOverwrite
    summary = [ordered]@{
        evidence_completeness = $evidenceCompleteness
        trace_loss_assessed = [bool]$traceLossState.assessed
        circular_overwrite_assessed = $circularAssessed
    }
    claims = [ordered]@{
        trace_loss_absence = $false
        circular_overwrite_absence = $false
        capture_completeness = 'not_claimed'
    }
}

$analysisRoot = Join-Path $experimentFull 'analysis'
New-Item -ItemType Directory -Path $analysisRoot -Force | Out-Null
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $analysisRoot 'trace-loss-accounting.json'
}
$outputFull = Get-NxbFullPath -Path $OutputPath
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $outputFull)
if (Test-Path -LiteralPath $outputFull) {
    throw "Trace-loss accounting çıktısı zaten var: $outputFull"
}

$written = $false
if ($PSCmdlet.ShouldProcess($outputFull, 'Write trace-loss accounting evidence')) {
    Write-NxbJsonAtomic -Path $outputFull -InputObject $document -Depth 20
    & (Join-Path $PSScriptRoot 'Test-TraceLossAccounting.ps1') -Path $outputFull
    $written = $true
}

if ($PassThru) {
    return [pscustomobject]$document
}
if ($written) {
    Write-Output $outputFull
}
