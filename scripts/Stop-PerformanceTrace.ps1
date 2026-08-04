[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

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
if ([string]$manifest.status -ne 'recording') {
    throw "WPR yalnız recording deneyde durdurulabilir. Mevcut durum: $($manifest.status)"
}

$sessionPath = Join-Path $experimentFull 'trace-session.json'
if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
    throw "Trace session manifesti bulunamadı: $sessionPath"
}

$session = Read-NxbJson -Path $sessionPath
if ([string]$session.status -ne 'recording') {
    throw "Trace session recording değil: $($session.status)"
}

try {
    $wprPath = Resolve-NxbExecutablePath -Name 'wpr.exe' -ExplicitPath $WprExecutablePath
}
catch {
    throw "wpr.exe bulunamadı. $($_.Exception.Message)"
}

$traces = Join-Path $experimentFull 'traces'
New-Item -ItemType Directory -Path $traces -Force | Out-Null
$etl = Join-Path $traces 'performance.etl'

$stopOutput = & $wprPath -stop $etl 2>&1
$stopExitCode = $LASTEXITCODE
if ($stopExitCode -ne 0) {
    throw "WPR durdurulamadı (exit $stopExitCode): $($stopOutput -join [Environment]::NewLine)"
}

if (-not (Test-Path -LiteralPath $etl -PathType Leaf)) {
    $failedUtc = [DateTime]::UtcNow.ToString('o')
    $failureMessage = "WPR başarı kodu döndürdü ancak ETL oluşturulmadı: $etl"

    try {
        $session.status = 'failed'
        $session | Add-Member -MemberType NoteProperty -Name failed_utc -Value $failedUtc -Force
        $session | Add-Member -MemberType NoteProperty -Name failure_reason -Value $failureMessage -Force
        Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 8
    }
    catch {
        Write-Warning "Trace session failed durumu yazılamadı: $($_.Exception.Message)"
    }

    try {
        Set-NxbExperimentState `
            -ExperimentPath $experimentFull `
            -State failed `
            -Updates @{
                failed_utc     = $failedUtc
                failure_reason = $failureMessage
            } `
            -Confirm:$false | Out-Null
    }
    catch {
        Write-Warning "Deney failed durumuna alınamadı: $($_.Exception.Message)"
    }

    throw $failureMessage
}

try {
    $hash = Get-FileHash -LiteralPath $etl -Algorithm SHA256
    $traceMetadata = [ordered]@{
        path           = $etl
        sha256         = $hash.Hash
        length         = (Get-Item -LiteralPath $etl).Length
        stopped_utc    = [DateTime]::UtcNow.ToString('o')
        wpr_executable = $wprPath
    }

    Write-NxbJsonAtomic `
        -Path (Join-Path $traces 'performance.etl.json') `
        -InputObject $traceMetadata `
        -Depth 8

    $session.status = 'stopped'
    $session | Add-Member -MemberType NoteProperty -Name stopped_utc -Value $traceMetadata.stopped_utc -Force
    $session | Add-Member -MemberType NoteProperty -Name etl -Value $etl -Force
    Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 8

    Set-NxbExperimentState `
        -ExperimentPath $experimentFull `
        -State stopped `
        -Confirm:$false | Out-Null
}
catch {
    $finalizationError = $_.Exception.Message
    $failedUtc = [DateTime]::UtcNow.ToString('o')
    $failureMessage = "WPR durdu ancak trace finalization başarısız: $finalizationError"

    try {
        $session.status = 'failed'
        $session | Add-Member -MemberType NoteProperty -Name failed_utc -Value $failedUtc -Force
        $session | Add-Member -MemberType NoteProperty -Name failure_reason -Value $failureMessage -Force
        Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 8
    }
    catch {
        Write-Warning "Trace session failed durumu yazılamadı: $($_.Exception.Message)"
    }

    try {
        Set-NxbExperimentState `
            -ExperimentPath $experimentFull `
            -State failed `
            -Updates @{
                failed_utc     = $failedUtc
                failure_reason = $failureMessage
            } `
            -Confirm:$false | Out-Null
    }
    catch {
        Write-Warning "Deney failed durumuna alınamadı: $($_.Exception.Message)"
    }

    throw $failureMessage
}

Write-Host "WPR kaydı tamamlandı: $etl"
