[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot

Write-Host 'Public repository content policy denetleniyor...'
& (Join-Path $PSScriptRoot 'Test-PublicRepositoryContent.ps1') `
    -RepositoryRoot $repositoryRoot

Write-Host 'PowerShell syntax denetleniyor...'
$scriptFiles = Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'scripts') -File |
    Where-Object { $_.Extension -in @('.ps1', '.psm1') }
$scriptFiles += Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tests') -Filter '*.ps1' -File

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
    (Join-Path $repositoryRoot 'config\public-repository-policy.json'),
    (Join-Path $repositoryRoot 'schemas\experiment.schema.json'),
    (Join-Path $repositoryRoot 'schemas\system-capabilities.schema.json'),
    (Join-Path $repositoryRoot 'schemas\observation-identity.schema.json'),
    (Join-Path $repositoryRoot 'schemas\observability-event.schema.json')
)
foreach ($jsonFile in $jsonFiles) {
    Get-Content -LiteralPath $jsonFile -Raw | ConvertFrom-Json | Out-Null
}

Write-Host 'Workspace, capability, identity, schema ve evidence smoke testi çalıştırılıyor...'
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
        -Hypothesis 'Manifest, capability, identity ve evidence akışı çalışır'

    & (Join-Path $PSScriptRoot 'Test-ExperimentManifest.ps1') `
        -ExperimentPath $experimentPath

    $capabilityPath = & (Join-Path $PSScriptRoot 'Get-SystemCapabilities.ps1') `
        -ExperimentPath $experimentPath

    if (-not (Test-Path -LiteralPath $capabilityPath -PathType Leaf)) {
        throw 'System capability envanteri oluşturulmadı.'
    }

    & (Join-Path $PSScriptRoot 'Test-SystemCapabilities.ps1') `
        -ExperimentPath $experimentPath

    $capability = Get-Content -LiteralPath $capabilityPath -Raw | ConvertFrom-Json
    if ($capability.schema_version -ne 1) {
        throw "Beklenmeyen capability schema version: $($capability.schema_version)"
    }
    if ($capability.domains.PSObject.Properties.Name.Count -lt 11) {
        throw 'System capability envanterinde beklenen domainler bulunamadı.'
    }

    $identityPath = & (Join-Path $PSScriptRoot 'Get-ObservationIdentity.ps1') `
        -ExperimentPath $experimentPath

    if (-not (Test-Path -LiteralPath $identityPath -PathType Leaf)) {
        throw 'Observation identity oluşturulmadı.'
    }

    & (Join-Path $PSScriptRoot 'Test-ObservationIdentity.ps1') `
        -ExperimentPath $experimentPath

    $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    if ([string]$identity.experiment_id -ne [string](Split-Path -Leaf $experimentPath)) {
        throw 'Observation identity experiment_id ile deney dizini uyuşmuyor.'
    }
    if ([string]$identity.machine_id -ne [string]$capability.machine_id) {
        throw 'Capability ve observation identity machine_id değerleri uyuşmuyor.'
    }

    $syntheticEvidence = Join-Path $experimentPath 'logs\synthetic-evidence.txt'
    'synthetic test evidence' | Set-Content -LiteralPath $syntheticEvidence -Encoding utf8

    & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
        -ExperimentPath $experimentPath

    & (Join-Path $PSScriptRoot 'Test-ExperimentManifest.ps1') `
        -ExperimentPath $experimentPath

    $manifestPath = Join-Path $experimentPath 'manifest.json'
    $evidencePath = Join-Path $experimentPath 'evidence.sha256'
    $manifestHashBefore = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $evidenceHashBefore = (Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash

    & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
        -ExperimentPath $experimentPath

    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ne $manifestHashBefore) {
        throw 'İkinci finalization manifesti değiştirdi.'
    }
    if ((Get-FileHash -LiteralPath $evidencePath -Algorithm SHA256).Hash -ne $evidenceHashBefore) {
        throw 'İkinci finalization evidence listesini değiştirdi.'
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.status -ne 'finalized') {
        throw "Manifest finalized değil: $($manifest.status)"
    }

    $integrity = & (Join-Path $PSScriptRoot 'Test-EvidenceIntegrity.ps1') `
        -ExperimentPath $experimentPath `
        -PassThru
    if (-not $integrity.IsValid) {
        throw 'Evidence doğrulaması başarısız.'
    }

    $status = & (Join-Path $PSScriptRoot 'Get-ExperimentStatus.ps1') `
        -ExperimentPath $experimentPath
    if ($status.EvidenceStatus -ne 'valid') {
        throw "Beklenmeyen evidence durumu: $($status.EvidenceStatus)"
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Host 'Repository doğrulaması başarılı.'
