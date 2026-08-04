[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [switch]$CancelExistingSession,

    [Parameter()]
    [string]$WprExecutablePath
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

try {
    $wprPath = Resolve-NxbExecutablePath -Name 'wpr.exe' -ExplicitPath $WprExecutablePath
}
catch {
    throw "wpr.exe bulunamadı. Windows ADK içindeki Windows Performance Toolkit kurulmalı. $($_.Exception.Message)"
}

if ($CancelExistingSession) {
    $cancelOutput = & $wprPath -cancel 2>&1
    $cancelExitCode = $LASTEXITCODE
    if ($cancelExitCode -ne 0) {
        throw "Mevcut WPR oturumu iptal edilemedi (exit $cancelExitCode): $($cancelOutput -join [Environment]::NewLine)"
    }
}

$sessionPath = Join-Path $experimentFull 'trace-session.json'
if (Test-Path -LiteralPath $sessionPath) {
    throw "Bu deneyde trace-session.json zaten var: $sessionPath"
}

$startOutput = & $wprPath -start GeneralProfile -filemode 2>&1
$startExitCode = $LASTEXITCODE
if ($startExitCode -ne 0) {
    throw "WPR başlatılamadı (exit $startExitCode): $($startOutput -join [Environment]::NewLine)"
}

$session = [ordered]@{
    started_utc   = [DateTime]::UtcNow.ToString('o')
    profile       = 'GeneralProfile'
    mode          = 'filemode'
    status        = 'recording'
    wpr_executable = $wprPath
}

try {
    Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 8
    Set-NxbExperimentState `
        -ExperimentPath $experimentFull `
        -State recording `
        -Confirm:$false | Out-Null
}
catch {
    $rollbackOutput = & $wprPath -cancel 2>&1
    $rollbackExitCode = $LASTEXITCODE
    if ($rollbackExitCode -ne 0) {
        Write-Warning "WPR rollback iptali başarısız (exit $rollbackExitCode): $($rollbackOutput -join [Environment]::NewLine)"
    }

    if (Test-Path -LiteralPath $sessionPath) {
        Remove-Item -LiteralPath $sessionPath -Force
    }

    throw
}

Write-Host 'WPR kaydı başladı.'
