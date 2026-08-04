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
$sessionPath = Join-Path $experimentFull 'trace-session.json'
$evidencePath = Join-Path $experimentFull 'evidence.sha256'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}

$manifest = Read-NxbJson -Path $manifestPath
$session = $null
if (Test-Path -LiteralPath $sessionPath -PathType Leaf) {
    $session = Read-NxbJson -Path $sessionPath
}

$evidenceState = 'not-finalized'
$evidenceIssues = @()
if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
    try {
        $integrity = & (Join-Path $PSScriptRoot 'Test-EvidenceIntegrity.ps1') `
            -ExperimentPath $experimentFull `
            -PassThru
        $evidenceState = if ($integrity.IsValid) { 'valid' } else { 'invalid' }
        $evidenceIssues = @($integrity.Issues)
    }
    catch {
        $evidenceState = 'invalid'
        $evidenceIssues = @($_.Exception.Message)
    }
}

[pscustomobject]@{
    ExperimentPath = $experimentFull
    ExperimentId = [string]$manifest.experiment_id
    Name = [string]$manifest.name
    Status = [string]$manifest.status
    CreatedUtc = [string]$manifest.created_utc
    CompletedUtc = [string]$manifest.completed_utc
    TraceStatus = if ($null -ne $session) { [string]$session.status } else { 'none' }
    EvidenceStatus = $evidenceState
    EvidenceIssues = $evidenceIssues
}
