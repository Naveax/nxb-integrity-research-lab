[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [switch]$CleanTemporaryFiles,

    [Parameter()]
    [switch]$MarkInterruptedRecordingFailed,

    [Parameter()]
    [switch]$FinalizeStopped,

    [Parameter()]
    [switch]$CancelActiveWpr
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$manifestPath = Join-Path $experimentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}

$actions = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

if ($CleanTemporaryFiles) {
    $temporaryFiles = Get-ChildItem -LiteralPath $experimentFull -File -Recurse -Force |
        Where-Object { $_.Name -match '\.tmp\.[0-9a-f]{32}$' }

    foreach ($temporaryFile in $temporaryFiles) {
        if ($PSCmdlet.ShouldProcess($temporaryFile.FullName, 'Yarım atomik geçici dosyayı kaldır')) {
            Remove-Item -LiteralPath $temporaryFile.FullName -Force
            $actions.Add("removed-temp:$($temporaryFile.FullName)")
        }
    }
}

$manifest = Read-NxbJson -Path $manifestPath
$currentState = [string]$manifest.status
$sessionPath = Join-Path $experimentFull 'trace-session.json'

switch ($currentState) {
    'prepared' {
        $warnings.Add('Deney prepared durumda; otomatik recovery gerekmiyor.')
    }

    'recording' {
        if ($CancelActiveWpr) {
            $wpr = Get-Command wpr.exe -ErrorAction SilentlyContinue
            if ($wpr) {
                if ($PSCmdlet.ShouldProcess($experimentFull, 'Aktif WPR oturumunu iptal et')) {
                    $output = & $wpr.Source -cancel 2>&1
                    if ($LASTEXITCODE -ne 0) {
                        $warnings.Add("WPR cancel başarısız: $($output -join [Environment]::NewLine)")
                    }
                    else {
                        $actions.Add('cancelled-wpr')
                    }
                }
            }
            else {
                $warnings.Add('wpr.exe bulunamadığı için aktif oturum iptal edilemedi.')
            }
        }

        if ($MarkInterruptedRecordingFailed) {
            $reason = 'Recording state was interrupted before a valid stop/finalization sequence.'
            & (Join-Path $PSScriptRoot 'Set-ExperimentFailed.ps1') `
                -ExperimentPath $experimentFull `
                -Reason $reason `
                -Confirm:$false
            $actions.Add('marked-failed')
        }
        else {
            $warnings.Add('Recording durumundaki deney otomatik ilerletilmedi; -MarkInterruptedRecordingFailed gerekir.')
        }
    }

    'stopped' {
        if ($FinalizeStopped) {
            if ($PSCmdlet.ShouldProcess($experimentFull, 'Durdurulmuş deneyi finalize et')) {
                & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
                    -ExperimentPath $experimentFull
                $actions.Add('finalized-stopped')
            }
        }
        else {
            $warnings.Add('Deney stopped durumda; finalize etmek için -FinalizeStopped gerekir.')
        }
    }

    'finalized' {
        & (Join-Path $PSScriptRoot 'Test-EvidenceIntegrity.ps1') `
            -ExperimentPath $experimentFull
        $actions.Add('verified-finalized')
    }

    'failed' {
        $warnings.Add('Deney failed durumda; otomatik yeniden açılmaz.')
    }

    default {
        throw "Bilinmeyen deney durumu: $currentState"
    }
}

$updatedManifest = Read-NxbJson -Path $manifestPath
[pscustomobject]@{
    ExperimentPath = $experimentFull
    PreviousState = $currentState
    CurrentState = [string]$updatedManifest.status
    TraceSessionPresent = (Test-Path -LiteralPath $sessionPath -PathType Leaf)
    Actions = @($actions)
    Warnings = @($warnings)
}
