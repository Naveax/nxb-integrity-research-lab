[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateRange(1, 16)]
    [int]$FileSizeMiB = 4,

    [Parameter()]
    [ValidateRange(64, 1024)]
    [int]$BlockSizeKiB = 256,

    [Parameter()]
    [string]$ReceiptPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputDirectory already exists: $outputFull"
}
$outputParent = Split-Path -Parent $outputFull
if ([string]::IsNullOrWhiteSpace($outputParent)) {
    throw "Output parent could not be resolved: $outputFull"
}
if (-not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    [IO.Directory]::CreateDirectory($outputParent) | Out-Null
}
$parentItem = Get-Item -LiteralPath $outputParent -Force
if (($parentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Output parent cannot be a reparse point: $outputParent"
}
[IO.Directory]::CreateDirectory($outputFull) | Out-Null

if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $ReceiptPath = Join-Path $outputFull 'storage-header-probe-workload-receipt.json'
}
$receiptFull = [IO.Path]::GetFullPath($ReceiptPath)
if (Test-Path -LiteralPath $receiptFull) {
    throw "ReceiptPath already exists: $receiptFull"
}

$fileA = Join-Path $outputFull 'storage-header-probe.bin'
$fileB = Join-Path $outputFull 'storage-header-probe-renamed.bin'
$targetBytes = [int64]$FileSizeMiB * 1MB
$blockBytes = [int]$BlockSizeKiB * 1KB
if ($blockBytes -gt $targetBytes) {
    throw 'BlockSizeKiB cannot exceed FileSizeMiB.'
}

$buffer = [byte[]]::new($blockBytes)
for ($index = 0; $index -lt $buffer.Length; $index++) {
    $buffer[$index] = [byte](($index * 31 + 17) % 251)
}

$startedUtc = [DateTime]::UtcNow
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$writeHash = [Security.Cryptography.IncrementalHash]::CreateHash(
    [Security.Cryptography.HashAlgorithmName]::SHA256
)
$readHash = [Security.Cryptography.IncrementalHash]::CreateHash(
    [Security.Cryptography.HashAlgorithmName]::SHA256
)
$bytesWritten = [int64]0
$bytesRead = [int64]0
$flushCount = 0
$renamed = $false
$deleted = $false
$status = 'failed'
$failure = $null

try {
    $writer = [IO.FileStream]::new(
        $fileA,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        $blockBytes,
        [IO.FileOptions]::SequentialScan
    )
    try {
        while ($bytesWritten -lt $targetBytes) {
            $remaining = $targetBytes - $bytesWritten
            $count = [int][Math]::Min([int64]$buffer.Length, $remaining)
            $writer.Write($buffer, 0, $count)
            $writeHash.AppendData($buffer, 0, $count)
            $bytesWritten += $count
        }
        $writer.Flush($true)
        $flushCount++
    }
    finally {
        $writer.Dispose()
    }

    $reader = [IO.FileStream]::new(
        $fileA,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read,
        $blockBytes,
        [IO.FileOptions]::SequentialScan
    )
    try {
        while ($true) {
            $count = $reader.Read($buffer, 0, $buffer.Length)
            if ($count -le 0) {
                break
            }
            $readHash.AppendData($buffer, 0, $count)
            $bytesRead += $count
        }
    }
    finally {
        $reader.Dispose()
    }

    $writeDigest = -join @($writeHash.GetHashAndReset() | ForEach-Object {
        $_.ToString('x2')
    })
    $readDigest = -join @($readHash.GetHashAndReset() | ForEach-Object {
        $_.ToString('x2')
    })
    if ($writeDigest -cne $readDigest) {
        throw 'Storage probe write/read SHA-256 mismatch.'
    }
    if ($bytesWritten -ne $targetBytes -or $bytesRead -ne $targetBytes) {
        throw 'Storage probe byte-count mismatch.'
    }

    [IO.File]::Move($fileA, $fileB)
    $renamed = $true
    [IO.File]::Delete($fileB)
    $deleted = $true
    $status = 'passed'
}
catch {
    $failure = $_.Exception.Message
    throw
}
finally {
    $stopwatch.Stop()
    $writeHash.Dispose()
    $readHash.Dispose()

    foreach ($ownedPath in @($fileA, $fileB)) {
        if (Test-Path -LiteralPath $ownedPath -PathType Leaf) {
            try {
                Remove-Item -LiteralPath $ownedPath -Force
                $deleted = $true
            }
            catch {
                Write-Warning "Owned storage probe cleanup failed: $($_.Exception.Message)"
            }
        }
    }

    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        status = $status
        started_utc = $startedUtc.ToString('o')
        stopped_utc = [DateTime]::UtcNow.ToString('o')
        duration_ms = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 3)
        process_id = $PID
        output_directory = $outputFull
        requested_file_size_mib = $FileSizeMiB
        block_size_kib = $BlockSizeKiB
        bytes_written = $bytesWritten
        bytes_read = $bytesRead
        flush_count = $flushCount
        renamed = $renamed
        deleted = $deleted
        failure = $failure
        claims = [ordered]@{
            benchmark = $false
            representative_throughput = $false
            representative_iops = $false
            cache_state_controlled = $false
        }
    }
    [IO.File]::WriteAllText(
        $receiptFull,
        ($receipt | ConvertTo-Json -Depth 12),
        [Text.UTF8Encoding]::new($false)
    )
}
