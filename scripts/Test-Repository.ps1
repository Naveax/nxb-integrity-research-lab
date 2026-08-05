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

Write-Host 'Bounded WPR profile sözleşmesi denetleniyor...'
$wprProfile = & (Join-Path $PSScriptRoot 'Test-WprProfile.ps1') -PassThru
if ([string]$wprProfile.RelativePath -cne 'profiles/Nxb.MinimalCpuScheduler.wprp' -or
    -not [bool]$wprProfile.MaximumFileSizeMiB -or
    [int]$wprProfile.MaximumFileSizeMiB -ne 512 -or
    [string]$wprProfile.FileMode -cne 'Circular') {
    throw 'Bounded WPR profile repository smoke sözleşmesini karşılamıyor.'
}

Write-Host 'JSON dosyaları denetleniyor...'
$jsonFiles = @(
    (Join-Path $repositoryRoot 'config\lab.config.example.json'),
    (Join-Path $repositoryRoot 'config\public-repository-policy.json'),
    (Join-Path $repositoryRoot 'schemas\experiment.schema.json'),
    (Join-Path $repositoryRoot 'schemas\system-capabilities.schema.json'),
    (Join-Path $repositoryRoot 'schemas\observation-identity.schema.json'),
    (Join-Path $repositoryRoot 'schemas\observability-event.schema.json'),
    (Join-Path $repositoryRoot 'schemas\evidence-store-record.schema.json'),
    (Join-Path $repositoryRoot 'schemas\evidence-chain-head.schema.json'),
    (Join-Path $repositoryRoot 'schemas\evidence-bundle-manifest.schema.json')
)
foreach ($jsonFile in $jsonFiles) {
    Get-Content -LiteralPath $jsonFile -Raw | ConvertFrom-Json | Out-Null
}

Write-Host 'Canonical evidence-store JSON ve SHA-256 sözleşmesi denetleniyor...'
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force
$canonicalFixture = [ordered]@{
    z = 1
    list = @(3, "x`n", $false)
    a = [ordered]@{
        b = $true
        a = $null
    }
}
$expectedCanonicalJson = '{"a":{"a":null,"b":true},"list":[3,"x\n",false],"z":1}'
$expectedCanonicalHash = '170f36671e659fda9fdc5237be36ae283a2e5a63c03029ce11cb6b4c17f839a7'

if ((ConvertTo-NxbCanonicalJson -InputObject $canonicalFixture) -ne $expectedCanonicalJson) {
    throw 'Canonical JSON smoke vektörü uyuşmuyor.'
}
if ((Get-NxbCanonicalJsonHash -InputObject $canonicalFixture) -ne $expectedCanonicalHash) {
    throw 'Canonical SHA-256 smoke vektörü uyuşmuyor.'
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

    Write-Host 'Evidence-store chain ve offline bundle smoke testi çalıştırılıyor...'
    [void](& (Join-Path $PSScriptRoot 'New-EvidenceStoreRecord.ps1') `
        -ExperimentPath $experimentPath `
        -RecordType manifest_snapshot `
        -Payload ([ordered]@{
            status = [string]$manifest.status
            manifest_sha256 = $manifestHashBefore.ToLowerInvariant()
        }) `
        -SessionId 'repository-smoke-session' `
        -CapturedUtc ([DateTime]'2026-08-04T22:00:00Z') `
        -MonotonicNs 100)

    [void](& (Join-Path $PSScriptRoot 'New-EvidenceStoreRecord.ps1') `
        -ExperimentPath $experimentPath `
        -RecordType evidence_index_snapshot `
        -Payload ([ordered]@{
            checked_entries = [int64]$integrity.CheckedEntries
            evidence_index_sha256 = $evidenceHashBefore.ToLowerInvariant()
        }) `
        -SessionId 'repository-smoke-session' `
        -CapturedUtc ([DateTime]'2026-08-04T22:00:01Z') `
        -MonotonicNs 200)

    $chain = & (Join-Path $PSScriptRoot 'Test-EvidenceStoreChain.ps1') `
        -ExperimentPath $experimentPath `
        -PassThru
    if (-not $chain.IsValid -or $chain.RecordCount -ne 2) {
        throw 'Evidence-store chain smoke doğrulaması başarısız.'
    }

    $bundle = & (Join-Path $PSScriptRoot 'New-EvidenceBundle.ps1') `
        -ExperimentPath $experimentPath `
        -IncludeRelativePath @(
            'manifest.json',
            'baseline/observation-identity.json',
            'evidence-store/chain-head.json',
            'evidence.sha256',
            'logs/synthetic-evidence.txt'
        ) `
        -Confirm:$false

    $bundleVerification = & (Join-Path $PSScriptRoot 'Test-EvidenceBundle.ps1') `
        -ExperimentPath $experimentPath `
        -BundlePath $bundle.BundlePath `
        -PassThru
    if (-not $bundleVerification.IsValid -or
        $bundleVerification.SignatureState -cne 'unsigned' -or
        $bundleVerification.RecordCount -ne 2) {
        throw 'Unsigned offline evidence bundle smoke doğrulaması başarısız.'
    }
}
finally {
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

Write-Host 'Repository doğrulaması başarılı.'
