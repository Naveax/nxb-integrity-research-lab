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
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

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
        if ([string]::IsNullOrWhiteSpace([string]$Counter.source)) {
            return [ordered]@{
                status = 'failed'
                value = $null
                unit = 'count'
                source = $null
                reason = 'Measured native counter source alanı eksik.'
            }
        }
        return [ordered]@{
            status = 'measured'
            value = [int64]$Counter.value
            unit = 'count'
            source = [string]$Counter.source
            reason = $null
        }
    }

    if ($status -notin @(
        'unsupported',
        'unavailable',
        'failed',
        'not_assessed',
        'not_applicable'
    )) {
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

    $applicable = @($Counters | Where-Object status -ne 'not_applicable')
    $measured = @($applicable | Where-Object status -eq 'measured')
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

    if ($applicable.Count -gt 0 -and $measured.Count -eq $applicable.Count) {
        return [ordered]@{
            classification = 'no_native_loss_reported'
            measured_counter_count = $measured.Count
            total_reported_loss = [int64]0
            reason = $null
            assessed = $true
        }
    }

    if (@($applicable | Where-Object status -eq 'failed').Count -gt 0) {
        return [ordered]@{
            classification = 'failed'
            measured_counter_count = $measured.Count
            total_reported_loss = $null
            reason = 'Bir veya daha fazla uygulanabilir native trace-loss counter kaynağı başarısız oldu.'
            assessed = $false
        }
    }

    return [ordered]@{
        classification = 'not_assessed'
        measured_counter_count = $measured.Count
        total_reported_loss = $null
        reason = 'Tüm uygulanabilir native trace-loss counter alanları ölçülemedi.'
        assessed = $false
    }
}

function Resolve-NxbEvidencePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$ExperimentRoot,

        [Parameter()]
        [switch]$RequireLeaf
    )

    $full = Get-NxbFullPath -Path $Path
    [void](Get-NxbRelativePath -BasePath $ExperimentRoot -ChildPath $full)

    if ($RequireLeaf) {
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "Kanıt girdisi bulunamadı: $full"
        }
        [void](Test-NxbPathSafety -Path $full -RootPath $ExperimentRoot)
    }
    else {
        $parent = Split-Path -Parent $full
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            throw "Kanıt çıktı dizini bulunamadı: $parent"
        }
        [void](Test-NxbPathSafety -Path $parent -RootPath $ExperimentRoot)
    }

    return $full
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
[void](Test-NxbPathSafety -Path $experimentFull -RootPath $experimentFull)
$experimentId = [string](Split-Path -Leaf $experimentFull)
$manifestPath = Resolve-NxbEvidencePath `
    -Path (Join-Path $experimentFull 'manifest.json') `
    -ExperimentRoot $experimentFull `
    -RequireLeaf
$identityPath = Resolve-NxbEvidencePath `
    -Path (Join-Path $experimentFull 'baseline\observation-identity.json') `
    -ExperimentRoot $experimentFull `
    -RequireLeaf
$sessionPath = Resolve-NxbEvidencePath `
    -Path (Join-Path $experimentFull 'trace-session.json') `
    -ExperimentRoot $experimentFull `
    -RequireLeaf
$etlPath = Resolve-NxbEvidencePath `
    -Path (Join-Path $experimentFull 'traces\performance.etl') `
    -ExperimentRoot $experimentFull `
    -RequireLeaf

if ([string]::IsNullOrWhiteSpace($EtlMetadataPath)) {
    $EtlMetadataPath = Join-Path $experimentFull 'traces\performance.etl.json'
}
$etlMetadataFull = Resolve-NxbEvidencePath `
    -Path $EtlMetadataPath `
    -ExperimentRoot $experimentFull `
    -RequireLeaf

if ([string]::IsNullOrWhiteSpace($StatusSnapshotPath)) {
    $StatusSnapshotPath = Join-Path $experimentFull 'analysis\wpr-status-pre-stop.json'
}
$statusSnapshotFull = Get-NxbFullPath -Path $StatusSnapshotPath
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $statusSnapshotFull)
if (Test-Path -LiteralPath $statusSnapshotFull -PathType Leaf) {
    [void](Test-NxbPathSafety -Path $statusSnapshotFull -RootPath $experimentFull)
}
else {
    $statusParent = Split-Path -Parent $statusSnapshotFull
    if (Test-Path -LiteralPath $statusParent -PathType Container) {
        [void](Test-NxbPathSafety -Path $statusParent -RootPath $experimentFull)
    }
}

$manifest = Read-NxbJson -Path $manifestPath
$identity = Read-NxbJson -Path $identityPath
$session = Read-NxbJson -Path $sessionPath
$etlMetadata = Read-NxbJson -Path $etlMetadataFull

if ([string]$manifest.status -cne 'stopped') {
    throw "Trace-loss accounting yalnız stopped deneyde üretilebilir. Mevcut durum: $($manifest.status)"
}
if ([string]$session.status -cne 'stopped') {
    throw "Trace-loss accounting yalnız stopped trace session üzerinde üretilebilir. Mevcut durum: $($session.status)"
}
if ([string]$manifest.experiment_id -cne $experimentId) {
    throw 'Manifest experiment_id ile deney dizini uyuşmuyor.'
}
if ([string]$identity.experiment_id -cne $experimentId) {
    throw 'Observation identity experiment_id ile deney dizini uyuşmuyor.'
}
if ([string]::IsNullOrWhiteSpace([string]$identity.machine_id) -or
    [string]$identity.boot_id -notmatch '^[0-9a-f]{64}$') {
    throw 'Observation identity machine_id veya boot_id alanı geçersiz.'
}
if ([string]$session.profile_provenance_sha256 -notmatch '^[0-9a-f]{64}$') {
    throw 'Trace session profile provenance SHA-256 değeri geçersiz.'
}
$actualProfileSeal = Get-NxbCanonicalJsonHash -InputObject $session.profile_provenance
if ($actualProfileSeal -cne [string]$session.profile_provenance_sha256) {
    throw 'Trace session profile provenance canonical SHA-256 değeri uyuşmuyor.'
}
if ([string]$etlMetadata.profile -cne [string]$session.profile -or
    [string]$etlMetadata.profile_provenance_sha256 -cne [string]$session.profile_provenance_sha256) {
    throw 'ETL metadata profile provenance ile trace session uyuşmuyor.'
}
if ((Get-NxbFullPath -Path ([string]$etlMetadata.path)) -cne $etlPath) {
    throw 'ETL metadata path kanonik performance.etl yoluyla uyuşmuyor.'
}

$actualEtlItem = Get-Item -LiteralPath $etlPath
$actualEtlLength = [int64]$actualEtlItem.Length
$actualEtlSha256 = (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant()
$metadataEtlSha256 = ([string]$etlMetadata.sha256).ToLowerInvariant()
if ($metadataEtlSha256 -cne $actualEtlSha256 -or
    [int64]$etlMetadata.length -ne $actualEtlLength) {
    throw 'ETL metadata SHA-256 veya length değeri gerçek ETL ile uyuşmuyor.'
}

$statusSnapshot = if (Test-Path -LiteralPath $statusSnapshotFull -PathType Leaf) {
    $snapshot = Read-NxbJson -Path $statusSnapshotFull
    if ([string]$snapshot.experiment_id -cne $experimentId) {
        throw 'Native counter snapshot experiment_id ile deney dizini uyuşmuyor.'
    }
    if ([string]$snapshot.raw_output_sha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Native counter snapshot raw_output_sha256 alanı geçersiz.'
    }
    $snapshot
}
else {
    $null
}

$eventsLost = ConvertTo-NxbCounterEvidence `
    -Counter $(if ($null -ne $statusSnapshot) { $statusSnapshot.events_lost } else { $null }) `
    -MissingReason 'Native counter snapshot bulunamadı.'
$buffersLost = ConvertTo-NxbCounterEvidence `
    -Counter $(if ($null -ne $statusSnapshot) { $statusSnapshot.buffers_lost } else { $null }) `
    -MissingReason 'Native counter snapshot bulunamadı.'
$realtimeBuffersLost = ConvertTo-NxbCounterEvidence `
    -Counter $(if ($null -ne $statusSnapshot) { $statusSnapshot.realtime_buffers_lost } else { $null }) `
    -MissingReason 'Native counter snapshot bulunamadı.'

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

$etlEvidence = [ordered]@{
    status = 'measured'
    sha256 = $actualEtlSha256
    length = $actualEtlLength
    reason = $null
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
elseif ($null -eq $maximumFileSizeMiB) {
    $circularOverwrite = [ordered]@{
        classification = 'failed'
        capacity_bytes = $null
        final_etl_length = $null
        utilization_ratio = $null
        risk_threshold_ratio = 0.9
        risk_reasons = @()
        reason = 'Circular capture maksimum dosya kapasitesi eksik.'
    }
}
else {
    $capacityBytes = [int64]($maximumFileSizeMiB * 1MB)
    $utilizationRatio = [double]$actualEtlLength / [double]$capacityBytes
    $riskReasons = [Collections.Generic.List[string]]::new()
    if ($utilizationRatio -ge 0.9) {
        $riskReasons.Add('capacity_threshold_reached')
    }
    if ($actualEtlLength -gt $capacityBytes) {
        $riskReasons.Add('etl_length_exceeds_declared_capacity')
    }

    $circularOverwrite = [ordered]@{
        classification = if ($riskReasons.Count -gt 0) { 'risk_observed' } else { 'no_risk_observed' }
        capacity_bytes = $capacityBytes
        final_etl_length = $actualEtlLength
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

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $experimentFull 'analysis\trace-loss-accounting.json'
}
$outputFull = Resolve-NxbEvidencePath `
    -Path $OutputPath `
    -ExperimentRoot $experimentFull
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
