[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$LeftBundlePath,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$RightBundlePath,

    [Parameter()]
    [string]$LeftExperimentPath,

    [Parameter()]
    [string]$RightExperimentPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.EvidenceStore.psm1') -Force

function Read-NxbComparisonBundle {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][string]$ExperimentPath
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    & (Join-Path $PSScriptRoot 'Test-EvidenceStoreSchema.ps1') `
        -Path $fullPath `
        -DocumentType bundle-manifest

    $bundle = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
    $actualHash = Get-NxbCanonicalJsonHash `
        -InputObject $bundle `
        -ExcludeRootProperty @('bundle_sha256', 'signature_state', 'signature')
    if ([string]$bundle.bundle_sha256 -cne $actualHash) {
        throw "Bundle SHA-256 uyuşmuyor: $fullPath"
    }

    $fullyVerified = $false
    if (-not [string]::IsNullOrWhiteSpace($ExperimentPath)) {
        & (Join-Path $PSScriptRoot 'Test-EvidenceBundle.ps1') `
            -ExperimentPath $ExperimentPath `
            -BundlePath $fullPath | Out-Null
        $fullyVerified = $true
    }

    return [pscustomobject]@{
        Path = $fullPath
        Document = $bundle
        BundleSha256 = $actualHash
        FullyVerified = $fullyVerified
    }
}

function New-NxbInventoryMap {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Entries,
        [Parameter(Mandatory)][ValidateSet('record', 'file')][string]$Kind
    )

    $map = [Collections.Generic.SortedDictionary[string, object]]::new(
        [StringComparer]::Ordinal
    )
    foreach ($entry in $Entries) {
        $key = if ($Kind -eq 'record') {
            ([int64]$entry.sequence).ToString(
                'D16',
                [Globalization.CultureInfo]::InvariantCulture
            )
        }
        else {
            [string]$entry.relative_path
        }

        if ($map.ContainsKey($key)) {
            throw "Comparison inventory duplicate key: $Kind/$key"
        }
        $map.Add($key, $entry)
    }

    return $map
}

function Compare-NxbInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Collections.Generic.SortedDictionary[string, object]]$Left,

        [Parameter(Mandatory)]
        [Collections.Generic.SortedDictionary[string, object]]$Right
    )

    $leftOnly = [Collections.Generic.List[string]]::new()
    $rightOnly = [Collections.Generic.List[string]]::new()
    $changed = [Collections.Generic.List[string]]::new()

    foreach ($key in $Left.Keys) {
        if (-not $Right.ContainsKey($key)) {
            [void]$leftOnly.Add($key)
            continue
        }

        $leftHash = Get-NxbCanonicalJsonHash -InputObject $Left[$key]
        $rightHash = Get-NxbCanonicalJsonHash -InputObject $Right[$key]
        if ($leftHash -cne $rightHash) {
            [void]$changed.Add($key)
        }
    }

    foreach ($key in $Right.Keys) {
        if (-not $Left.ContainsKey($key)) {
            [void]$rightOnly.Add($key)
        }
    }

    return [pscustomobject]@{
        LeftOnly = $leftOnly.ToArray()
        RightOnly = $rightOnly.ToArray()
        Changed = $changed.ToArray()
    }
}

$left = Read-NxbComparisonBundle `
    -Path $LeftBundlePath `
    -ExperimentPath $LeftExperimentPath
$right = Read-NxbComparisonBundle `
    -Path $RightBundlePath `
    -ExperimentPath $RightExperimentPath

$leftDocument = $left.Document
$rightDocument = $right.Document
$identityFields = @('experiment_id', 'machine_id', 'boot_id', 'session_id')
$identityChanges = [Collections.Generic.List[string]]::new()
foreach ($field in $identityFields) {
    if ([string]$leftDocument.$field -cne [string]$rightDocument.$field) {
        [void]$identityChanges.Add($field)
    }
}

$recordComparison = Compare-NxbInventory `
    -Left (New-NxbInventoryMap -Entries @($leftDocument.records) -Kind record) `
    -Right (New-NxbInventoryMap -Entries @($rightDocument.records) -Kind record)
$fileComparison = Compare-NxbInventory `
    -Left (New-NxbInventoryMap -Entries @($leftDocument.files) -Kind file) `
    -Right (New-NxbInventoryMap -Entries @($rightDocument.files) -Kind file)

$relationship = if ($left.BundleSha256 -ceq $right.BundleSha256) {
    'identical_bundle_identity'
}
elseif ($identityChanges.Count -eq 0) {
    'same_experiment_identity_different_content'
}
else {
    'different_experiment_identity'
}

[pscustomobject]@{
    Relationship = $relationship
    IsIdentical = ($relationship -eq 'identical_bundle_identity')
    LeftBundlePath = $left.Path
    RightBundlePath = $right.Path
    LeftBundleSha256 = $left.BundleSha256
    RightBundleSha256 = $right.BundleSha256
    LeftFullyVerified = [bool]$left.FullyVerified
    RightFullyVerified = [bool]$right.FullyVerified
    IdentityChanges = $identityChanges.ToArray()
    ChainSha256Changed = ([string]$leftDocument.chain_sha256 -cne [string]$rightDocument.chain_sha256)
    SignatureStateChanged = ([string]$leftDocument.signature_state -cne [string]$rightDocument.signature_state)
    RecordsLeftOnly = $recordComparison.LeftOnly
    RecordsRightOnly = $recordComparison.RightOnly
    RecordsChanged = $recordComparison.Changed
    FilesLeftOnly = $fileComparison.LeftOnly
    FilesRightOnly = $fileComparison.RightOnly
    FilesChanged = $fileComparison.Changed
}
