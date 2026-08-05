[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateRange(1, 1000000)]
    [int]$Iterations,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [ValidateRange(1, 255)]
    [int]$Seed = 73
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$outputFull = [IO.Path]::GetFullPath($OutputPath)
$outputParent = Split-Path -Parent $outputFull
if ([string]::IsNullOrWhiteSpace($outputParent) -or
    -not (Test-Path -LiteralPath $outputParent -PathType Container)) {
    throw "Workload çıktı dizini bulunamadı: $outputParent"
}
if (Test-Path -LiteralPath $outputFull) {
    throw "Workload çıktı dosyası zaten var: $outputFull"
}

$buffer = New-Object byte[] 4096
for ($index = 0; $index -lt $buffer.Length; $index++) {
    $buffer[$index] = [byte](($Seed + ($index * 31)) % 256)
}

$hashAlgorithm = [Security.Cryptography.SHA256]::Create()
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$hash = $null
try {
    for ($iteration = 0; $iteration -lt $Iterations; $iteration++) {
        $hash = $hashAlgorithm.ComputeHash($buffer)
        [Array]::Copy($hash, 0, $buffer, 0, $hash.Length)
        $buffer[32] = [byte](($buffer[32] + $iteration + $Seed) % 256)
    }
}
finally {
    $stopwatch.Stop()
    $hashAlgorithm.Dispose()
}

if ($null -eq $hash -or $hash.Length -ne 32) {
    throw 'Deterministik CPU workload geçerli SHA-256 sonucu üretemedi.'
}

$checksum = ([BitConverter]::ToString($hash)).Replace('-', '').ToLowerInvariant()
$result = [ordered]@{
    schema_version  = 1
    workload_id     = 'nxb.cpu.sha256-chain.v1'
    iterations      = $Iterations
    seed            = $Seed
    buffer_bytes    = $buffer.Length
    checksum_sha256 = $checksum
    elapsed_ms      = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 6)
    process_id      = $PID
    completed_utc   = [DateTime]::UtcNow.ToString('o')
}

if ($PSCmdlet.ShouldProcess($outputFull, 'Write deterministic CPU workload result')) {
    $temporaryPath = "$outputFull.tmp-$([guid]::NewGuid().ToString('N'))"
    try {
        $json = $result | ConvertTo-Json -Depth 8
        [IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            [Text.UTF8Encoding]::new($false)
        )
        Move-Item -LiteralPath $temporaryPath -Destination $outputFull -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

Write-Output $outputFull
