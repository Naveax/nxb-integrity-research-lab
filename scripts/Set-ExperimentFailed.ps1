[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$Reason
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
$currentState = [string]$manifest.status
if ($currentState -eq 'finalized') {
    throw 'Finalized deney failed durumuna geçirilemez.'
}
if ($currentState -eq 'failed') {
    throw 'Deney zaten failed durumunda.'
}

if ($PSCmdlet.ShouldProcess($experimentFull, "Deneyi failed durumuna geçir: $Reason")) {
    Set-NxbExperimentState `
        -ExperimentPath $experimentFull `
        -State failed `
        -Updates @{
            failed_utc = [DateTime]::UtcNow.ToString('o')
            failure_reason = $Reason
        } | Out-Null

    Write-Host "Deney failed durumuna geçirildi: $experimentFull"
}
