[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot

Write-Host 'PowerShell syntax denetleniyor...'
$scriptFiles = Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'scripts') -Filter '*.ps1' -File
foreach ($file in $scriptFiles) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if ($parseErrors.Count -gt 0) {
        $messages = $parseErrors | ForEach-Object {
            "$($file.Name):$($_.Extent.StartLineNumber): $($_.Message)"
        }
        throw ($messages -join [Environment]::NewLine)
    }
}

Write-Host 'JSON dosyaları denetleniyor...'
$jsonFiles = @(
    (Join-Path $repositoryRoot 'config\lab.config.example.json'),
    (Join-Path $repositoryRoot 'schemas\experiment.schema.json')
)
foreach ($jsonFile in $jsonFiles) {
    Get-Content -LiteralPath $jsonFile -Raw | ConvertFrom-Json | Out-Null
}

Write-Host 'Workspace ve evidence smoke testi çalıştırılıyor...'
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-lab-test-{0}" -f [guid]::NewGuid())
try {
    $initializedRoot = & (Join-Path $PSScriptRoot 'Initialize-Lab.ps1') `
        -Root $tempRoot `
        -Role Target

    if ($initializedRoot -ne $tempRoot) {
        throw "Initialize-Lab beklenmeyen çıktı verdi: $initializedRoot"
    }

    $experimentPath = & (Join-Path $PSScriptRoot 'New-Experiment.ps1') `
        -Root $tempRoot `
        -Name 'Repository-Smoke-Test' `
        -Hypothesis 'Manifest ve evidence finalization akışı çalışır'

    $syntheticEvidence = Join-Path $experimentPath 'logs\synthetic-evidence.txt'
    'synthetic test evidence' | Set-Content -LiteralPath $syntheticEvidence -Encoding utf8

    & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
        -ExperimentPath $experimentPath

    $manifestPath = Join-Path $experimentPath 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.status -ne 'finalized') {
        throw "Manifest finalized değil: $($manifest.status)"
    }

    $evidencePath = Join-Path $experimentPath 'evidence.sha256'
    if (-not (Test-Path -LiteralPath $evidencePath -PathType Leaf)) {
        throw 'evidence.sha256 oluşturulmadı.'
    }

    $evidenceText = Get-Content -LiteralPath $evidencePath -Raw
    if ($evidenceText -notmatch 'logs[\\/]synthetic-evidence\.txt') {
        throw 'Sentetik kanıt evidence listesine eklenmedi.'
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Host 'Repository doğrulaması başarılı.'
