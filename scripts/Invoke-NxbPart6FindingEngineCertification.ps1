[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$ExpectedHead,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $RepositoryRoot 'scripts\NxbProductionFinalization.Common.ps1')
$policy = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\nxb-production-finalization-policy.json') -Raw | ConvertFrom-Json
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

$targetId = 'cert-target-loopback'
$sessionId = 'cert-session-part6'
$session = [pscustomobject][ordered]@{
    target_id = $targetId
    session_id = $sessionId
    orchestration_mode = 'bounded-authorized-session'
    scope_authorized = $true
    maximum_findings = [int]$policy.part6.maximum_findings
    evidence_only = $true
    destructive_validation_allowed = $false
}
if (-not [bool]$session.scope_authorized -or [bool]$session.destructive_validation_allowed) {
    throw 'Part 6 target/session orchestration boundary is invalid.'
}

$observations = @(
    [pscustomobject][ordered]@{ target_id=$targetId; session_id=$sessionId; class='authorization'; root_cause_key='scope-check'; evidence_sha256=(Get-NxbFinalSha256Text -Text 'scope-a'); severity_hint='medium' },
    [pscustomobject][ordered]@{ target_id=$targetId; session_id=$sessionId; class='authorization'; root_cause_key='scope-check'; evidence_sha256=(Get-NxbFinalSha256Text -Text 'scope-b'); severity_hint='high' },
    [pscustomobject][ordered]@{ target_id=$targetId; session_id=$sessionId; class='authorization'; root_cause_key='scope-check'; evidence_sha256=(Get-NxbFinalSha256Text -Text 'scope-b'); severity_hint='high' },
    [pscustomobject][ordered]@{ target_id=$targetId; session_id=$sessionId; class='state'; root_cause_key='state-transition'; evidence_sha256=(Get-NxbFinalSha256Text -Text 'state-a'); severity_hint='low' }
)
foreach ($observation in $observations) {
    if ([string]$observation.target_id -cne $targetId -or [string]$observation.session_id -cne $sessionId) {
        throw 'Part 6 observation escaped the authorized target/session boundary.'
    }
}

$findings = @(Invoke-NxbFinalFindingCorrelation -Observation $observations -MaximumFindings ([int]$policy.part6.maximum_findings))
if ($findings.Count -ne 2) { throw ('Part 6 correlation expected 2 findings, got {0}.' -f $findings.Count) }
if (@($findings | Where-Object { $_.severity_promoted }).Count -ne 0) { throw 'Part 6 must not promote severity from hints.' }
$authFinding = @($findings | Where-Object { $_.root_cause_key -ceq 'scope-check' })
if ($authFinding.Count -ne 1 -or [int]$authFinding[0].evidence_count -ne 2) { throw 'Part 6 root-cause correlation or duplicate suppression failed.' }
foreach ($finding in $findings) {
    if ([string]$finding.target_id -cne $targetId -or [string]$finding.session_id -cne $sessionId) {
        throw 'Part 6 finding escaped the authorized target/session boundary.'
    }
}

$repeat = @(Invoke-NxbFinalFindingCorrelation -Observation $observations -MaximumFindings ([int]$policy.part6.maximum_findings))
if ((Get-NxbFinalCanonicalJsonSha256 -InputObject $findings) -cne (Get-NxbFinalCanonicalJsonSha256 -InputObject $repeat)) {
    throw 'Part 6 finding correlation is not deterministic.'
}

$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    contract_id = [string]$policy.part6.contract_id
    head_sha = $ExpectedHead
    target_id = $targetId
    session_id = $sessionId
    orchestration_mode = [string]$session.orchestration_mode
    target_session_binding = $true
    scope_authorized = $true
    evidence_only = $true
    destructive_validation_allowed = $false
    observations_input = $observations.Count
    findings_output = $findings.Count
    duplicate_suppressed = 1
    root_cause_groups = 2
    severity_promoted = $false
    requirements_validated = @($policy.part6.requirements).Count
    findings_sha256 = Get-NxbFinalCanonicalJsonSha256 -InputObject $findings
    findings = $findings
}
$path = Join-Path $OutputDirectory 'part6-finding-engine-receipt.json'
Write-NxbFinalAtomicJson -Path $path -InputObject $receipt

if ($PassThru) {
    return [pscustomobject][ordered]@{
        status = 'passed'
        receipt_path = $path
        receipt_sha256 = Get-NxbFinalFileSha256 -Path $path
        requirements_validated = [int]$receipt.requirements_validated
        findings = $findings.Count
        target_session_binding = $true
    }
}
