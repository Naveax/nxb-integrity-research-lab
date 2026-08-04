[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [switch]$CancelExistingSession
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
if (-not $wpr) {
    throw 'wpr.exe bulunamadı. Windows ADK içindeki Windows Performance Toolkit kurulmalı.'
}

if ($CancelExistingSession) {
    & $wpr.Source -cancel 2>$null | Out-Null
}

$sessionPath = Join-Path $ExperimentPath 'trace-session.json'
if (Test-Path -LiteralPath $sessionPath) {
    throw "Bu deneyde trace-session.json zaten var: $sessionPath"
}

$output = & $wpr.Source -start GeneralProfile -filemode 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "WPR başlatılamadı: $($output -join [Environment]::NewLine)"
}

$session = [ordered]@{
    started_utc = [DateTime]::UtcNow.ToString('o')
    profile     = 'GeneralProfile'
    mode        = 'filemode'
    status      = 'recording'
}

$session | ConvertTo-Json |
    Set-Content -LiteralPath $sessionPath -Encoding UTF8

$manifestPath = Join-Path $ExperimentPath 'manifest.json'
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.status = 'recording'
    $manifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

Write-Host 'WPR kaydı başladı.'
