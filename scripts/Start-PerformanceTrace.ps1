[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [ValidateSet('NxbMinimalCpuScheduler', 'GeneralProfile')]
    [string]$CaptureProfile = 'NxbMinimalCpuScheduler',

    [Parameter()]
    [switch]$AllowUnboundedBuiltInProfile,

    [Parameter()]
    [switch]$CancelExistingSession,

    [Parameter()]
    [string]$WprExecutablePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$manifestPath = Join-Path $experimentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}

$manifest = Read-NxbJson -Path $manifestPath
if ([string]$manifest.status -ne 'prepared') {
    throw "WPR yalnız prepared deneyde başlatılabilir. Mevcut durum: $($manifest.status)"
}

$startProfileArgument = $null
$profileProvenance = $null
switch ($CaptureProfile) {
    'NxbMinimalCpuScheduler' {
        $profileMetadata = & (Join-Path $PSScriptRoot 'Test-WprProfile.ps1') -PassThru
        $startProfileArgument = [string]$profileMetadata.FileProfileReference
        $profileProvenance = [ordered]@{
            type                  = 'repository_wprp'
            relative_path         = [string]$profileMetadata.RelativePath
            sha256               = [string]$profileMetadata.Sha256
            length               = [int64]$profileMetadata.Length
            name                 = [string]$profileMetadata.Name
            detail_level         = [string]$profileMetadata.DetailLevel
            logging_mode         = 'File'
            bounded              = $true
            buffer_size_kib       = [int]$profileMetadata.BufferSizeKiB
            buffers              = [int]$profileMetadata.Buffers
            maximum_file_size_mib = [int]$profileMetadata.MaximumFileSizeMiB
            file_mode            = [string]$profileMetadata.FileMode
            keywords             = @($profileMetadata.Keywords)
            stacks               = @($profileMetadata.Stacks)
        }
    }
    'GeneralProfile' {
        if (-not $AllowUnboundedBuiltInProfile) {
            throw 'GeneralProfile file-mode capture unbounded olabilir. Kullanım için -AllowUnboundedBuiltInProfile açıkça verilmelidir.'
        }

        $startProfileArgument = 'GeneralProfile'
        $profileProvenance = [ordered]@{
            type                  = 'builtin'
            relative_path         = $null
            sha256               = $null
            length               = $null
            name                 = 'GeneralProfile'
            detail_level         = $null
            logging_mode         = 'File'
            bounded              = $false
            buffer_size_kib       = $null
            buffers              = $null
            maximum_file_size_mib = $null
            file_mode            = 'Unbounded'
            keywords             = @()
            stacks               = @()
        }
    }
    default {
        throw "Desteklenmeyen capture profile: $CaptureProfile"
    }
}

$profileProvenanceSha256 = Get-NxbCanonicalJsonHash -InputObject $profileProvenance

try {
    $wprPath = Resolve-NxbExecutablePath -Name 'wpr.exe' -ExplicitPath $WprExecutablePath
}
catch {
    throw "wpr.exe bulunamadı. Windows ADK içindeki Windows Performance Toolkit kurulmalı. $($_.Exception.Message)"
}

$sessionPath = Join-Path $experimentFull 'trace-session.json'
if (Test-Path -LiteralPath $sessionPath) {
    throw "Bu deneyde trace-session.json zaten var: $sessionPath"
}

if ($CancelExistingSession) {
    $cancelOutput = & $wprPath -cancel 2>&1
    $cancelExitCode = $LASTEXITCODE
    if ($cancelExitCode -ne 0) {
        throw "Mevcut WPR oturumu iptal edilemedi (exit $cancelExitCode): $($cancelOutput -join [Environment]::NewLine)"
    }
}

$startArguments = @('-start', $startProfileArgument, '-filemode')
$startOutput = & $wprPath @startArguments 2>&1
$startExitCode = $LASTEXITCODE
if ($startExitCode -ne 0) {
    throw "WPR başlatılamadı (exit $startExitCode): $($startOutput -join [Environment]::NewLine)"
}

$session = [ordered]@{
    started_utc                = [DateTime]::UtcNow.ToString('o')
    profile                    = $CaptureProfile
    mode                       = 'filemode'
    profile_provenance         = $profileProvenance
    profile_provenance_sha256  = $profileProvenanceSha256
    status                     = 'recording'
    wpr_executable             = $wprPath
}

try {
    Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 16
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

Write-Host "WPR kaydı başladı: $CaptureProfile"
