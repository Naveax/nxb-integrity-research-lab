[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [string]$BundlePath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

function ConvertTo-NxbVerifiedRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        throw "Bundle relative path mutlak olamaz: $Path"
    }
    if ($Path.Contains('\\')) {
        throw "Bundle relative path forward-slash kullanmalıdır: $Path"
    }
    if ($Path.StartsWith('/', [StringComparison]::Ordinal)) {
        throw "Bundle relative path kökten başlayamaz: $Path"
    }

    return $Path
}

function Resolve-NxbVerifiedBundleFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExperimentRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $nativeRelative = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $ExperimentRoot $nativeRelative))
    [void](Get-NxbRelativePath -BasePath $ExperimentRoot -ChildPath $candidate)

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Bundle envanter dosyası bulunamadı: $RelativePath"
    }

    [void](Test-NxbPathSafety -Path $candidate -RootPath $ExperimentRoot)
    return Get-Item -LiteralPath $candidate -Force
}

function Add-NxbBundlePathIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Collections.Generic.Dictionary[string, string]]$CaseMap,

        [Parameter(Mandatory)]
        [Collections.Generic.HashSet[string]]$ExactSet,

        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    if ($ExactSet.Contains($RelativePath)) {
        throw "Bundle envanterinde yinelenen path bulundu: $RelativePath"
    }
    if ($CaseMap.ContainsKey($RelativePath)) {
        throw "Bundle path case-collision bulundu: '$RelativePath' ve '$($CaseMap[$RelativePath])'"
    }

    [void]$ExactSet.Add($RelativePath)
    $CaseMap[$RelativePath] = $RelativePath
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
if ([string]::IsNullOrWhiteSpace($BundlePath)) {
    $BundlePath = Join-Path $experimentFull 'evidence-store\bundle-manifest.json'
}
$bundleFull = Get-NxbFullPath -Path $BundlePath
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $bundleFull)
[void](Test-NxbPathSafety -Path $bundleFull -RootPath $experimentFull)

if (-not (Test-Path -LiteralPath $bundleFull -PathType Leaf)) {
    throw "Evidence bundle manifest bulunamadı: $bundleFull"
}

& (Join-Path $PSScriptRoot 'Test-EvidenceStoreSchema.ps1') `
    -Path $bundleFull `
    -DocumentType bundle-manifest

$bundle = Read-NxbJson -Path $bundleFull
if ([string]$bundle.signature_state -cne 'unsigned') {
    throw "Signature adapter olmadan bundle doğrulanamaz: $($bundle.signature_state)"
}
if ($null -ne $bundle.PSObject.Properties['signature']) {
    throw 'Unsigned bundle signature metadata içeremez.'
}

$actualBundleHash = Get-NxbCanonicalJsonHash `
    -InputObject $bundle `
    -ExcludeRootProperty @('bundle_sha256', 'signature')
if ([string]$bundle.bundle_sha256 -cne $actualBundleHash) {
    throw 'Bundle SHA-256 uyuşmuyor.'
}

$chain = & (Join-Path $PSScriptRoot 'Test-EvidenceStoreChain.ps1') `
    -ExperimentPath $experimentFull `
    -PassThru

$identityExpectations = [ordered]@{
    experiment_id = [string]$chain.ExperimentId
    machine_id = [string]$chain.MachineId
    boot_id = [string]$chain.BootId
    session_id = [string]$chain.SessionId
    chain_sha256 = [string]$chain.ChainSha256
}
foreach ($entry in $identityExpectations.GetEnumerator()) {
    if ([string]$bundle.($entry.Key) -cne [string]$entry.Value) {
        throw "Bundle chain kimliği uyuşmuyor: $($entry.Key)"
    }
}

$caseMap = [Collections.Generic.Dictionary[string, string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$exactSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$bundleRelative = Get-NxbRelativePath -BasePath $experimentFull -ChildPath $bundleFull
$bundleRelative = $bundleRelative.Replace([IO.Path]::DirectorySeparatorChar, '/')

$records = @($bundle.records)
if ($records.Count -ne [int64]$chain.RecordCount) {
    throw 'Bundle record sayısı verified chain ile uyuşmuyor.'
}

for ($index = 0; $index -lt $records.Count; $index++) {
    $recordEntry = $records[$index]
    $expectedSequence = [int64]$index
    if ([int64]$recordEntry.sequence -ne $expectedSequence) {
        throw "Bundle record sırası kesintili: beklenen $expectedSequence"
    }

    $recordName = [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        '{0:D16}.json',
        $expectedSequence
    )
    $expectedRelative = "evidence-store/records/$recordName"
    $relative = ConvertTo-NxbVerifiedRelativePath -Path ([string]$recordEntry.relative_path)
    if ($relative -cne $expectedRelative) {
        throw "Bundle record path sequence ile uyuşmuyor: $relative"
    }

    Add-NxbBundlePathIdentity -CaseMap $caseMap -ExactSet $exactSet -RelativePath $relative
    $item = Resolve-NxbVerifiedBundleFile `
        -ExperimentRoot $experimentFull `
        -RelativePath $relative

    if ([int64]$recordEntry.length -ne [int64]$item.Length) {
        throw "Bundle record byte uzunluğu uyuşmuyor: $relative"
    }
    $actualHash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$recordEntry.sha256 -cne $actualHash) {
        throw "Bundle record file SHA-256 uyuşmuyor: $relative"
    }
}

$files = @($bundle.files)
$declaredPaths = [Collections.Generic.List[string]]::new()
$hasChainHead = $false
foreach ($fileEntry in $files) {
    $relative = ConvertTo-NxbVerifiedRelativePath -Path ([string]$fileEntry.relative_path)
    if ($relative -ceq $bundleRelative) {
        throw 'Bundle manifest kendi envanterinde listelenemez.'
    }
    if ($relative -ceq 'evidence-store/chain-head.json') {
        $hasChainHead = $true
    }

    Add-NxbBundlePathIdentity -CaseMap $caseMap -ExactSet $exactSet -RelativePath $relative
    [void]$declaredPaths.Add($relative)

    $item = Resolve-NxbVerifiedBundleFile `
        -ExperimentRoot $experimentFull `
        -RelativePath $relative
    if ([int64]$fileEntry.length -ne [int64]$item.Length) {
        throw "Bundle file byte uzunluğu uyuşmuyor: $relative"
    }

    $actualHash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ([string]$fileEntry.sha256 -cne $actualHash) {
        throw "Bundle file SHA-256 uyuşmuyor: $relative"
    }
}

if (-not $hasChainHead) {
    throw 'Bundle envanteri chain-head.json içermiyor.'
}

$sortedPaths = $declaredPaths.ToArray()
[Array]::Sort($sortedPaths, [StringComparer]::Ordinal)
for ($index = 0; $index -lt $sortedPaths.Count; $index++) {
    if ($declaredPaths[$index] -cne $sortedPaths[$index]) {
        throw 'Bundle file envanteri ordinal path sırasına göre sıralı değil.'
    }
}

$result = [pscustomobject]@{
    IsValid = $true
    BundlePath = $bundleFull
    BundleSha256 = $actualBundleHash
    ChainSha256 = [string]$chain.ChainSha256
    RecordCount = [int64]$records.Count
    FileCount = [int64]$files.Count
    SignatureState = [string]$bundle.signature_state
}

if ($PassThru) {
    Write-Output $result
}
else {
    Write-Host "Evidence bundle geçerli: $bundleFull"
}
