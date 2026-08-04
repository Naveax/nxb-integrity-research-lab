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

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$manifestPath = Join-Path $experimentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}

$manifest = Read-NxbJson -Path $manifestPath
if ([string]$manifest.status -ne 'prepared') {
    throw "WPR yalnız prepared deneyde başlatılabilir. Mevcut durum: $($manifest.status)"
}

$wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
if (-not $wpr) {
    throw 'wpr.exe bulunamadı. Windows ADK içindeki Windows Performance Toolkit kurulmalı.'
}

if ($CancelExistingSession) {
    & $wpr.Source -cancel 2>$null | Out-Null
}

$sessionPath = Join-Path $experimentFull 'trace-session.json'
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

try {
    Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 8
    Set-NxbExperimentState `
        -ExperimentPath $experimentFull `
        -State recording | Out-Null
}
catch {
    & $wpr.Source -cancel 2>$null | Out-Null
    if (Test-Path -LiteralPath $sessionPath) {
        Remove-Item -LiteralPath $sessionPath -Force
    }
    throw
}

Write-Host 'WPR kaydı başladı.'
