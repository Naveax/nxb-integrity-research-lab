[CmdletBinding()]
param(
    [Parameter()][string]$RepositoryRoot,
    [Parameter()][string]$PolicyPath,
    [Parameter()][string]$MainRef = 'main',
    [Parameter()][string]$OutputPath,
    [Parameter()][switch]$PassThru,
    [Parameter()][switch]$NoThrow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-NxbV1Native {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$ArgumentList
    )

    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativePreferenceAvailable = ($null -ne $nativePreferenceVariable)
    $previousNativePreference = if ($nativePreferenceAvailable) { [bool]$nativePreferenceVariable.Value } else { $null }

    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceAvailable) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local
        }
        $nativeOutput = @(& $Executable @ArgumentList 2>&1)
        $nativeExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceAvailable) {
            Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local
        }
    }

    return [pscustomobject][ordered]@{
        exit_code = $nativeExitCode
        output = (@($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        lines = @($nativeOutput | ForEach-Object { [string]$_ })
    }
}

function Test-NxbV1LowerHex {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][int]$Length
    )
    return ($Text.Length -eq $Length -and $Text -cmatch '^[0-9a-f]+$')
}

function Test-NxbV1AllowedSuccessorPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$AllowedPrefixes
    )

    $normalized = $Path.Replace('\','/')
    foreach ($prefixObject in @($AllowedPrefixes)) {
        $prefix = [string]$prefixObject
        if (-not [string]::IsNullOrWhiteSpace($prefix) -and $normalized.StartsWith($prefix,[StringComparison]::Ordinal)) {
            return $true
        }
    }
    return $false
}

if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
    $RepositoryRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
}
$RepositoryRoot = [IO.Path]::GetFullPath($RepositoryRoot)
if ([string]::IsNullOrWhiteSpace($PolicyPath)) {
    $PolicyPath = Join-Path $RepositoryRoot 'config\nxb-v1-release-integration-policy.json'
}
$PolicyPath = [IO.Path]::GetFullPath($PolicyPath)

$failures = [Collections.Generic.List[string]]::new()
$changedPaths = [Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath $PolicyPath -PathType Leaf)) {
    throw ('Release integration policy missing: {0}' -f $PolicyPath)
}
$policy = Get-Content -LiteralPath $PolicyPath -Raw | ConvertFrom-Json

$certifiedHead = [string]$policy.certified_implementation_head
$certifiedMainAncestor = [string]$policy.certified_main_ancestor
if (-not (Test-NxbV1LowerHex -Text $certifiedHead -Length 40)) { throw 'certified_implementation_head must be 40 lowercase hex.' }
if (-not (Test-NxbV1LowerHex -Text $certifiedMainAncestor -Length 40)) { throw 'certified_main_ancestor must be 40 lowercase hex.' }
if ([string]$policy.candidate_version -cne '1.0.1-candidate') { throw 'candidate_version contract drift.' }
if ([string]$policy.target_version -cne '1.0.1') { throw 'target_version contract drift.' }

$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction Stop }
$git = [string]$gitCommand.Source

$releaseHeadRun = Invoke-NxbV1Native -Executable $git -ArgumentList @('-C',$RepositoryRoot,'rev-parse','HEAD')
if ($releaseHeadRun.exit_code -ne 0) { throw ('Unable to resolve release HEAD: {0}' -f $releaseHeadRun.output) }
$releaseHead = $releaseHeadRun.output.Trim().ToLowerInvariant()
if (-not (Test-NxbV1LowerHex -Text $releaseHead -Length 40)) { throw 'Release HEAD is not 40 lowercase hex.' }

$mainHead = $null
foreach ($candidateRef in @($MainRef,('refs/heads/{0}' -f $MainRef),('refs/remotes/origin/{0}' -f $MainRef))) {
    $resolveMain = Invoke-NxbV1Native -Executable $git -ArgumentList @('-C',$RepositoryRoot,'rev-parse','--verify',('{0}^{{commit}}' -f $candidateRef))
    if ($resolveMain.exit_code -eq 0) {
        $candidateHead = $resolveMain.output.Trim().ToLowerInvariant()
        if (Test-NxbV1LowerHex -Text $candidateHead -Length 40) {
            $mainHead = $candidateHead
            break
        }
    }
}
if ($null -eq $mainHead) {
    $failures.Add('main_ref_unavailable')
    $mainHead = '0000000000000000000000000000000000000000'
}

$statusRun = Invoke-NxbV1Native -Executable $git -ArgumentList @('-C',$RepositoryRoot,'status','--porcelain=v1','--untracked-files=all')
$cleanWorktree = ($statusRun.exit_code -eq 0 -and @($statusRun.lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -eq 0)
if (-not $cleanWorktree) { $failures.Add('dirty_worktree') }

$certifiedAncestorRun = Invoke-NxbV1Native -Executable $git -ArgumentList @('-C',$RepositoryRoot,'merge-base','--is-ancestor',$certifiedHead,$releaseHead)
$certifiedHeadAncestor = ($certifiedAncestorRun.exit_code -eq 0)
if (-not $certifiedHeadAncestor) { $failures.Add('certified_head_not_ancestor') }

$mainHeadAncestor = $false
if ($mainHead -cne '0000000000000000000000000000000000000000') {
    $mainAncestorRun = Invoke-NxbV1Native -Executable $git -ArgumentList @('-C',$RepositoryRoot,'merge-base','--is-ancestor',$mainHead,$releaseHead)
    $mainHeadAncestor = ($mainAncestorRun.exit_code -eq 0)
}
if (-not $mainHeadAncestor) { $failures.Add('main_head_not_ancestor') }

$certifiedMainRun = Invoke-NxbV1Native -Executable $git -ArgumentList @('-C',$RepositoryRoot,'merge-base','--is-ancestor',$certifiedMainAncestor,$certifiedHead)
if ($certifiedMainRun.exit_code -ne 0) { $failures.Add('certified_main_ancestor_binding_failed') }

$diffRun = Invoke-NxbV1Native -Executable $git -ArgumentList @('-C',$RepositoryRoot,'diff','--name-only','--diff-filter=ACMRTUXB',('{0}...{1}' -f $certifiedHead,$releaseHead))
if ($diffRun.exit_code -ne 0) { throw ('Unable to enumerate release successor paths: {0}' -f $diffRun.output) }
foreach ($pathLine in @($diffRun.lines)) {
    $pathText = $pathLine.Trim().Replace('\','/')
    if (-not [string]::IsNullOrWhiteSpace($pathText)) { $changedPaths.Add($pathText) }
}

$allowedSuccessorPaths = $true
foreach ($changedPath in @($changedPaths)) {
    if (-not (Test-NxbV1AllowedSuccessorPath -Path $changedPath -AllowedPrefixes @($policy.integration.allowed_successor_paths))) {
        $allowedSuccessorPaths = $false
        $failures.Add(('certified_runtime_modified:{0}' -f $changedPath))
    }
}
$certifiedRuntimeUnchanged = $allowedSuccessorPaths

$generatedArtifactsAbsent = $true
foreach ($changedPath in @($changedPaths)) {
    $lowerPath = $changedPath.ToLowerInvariant()
    foreach ($suffixObject in @($policy.integration.forbidden_artifact_suffixes)) {
        $suffix = ([string]$suffixObject).ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($suffix) -and $lowerPath.EndsWith($suffix,[StringComparison]::Ordinal)) {
            $generatedArtifactsAbsent = $false
            $failures.Add(('forbidden_release_artifact:{0}' -f $changedPath))
        }
    }
}

$privateKeyMarkerMap = @{
    pkcs8 = ('-----BEGIN ' + 'PRIVATE KEY-----')
    rsa = ('-----BEGIN RSA ' + 'PRIVATE KEY-----')
    ec = ('-----BEGIN EC ' + 'PRIVATE KEY-----')
    openssh = ('-----BEGIN OPENSSH ' + 'PRIVATE KEY-----')
}
$privateKeyMaterialAbsent = $true
foreach ($markerIdObject in @($policy.integration.forbidden_private_key_marker_ids)) {
    $markerId = [string]$markerIdObject
    if ([string]::IsNullOrWhiteSpace($markerId) -or -not $privateKeyMarkerMap.ContainsKey($markerId)) {
        $privateKeyMaterialAbsent = $false
        $failures.Add(('private_key_marker_id_unknown:{0}' -f $markerId))
        continue
    }
    $marker = [string]$privateKeyMarkerMap[$markerId]
    $grepRun = Invoke-NxbV1Native -Executable $git -ArgumentList @('-C',$RepositoryRoot,'grep','-I','-l','-F','--',$marker,'HEAD')
    if ($grepRun.exit_code -eq 0) {
        $privateKeyMaterialAbsent = $false
        foreach ($matchedPath in @($grepRun.lines | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $failures.Add(('private_key_material:{0}' -f $matchedPath.Trim()))
        }
    }
    elseif ($grepRun.exit_code -ne 1) {
        $privateKeyMaterialAbsent = $false
        $failures.Add('private_key_scan_failed')
    }
}

$productionSignerSeparated = (
    [bool]$policy.signing.production_signer_required_for_release -and
    -not [bool]$policy.signing.certification_signer_reuse_allowed -and
    -not [bool]$policy.signing.private_key_in_repository_allowed -and
    [bool]$policy.signing.key_rotation_policy_required -and
    [bool]$policy.signing.revocation_policy_required
)
if (-not $productionSignerSeparated) { $failures.Add('production_signer_boundary_failed') }

$candidatePolicyPath = Join-Path $RepositoryRoot 'config\nxb-production-finalization-policy.json'
$candidateVersionPreserved = $false
if (Test-Path -LiteralPath $candidatePolicyPath -PathType Leaf) {
    $candidatePolicy = Get-Content -LiteralPath $candidatePolicyPath -Raw | ConvertFrom-Json
    $candidateVersionPreserved = ([string]$candidatePolicy.part10.release_version -ceq '1.0.0-candidate')
}
if (-not $candidateVersionPreserved) { $failures.Add('certified_candidate_version_rewritten') }

$uniqueFailures = @($failures | Sort-Object -Unique)
$uniqueChangedPaths = @($changedPaths | Sort-Object -Unique)
$status = if ($uniqueFailures.Count -eq 0) { 'passed' } else { 'failed' }

$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = $status
    authority = 'nxb-v1-release-integration-preflight-v1'
    certified_implementation_head = $certifiedHead
    release_head = $releaseHead
    main_head = $mainHead
    candidate_version = [string]$policy.candidate_version
    target_version = [string]$policy.target_version
    checks = [pscustomobject][ordered]@{
        clean_worktree = $cleanWorktree
        certified_head_ancestor = $certifiedHeadAncestor
        main_head_ancestor = $mainHeadAncestor
        certified_runtime_unchanged = $certifiedRuntimeUnchanged
        successor_paths_allowed = $allowedSuccessorPaths
        generated_artifacts_absent = $generatedArtifactsAbsent
        private_key_material_absent = $privateKeyMaterialAbsent
        production_signer_separated = $productionSignerSeparated
        candidate_version_preserved = $candidateVersionPreserved
    }
    changed_paths = $uniqueChangedPaths
    failure_count = $uniqueFailures.Count
    failures = $uniqueFailures
    created_utc = [DateTime]::UtcNow.ToString('o')
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    $outputParent = Split-Path -Parent $outputFull
    if (-not [string]::IsNullOrWhiteSpace($outputParent)) { [IO.Directory]::CreateDirectory($outputParent) | Out-Null }
    $json = ($receipt | ConvertTo-Json -Depth 8) + [Environment]::NewLine
    [IO.File]::WriteAllText($outputFull,$json,[Text.UTF8Encoding]::new($false))
}

if ($PassThru) { $receipt }
if ($status -cne 'passed' -and -not $NoThrow) {
    throw ('NXB v1 release integration preflight failed: {0}' -f ($uniqueFailures -join ', '))
}
if (-not $PassThru) {
    Write-Information ('NXB v1 release integration preflight {0}: release_head={1} main_head={2} changed_paths={3} failures={4}' -f $status,$releaseHead,$mainHead,$uniqueChangedPaths.Count,$uniqueFailures.Count)
}
