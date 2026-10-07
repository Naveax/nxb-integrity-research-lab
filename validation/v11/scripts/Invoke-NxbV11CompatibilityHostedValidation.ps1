param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][string]$CandidateSha,
    [Parameter(Mandatory = $true)][string]$CandidateTree,
    [Parameter(Mandatory = $true)][string]$EvidenceStoreModulePath,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 required.'
}

$ExpectedPredecessorSha = '9203ab9f89ff4383832119683eb4e19df5490213'
$ExpectedPredecessorTree = '241d3086e9bcb5a847445258cab25bff4fd34da8'
$ExpectedEvidenceStoreSha256 = '207a3e379e411fa6761f21cf01810135572d87033779ec8f791fa0befcd17cd7'
$ExpectedAllowlistSha256 = '5764ed8ff14b6816c28935d1e317197512ae39e888bf4ecf61fee9ebd9ceb57e'
$AllowlistVersion = 6
$AllowlistAuthorityCommentId = [long]5426682541
$Git40Pattern = '^[0-9a-f]{40}$'

$ExactPaths = @(
    '.github/workflows/nxb-v11-compatibility.yml',
    'config/nxb-native-impact-policy.json',
    'config/nxb-v11-compatibility-policy.json',
    'config/nxb-v11-known-error-signatures.json',
    'config/nxb-v11-validation-toolchain-lock.json',
    'docs/NXB-V11-COMPATIBILITY-AUTHORITY.md',
    'schemas/nxb-artifact-tree-manifest.schema.json',
    'schemas/nxb-native-impact-policy.schema.json',
    'schemas/nxb-v11-a0-hosted-substrate.schema.json',
    'schemas/nxb-v11-compatibility-plan.schema.json',
    'schemas/nxb-v11-compatibility-policy.schema.json',
    'schemas/nxb-v11-compatibility-receipt.schema.json',
    'schemas/nxb-v11-endurance-cycle-summary.schema.json',
    'schemas/nxb-v11-environment-fingerprint.schema.json',
    'schemas/nxb-v11-independent-validation.schema.json',
    'schemas/nxb-v11-installed-distribution-manifest.schema.json',
    'schemas/nxb-v11-known-error-scan.schema.json',
    'schemas/nxb-v11-known-error-signatures.schema.json',
    'schemas/nxb-v11-module-root-manifest.schema.json',
    'schemas/nxb-v11-powershell-module-lock.schema.json',
    'schemas/nxb-v11-predecessor-replay-receipt.schema.json',
    'schemas/nxb-v11-python-dependency-lock.schema.json',
    'schemas/nxb-v11-validation-toolchain-lock.schema.json',
    'schemas/nxb-v11-wheelhouse-manifest.schema.json',
    'validation/v11/locks/powershell-modules.lock.json',
    'validation/v11/locks/validator-py312.lock',
    'validation/v11/locks/validator-py313.lock',
    'validation/v11/locks/validator-py314.lock',
    'validation/v11/scripts/ConvertTo-NxbV11CanonicalAuthority.ps1',
    'validation/v11/scripts/Expand-NxbV11VerifiedArchive.ps1',
    'validation/v11/scripts/Get-NxbCompatibilityEnvironmentFingerprint.ps1',
    'validation/v11/scripts/Invoke-NxbV11CandidateDispatcher.ps1',
    'validation/v11/scripts/Invoke-NxbV11CompatibilityHostedValidation.ps1',
    'validation/v11/scripts/Invoke-NxbV11CompatibilityNativeValidation.ps1',
    'validation/v11/scripts/Invoke-NxbV11EnduranceCycle.ps1',
    'validation/v11/tests/CanonicalJson.Tests.ps1',
    'validation/v11/tests/V11Compatibility.Tests.ps1',
    'validation/v11/tests/V11NativeCompatibility.Tests.ps1',
    'validation/v11/tools/build_artifact_tree_manifest.py',
    'validation/v11/tools/classify_native_impact.py',
    'validation/v11/tools/materialize_python_requirements.py',
    'validation/v11/tools/run_pinned_pip.py',
    'validation/v11/tools/scan_v11_known_errors.py',
    'validation/v11/tools/validate_v11_compatibility.py'
)

$SubtreeRules = @(
    'validation/v11/fixtures/artifact-tree/',
    'validation/v11/fixtures/canonical-json/',
    'validation/v11/fixtures/compatibility-artifact/',
    'validation/v11/fixtures/known-error/',
    'validation/v11/fixtures/native-impact-classifier/',
    'validation/v11/fixtures/native-runtime/',
    'validation/v11/fixtures/verified-archive/'
)

$WorkflowPathSet = @(
    '.github/workflows/nxb-v11-compatibility.yml'
)

$PowerShellPathSet = @(
    'validation/v11/scripts/ConvertTo-NxbV11CanonicalAuthority.ps1',
    'validation/v11/scripts/Expand-NxbV11VerifiedArchive.ps1',
    'validation/v11/scripts/Get-NxbCompatibilityEnvironmentFingerprint.ps1',
    'validation/v11/scripts/Invoke-NxbV11CandidateDispatcher.ps1',
    'validation/v11/scripts/Invoke-NxbV11CompatibilityHostedValidation.ps1',
    'validation/v11/scripts/Invoke-NxbV11CompatibilityNativeValidation.ps1',
    'validation/v11/scripts/Invoke-NxbV11EnduranceCycle.ps1'
)

$PythonPathSet = @(
    'validation/v11/tools/build_artifact_tree_manifest.py',
    'validation/v11/tools/classify_native_impact.py',
    'validation/v11/tools/materialize_python_requirements.py',
    'validation/v11/tools/run_pinned_pip.py',
    'validation/v11/tools/scan_v11_known_errors.py',
    'validation/v11/tools/validate_v11_compatibility.py'
)

$PesterPathSet = @(
    'validation/v11/tests/CanonicalJson.Tests.ps1',
    'validation/v11/tests/V11Compatibility.Tests.ps1',
    'validation/v11/tests/V11NativeCompatibility.Tests.ps1'
)

$LockPathSet = @(
    'validation/v11/locks/powershell-modules.lock.json',
    'validation/v11/locks/validator-py312.lock',
    'validation/v11/locks/validator-py313.lock',
    'validation/v11/locks/validator-py314.lock'
)

$DocumentationPathSet = @(
    'docs/NXB-V11-COMPATIBILITY-AUTHORITY.md'
)

$StrictJsonPathSet = @(
    $ExactPaths |
        Where-Object {
            $_ -like 'config/*.json' -or
            $_ -like 'schemas/*.json'
        }
)

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw $Message
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

function Assert-OrdinaryDirectory {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $full = Get-NormalizedAbsolutePath -Path $Path -Label $Label
    if (-not (Test-Path -LiteralPath $full -PathType Container)) {
        Fail "$Label is not an existing directory: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Label is reparse-backed: $full"
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
        Fail "$Label is not an existing file: $full"
    }
    $item = Get-Item -LiteralPath $full -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        Fail "$Label is reparse-backed: $full"
    }
    return $full
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

function Get-CanonicalHash {
    param([Parameter(Mandatory = $true)]$InputObject)
    $canonical = ConvertTo-NxbCanonicalJson -InputObject $InputObject
    $bytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($canonical)
    return Get-Sha256Hex -Bytes $bytes
}

function Invoke-GitOutput {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(
            & $script:GitPath -C $script:RepositoryRootFull @Arguments 2>&1 |
                ForEach-Object { [string]$_ }
        )
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    if ($exitCode -ne 0) {
        Fail "$Label failed: exit=$exitCode output=$($output -join ' | ')"
    }
    return @($output)
}

function Get-GitOneLine {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $rows = @(Invoke-GitOutput -Arguments $Arguments -Label $Label |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($rows.Count -ne 1) {
        Fail "$Label did not return exactly one line."
    }
    return $rows[0].Trim()
}

function Get-OrdinalSortedStringArray {
    param([Parameter(Mandatory = $true)][string[]]$Values)
    $copy = [string[]]@($Values)
    [Array]::Sort($copy, [StringComparer]::Ordinal)
    return $copy
}

function Assert-RepositoryPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AllowTrailingSlash
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        Fail 'repository path is empty.'
    }
    if ($Path.StartsWith('/', [StringComparison]::Ordinal) -or
        $Path.StartsWith('./', [StringComparison]::Ordinal) -or
        $Path.Contains('\')) {
        Fail "repository path is not canonical: $Path"
    }
    if (-not $AllowTrailingSlash -and $Path.EndsWith('/', [StringComparison]::Ordinal)) {
        Fail "file path has a trailing slash: $Path"
    }
    if ($AllowTrailingSlash -and -not $Path.EndsWith('/', [StringComparison]::Ordinal)) {
        Fail "subtree prefix must end with '/': $Path"
    }
    if ($Path -match '[\x00-\x1f\x7f]') {
        Fail "repository path contains a control character: $Path"
    }

    $trimmed = if ($AllowTrailingSlash) { $Path.TrimEnd('/') } else { $Path }
    $segments = $trimmed.Split('/')
    if ($segments.Count -eq 0) {
        Fail "repository path has no segments: $Path"
    }
    foreach ($segment in $segments) {
        if ([string]::IsNullOrEmpty($segment) -or $segment -ceq '.' -or $segment -ceq '..') {
            Fail "repository path contains an invalid segment: $Path"
        }
    }
}

function Assert-CaseFoldUniqueSet {
    param(
        [Parameter(Mandatory = $true)][string[]]$Values,
        [Parameter(Mandatory = $true)][string]$Label
    )
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $Values) {
        if (-not $seen.Add($value)) {
            Fail "$Label contains a duplicate or case-fold collision: $value"
        }
    }
}

function Test-PathInSet {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Set
    )
    foreach ($candidate in $Set) {
        if ($Path -ceq $candidate) {
            return $true
        }
    }
    return $false
}

function Get-MatchingSubtree {
    param([Parameter(Mandatory = $true)][string]$Path)
    $subtreeMatches = @(
        $script:SubtreeRulesSorted |
            Where-Object { $Path.StartsWith($_, [StringComparison]::Ordinal) }
    )
    if ($subtreeMatches.Count -gt 1) {
        Fail "repository path matches multiple A0 fixture prefixes: $Path"
    }
    if ($subtreeMatches.Count -eq 1) {
        return [string]$subtreeMatches[0]
    }
    return $null
}

function Get-ValidationClass {
    param([Parameter(Mandatory = $true)][string]$Path)

    $classMatches = [Collections.Generic.List[string]]::new()
    if (Test-PathInSet -Path $Path -Set $WorkflowPathSet) {
        $classMatches.Add('workflow_orchestration')
    }
    if (Test-PathInSet -Path $Path -Set $PowerShellPathSet) {
        $classMatches.Add('executable_powershell')
    }
    if (Test-PathInSet -Path $Path -Set $PythonPathSet) {
        $classMatches.Add('executable_python')
    }
    if (Test-PathInSet -Path $Path -Set $PesterPathSet) {
        $classMatches.Add('pester_test')
    }
    if (Test-PathInSet -Path $Path -Set $StrictJsonPathSet) {
        $classMatches.Add('strict_json_policy_or_schema')
    }
    if (Test-PathInSet -Path $Path -Set $LockPathSet) {
        $classMatches.Add('locked_dependency_manifest')
    }
    if (Test-PathInSet -Path $Path -Set $DocumentationPathSet) {
        $classMatches.Add('authority_documentation')
    }

    $subtree = Get-MatchingSubtree -Path $Path
    if ($null -ne $subtree) {
        if ($Path -match '(?i)\.(ps1|psm1|psd1|py|exe|dll|com|bat|cmd|msi|msp|zip|nupkg|whl)$') {
            Fail "fixture path has executable/package-like content extension: $Path"
        }
        $classMatches.Add('logical_fixture_spec')
    }

    if ($classMatches.Count -ne 1) {
        Fail "changed path must resolve to exactly one validation class: path=$Path matches=$($classMatches -join ',')"
    }
    return $classMatches[0]
}

function Get-SecondaryCheckSet {
    param([Parameter(Mandatory = $true)][string]$PrimaryClass)
    switch ($PrimaryClass) {
        'workflow_orchestration' {
            return @('strict_yaml_semantics', 'known_error_scan', 'action_pin_set_match')
        }
        'executable_powershell' {
            return @('powershell_parser', 'psscriptanalyzer', 'known_error_scan')
        }
        'executable_python' {
            return @('python_syntax', 'known_error_scan')
        }
        'pester_test' {
            return @('powershell_parser', 'psscriptanalyzer', 'pester_isolated', 'known_error_scan')
        }
        'strict_json_policy_or_schema' {
            return @('json_parse', 'canonical_bytes', 'strict_schema', 'cross_document_validation')
        }
        'locked_dependency_manifest' {
            return @('lock_schema', 'canonical_bytes', 'identity_cardinality', 'parent_policy_binding')
        }
        'logical_fixture_spec' {
            return @('public_content_guard', 'fixture_shape_size_path', 'independent_expected_decision')
        }
        'authority_documentation' {
            return @('public_content_guard', 'source_contract_tokens')
        }
        default {
            Fail "unknown validation class: $PrimaryClass"
        }
    }
}

function Get-ChangedPathSet {
    $arguments = @(
        '-c', 'core.quotepath=false',
        'diff-tree',
        '--no-commit-id',
        '--name-status',
        '-r',
        '-M',
        '-C',
        '--find-copies-harder',
        $ExpectedPredecessorSha,
        $CandidateSha
    )
    $rows = @(Invoke-GitOutput -Arguments $arguments -Label 'candidate changed-path diff' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $rows) {
        $parts = [string[]]$row.Split([char]9)
        if ($parts.Count -lt 2) {
            Fail "malformed Git name-status row: $row"
        }
        $status = [string]$parts[0]

        if ($status -cmatch '^[RC][0-9]{1,3}$') {
            if ($parts.Count -ne 3) {
                Fail "rename/copy row does not contain source and destination paths: $row"
            }
            foreach ($path in @([string]$parts[1], [string]$parts[2])) {
                Assert-RepositoryPath -Path $path
                if (-not $paths.Add($path)) {
                    continue
                }
            }
            continue
        }

        if ($status -cnotmatch '^[ADMT]$') {
            Fail "unsupported Git change status: $status"
        }
        if ($parts.Count -ne 2) {
            Fail "Git change row has unexpected field count: $row"
        }
        $path = [string]$parts[1]
        Assert-RepositoryPath -Path $path
        [void]$paths.Add($path)
    }

    $result = Get-OrdinalSortedStringArray -Values @($paths)
    Assert-CaseFoldUniqueSet -Values $result -Label 'changed path set'
    return $result
}

Assert-Git40 -Value $CandidateSha -Label 'CandidateSha'
Assert-Git40 -Value $CandidateTree -Label 'CandidateTree'

$script:RepositoryRootFull = Assert-OrdinaryDirectory -Path $RepositoryRoot -Label 'RepositoryRoot'
$modulePath = Assert-OrdinaryFile -Path $EvidenceStoreModulePath -Label 'EvidenceStoreModulePath'
$expectedModulePath = [IO.Path]::GetFullPath((Join-Path $script:RepositoryRootFull 'scripts\Nxb.EvidenceStore.psm1'))
if (-not $modulePath.Equals($expectedModulePath, [StringComparison]::OrdinalIgnoreCase)) {
    Fail "EvidenceStoreModulePath is not the exact shared module in the trusted checkout: $modulePath"
}
$moduleSha = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($moduleSha -cne $ExpectedEvidenceStoreSha256) {
    Fail "EvidenceStore module SHA-256 drift: expected=$ExpectedEvidenceStoreSha256 actual=$moduleSha"
}

Import-Module -Name $modulePath -Force -ErrorAction Stop
$canonicalCommand = Get-Command -Name 'ConvertTo-NxbCanonicalJson' -CommandType Function -ErrorAction Stop
if (-not ([string]$canonicalCommand.Module.Path).Equals($modulePath, [StringComparison]::OrdinalIgnoreCase)) {
    Fail "ConvertTo-NxbCanonicalJson resolved from unexpected module: $($canonicalCommand.Module.Path)"
}

$gitCommand = Get-Command -Name git -CommandType Application -ErrorAction Stop
$script:GitPath = [string]$gitCommand.Source
if ([string]::IsNullOrWhiteSpace($script:GitPath)) {
    Fail 'git executable could not be resolved.'
}

$inside = Get-GitOneLine -Arguments @('rev-parse', '--is-inside-work-tree') -Label 'Git worktree check'
if ($inside -cne 'true') {
    Fail 'RepositoryRoot is not a Git worktree.'
}

$currentHead = Get-GitOneLine -Arguments @('rev-parse', 'HEAD') -Label 'current HEAD'
$currentTree = Get-GitOneLine -Arguments @('rev-parse', 'HEAD^{tree}') -Label 'current tree'
if ($currentHead -cne $CandidateSha) {
    Fail "candidate HEAD mismatch: expected=$CandidateSha actual=$currentHead"
}
if ($currentTree -cne $CandidateTree) {
    Fail "candidate tree mismatch: expected=$CandidateTree actual=$currentTree"
}

$predecessorTree = Get-GitOneLine -Arguments @('rev-parse', ($ExpectedPredecessorSha + '^{tree}')) -Label 'predecessor tree'
if ($predecessorTree -cne $ExpectedPredecessorTree) {
    Fail "predecessor tree drift: expected=$ExpectedPredecessorTree actual=$predecessorTree"
}
$candidateCommitTree = Get-GitOneLine -Arguments @('rev-parse', ($CandidateSha + '^{tree}')) -Label 'candidate commit tree'
if ($candidateCommitTree -cne $CandidateTree) {
    Fail "candidate commit/tree binding mismatch: expected=$CandidateTree actual=$candidateCommitTree"
}

$statusRows = @(Invoke-GitOutput -Arguments @('status', '--porcelain=v1', '--untracked-files=all') -Label 'worktree status' |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($statusRows.Count -ne 0) {
    Fail 'A0 hosted source-preflight requires a clean candidate worktree.'
}

$script:SubtreeRulesSorted = Get-OrdinalSortedStringArray -Values $SubtreeRules
$exactPathsSorted = Get-OrdinalSortedStringArray -Values $ExactPaths
if ($exactPathsSorted.Count -ne 44) {
    Fail "A0 exact-path cardinality drift: $($exactPathsSorted.Count)"
}
if ($script:SubtreeRulesSorted.Count -ne 7) {
    Fail "A0 subtree cardinality drift: $($script:SubtreeRulesSorted.Count)"
}
foreach ($path in $exactPathsSorted) {
    Assert-RepositoryPath -Path $path
}
foreach ($prefix in $script:SubtreeRulesSorted) {
    Assert-RepositoryPath -Path $prefix -AllowTrailingSlash
}
Assert-CaseFoldUniqueSet -Values $exactPathsSorted -Label 'A0 exact path list'
Assert-CaseFoldUniqueSet -Values $script:SubtreeRulesSorted -Label 'A0 subtree rule list'

$allowlistManifest = [ordered]@{
    authority = 'nxb-v11-a0-allowlist-v1'
    schema_version = 1
    allowlist_version = $AllowlistVersion
    authority_comment = $AllowlistAuthorityCommentId
    exact_paths = $exactPathsSorted
    subtree_rules = $script:SubtreeRulesSorted
}
$allowlistSha = Get-CanonicalHash -InputObject $allowlistManifest
if ($allowlistSha -cne $ExpectedAllowlistSha256) {
    Fail "A0 allowlist SHA-256 drift: expected=$ExpectedAllowlistSha256 actual=$allowlistSha"
}

$changedPaths = @(Get-ChangedPathSet)
foreach ($path in $changedPaths) {
    $exactMatch = Test-PathInSet -Path $path -Set $exactPathsSorted
    $subtreeMatch = $null -ne (Get-MatchingSubtree -Path $path)
    if (($exactMatch -and $subtreeMatch) -or (-not $exactMatch -and -not $subtreeMatch)) {
        Fail "changed path is outside or ambiguously inside A0 allowlist v6: $path"
    }
}

$changedManifest = [ordered]@{
    authority = 'nxb-v11-a0-changed-path-set-v1'
    schema_version = 1
    base_sha = $ExpectedPredecessorSha
    base_tree_sha = $ExpectedPredecessorTree
    candidate_sha = $CandidateSha
    candidate_tree_sha = $CandidateTree
    paths = $changedPaths
}
$changedSha = Get-CanonicalHash -InputObject $changedManifest

$coverageEntries = [Collections.Generic.List[object]]::new()
$classCounts = [ordered]@{
    workflow_orchestration = 0
    executable_powershell = 0
    executable_python = 0
    pester_test = 0
    strict_json_policy_or_schema = 0
    locked_dependency_manifest = 0
    logical_fixture_spec = 0
    authority_documentation = 0
}
foreach ($path in $changedPaths) {
    $primaryClass = Get-ValidationClass -Path $path
    $classCounts[$primaryClass] = [int]$classCounts[$primaryClass] + 1
    $coverageEntries.Add([ordered]@{
        path = $path
        primary_class = $primaryClass
        secondary_checks = @(Get-SecondaryCheckSet -PrimaryClass $primaryClass)
    })
}

$coverageManifest = [ordered]@{
    authority = 'nxb-v11-a0-validation-coverage-v1'
    schema_version = 1
    allowlist_version = $AllowlistVersion
    allowlist_authority = $AllowlistAuthorityCommentId
    changed_path_set_sha256 = $changedSha
    entries = @($coverageEntries)
}
$coverageSha = Get-CanonicalHash -InputObject $coverageManifest

$treePaths = @(
    Invoke-GitOutput -Arguments @('-c', 'core.quotepath=false', 'ls-tree', '-r', '--name-only', $CandidateSha) -Label 'candidate tree path inventory' |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
)
foreach ($path in $treePaths) {
    Assert-RepositoryPath -Path $path
}
Assert-CaseFoldUniqueSet -Values ([string[]]$treePaths) -Label 'candidate tree path inventory'
$treePathSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($path in $treePaths) {
    [void]$treePathSet.Add([string]$path)
}

$missingPaths = [Collections.Generic.List[string]]::new()
foreach ($path in $exactPathsSorted) {
    if (-not $treePathSet.Contains($path)) {
        $missingPaths.Add($path)
    }
}

$result = [pscustomobject][ordered]@{
    status = 'SOURCE_PREFLIGHT_ONLY'
    admitted = $false
    physical_compatibility_claims = 0
    native_wpt_dispatch_performed = $false
    repository_mutated = $false
    allowlist_version = $AllowlistVersion
    allowlist_authority_comment_id = $AllowlistAuthorityCommentId
    a0_allowlist_exact_path_count = 44
    a0_allowlist_subtree_rule_count = 7
    a0_allowlist_sha256 = $allowlistSha
    a0_changed_path_count = $changedPaths.Count
    a0_changed_path_set_sha256 = $changedSha
    validation_coverage_sha256 = $coverageSha
    validation_class_counts = [pscustomobject]$classCounts
    missing_mandatory_paths = @($missingPaths)
    source_surface_complete = ($missingPaths.Count -eq 0)
    candidate_sha = $CandidateSha
    candidate_tree_sha = $CandidateTree
    predecessor_main_sha = $ExpectedPredecessorSha
    predecessor_tree_sha = $ExpectedPredecessorTree
}

if ($PassThru) {
    $result
}
