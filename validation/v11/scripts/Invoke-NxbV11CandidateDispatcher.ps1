param(
    [Parameter(Mandatory = $true)][string]$RepositoryRoot,
    [Parameter(Mandatory = $true)][ValidateSet('admitted_main', 'candidate')][string]$ExecutionMode,
    [Parameter(Mandatory = $true)][string]$Repository,
    [Parameter(Mandatory = $true)][long]$RepositoryId,
    [Parameter(Mandatory = $true)][string]$WorkflowPath,
    [Parameter(Mandatory = $true)][long]$WorkflowId,
    [Parameter(Mandatory = $true)][string]$AdmittedDispatcherSha,
    [Parameter(Mandatory = $true)][string]$AdmittedDispatcherTree,
    [Parameter(Mandatory = $true)][string]$AdmittedWorkflowBlobSha,
    [Parameter(Mandatory = $true)][string]$HarnessManifestSha256,
    [Parameter(Mandatory = $true)][string]$CandidateSha,
    [Parameter(Mandatory = $true)][string]$CandidateTree,
    [Parameter(Mandatory = $false)][Nullable[long]]$CandidatePr,
    [Parameter(Mandatory = $true)][string]$BaseSha,
    [Parameter(Mandatory = $true)][string]$BaseTree,
    [Parameter(Mandatory = $true)][string]$PolicySha256,
    [Parameter(Mandatory = $true)][string]$CellId,
    [Parameter(Mandatory = $true)][ValidateSet('1h', '6h', '24h')][string]$EnduranceTier,
    [Parameter(Mandatory = $true)][ValidateSet('nxb-native')][string]$RunnerClass,
    [Parameter(Mandatory = $true)][string]$ExpectedIntentSha256,
    [Parameter(Mandatory = $true)][string]$EvidenceStoreModulePath,
    [Parameter(Mandatory = $false)][string]$OutputReceiptPath,
    [Parameter(Mandatory = $false)][Nullable[long]]$RunId,
    [Parameter(Mandatory = $false)][Nullable[long]]$RunAttempt,
    [Parameter(Mandatory = $false)][string]$Event,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'PowerShell 7 required.'
}

$ExpectedRepository = 'Naveax/nxb-integrity-research-lab'
$ExpectedRepositoryId = 1322938859
$ExpectedWorkflowPath = '.github/workflows/nxb-v11-compatibility.yml'
$ExpectedIntentAuthority = 'nxb-v11-compatibility-dispatch-intent-v1'
$ExpectedReceiptAuthority = 'nxb-v11-compatibility-dispatch-intent-receipt-v1'
$ExpectedPolicyAuthority = 'nxb-v11-compatibility-policy-v1'
$ExpectedEvidenceStoreSha256 = '207a3e379e411fa6761f21cf01810135572d87033779ec8f791fa0befcd17cd7'
$Git40Pattern = '^[0-9a-f]{40}$'
$Sha256Pattern = '^[0-9a-f]{64}$'
$CellIdPattern = '^[a-z0-9][a-z0-9._-]{0,127}$'

function Fail {
    param([Parameter(Mandatory = $true)][string]$Message)
    throw $Message
}

function Assert-PositiveInt64 {
    param(
        [Parameter(Mandatory = $true)][long]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value -lt 1) {
        Fail "$Label must be a positive integer."
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

function Assert-Sha256 {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Label
    )
    if ($Value -cnotmatch $Sha256Pattern) {
        Fail "$Label must be lowercase SHA-256."
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

function Test-PathWithinRoot {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root
    )

    $prefix = $Root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)

    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([Convert]::ToHexString($sha.ComputeHash($Bytes))).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Assert-UniqueJsonKeySet {
    param(
        [Parameter(Mandatory = $true)][System.Text.Json.JsonElement]$Element,
        [Parameter(Mandatory = $true)][string]$Label
    )

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add([string]$property.Name)) {
                Fail "$Label contains duplicate JSON key: $($property.Name)"
            }
            Assert-UniqueJsonKeySet -Element $property.Value -Label "$Label.$($property.Name)"
        }
        return
    }

    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        $index = 0
        foreach ($child in $Element.EnumerateArray()) {
            Assert-UniqueJsonKeySet -Element $child -Label "$Label[$index]"
            $index++
        }
    }
}

function Read-StrictJsonHashtable {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and
        $bytes[1] -eq 0xBB -and
        $bytes[2] -eq 0xBF) {
        Fail "$Label must not contain a UTF-8 BOM."
    }

    try {
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $document = [System.Text.Json.JsonDocument]::Parse($text)
    }
    catch {
        Fail "$Label is not strict UTF-8 JSON: $($_.Exception.Message)"
    }

    try {
        if ($document.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            Fail "$Label root must be an object."
        }
        Assert-UniqueJsonKeySet -Element $document.RootElement -Label $Label
    }
    finally {
        $document.Dispose()
    }

    try {
        return ($text | ConvertFrom-Json -AsHashtable -Depth 100)
    }
    catch {
        Fail "$Label cannot be materialized as a hashtable: $($_.Exception.Message)"
    }
}

function Invoke-GitOneLine {
    param(
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $output = @(
        & $script:GitPath -C $script:RepositoryRootFull @Arguments 2>&1 |
            ForEach-Object { [string]$_ }
    )
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Fail "$Label failed: exit=$exitCode output=$($output -join ' | ')"
    }

    $lines = @($output | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -ne 1) {
        Fail "$Label did not return exactly one line."
    }
    return $lines[0].Trim()
}

function Assert-GitCommitTree {
    param(
        [Parameter(Mandatory = $true)][string]$Commit,
        [Parameter(Mandatory = $true)][string]$ExpectedTree,
        [Parameter(Mandatory = $true)][string]$Label
    )

    $treeSpec = $Commit + '^{tree}'
    $actual = Invoke-GitOneLine -Arguments @('rev-parse', $treeSpec) -Label "$Label tree"
    if ($actual -cne $ExpectedTree) {
        Fail "$Label tree mismatch: expected=$ExpectedTree actual=$actual"
    }
}

Assert-PositiveInt64 -Value $RepositoryId -Label 'RepositoryId'
Assert-PositiveInt64 -Value $WorkflowId -Label 'WorkflowId'

if ($Repository -cne $ExpectedRepository) {
    Fail "Repository mismatch: expected=$ExpectedRepository actual=$Repository"
}
if ($RepositoryId -ne $ExpectedRepositoryId) {
    Fail "RepositoryId mismatch: expected=$ExpectedRepositoryId actual=$RepositoryId"
}
if ($WorkflowPath -cne $ExpectedWorkflowPath) {
    Fail "WorkflowPath mismatch: expected=$ExpectedWorkflowPath actual=$WorkflowPath"
}
if ($CellId -cnotmatch $CellIdPattern) {
    Fail 'CellId syntax invalid.'
}

foreach ($pair in @(
    @($AdmittedDispatcherSha, 'AdmittedDispatcherSha'),
    @($AdmittedDispatcherTree, 'AdmittedDispatcherTree'),
    @($AdmittedWorkflowBlobSha, 'AdmittedWorkflowBlobSha'),
    @($CandidateSha, 'CandidateSha'),
    @($CandidateTree, 'CandidateTree'),
    @($BaseSha, 'BaseSha'),
    @($BaseTree, 'BaseTree')
)) {
    Assert-Git40 -Value ([string]$pair[0]) -Label ([string]$pair[1])
}

foreach ($pair in @(
    @($HarnessManifestSha256, 'HarnessManifestSha256'),
    @($PolicySha256, 'PolicySha256'),
    @($ExpectedIntentSha256, 'ExpectedIntentSha256')
)) {
    Assert-Sha256 -Value ([string]$pair[0]) -Label ([string]$pair[1])
}

if ($ExecutionMode -ceq 'admitted_main') {
    if ($null -ne $CandidatePr) {
        Fail 'CandidatePr must be null in admitted_main mode.'
    }
    if ($CandidateSha -cne $AdmittedDispatcherSha -or
        $CandidateTree -cne $AdmittedDispatcherTree) {
        Fail 'admitted_main candidate identity must equal admitted dispatcher identity.'
    }
}
else {
    if ($null -eq $CandidatePr) {
        Fail 'CandidatePr is required in candidate mode.'
    }
    Assert-PositiveInt64 -Value ([long]$CandidatePr) -Label 'CandidatePr'
}

$script:RepositoryRootFull = Assert-OrdinaryDirectory -Path $RepositoryRoot -Label 'RepositoryRoot'
$modulePath = Assert-OrdinaryFile -Path $EvidenceStoreModulePath -Label 'EvidenceStoreModulePath'

$expectedModulePath = [IO.Path]::GetFullPath(
    (Join-Path $script:RepositoryRootFull 'scripts\Nxb.EvidenceStore.psm1')
)
if (-not $modulePath.Equals($expectedModulePath, [StringComparison]::OrdinalIgnoreCase)) {
    Fail "EvidenceStoreModulePath is not the exact shared module in the trusted checkout: $modulePath"
}
$moduleSha = (Get-FileHash -LiteralPath $modulePath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($moduleSha -cne $ExpectedEvidenceStoreSha256) {
    Fail "EvidenceStore module SHA-256 drift: expected=$ExpectedEvidenceStoreSha256 actual=$moduleSha"
}

$gitCommand = Get-Command -Name git -CommandType Application -ErrorAction Stop
$script:GitPath = [string]$gitCommand.Source
if ([string]::IsNullOrWhiteSpace($script:GitPath)) {
    Fail 'git executable could not be resolved.'
}

$inside = Invoke-GitOneLine -Arguments @('rev-parse', '--is-inside-work-tree') -Label 'git worktree check'
if ($inside -cne 'true') {
    Fail 'RepositoryRoot is not a Git worktree.'
}

$currentHead = Invoke-GitOneLine -Arguments @('rev-parse', 'HEAD') -Label 'current HEAD'
$currentTree = Invoke-GitOneLine -Arguments @('rev-parse', 'HEAD^{tree}') -Label 'current tree'
if ($currentHead -cne $AdmittedDispatcherSha) {
    Fail "trusted checkout HEAD mismatch: expected=$AdmittedDispatcherSha actual=$currentHead"
}
if ($currentTree -cne $AdmittedDispatcherTree) {
    Fail "trusted checkout tree mismatch: expected=$AdmittedDispatcherTree actual=$currentTree"
}

$statusOutput = @(
    & $script:GitPath -C $script:RepositoryRootFull status --porcelain=v1 --untracked-files=all 2>&1 |
        ForEach-Object { [string]$_ }
)
if ($LASTEXITCODE -ne 0) {
    Fail "git status failed: $($statusOutput -join ' | ')"
}
if (@($statusOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -ne 0) {
    Fail 'trusted dispatcher worktree must be clean.'
}

Assert-GitCommitTree -Commit $AdmittedDispatcherSha -ExpectedTree $AdmittedDispatcherTree -Label 'dispatcher'
Assert-GitCommitTree -Commit $CandidateSha -ExpectedTree $CandidateTree -Label 'candidate'
Assert-GitCommitTree -Commit $BaseSha -ExpectedTree $BaseTree -Label 'base'

$workflowSpec = $AdmittedDispatcherSha + ':' + $WorkflowPath
$workflowBlob = Invoke-GitOneLine -Arguments @('rev-parse', $workflowSpec) -Label 'dispatcher workflow blob'
$workflowType = Invoke-GitOneLine -Arguments @('cat-file', '-t', $workflowBlob) -Label 'dispatcher workflow object type'
if ($workflowType -cne 'blob') {
    Fail 'dispatcher workflow object is not a blob.'
}
if ($workflowBlob -cne $AdmittedWorkflowBlobSha) {
    Fail "dispatcher workflow blob mismatch: expected=$AdmittedWorkflowBlobSha actual=$workflowBlob"
}

$policyPath = [IO.Path]::GetFullPath(
    (Join-Path $script:RepositoryRootFull 'config\nxb-v11-compatibility-policy.json')
)
$policyFile = Assert-OrdinaryFile -Path $policyPath -Label 'compatibility policy'
$policy = Read-StrictJsonHashtable -Path $policyFile -Label 'compatibility policy'

if (-not $policy.ContainsKey('authority') -or
    [string]$policy['authority'] -cne $ExpectedPolicyAuthority) {
    Fail 'compatibility policy authority mismatch.'
}
if (-not $policy.ContainsKey('schema_version') -or
    [long]$policy['schema_version'] -ne 1) {
    Fail 'compatibility policy schema_version mismatch.'
}
if ($policy.ContainsKey('policy_sha256') -or
    $policy.ContainsKey('compatibility_policy_sha256')) {
    Fail 'compatibility policy source contains a forbidden self-digest field.'
}
if (-not $policy.ContainsKey('cells')) {
    Fail 'compatibility policy cells are missing.'
}

$selectedCells = @(
    @($policy['cells']) |
        Where-Object {
            $_ -is [System.Collections.IDictionary] -and
            $_.Contains('id') -and
            [string]($_['id']) -ceq $CellId
        }
)
if ($selectedCells.Count -ne 1) {
    Fail "compatibility policy must contain CellId exactly once: $CellId"
}
$selectedCell = $selectedCells[0]
if (-not $selectedCell.Contains('status') -or
    [string]$selectedCell['status'] -cne 'enabled') {
    Fail "compatibility policy CellId is not enabled: $CellId"
}

Import-Module -Name $modulePath -Force -ErrorAction Stop
$canonicalCommand = Get-Command -Name 'ConvertTo-NxbCanonicalJson' -CommandType Function -ErrorAction Stop
if (-not ([string]$canonicalCommand.Module.Path).Equals(
    $modulePath,
    [StringComparison]::OrdinalIgnoreCase
)) {
    Fail "ConvertTo-NxbCanonicalJson resolved from unexpected module: $($canonicalCommand.Module.Path)"
}

$canonicalPolicy = ConvertTo-NxbCanonicalJson -InputObject $policy
$canonicalPolicyBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($canonicalPolicy)
$observedPolicySha = Get-Sha256Hex -Bytes $canonicalPolicyBytes
if ($observedPolicySha -cne $PolicySha256) {
    Fail "compatibility policy SHA-256 mismatch: expected=$PolicySha256 actual=$observedPolicySha"
}

$candidatePrValue = if ($null -ne $CandidatePr) {
    [long]$CandidatePr
}
else {
    $null
}

$intent = [ordered]@{
    authority = $ExpectedIntentAuthority
    execution_mode = $ExecutionMode
    repository = $Repository
    repository_id = [long]$RepositoryId
    workflow_path = $WorkflowPath
    workflow_id = [long]$WorkflowId
    admitted_dispatcher_sha = $AdmittedDispatcherSha
    admitted_dispatcher_tree = $AdmittedDispatcherTree
    admitted_workflow_blob_sha = $AdmittedWorkflowBlobSha
    harness_manifest_sha256 = $HarnessManifestSha256
    candidate_sha = $CandidateSha
    candidate_tree = $CandidateTree
    candidate_pr = $candidatePrValue
    base_sha = $BaseSha
    base_tree = $BaseTree
    policy_sha256 = $PolicySha256
    cell_id = $CellId
    endurance_tier = $EnduranceTier
    runner_class = $RunnerClass
}

$canonicalIntent = ConvertTo-NxbCanonicalJson -InputObject $intent
$canonicalIntentBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($canonicalIntent)
$intentSha = Get-Sha256Hex -Bytes $canonicalIntentBytes
if ($intentSha -cne $ExpectedIntentSha256) {
    Fail "intent SHA-256 mismatch: expected=$ExpectedIntentSha256 actual=$intentSha"
}

$receiptWritten = $false
if (-not [string]::IsNullOrWhiteSpace($OutputReceiptPath)) {
    if ($null -eq $RunId -or $null -eq $RunAttempt) {
        Fail 'RunId and RunAttempt are required when OutputReceiptPath is supplied.'
    }
    Assert-PositiveInt64 -Value ([long]$RunId) -Label 'RunId'
    Assert-PositiveInt64 -Value ([long]$RunAttempt) -Label 'RunAttempt'
    if ($Event -cne 'workflow_dispatch') {
        Fail 'Event must be workflow_dispatch when writing a dispatch-intent receipt.'
    }

    $output = Get-NormalizedAbsolutePath -Path $OutputReceiptPath -Label 'OutputReceiptPath'
    if (Test-PathWithinRoot -Path $output -Root $script:RepositoryRootFull) {
        Fail 'OutputReceiptPath must be outside the trusted repository worktree.'
    }
    if (Test-Path -LiteralPath $output) {
        Fail "OutputReceiptPath already exists: $output"
    }
    [void](Assert-OrdinaryDirectory -Path (Split-Path -Parent $output) -Label 'receipt parent')

    $receipt = [ordered]@{
        authority = $ExpectedReceiptAuthority
        schema_version = 1
        status = 'passed'
        execution_mode = $ExecutionMode
        repository = $Repository
        repository_id = [long]$RepositoryId
        workflow_path = $WorkflowPath
        workflow_id = [long]$WorkflowId
        admitted_dispatcher_sha = $AdmittedDispatcherSha
        admitted_dispatcher_tree = $AdmittedDispatcherTree
        admitted_workflow_blob_sha = $AdmittedWorkflowBlobSha
        harness_manifest_sha256 = $HarnessManifestSha256
        candidate_sha = $CandidateSha
        candidate_tree = $CandidateTree
        candidate_pr = $candidatePrValue
        base_sha = $BaseSha
        base_tree = $BaseTree
        policy_sha256 = $PolicySha256
        cell_id = $CellId
        endurance_tier = $EnduranceTier
        runner_class = $RunnerClass
        intent_sha256 = $intentSha
        run_id = [long]$RunId
        run_attempt = [long]$RunAttempt
        event = $Event
        intent_recomputed_valid = $true
        repository_mutated = $false
        dispatch_performed_by_this_script = $false
    }

    $canonicalReceipt = ConvertTo-NxbCanonicalJson -InputObject $receipt
    $receiptBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($canonicalReceipt)

    $stream = [IO.File]::Open(
        $output,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $stream.Write($receiptBytes, 0, $receiptBytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    $receiptWritten = $true
}

$result = [pscustomobject][ordered]@{
    status = 'passed'
    authority = $ExpectedIntentAuthority
    execution_mode = $ExecutionMode
    intent_sha256 = $intentSha
    candidate_sha = $CandidateSha
    candidate_tree = $CandidateTree
    policy_sha256 = $PolicySha256
    cell_id = $CellId
    endurance_tier = $EnduranceTier
    runner_class = $RunnerClass
    receipt_written = $receiptWritten
    repository_mutated = $false
    dispatch_performed_by_this_script = $false
}

if ($PassThru) {
    $result
}
