[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PlanJsonPath,
    [Parameter(Mandatory = $true)][string]$ExpectedPlanSha256,
    [Parameter(Mandatory = $true)][string]$FingerprintBeforeJsonPath,
    [Parameter(Mandatory = $true)][string]$FingerprintAfterJsonPath,
    [Parameter(Mandatory = $true)][string]$EvidenceStoreModulePath,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 required.'
}

$ExpectedEvidenceStoreSha256 = '207a3e379e411fa6761f21cf01810135572d87033779ec8f791fa0befcd17cd7'
$Sha256Pattern = '^[0-9a-f]{64}$'
$Git40Pattern = '^[0-9a-f]{40}$'
$Utf8 = [Text.UTF8Encoding]::new($false, $true)

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw $Message
}

function Get-NormalizedAbsolutePath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        Fail "$Label is empty."
    }
    $full = [IO.Path]::GetFullPath($Path)
    if (-not $full.Equals($Path, [StringComparison]::OrdinalIgnoreCase)) {
        Fail "$Label must be an absolute normalized path: $Path"
    }
    return $full
}

function Assert-OrdinaryFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $full = Get-NormalizedAbsolutePath -Path $Path -Label $Label
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        Fail "$Label does not exist: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Label is reparse-backed: $full"
    }
    return $full
}

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value -cnotmatch $Sha256Pattern) {
        Fail "$Label must be lowercase 64-hex."
    }
}

function Assert-Git40 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value -cnotmatch $Git40Pattern) {
        Fail "$Label must be lowercase 40-hex."
    }
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Assert-ByteIdentity {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Left,
        [Parameter(Mandatory = $true)][byte[]]$Right,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Left.Length -ne $Right.Length) {
        Fail "$Label byte length mismatch."
    }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            Fail "$Label byte mismatch at offset $index."
        }
    }
}

function Assert-NfcString {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value.Normalize([Text.NormalizationForm]::FormC) -cne $Value) {
        Fail "$Label is not NFC-normalized."
    }
    foreach ($character in $Value.ToCharArray()) {
        $code = [int][char]$character
        if ($code -ge 0xD800 -and $code -le 0xDFFF) {
            Fail "$Label contains a surrogate code unit."
        }
    }
}

function Assert-JsonElementProfile {
    param(
        [Parameter(Mandatory = $true)][Text.Json.JsonElement]$Element,
        [Parameter(Mandatory = $true)][string]$Label
    )

    switch ($Element.ValueKind) {
        ([Text.Json.JsonValueKind]::Object) {
            $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
            foreach ($property in $Element.EnumerateObject()) {
                Assert-NfcString -Value $property.Name -Label "$Label key"
                if (-not $seen.Add($property.Name)) {
                    Fail "duplicate JSON key: $($property.Name)"
                }
                Assert-JsonElementProfile -Element $property.Value -Label "$Label.$($property.Name)"
            }
            break
        }
        ([Text.Json.JsonValueKind]::Array) {
            $index = 0
            foreach ($child in $Element.EnumerateArray()) {
                Assert-JsonElementProfile -Element $child -Label "$Label[$index]"
                $index++
            }
            break
        }
        ([Text.Json.JsonValueKind]::String) {
            Assert-NfcString -Value $Element.GetString() -Label $Label
            break
        }
        ([Text.Json.JsonValueKind]::Number) {
            [long]$integer = 0
            if (-not $Element.TryGetInt64([ref]$integer)) {
                Fail "$Label contains a non-Int64 JSON number."
            }
            break
        }
        ([Text.Json.JsonValueKind]::Undefined) {
            Fail "$Label contains an undefined JSON value."
        }
    }
}

function Read-StrictJsonObject {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $full = Assert-OrdinaryFile -Path $Path -Label $Label
    $bytes = [IO.File]::ReadAllBytes($full)
    if ($bytes.Length -eq 0) {
        Fail "$Label is empty."
    }
    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        Fail "$Label contains a UTF-8 BOM."
    }

    $text = $Utf8.GetString($bytes)
    $options = [Text.Json.JsonDocumentOptions]::new()
    $options.AllowTrailingCommas = $false
    $options.CommentHandling = [Text.Json.JsonCommentHandling]::Disallow
    $options.MaxDepth = 100
    $jsonDocument = [Text.Json.JsonDocument]::Parse($text, $options)
    try {
        if ($jsonDocument.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            Fail "$Label root must be a JSON object."
        }
        Assert-JsonElementProfile -Element $jsonDocument.RootElement -Label $Label
    }
    finally {
        $jsonDocument.Dispose()
    }

    $document = $text | ConvertFrom-Json -Depth 100 -DateKind String
    if ($document -isnot [pscustomobject]) {
        Fail "$Label root must deserialize to an object."
    }

    return [pscustomobject]@{
        Path = $full
        Bytes = $bytes
        Text = $text
        Document = $document
    }
}

function Get-CanonicalSha256 {
    param([Parameter(Mandatory = $true)]$InputObject)
    $canonical = ConvertTo-NxbCanonicalJson -InputObject $InputObject
    $bytes = $Utf8.GetBytes($canonical)
    return [pscustomobject]@{
        Text = $canonical
        Bytes = $bytes
        Sha256 = (Get-Sha256Hex -Bytes $bytes)
    }
}

function Get-FingerprintIdentity {
    param(
        [Parameter(Mandatory = $true)]$Record,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $document = $Record.Text | ConvertFrom-Json -Depth 100 -DateKind String
    Assert-Sha256 -Value ([string]$document.fingerprint_sha256) -Label "$Label fingerprint_sha256"
    [void]$document.PSObject.Properties.Remove('captured_utc')
    [void]$document.PSObject.Properties.Remove('fingerprint_sha256')
    $identity = Get-CanonicalSha256 -InputObject $document
    if ([string]$Record.Document.fingerprint_sha256 -cne $identity.Sha256) {
        Fail "$Label stored fingerprint SHA-256 mismatch."
    }
    return $identity.Sha256
}

function Assert-StringSequenceEqual {
    param(
        [Parameter(Mandatory = $true)][object[]]$Left,
        [Parameter(Mandatory = $true)][object[]]$Right,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Left.Count -ne $Right.Count) {
        Fail "$Label cardinality mismatch."
    }
    for ($index = 0; $index -lt $Left.Count; $index++) {
        if ([string]$Left[$index] -cne [string]$Right[$index]) {
            Fail "$Label mismatch at index $index."
        }
    }
}

function Assert-SortedUniqueLabelSet {
    param(
        [Parameter(Mandatory = $true)][object[]]$Labels,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $values = [string[]]@($Labels | ForEach-Object { [string]$_ })
    $copy = [string[]]@($values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $values) {
        if ([string]::IsNullOrWhiteSpace($value)) {
            Fail "$Label contains an empty label."
        }
        if (-not $seen.Add($value)) {
            Fail "$Label contains a duplicate label: $value"
        }
    }
    Assert-StringSequenceEqual -Left $values -Right $copy -Label "$Label ordinal order"
}

Assert-Sha256 -Value $ExpectedPlanSha256 -Label 'ExpectedPlanSha256'
$planPath = Assert-OrdinaryFile -Path $PlanJsonPath -Label 'PlanJsonPath'
$beforePath = Assert-OrdinaryFile -Path $FingerprintBeforeJsonPath -Label 'FingerprintBeforeJsonPath'
$afterPath = Assert-OrdinaryFile -Path $FingerprintAfterJsonPath -Label 'FingerprintAfterJsonPath'
$modulePath = Assert-OrdinaryFile -Path $EvidenceStoreModulePath -Label 'EvidenceStoreModulePath'

$moduleSha = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($moduleSha -cne $ExpectedEvidenceStoreSha256) {
    Fail "EvidenceStore module SHA-256 drift: expected=$ExpectedEvidenceStoreSha256 actual=$moduleSha"
}
Import-Module -Name $modulePath -Force -ErrorAction Stop
$canonicalCommand = Get-Command -Name 'ConvertTo-NxbCanonicalJson' -CommandType Function -ErrorAction Stop
if (-not ([string]$canonicalCommand.Module.Path).Equals($modulePath, [StringComparison]::OrdinalIgnoreCase)) {
    Fail "ConvertTo-NxbCanonicalJson resolved from unexpected module: $($canonicalCommand.Module.Path)"
}

$planRecord = Read-StrictJsonObject -Path $planPath -Label 'compatibility plan'
$planCanonical = Get-CanonicalSha256 -InputObject $planRecord.Document
Assert-ByteIdentity -Left $planRecord.Bytes -Right $planCanonical.Bytes -Label 'compatibility plan canonical JSON'
if ($planCanonical.Sha256 -cne $ExpectedPlanSha256) {
    Fail "compatibility plan SHA-256 mismatch: expected=$ExpectedPlanSha256 actual=$($planCanonical.Sha256)"
}

$plan = $planRecord.Document
if ([string]$plan.authority -cne 'nxb-v11-compatibility-plan-v1') {
    Fail 'compatibility plan authority mismatch.'
}
if ([int]$plan.schema_version -ne 1) {
    Fail 'compatibility plan schema_version mismatch.'
}
if ([string]$plan.repository -cne 'Naveax/nxb-integrity-research-lab') {
    Fail 'compatibility plan repository mismatch.'
}
if ([string]$plan.cell.status -cne 'enabled') {
    Fail 'compatibility plan cell must be enabled.'
}
if ([int]$plan.review.entry_count -ne 6) {
    Fail 'compatibility plan review entry_count must be 6.'
}
if ([string]$plan.intent.authority -cne 'nxb-v11-compatibility-dispatch-intent-v1') {
    Fail 'compatibility plan intent authority mismatch.'
}
if ([string]$plan.intent.runner_class -cne 'nxb-native') {
    Fail 'compatibility plan runner_class must be nxb-native.'
}

foreach ($name in @(
    'merge_mutation',
    'private_key_used',
    'release_mutation',
    'repository_protection_mutated',
    'tag_mutation'
)) {
    if ([bool]$plan.production_boundary.$name) {
        Fail "compatibility plan production boundary is not claim-free: $name"
    }
}

Assert-Git40 -Value ([string]$plan.candidate.sha) -Label 'plan candidate SHA'
Assert-Git40 -Value ([string]$plan.candidate.tree_sha) -Label 'plan candidate tree'
Assert-Sha256 -Value ([string]$plan.policy.sha256) -Label 'plan policy SHA-256'
Assert-Sha256 -Value ([string]$plan.intent.sha256) -Label 'plan intent SHA-256'

$tier = [string]$plan.endurance.tier
$cycleCount = [int]$plan.endurance.bounded_cycle_count
$expectedCycleCount = switch ($tier) {
    '1h' { 1 }
    '6h' { 6 }
    '24h' { 24 }
    default { Fail "unsupported endurance tier: $tier" }
}
if ($cycleCount -ne $expectedCycleCount) {
    Fail "endurance tier/cycle count mismatch: tier=$tier count=$cycleCount expected=$expectedCycleCount"
}

$beforeRecord = Read-StrictJsonObject -Path $beforePath -Label 'fingerprint before'
$afterRecord = Read-StrictJsonObject -Path $afterPath -Label 'fingerprint after'
$before = $beforeRecord.Document
$after = $afterRecord.Document

foreach ($entry in @(
    [pscustomobject]@{ Label = 'fingerprint before'; Document = $before },
    [pscustomobject]@{ Label = 'fingerprint after'; Document = $after }
)) {
    $label = [string]$entry.Label
    $fingerprint = $entry.Document

    if ([string]$fingerprint.authority -cne 'nxb-compatibility-environment-fingerprint-v1') {
        Fail "$label authority mismatch."
    }
    if ([int]$fingerprint.schema_version -ne 1) {
        Fail "$label schema_version mismatch."
    }
    if ([string]$fingerprint.repository -cne [string]$plan.repository) {
        Fail "$label repository does not match the plan."
    }
    if (-not [bool]$fingerprint.worktree_clean) {
        Fail "$label requires worktree_clean=true."
    }
    if ([string]$fingerprint.head_sha -cne [string]$plan.candidate.sha) {
        Fail "$label candidate SHA does not match the plan."
    }
    if ([string]$fingerprint.head_tree_sha -cne [string]$plan.candidate.tree_sha) {
        Fail "$label candidate tree does not match the plan."
    }
    if ([string]$fingerprint.cell_id -cne [string]$plan.cell.id) {
        Fail "$label cell_id does not match the plan."
    }
    if ([string]$fingerprint.support_class -cne [string]$plan.cell.support_class) {
        Fail "$label support_class does not match the plan."
    }
    if ([string]$fingerprint.policy_path -cne [string]$plan.policy.path) {
        Fail "$label policy path does not match the plan."
    }
    if ([string]$fingerprint.policy_sha256 -cne [string]$plan.policy.sha256) {
        Fail "$label policy SHA-256 does not match the plan."
    }
    if ([string]$fingerprint.runner.os -cne 'Windows') {
        Fail "$label runner OS must be Windows."
    }
    if ([string]$fingerprint.runner.arch -cne [string]$fingerprint.windows.architecture) {
        Fail "$label runner architecture does not match Windows architecture."
    }
    if (-not [bool]$fingerprint.wpt.same_directory) {
        Fail "$label requires paired WPT tools from the same directory."
    }
    if (-not [bool]$fingerprint.wpt.same_kits_root) {
        Fail "$label requires paired WPT tools from the same KitsRoot."
    }
    Assert-SortedUniqueLabelSet -Labels @($fingerprint.runner.labels) -Label "$label runner labels"
}

$beforeIdentity = Get-FingerprintIdentity -Record $beforeRecord -Label 'fingerprint before'
$afterIdentity = Get-FingerprintIdentity -Record $afterRecord -Label 'fingerprint after'
if ($beforeIdentity -cne $afterIdentity) {
    Fail "pre/post fingerprint identity drift: before=$beforeIdentity after=$afterIdentity"
}

$result = [pscustomobject][ordered]@{
    status = 'NATIVE_HARNESS_PREFLIGHT_ONLY'
    admitted = $false
    physical_compatibility_claimed = $false
    native_wpt_dispatch_performed = $false
    workload_executed = $false
    repository_mutated = $false
    plan_sha256 = $planCanonical.Sha256
    fingerprint_before_sha256 = $beforeIdentity
    fingerprint_after_sha256 = $afterIdentity
    fingerprint_stable = $true
    candidate_sha = [string]$plan.candidate.sha
    candidate_tree_sha = [string]$plan.candidate.tree_sha
    cell_id = [string]$plan.cell.id
    policy_sha256 = [string]$plan.policy.sha256
    endurance_tier = $tier
    endurance_cycle_count = $cycleCount
}

if ($PassThru) {
    $result
}
