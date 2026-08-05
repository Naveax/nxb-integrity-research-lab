[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [switch]$IgnoreChainHead,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

function Get-NxbChainDigest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$RecordSha256
    )

    $combined = [byte[]]::new($RecordSha256.Count * 32)
    for ($recordIndex = 0; $recordIndex -lt $RecordSha256.Count; $recordIndex++) {
        $hash = $RecordSha256[$recordIndex]
        if ($hash -cnotmatch '^[0-9a-f]{64}$') {
            throw "Geçersiz record SHA-256: $hash"
        }

        for ($byteIndex = 0; $byteIndex -lt 32; $byteIndex++) {
            $combined[($recordIndex * 32) + $byteIndex] = [Convert]::ToByte(
                $hash.Substring($byteIndex * 2, 2),
                16
            )
        }
    }

    return Get-NxbSha256Hex -InputBytes $combined
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$storePath = Join-Path $experimentFull 'evidence-store'
$recordsPath = Join-Path $storePath 'records'
$chainHeadPath = Join-Path $storePath 'chain-head.json'

if (-not (Test-Path -LiteralPath $recordsPath -PathType Container)) {
    throw "Evidence-store records dizini bulunamadı: $recordsPath"
}

[void](Test-NxbPathSafety -Path $storePath -RootPath $experimentFull)
[void](Test-NxbPathSafety -Path $recordsPath -RootPath $experimentFull)

$items = @(Get-NxbSafeChildItem -RootPath $recordsPath)
$recordEntries = [Collections.Generic.List[object]]::new()

foreach ($item in $items) {
    if ($item.PSIsContainer) {
        throw "Records dizininde alt dizin kabul edilmez: $($item.FullName)"
    }
    if ($item.Name -cnotmatch '^(?<sequence>[0-9]{16})\.json$') {
        throw "Geçersiz evidence record dosya adı: $($item.Name)"
    }

    [void]$recordEntries.Add([pscustomobject]@{
        Sequence = [int64]$Matches.sequence
        Path = $item.FullName
        Name = $item.Name
    })
}

if ($recordEntries.Count -eq 0) {
    throw 'Evidence-store zincirinde hiç record yok.'
}

$orderedEntries = @($recordEntries | Sort-Object Sequence)
$recordHashes = [Collections.Generic.List[string]]::new()
$expectedPreviousHash = $null
$identity = $null

for ($index = 0; $index -lt $orderedEntries.Count; $index++) {
    $entry = $orderedEntries[$index]
    $expectedSequence = [int64]$index
    if ($entry.Sequence -ne $expectedSequence) {
        throw "Evidence record sequence kesintisi: beklenen $expectedSequence, bulunan $($entry.Sequence)."
    }

    $expectedName = [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        '{0:D16}.json',
        $expectedSequence
    )
    if ($entry.Name -cne $expectedName) {
        throw "Evidence record dosya adı sequence ile uyuşmuyor: $($entry.Name)"
    }

    & (Join-Path $PSScriptRoot 'Test-EvidenceStoreSchema.ps1') `
        -Path $entry.Path `
        -DocumentType record

    $record = Read-NxbJson -Path $entry.Path
    if ([int64]$record.sequence -ne $expectedSequence) {
        throw "Record içi sequence dosya adıyla uyuşmuyor: $($entry.Name)"
    }

    if ($expectedSequence -eq 0) {
        if ($null -ne $record.previous_record_sha256) {
            throw 'Genesis record previous_record_sha256 değeri null olmalıdır.'
        }
    }
    elseif ([string]$record.previous_record_sha256 -cne $expectedPreviousHash) {
        throw "Previous-record hash uyuşmazlığı sequence $expectedSequence için bulundu."
    }

    $currentIdentity = [ordered]@{
        experiment_id = [string]$record.experiment_id
        machine_id = [string]$record.machine_id
        boot_id = [string]$record.boot_id
        session_id = [string]$record.session_id
    }

    if ($null -eq $identity) {
        $identity = $currentIdentity
    }
    else {
        foreach ($identityName in @('experiment_id', 'machine_id', 'boot_id', 'session_id')) {
            if ([string]$identity[$identityName] -cne [string]$currentIdentity[$identityName]) {
                throw "Evidence chain identity değişti: $identityName sequence $expectedSequence."
            }
        }
    }

    $actualPayloadHash = Get-NxbCanonicalJsonHash -InputObject $record.payload
    if ([string]$record.payload_sha256 -cne $actualPayloadHash) {
        throw "Payload SHA-256 uyuşmazlığı sequence $expectedSequence için bulundu."
    }

    $actualRecordHash = Get-NxbCanonicalJsonHash `
        -InputObject $record `
        -ExcludeRootProperty 'record_sha256'
    if ([string]$record.record_sha256 -cne $actualRecordHash) {
        throw "Record SHA-256 uyuşmazlığı sequence $expectedSequence için bulundu."
    }

    [void]$recordHashes.Add($actualRecordHash)
    $expectedPreviousHash = $actualRecordHash
}

$chainDigest = Get-NxbChainDigest -RecordSha256 $recordHashes.ToArray()
$result = [pscustomobject]@{
    IsValid = $true
    ExperimentId = [string]$identity.experiment_id
    MachineId = [string]$identity.machine_id
    BootId = [string]$identity.boot_id
    SessionId = [string]$identity.session_id
    RecordCount = [int64]$orderedEntries.Count
    GenesisRecordSha256 = [string]$recordHashes[0]
    LastSequence = [int64]($orderedEntries.Count - 1)
    LastRecordSha256 = [string]$recordHashes[$recordHashes.Count - 1]
    ChainSha256 = $chainDigest
}

if (-not $IgnoreChainHead) {
    if (-not (Test-Path -LiteralPath $chainHeadPath -PathType Leaf)) {
        throw "Evidence chain-head bulunamadı: $chainHeadPath"
    }

    [void](Test-NxbPathSafety -Path $chainHeadPath -RootPath $experimentFull)
    & (Join-Path $PSScriptRoot 'Test-EvidenceStoreSchema.ps1') `
        -Path $chainHeadPath `
        -DocumentType chain-head

    $chainHead = Read-NxbJson -Path $chainHeadPath
    $comparisons = [ordered]@{
        experiment_id = $result.ExperimentId
        machine_id = $result.MachineId
        boot_id = $result.BootId
        session_id = $result.SessionId
        record_count = $result.RecordCount
        genesis_record_sha256 = $result.GenesisRecordSha256
        last_sequence = $result.LastSequence
        last_record_sha256 = $result.LastRecordSha256
        chain_sha256 = $result.ChainSha256
    }

    foreach ($name in $comparisons.Keys) {
        if ([string]$chainHead.$name -cne [string]$comparisons[$name]) {
            throw "Chain-head alanı doğrulanamadı: $name"
        }
    }
}

if ($PassThru) {
    Write-Output $result
}
else {
    Write-Host "Evidence-store zinciri geçerli: $($result.RecordCount) record"
}
