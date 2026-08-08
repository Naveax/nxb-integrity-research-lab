[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$WprExecutablePath,

    [Parameter()]
    [string]$XperfExecutablePath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$manifestPath = Join-Path $experimentFull 'manifest.json'
$sessionPath = Join-Path $experimentFull 'trace-session.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}
if (-not (Test-Path -LiteralPath $sessionPath -PathType Leaf)) {
    throw "Trace session bulunamadı: $sessionPath"
}

$manifest = Read-NxbJson -Path $manifestPath
$session = Read-NxbJson -Path $sessionPath
if ([string]$manifest.status -ne 'recording' -or [string]$session.status -ne 'recording') {
    throw 'Accounting-aware stop yalnız recording deney ve session üzerinde çalışabilir.'
}

if (-not $PSCmdlet.ShouldProcess($experimentFull, 'Stop WPR and finalize trace-loss accounting')) {
    return
}

$statusSnapshotPath = Join-Path $experimentFull 'analysis\wpr-status-pre-stop.json'
try {
    $statusSnapshotPath = & (Join-Path $PSScriptRoot 'Get-NxbWprStatusSnapshot.ps1') `
        -ExperimentPath $experimentFull `
        -WprExecutablePath $WprExecutablePath `
        -Confirm:$false
}
catch {
    Write-Warning "Pre-stop WPR status snapshot alınamadı: $($_.Exception.Message)"
}

& (Join-Path $PSScriptRoot 'Stop-PerformanceTrace.ps1') `
    -ExperimentPath $experimentFull `
    -WprExecutablePath $WprExecutablePath

try {
    $accountingPath = & (Join-Path $PSScriptRoot 'New-NxbTraceLossAccountingFromSources.ps1') `
        -ExperimentPath $experimentFull `
        -PreStopSnapshotPath $statusSnapshotPath `
        -XperfExecutablePath $XperfExecutablePath `
        -Confirm:$false

    $accounting = Read-NxbJson -Path $accountingPath
    if ([string]$accounting.summary.evidence_completeness -eq 'failed') {
        throw 'Trace-loss accounting belgesi failed durumunda.'
    }

    $session = Read-NxbJson -Path $sessionPath
    $relativeAccountingPath = Get-NxbRelativePath `
        -BasePath $experimentFull `
        -ChildPath $accountingPath
    $session | Add-Member `
        -MemberType NoteProperty `
        -Name trace_loss_accounting `
        -Value $relativeAccountingPath.Replace([IO.Path]::DirectorySeparatorChar, [char]'/') `
        -Force
    Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 20
}
catch {
    $failureMessage = "WPR durdu ancak trace-loss accounting finalization başarısız: $($_.Exception.Message)"
    $failedUtc = [DateTime]::UtcNow.ToString('o')

    try {
        $session = Read-NxbJson -Path $sessionPath
        $session.status = 'failed'
        $session | Add-Member -MemberType NoteProperty -Name failed_utc -Value $failedUtc -Force
        $session | Add-Member -MemberType NoteProperty -Name failure_reason -Value $failureMessage -Force
        Write-NxbJsonAtomic -Path $sessionPath -InputObject $session -Depth 20
    }
    catch {
        Write-Warning "Trace session accounting failure durumu yazılamadı: $($_.Exception.Message)"
    }

    try {
        Set-NxbExperimentState `
            -ExperimentPath $experimentFull `
            -State failed `
            -Updates @{
                failed_utc = $failedUtc
                failure_reason = $failureMessage
            } `
            -Confirm:$false | Out-Null
    }
    catch {
        Write-Warning "Deney accounting failure nedeniyle failed durumuna alınamadı: $($_.Exception.Message)"
    }

    throw $failureMessage
}

Write-Host "WPR ve trace-loss accounting tamamlandı: $accountingPath"
if ($PassThru) {
    return [pscustomobject]@{
        ExperimentPath = $experimentFull
        StatusSnapshotPath = $statusSnapshotPath
        PostStopStatisticsPath = (Join-Path $experimentFull 'analysis\etl-trace-statistics.json')
        AccountingPath = $accountingPath
    }
}
Write-Output $accountingPath
