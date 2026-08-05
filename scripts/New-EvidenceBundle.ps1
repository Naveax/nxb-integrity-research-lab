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

    if ([IO.Path]::IsPathRooted($Path) -or $Path -match '^[A-Za-z]:') {
        throw "Bundle relative path mutlak olamaz: $Path"
    }

    $normalized = $Path.Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
    if ([string]::IsNullOrWhiteSpace($normalized) -or
        $normalized.StartsWith('/', [StringComparison]::Ordinal)) {
        throw "Bundle relative path geçersiz: $Path"
    }

    foreach ($segment in $normalized.Split([char]'/')) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -eq '.' -or $segment -eq '..') {
            throw "Bundle relative path canonical değil: $Path"
        }
    }

    return $normalized
}

function Resolve-NxbBundleFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ExperimentRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $nativeRelative = $RelativePath.Replace([char]'/', [IO.Path]::DirectorySeparatorChar)
    $candidate = [IO.Path]::GetFullPath((Join-Path $ExperimentRoot $nativeRelative))
    [void](Get-NxbRelativePath -BasePath $ExperimentRoot -ChildPath $candidate)

    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "Bundle dosyası bulunamadı: $RelativePath"
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

function Test-NxbBundleOutputPathSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
        [string]$ExperimentRoot
    )

    $pathFull = Get-NxbFullPath -Path $Path
    [void](Get-NxbRelativePath -BasePath $ExperimentRoot -ChildPath $pathFull)

    $existingAncestor = $pathFull
    while (-not (Test-Path -LiteralPath $existingAncestor)) {
        $parent = Split-Path -Parent $existingAncestor
        if ([string]::IsNullOrWhiteSpace($parent) -or
            $parent.Equals($existingAncestor, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Bundle output yolu için mevcut güvenli ancestor bulunamadı: $pathFull"
        }
        $existingAncestor = $parent
    }

    [void](Test-NxbPathSafety -Path $existingAncestor -RootPath $ExperimentRoot)
    return $true
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$storePath = Join-Path $experimentFull 'evidence-store'
$recordsPath = Join-Path $storePath 'records'

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $storePath 'bundle-manifest.json'
}
$outputFull = Get-NxbFullPath -Path $OutputPath
$outputRelative = Get-NxbRelativePath -BasePath $experimentFull -ChildPath $outputFull
$outputRelative = $outputRelative.Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
if ($outputRelative.StartsWith('evidence-store/records/', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Bundle manifest records dizini altında yazılamaz.'
}
[void](Test-NxbBundleOutputPathSafety -Path $outputFull -ExperimentRoot $experimentFull)

$verifiedChain = & (Join-Path $PSScriptRoot 'Test-EvidenceStoreChain.ps1') `
    -ExperimentPath $experimentFull `
    -PassThru

$caseMap = [Collections.Generic.Dictionary[string, string]]::new(
    [StringComparer]::OrdinalIgnoreCase
)
$exactSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$recordInventory = [Collections.Generic.List[object]]::new()

for ($sequence = [int64]0; $sequence -lt $verifiedChain.RecordCount; $sequence++) {
    $recordName = [string]::Format(
        [Globalization.CultureInfo]::InvariantCulture,
        '{0:D16}.json',
        $sequence
    )
    $relative = "evidence-store/records/$recordName"
    Add-NxbBundlePathIdentity -CaseMap $caseMap -ExactSet $exactSet -RelativePath $relative

    $recordPath = Join-Path $recordsPath $recordName
    [void](Test-NxbPathSafety -Path $recordPath -RootPath $experimentFull)
    if (-not (Test-Path -LiteralPath $recordPath -PathType Leaf)) {
        throw "Bundle record dosyası bulunamadı: $recordName"
    }

    $recordItem = Get-Item -LiteralPath $recordPath -Force
    $recordHash = (Get-FileHash -LiteralPath $recordPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [void]$recordInventory.Add([ordered]@{
        sequence = $sequence
        relative_path = $relative
        length = [int64]$recordItem.Length
        sha256 = $recordHash
    })
}

$normalizedPaths = [Collections.Generic.List[string]]::new()
foreach ($candidatePath in $IncludeRelativePath) {
    $relative = ConvertTo-NxbBundleRelativePath -Path $candidatePath
    if ($relative.Equals($outputRelative, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Bundle manifest kendi dosya envanterine dahil edilemez.'
    }

    if ($exactSet.Contains($relative)) {
        continue
    }
    if ($caseMap.ContainsKey($relative)) {
        throw "Bundle path case-collision bulundu: '$relative' ve '$($caseMap[$relative])'"
    }

    Add-NxbBundlePathIdentity -CaseMap $caseMap -ExactSet $exactSet -RelativePath $relative
    [void]$normalizedPaths.Add($relative)
}

[string[]]$sortedPaths = $normalizedPaths.ToArray()
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
$bundleHash = Get-NxbCanonicalJsonHash `
    -InputObject $bundle `
    -ExcludeRootProperty @('bundle_sha256', 'signature_state', 'signature')
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
