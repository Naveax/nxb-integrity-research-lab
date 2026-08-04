[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
if (-not $wpr) {
    throw 'wpr.exe bulunamadı.'
}

$traces = Join-Path $ExperimentPath 'traces'
New-Item -ItemType Directory -Path $traces -Force | Out-Null
$etl = Join-Path $traces 'performance.etl'

$output = & $wpr.Source -stop $etl 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "WPR durdurulamadı: $($output -join [Environment]::NewLine)"
}

$hash = Get-FileHash -LiteralPath $etl -Algorithm SHA256
[pscustomobject]@{
    Path = $etl
    SHA256 = $hash.Hash
    Length = (Get-Item -LiteralPath $etl).Length
    StoppedUtc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json |
    Set-Content -LiteralPath (Join-Path $traces 'performance.etl.json') -Encoding UTF8

$sessionPath = Join-Path $ExperimentPath 'trace-session.json'
if (Test-Path -LiteralPath $sessionPath) {
    $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    $session.status = 'stopped'
    $session.stopped_utc = [DateTime]::UtcNow.ToString('o')
    $session.etl = $etl
    $session | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath $sessionPath -Encoding UTF8
}

$manifestPath = Join-Path $ExperimentPath 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.status = 'stopped'
    $manifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

Write-Host "WPR kaydı tamamlandı: $etl"
