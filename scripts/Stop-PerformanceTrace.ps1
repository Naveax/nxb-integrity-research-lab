[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$manifestPath = Join-Path $experimentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}

$manifest = Read-NxbJson -Path $manifestPath
if ([string]$manifest.status -ne 'recording') {
    throw "WPR yalnız recording deneyde durdurulabilir. Mevcut durum: $($manifest.status)"
}

$wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
if (-not $wpr) {
    throw 'wpr.exe bulunamadı.'
}

$traces = Join-Path $experimentFull 'traces'
New-Item -ItemType Directory -Path $traces -Force | Out-Null
$etl = Join-Path $traces 'performance.etl'

$output = & $wpr.Source -stop $etl 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "WPR durdurulamadı: $($output -join [Environment]::NewLine)"
}

$hash = Get-FileHash -LiteralPath $etl -Algorithm SHA256
$traceMetadata = [ordered]@{
    path = $etl
    sha256 = $hash.Hash
    length = (Get-Item -LiteralPath $etl).Length
    stopped_utc = [DateTime]::UtcNow.ToString('o')
}
Write-NxbJsonAtomic `
    -Path (Join-Path $traces 'performance.etl.json') `
    -InputObject $traceMetadata `
    -Depth 8

$sessionPath = Join-Path $experimentFull 'trace-session.json'
if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
    throw "Trace session manifesti bulunamadı: $sessionPath"
}

$session = Read-NxbJson -Path $sessionPath
$session.status = 'stopped'
$session | Add-Member -MemberType NoteProperty -Name stopped_utc -Value $traceMetadata.stopped_utc -Force
$session | Add-Member -MemberType NoteProperty -Name etl -Value $etl -Force
Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 8

Set-NxbExperimentState `
    -ExperimentPath $experimentFull `
    -State stopped | Out-Null

Write-Host "WPR kaydı tamamlandı: $etl"
