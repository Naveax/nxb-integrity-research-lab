[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [switch]$CancelExistingSession,

    [Parameter()]
    [string]$WprExecutablePath,

    [Parameter()]
    [switch]$PassThru
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
    throw "Bounded memory WPR yalnız prepared deneyde başlatılabilir. Mevcut durum: $($manifest.status)"
}

$profileMetadata = & (Join-Path $PSScriptRoot 'Test-WprProfile.ps1') -PassThru
$memoryBudgetKiB = [int64]$profileMetadata.BufferSizeKiB * [int64]$profileMetadata.Buffers
if ($memoryBudgetKiB -le 0 -or ($memoryBudgetKiB % 1024) -ne 0) {
    throw 'Memory WPR buffer budget geçersiz veya MiB olarak tam temsil edilemiyor.'
}
$memoryBudgetMiB = [int]($memoryBudgetKiB / 1024)
if ($memoryBudgetMiB -ne 64) {
    throw ("Bounded memory WPR budget drift: expected=64 MiB actual={0} MiB" -f $memoryBudgetMiB)
}

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
    $noRunningTraceProfilesExitCode = -984076288 # 0xC5583000
    if ($cancelExitCode -ne 0 -and $cancelExitCode -ne $noRunningTraceProfilesExitCode) {
        throw "Mevcut WPR oturumu iptal edilemedi (exit $cancelExitCode): $($cancelOutput -join [Environment]::NewLine)"
    }
}

# The same profile selector resolves the Memory variant when -filemode is omitted.
$startProfileArgument = [string]$profileMetadata.FileProfileReference
$startOutput = & $wprPath -start $startProfileArgument 2>&1
$startExitCode = $LASTEXITCODE
if ($startExitCode -ne 0) {
    throw "Bounded memory WPR başlatılamadı (exit $startExitCode): $($startOutput -join [Environment]::NewLine)"
}

$profileProvenance = [ordered]@{
    type                     = 'repository_wprp'
    relative_path            = [string]$profileMetadata.RelativePath
    sha256                   = [string]$profileMetadata.Sha256
    length                   = [int64]$profileMetadata.Length
    name                     = [string]$profileMetadata.Name
    detail_level             = [string]$profileMetadata.DetailLevel
    logging_mode             = 'Memory'
    bounded                  = $true
    buffer_size_kib          = [int]$profileMetadata.BufferSizeKiB
    buffers                  = [int]$profileMetadata.Buffers
    memory_buffer_budget_mib = $memoryBudgetMiB
    maximum_file_size_mib    = $null
    file_mode                = $null
    memory_profile_id        = [string]$profileMetadata.MemoryProfileId
    keywords                 = @($profileMetadata.Keywords)
    stacks                   = @($profileMetadata.Stacks)
}
$profileProvenanceSha256 = Get-NxbCanonicalJsonHash -InputObject $profileProvenance

$session = [ordered]@{
    started_utc               = [DateTime]::UtcNow.ToString('o')
    profile                   = 'NxbMinimalCpuScheduler'
    mode                      = 'memory'
    capture_role              = 'bounded-pretrigger-ring'
    profile_provenance        = $profileProvenance
    profile_provenance_sha256 = $profileProvenanceSha256
    status                    = 'recording'
    wpr_executable            = $wprPath
}

try {
    Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 20
    Set-NxbExperimentState -ExperimentPath $experimentFull -State recording -Confirm:$false | Out-Null
}
catch {
    $rollbackOutput = & $wprPath -cancel 2>&1
    $rollbackExitCode = $LASTEXITCODE
    if ($rollbackExitCode -ne 0) {
        Write-Warning "Bounded memory WPR rollback iptali başarısız (exit $rollbackExitCode): $($rollbackOutput -join [Environment]::NewLine)"
    }
    if (Test-Path -LiteralPath $sessionPath) {
        Remove-Item -LiteralPath $sessionPath -Force
    }
    throw
}

$result = [pscustomobject][ordered]@{
    status = 'recording'
    experiment_path = $experimentFull
    session_path = $sessionPath
    logging_mode = 'Memory'
    memory_buffer_budget_mib = $memoryBudgetMiB
    profile_sha256 = [string]$profileMetadata.Sha256
    profile_provenance_sha256 = $profileProvenanceSha256
}

if ($PassThru) { return $result }
Write-Host ("Bounded memory WPR pre-trigger ring başlatıldı: {0} MiB" -f $memoryBudgetMiB)
