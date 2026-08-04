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
$hashFile = Join-Path $experimentFull 'evidence.sha256'
$manifestPath = Join-Path $experimentFull 'manifest.json'

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}

$manifest = Read-NxbJson -Path $manifestPath
$currentState = [string]$manifest.status

if ($currentState -eq 'finalized') {
    & (Join-Path $PSScriptRoot 'Test-EvidenceIntegrity.ps1') `
        -ExperimentPath $experimentFull
    Write-Host "Deney daha önce finalize edilmiş ve bütünlüğü geçerli: $experimentFull"
    return
}

if ($currentState -eq 'recording') {
    throw 'Aktif kayıt durdurulmadan deney finalize edilemez.'
}

if ($currentState -notin @('prepared', 'stopped')) {
    throw "Deney '$currentState' durumundan finalize edilemez."
}

$files = Get-NxbEvidenceFile -ExperimentPath $experimentFull
$lines = foreach ($file in $files) {
    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
    $relative = Get-NxbRelativePath -BasePath $experimentFull -ChildPath $file.FullName
    "$($hash.Hash.ToLowerInvariant())  $relative"
}

$temporaryHashFile = "$hashFile.tmp.$([guid]::NewGuid().ToString('N'))"
try {
    $lines | Set-Content -LiteralPath $temporaryHashFile -Encoding ascii
    Move-Item -LiteralPath $temporaryHashFile -Destination $hashFile -Force
}
finally {
    if (Test-Path -LiteralPath $temporaryHashFile) {
        Remove-Item -LiteralPath $temporaryHashFile -Force
    }
}

$evidenceHash = (Get-FileHash -LiteralPath $hashFile -Algorithm SHA256).Hash
$completedUtc = [DateTime]::UtcNow.ToString('o')

Set-NxbExperimentState `
    -ExperimentPath $experimentFull `
    -State finalized `
    -Updates @{
        completed_utc = $completedUtc
        evidence_sha256 = $evidenceHash
    } | Out-Null

& (Join-Path $PSScriptRoot 'Test-EvidenceIntegrity.ps1') `
    -ExperimentPath $experimentFull

Write-Host "Deney finalize edildi: $experimentFull"
Write-Host "Kanıt listesi: $hashFile"
