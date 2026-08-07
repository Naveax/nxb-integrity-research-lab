[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(4, 128)]
    [int]$PrivateMemoryMiB = 32,

    [Parameter()]
    [ValidateRange(1, 64)]
    [int]$MappedFileMiB = 8,

    [Parameter()]
    [ValidateRange(0, 3000)]
    [int]$HoldMilliseconds = 750,

    [Parameter()]
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') {
    throw 'Memory probe workload requires Windows.'
}

$startedUtc = [DateTime]::UtcNow
$process = [Diagnostics.Process]::GetCurrentProcess()
$processStartUtc = $process.StartTime.ToUniversalTime()
$privateBytes = [int64]$PrivateMemoryMiB * 1MB
$mappedBytes = [int64]$MappedFileMiB * 1MB
$pageSize = 4096
$probeId = [guid]::NewGuid().ToString('N')
$tempFile = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ('nxb-memory-probe-' + $probeId + '.bin')
$mapName = 'nxb-memory-probe-' + $probeId

$buffer = $null
$fileStream = $null
$mappedFile = $null
$accessor = $null
$checksum = [uint64]0

try {
    $buffer = [byte[]]::new($privateBytes)
    for ($offset = 0; $offset -lt $buffer.Length; $offset += $pageSize) {
        $value = [byte](($offset / $pageSize) % 251)
        $buffer[$offset] = $value
        $checksum = ($checksum + [uint64]$value) % [uint64]::MaxValue
    }

    $fileStream = [IO.File]::Open(
        $tempFile,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    $fileStream.SetLength($mappedBytes)
    $mappedFile = [IO.MemoryMappedFiles.MemoryMappedFile]::CreateFromFile(
        $fileStream,
        $mapName,
        $mappedBytes,
        [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite,
        [IO.HandleInheritability]::None,
        $false
    )
    $accessor = $mappedFile.CreateViewAccessor(
        0,
        $mappedBytes,
        [IO.MemoryMappedFiles.MemoryMappedFileAccess]::ReadWrite
    )

    for ($offset = 0; $offset -lt $mappedBytes; $offset += $pageSize) {
        $value = [byte](($offset / $pageSize + 17) % 251)
        $accessor.Write([int64]$offset, $value)
    }
    $accessor.Flush()

    for ($offset = 0; $offset -lt $mappedBytes; $offset += $pageSize) {
        $value = $accessor.ReadByte([int64]$offset)
        $checksum = ($checksum + [uint64]$value) % [uint64]::MaxValue
    }

    if ($HoldMilliseconds -gt 0) {
        Start-Sleep -Milliseconds $HoldMilliseconds
    }
}
finally {
    if ($null -ne $accessor) {
        $accessor.Dispose()
    }
    if ($null -ne $mappedFile) {
        $mappedFile.Dispose()
    }
    if ($null -ne $fileStream) {
        $fileStream.Dispose()
    }
    if (Test-Path -LiteralPath $tempFile -PathType Leaf) {
        Remove-Item -LiteralPath $tempFile -Force
    }
}

$stoppedUtc = [DateTime]::UtcNow
$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    process_id = $PID
    process_start_utc = $processStartUtc.ToString('o')
    started_utc = $startedUtc.ToString('o')
    stopped_utc = $stoppedUtc.ToString('o')
    private_memory_mib = $PrivateMemoryMiB
    mapped_file_mib = $MappedFileMiB
    hold_milliseconds = $HoldMilliseconds
    page_stride_bytes = $pageSize
    checksum = [string]$checksum
    claims = [ordered]@{
        hard_faults_guaranteed = $false
        soft_fault_class_guaranteed = $false
        cache_state_controlled = $false
        system_memory_exhaustion_attempted = $false
    }
}

if (-not [string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
    $parent = Split-Path -Parent $receiptFull
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "Receipt parent could not be resolved: $receiptFull"
    }
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    if (Test-Path -LiteralPath $receiptFull) {
        throw "Receipt already exists: $receiptFull"
    }
    [IO.File]::WriteAllText(
        $receiptFull,
        ($receipt | ConvertTo-Json -Depth 16),
        [Text.UTF8Encoding]::new($false)
    )
}

return $receipt
