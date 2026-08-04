[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$hashFile = Join-Path $ExperimentPath 'evidence.sha256'
$manifestPath = Join-Path $ExperimentPath 'manifest.json'

$files = Get-ChildItem -LiteralPath $ExperimentPath -File -Recurse -Force |
    Where-Object {
        $_.FullName -ne $hashFile -and
        $_.FullName -ne $manifestPath
    } |
    Sort-Object FullName

$lines = foreach ($file in $files) {
    $hash = Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256
    $relative = [IO.Path]::GetRelativePath($ExperimentPath, $file.FullName)
    "$($hash.Hash.ToLowerInvariant())  $relative"
}

$lines | Set-Content -LiteralPath $hashFile -Encoding ascii

if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.status = 'finalized'
    $manifest.completed_utc = [DateTime]::UtcNow.ToString('o')
    $manifest.evidence_sha256 = (Get-FileHash -LiteralPath $hashFile -Algorithm SHA256).Hash
    $manifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

Write-Host "Deney finalize edildi: $ExperimentPath"
Write-Host "Kanıt listesi: $hashFile"
