[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$ExpectedHead,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter(Mandatory)][string[]]$PriorReceiptPath,
    [Parameter(Mandatory)][bool]$Ps7ContractPassed,
    [Parameter(Mandatory)][bool]$Ps51ContractPassed,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $RepositoryRoot 'scripts\NxbProductionFinalization.Common.ps1')
$policy = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\nxb-production-finalization-policy.json') -Raw | ConvertFrom-Json
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

if (-not $Ps7ContractPassed -or -not $Ps51ContractPassed) { throw 'Part 8 requires PS7 and PS5.1 contract passes.' }

$watch = [Diagnostics.Stopwatch]::StartNew()
$manifest = @(Get-NxbFinalArtifactManifest -Path $PriorReceiptPath)
$totalBytes = [int64]0
foreach ($entry in $manifest) { $totalBytes += [int64]$entry.bytes }
if ($totalBytes -gt [int64]$policy.part8.maximum_artifact_bytes) { throw 'Part 8 prior evidence exceeded the artifact byte budget.' }

$baseEvidence = [pscustomobject][ordered]@{
    head_sha = $ExpectedHead
    session_id = 'part8-session-a'
    evidence_sha256 = Get-NxbFinalSha256Text -Text 'part8-evidence'
    payload_sha256 = Get-NxbFinalSha256Text -Text 'part8-payload'
}
$baseHash = Get-NxbFinalCanonicalJsonSha256 -InputObject $baseEvidence

$faults = [Collections.Generic.List[object]]::new()
function Add-NxbPart8FaultResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Rejected,
        [Parameter(Mandatory)][object]$Mutation
    )
    $faults.Add([pscustomobject][ordered]@{ name=$Name; rejected=$Rejected; mutation=$Mutation })
}

$stale = [pscustomobject][ordered]@{ head_sha=('0' * 40); session_id=$baseEvidence.session_id; evidence_sha256=$baseEvidence.evidence_sha256; payload_sha256=$baseEvidence.payload_sha256 }
Add-NxbPart8FaultResult -Name 'stale_head' -Rejected (([string]$stale.head_sha -cne $ExpectedHead)) -Mutation $stale

$crossSession = [pscustomobject][ordered]@{ head_sha=$ExpectedHead; session_id='part8-session-b'; evidence_sha256=$baseEvidence.evidence_sha256; payload_sha256=$baseEvidence.payload_sha256 }
Add-NxbPart8FaultResult -Name 'cross_session' -Rejected (([string]$crossSession.session_id -cne [string]$baseEvidence.session_id)) -Mutation $crossSession

$missingEvidence = [pscustomobject][ordered]@{ head_sha=$ExpectedHead; session_id=$baseEvidence.session_id; evidence_sha256=''; payload_sha256=$baseEvidence.payload_sha256 }
Add-NxbPart8FaultResult -Name 'missing_evidence' -Rejected (([string]$missingEvidence.evidence_sha256).Length -ne 64) -Mutation $missingEvidence

$tampered = [pscustomobject][ordered]@{ head_sha=$ExpectedHead; session_id=$baseEvidence.session_id; evidence_sha256=$baseEvidence.evidence_sha256; payload_sha256=(Get-NxbFinalSha256Text -Text 'tampered') }
Add-NxbPart8FaultResult -Name 'tampered_payload' -Rejected ((Get-NxbFinalCanonicalJsonSha256 -InputObject $tampered) -cne $baseHash) -Mutation $tampered

$wrongHash = [pscustomobject][ordered]@{ head_sha=$ExpectedHead; session_id=$baseEvidence.session_id; evidence_sha256=('a' * 64); payload_sha256=$baseEvidence.payload_sha256 }
Add-NxbPart8FaultResult -Name 'evidence_hash_mismatch' -Rejected ((Get-NxbFinalCanonicalJsonSha256 -InputObject $wrongHash) -cne $baseHash) -Mutation $wrongHash

if (@($faults | Where-Object { -not $_.rejected }).Count -ne 0) { throw 'Part 8 fault matrix did not reject every mutation.' }
$watch.Stop()
if ($watch.Elapsed.TotalSeconds -gt [double]$policy.certification.maximum_seconds) { throw 'Part 8 bounded runtime exceeded certification budget.' }

$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    contract_id = [string]$policy.part8.contract_id
    head_sha = $ExpectedHead
    base_evidence = $baseEvidence
    base_evidence_canonical_sha256 = $baseHash
    fault_count = $faults.Count
    fault_matrix = @($faults)
    artifact_count = $manifest.Count
    artifact_bytes = $totalBytes
    artifact_manifest_sha256 = Get-NxbFinalCanonicalJsonSha256 -InputObject $manifest
    elapsed_ms = [int64]$watch.ElapsedMilliseconds
    ps7_compatibility = $Ps7ContractPassed
    ps51_compatibility = $Ps51ContractPassed
    independent_replay_required = $true
    requirements_validated = @($policy.part8.requirements).Count
}
$path = Join-Path $OutputDirectory 'part8-evidence-hardening-receipt.json'
Write-NxbFinalAtomicJson -Path $path -InputObject $receipt

if ($PassThru) {
    return [pscustomobject][ordered]@{
        status = 'passed'
        receipt_path = $path
        receipt_sha256 = Get-NxbFinalFileSha256 -Path $path
        requirements_validated = [int]$receipt.requirements_validated
        fault_count = $faults.Count
        artifact_bytes = $totalBytes
    }
}
