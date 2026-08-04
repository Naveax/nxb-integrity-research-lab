[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$manifestPath = Join-Path $experimentFull 'manifest.json'
$evidencePath = Join-Path $experimentFull 'evidence.sha256'
$issues = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    $issues.Add("Manifest bulunamadı: $manifestPath")
}

if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
    $issues.Add("Evidence listesi bulunamadı: $evidencePath")
}

$manifest = $null
if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
    try {
        $manifest = Read-NxbJson -Path $manifestPath
    }
    catch {
        $issues.Add("Manifest okunamadı: $($_.Exception.Message)")
    }
}

$expected = @{}
if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $evidencePath) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        if ($line -notmatch '^([0-9a-fA-F]{64})  (.+)$') {
            $issues.Add("Geçersiz evidence satırı $lineNumber: $line")
            continue
        }

        $hash = $Matches[1].ToLowerInvariant()
        $relative = $Matches[2]
        $candidate = Get-NxbFullPath -Path (Join-Path $experimentFull $relative)

        try {
            [void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $candidate)
        }
        catch {
            $issues.Add("Evidence yolu deney kökü dışında: $relative")
            continue
        }

        if ($expected.ContainsKey($relative)) {
            $issues.Add("Tekrarlanan evidence yolu: $relative")
            continue
        }

        $expected[$relative] = $hash
    }
}

foreach ($entry in $expected.GetEnumerator()) {
    $path = Join-Path $experimentFull $entry.Key
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $issues.Add("Evidence dosyası eksik: $($entry.Key)")
        continue
    }

    try {
        Assert-NxbNoReparsePoint -Path $path
        $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -ne $entry.Value) {
            $issues.Add("Hash uyuşmazlığı: $($entry.Key)")
        }
    }
    catch {
        $issues.Add("Evidence doğrulanamadı '$($entry.Key)': $($_.Exception.Message)")
    }
}

try {
    $actualFiles = Get-NxbEvidenceFiles -ExperimentPath $experimentFull
    foreach ($file in $actualFiles) {
        $relative = Get-NxbRelativePath -BasePath $experimentFull -ChildPath $file.FullName
        if (-not $expected.ContainsKey($relative)) {
            $issues.Add("Evidence listesinde bulunmayan dosya: $relative")
        }
    }
}
catch {
    $issues.Add("Evidence dosya envanteri oluşturulamadı: $($_.Exception.Message)")
}

if ($null -ne $manifest) {
    if ([string]$manifest.status -ne 'finalized') {
        $issues.Add("Manifest finalized değil: $($manifest.status)")
    }

    if ($manifest.PSObject.Properties.Name -notcontains 'evidence_sha256') {
        $issues.Add('Manifest evidence_sha256 alanı içermiyor.')
    }
    elseif (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
        $actualEvidenceHash = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash
        if ([string]$manifest.evidence_sha256 -ne $actualEvidenceHash) {
            $issues.Add('Manifest evidence_sha256 değeri evidence.sha256 ile uyuşmuyor.')
        }
    }
}

$result = [pscustomobject]@{
    ExperimentPath = $experimentFull
    IsValid = ($issues.Count -eq 0)
    CheckedEntries = $expected.Count
    IssueCount = $issues.Count
    Issues = @($issues)
}

if ($PassThru) {
    Write-Output $result
}

if (-not $result.IsValid) {
    $message = "Evidence bütünlük doğrulaması başarısız:`n- " + ($issues -join "`n- ")
    throw $message
}

Write-Host "Evidence bütünlüğü doğrulandı: $experimentFull"
