[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [AllowEmptyCollection()]
    [string[]]$IncludeRelativePath = @(
        'manifest.json',
        'baseline/observation-identity.json',
        'evidence-store/chain-head.json'
    ),

    [Parameter()]
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

function ConvertTo-NxbBundleRelativePath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path
    )

    if ([IO.Path]::IsPathRooted($Path)) {
        throw "Bundle relative path mutlak olamaz: $Path"
    }

    $normalized = $Path.Replace('\\', '/').TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'Bundle relative path boş olamaz.'
    }

    return $normalized
}

function Resolve-NxbBundleFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExperimentRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $nativeRelative = $RelativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $ExperimentRoot $nativeRelative))
    [void](Get-NxbRelativePath -BasePath $ExperimentRoot -ChildPath $candidate)

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Bundle dosyası bulunamadı: $RelativePath"
    }

    [void](Test-NxbPathSafety -Path $candidate -RootPath $ExperimentRoot)
    return Get-Item -LiteralPath $candidate -Force
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$storePath = Join-Path $experimentFull 'evidence-store'
$recordsPath = Join-Path $storePath 'records'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $storePath 'bundle-manifest.json'
}
$outputFull = Get-NxbFullPath -Path $OutputPath
[void](Get-NxbRelativePath -BasePath $experimentFull -ChildPath $outputFull)
[void](Test-NxbPathSafety -Path $outputFull -RootPath $experimentFull)

$verifiedChain = & (Join-Path $PSScriptRoot 'Test-EvidenceStoreChain.ps1') `
    -ExperimentPath $experimentFull `
    -PassThru

$recordInventory = [Collections.Generic.List[object]]::new()
for ($sequence = [int64]0; $sequence -lt $verifiedChain.RecordCount; $sequence++) {
    $recordName = [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        '{0:D16}.json',
        $sequence
    )
    $recordPath = Join-Path $recordsPath $recordName
    [void](Test-NxbPathSafety -Path $recordPath -RootPath $experimentFull)
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        throw "Bundle record dosyası bulunamadı: $recordName"
    }

    $recordItem = Get-Item -LiteralPath $recordPath -Force
    $recordHash = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$recordInventory.Add([ordered]@{
        sequence = $sequence
        relative_path = "evidence-store/records/$recordName"
        length = [int64]$recordItem.Length
        sha256 = $recordHash
    })
}

$caseMap = [Collections.Generic.Dictionary[string, string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$exactSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$normalizedPaths = [Collections.Generic.List[string]]::new()

foreach ($candidatePath in $IncludeRelativePath) {
    $relative = ConvertTo-NxbBundleRelativePath -Path $candidatePath
    if ($relative -ceq 'evidence-store/bundle-manifest.json') {
        throw 'Bundle manifest kendi dosya envanterine dahil edilemez.'
    }

    if ($exactSet.Contains($relative)) {
        continue
    }
    if ($caseMap.ContainsKey($relative)) {
        throw "Bundle path case-collision bulundu: '$relative' ve '$($caseMap[$relative])'"
    }

    [void]$exactSet.Add($relative)
    $caseMap[$relative] = $relative
    [void]$normalizedPaths.Add($relative)
}

$sortedPaths = $normalizedPaths.ToArray()
[Array]::Sort($sortedPaths, [StringComparer]::Ordinal)

$fileInventory = [Collections.Generic.List[object]]::new()
foreach ($relative in $sortedPaths) {
    $item = Resolve-NxbBundleFile -ExperimentRoot $experimentFull -RelativePath $relative
    $fileHash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$fileInventory.Add([ordered]@{
        relative_path = $relative
        length = [int64]$item.Length
        sha256 = $fileHash
    })
}

if (-not $exactSet.Contains('evidence-store/chain-head.json')) {
    throw 'Bundle dosya envanteri chain-head.json içermelidir.'
}

$bundle = [ordered]@{
    schema_version = 1
    experiment_id = [string]$verifiedChain.ExperimentId
    machine_id = [string]$verifiedChain.MachineId
    boot_id = [string]$verifiedChain.BootId
    session_id = [string]$verifiedChain.SessionId
    chain_sha256 = [string]$verifiedChain.ChainSha256
    records = $recordInventory.ToArray()
    files = $fileInventory.ToArray()
    signature_state = 'unsigned'
}
$bundleHash = Get-NxbCanonicalJsonHash -InputObject $bundle
$bundle['bundle_sha256'] = $bundleHash

if ($PSCmdlet.ShouldProcess($outputFull, 'Deterministic offline evidence bundle manifest yaz')) {
    Write-NxbCanonicalJsonAtomic `
        -Path $outputFull `
        -InputObject $bundle `
        -Confirm:$false

    & (Join-Path $PSScriptRoot 'Test-EvidenceStoreSchema.ps1') `
        -Path $outputFull `
        -DocumentType bundle-manifest

    $verification = & (Join-Path $PSScriptRoot 'Test-EvidenceBundle.ps1') `
        -ExperimentPath $experimentFull `
        -BundlePath $outputFull `
        -PassThru

    [pscustomobject]@{
        BundlePath = $outputFull
        BundleSha256 = $bundleHash
        ChainSha256 = [string]$verification.ChainSha256
        RecordCount = [int64]$verification.RecordCount
        FileCount = [int64]$verification.FileCount
        SignatureState = [string]$verification.SignatureState
    }
}
