[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter(Mandatory)]
    [ValidateSet(
        'manifest_snapshot',
        'evidence_index_snapshot',
        'tool_provenance',
        'clock_offset',
        'observation_identity',
        'bundle_seal'
    )]
    [string]$RecordType,

    [Parameter(Mandatory)]
    [ValidateNotNull()]
    [object]$Payload,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SessionId,

    [Parameter()]
    [DateTime]$CapturedUtc = [DateTime]::UtcNow,

    [Parameter()]
    [ValidateRange(-1, 9223372036854775807)]
    [int64]$MonotonicNs = -1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$manifestPath = Join-Path $experimentFull 'manifest.json'
$identityPath = Join-Path $experimentFull 'baseline\observation-identity.json'
$storePath = Join-Path $experimentFull 'evidence-store'
$recordsPath = Join-Path $storePath 'records'
$chainHeadPath = Join-Path $storePath 'chain-head.json'
$lockPath = Join-Path $storePath 'append.lock'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}
if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
    throw "Observation identity bulunamadı: $identityPath"
}

$manifest = Read-NxbJson -Path $manifestPath
$identity = Read-NxbJson -Path $identityPath
$experimentId = [string]$manifest.experiment_id
$machineId = [string]$identity.machine_id
$bootId = [string]$identity.boot_id

$requiredIdentities = [ordered]@{
    experiment_id = $experimentId
    machine_id = $machineId
    boot_id = $bootId
    session_id = $SessionId
}
foreach ($requiredIdentity in $requiredIdentities.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$requiredIdentity.Value)) {
        throw "Evidence record identity alanı boş olamaz: $($requiredIdentity.Key)"
    }
}

New-Item -ItemType Directory -Path $recordsPath -Force | Out-Null
[void](Test-NxbPathSafety -Path $storePath -RootPath $experimentFull)
[void](Test-NxbPathSafety -Path $recordsPath -RootPath $experimentFull)

$lockStream = $null
$stagedRecordPath = $null
try {
    try {
        $lockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::CreateNew,
            [IO.FileAccess]::Write,
            [IO.FileShare]::None
        )
    }
    catch [IO.IOException] {
        throw "Evidence-store append kilidi alınamadı: $lockPath"
    }

    $existingItems = @(Get-NxbSafeChildItem -RootPath $recordsPath)
    $sequence = [int64]0
    $previousRecordHash = $null

    if ($existingItems.Count -gt 0) {
        $verified = & (Join-Path $PSScriptRoot 'Test-EvidenceStoreChain.ps1') `
            -ExperimentPath $experimentFull `
            -PassThru

        $identityComparisons = [ordered]@{
            experiment_id = @($verified.ExperimentId, $experimentId)
            machine_id = @($verified.MachineId, $machineId)
            boot_id = @($verified.BootId, $bootId)
            session_id = @($verified.SessionId, $SessionId)
        }
        foreach ($comparison in $identityComparisons.GetEnumerator()) {
            if ([string]$comparison.Value[0] -cne [string]$comparison.Value[1]) {
                throw "Yeni record mevcut zincir kimliğiyle uyuşmuyor: $($comparison.Key)"
            }
        }

        $sequence = [int64]$verified.LastSequence + 1
        $previousRecordHash = [string]$verified.LastRecordSha256
    }
    elseif (Test-Path -LiteralPath $chainHeadPath) {
        throw 'Record bulunmayan evidence-store içinde chain-head kabul edilmez.'
    }

    if ($MonotonicNs -lt 0) {
        $ticks = [Diagnostics.Stopwatch]::GetTimestamp()
        $frequency = [Diagnostics.Stopwatch]::Frequency
        $MonotonicNs = [int64]((
            [decimal]$ticks * [decimal]1000000000
        ) / [decimal]$frequency)
    }

    $captured = $CapturedUtc.ToUniversalTime().ToString(
        'yyyy-MM-ddTHH:mm:ss.fffffffZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $payloadHash = Get-NxbCanonicalJsonHash -InputObject $Payload

    $record = [ordered]@{
        schema_version = 1
        sequence = $sequence
        previous_record_sha256 = $previousRecordHash
        record_type = $RecordType
        experiment_id = $experimentId
        machine_id = $machineId
        boot_id = $bootId
        session_id = $SessionId
        captured_utc = $captured
        monotonic_ns = $MonotonicNs
        payload = $Payload
        payload_sha256 = $payloadHash
    }
    $recordHash = Get-NxbCanonicalJsonHash -InputObject $record
    $record['record_sha256'] = $recordHash

    $recordName = [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        '{0:D16}.json',
        $sequence
    )
    $recordPath = Join-Path $recordsPath $recordName
    if (Test-Path -LiteralPath $recordPath) {
        throw "Evidence record zaten mevcut: $recordPath"
    }

    $stagedRecordPath = Join-Path $storePath (
        'pending-record.{0}.json' -f [guid]::NewGuid().ToString('N')
    )
    Write-NxbCanonicalJsonAtomic `
        -Path $stagedRecordPath `
        -InputObject $record `
        -Confirm:$false

    & (Join-Path $PSScriptRoot 'Test-EvidenceStoreSchema.ps1') `
        -Path $stagedRecordPath `
        -DocumentType record

    Move-Item -LiteralPath $stagedRecordPath -Destination $recordPath
    $stagedRecordPath = $null

    & (Join-Path $PSScriptRoot 'Update-EvidenceStoreChainHead.ps1') `
        -ExperimentPath $experimentFull `
        -Confirm:$false | Out-Null

    $finalVerification = & (Join-Path $PSScriptRoot 'Test-EvidenceStoreChain.ps1') `
        -ExperimentPath $experimentFull `
        -PassThru

    [pscustomobject]@{
        RecordPath = $recordPath
        Sequence = $sequence
        PayloadSha256 = $payloadHash
        RecordSha256 = $recordHash
        ChainSha256 = $finalVerification.ChainSha256
        RecordCount = $finalVerification.RecordCount
    }
}
finally {
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
    if (-not [string]::IsNullOrWhiteSpace($stagedRecordPath) -and
        (Test-Path -LiteralPath $stagedRecordPath -PathType Leaf)) {
        Remove-Item -LiteralPath $stagedRecordPath -Force
    }
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        Remove-Item -LiteralPath $lockPath -Force
    }
}
