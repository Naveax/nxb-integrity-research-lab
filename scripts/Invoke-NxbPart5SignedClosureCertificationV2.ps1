[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') { throw 'Part 5 V2 signed closure certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Part 5 V2 signed closure certification requires PowerShell 7.' }

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Part 5 V2 requires elevated PowerShell 7 because inherited Part 2 native authority is mandatory.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw ('Part 5 V2 exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead)
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Part 5 V2 requires a clean exact-head worktree.' }

$childPath = Join-Path $PSScriptRoot 'Invoke-NxbPart5SignedClosureCertification.ps1'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$signaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$pnpPath = Join-Path $PSScriptRoot 'Invoke-NxbSemanticPnpEventExperiment.ps1'
foreach ($requiredPath in @($childPath,$scannerPath,$signaturePath,$pnpPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw ('Part 5 V2 component missing: {0}' -f $requiredPath)
    }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-006 PART 2 + PART 3 + PART 4 + PART 5 SIGNED CLOSURE CERTIFICATION V2 ==='
Write-Information -InformationAction Continue -MessageData '[top 1/3] ERR-030 exact-tree gate + wrapper analyzer'

Import-Module PSScriptAnalyzer -ErrorAction Stop
$selfFinding = @(Invoke-ScriptAnalyzer -Path $PSCommandPath -Severity Warning,Error)
if ($selfFinding.Count -gt 0) {
    $detail = @($selfFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join [Environment]::NewLine
    throw ('Part 5 V2 PSScriptAnalyzer findings: {0}{1}{2}' -f $selfFinding.Count,[Environment]::NewLine,$detail)
}

$scan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -NoThrow -PassThru
if ([string]$scan.status -cne 'passed' -or [int]$scan.finding_count -ne 0 -or [int]$scan.rule_count -lt 19) {
    $detail = @($scan.findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
    throw ('Part 5 V2 known-error preflight failed: rules={0} findings={1}{2}{3}' -f [int]$scan.rule_count,[int]$scan.finding_count,[Environment]::NewLine,$detail)
}

$pnpSource = Get-Content -LiteralPath $pnpPath -Raw
if ($pnpSource.IndexOf('[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Record',[StringComparison]::Ordinal) -lt 0) {
    throw 'ERR-030 repair missing: PnP Record collection does not explicitly allow empty input.'
}
if ($pnpSource.IndexOf('if ($Record.Count -eq 0) { return @() }',[StringComparison]::Ordinal) -lt 0) {
    throw 'ERR-030 repair missing: PnP shaper does not explicitly preserve zero-cardinality evidence.'
}
if ($pnpSource.IndexOf('[Parameter(Mandatory)][object[]]$Record',[StringComparison]::Ordinal) -ge 0) {
    throw 'ERR-030 regression: mandatory PnP Record collection rejects valid empty evidence.'
}

Write-Information -InformationAction Continue -MessageData ('Part 5 V2 preflight passed: rules={0} findings=0 ERR-030=true.' -f [int]$scan.rule_count)
Write-Information -InformationAction Continue -MessageData '[top 2/3] Run complete Part 5 signed closure child authority'

$pipeline = @(& $childPath -ExpectedHead $ExpectedHead -OutputDirectory $OutputDirectory -PassThru)
$result = $null
foreach ($item in $pipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $result = $item }
}
if ($null -eq $result) { throw 'Part 5 V2 child authority returned no passed result.' }
if ([string]$result.head_sha -cne $currentHead) { throw 'Part 5 V2 child exact-head binding mismatch.' }
if ([int]$result.known_error_rule_count -lt 19 -or [int]$result.known_error_finding_count -ne 0) {
    throw ('Part 5 V2 child known-error closure failed: rules={0} findings={1}' -f [int]$result.known_error_rule_count,[int]$result.known_error_finding_count)
}

Write-Information -InformationAction Continue -MessageData '[top 3/3] Bind ERR-030 repair into final Part 2+3+4+5 result'
Write-Information -InformationAction Continue -MessageData ('NXB Part 5 V2 passed: head={0} known_errors=0 rules={1} ERR-030=true.' -f $currentHead,[int]$result.known_error_rule_count)
if ($PassThru) { return $result }
Write-Output ([string]$result.review_zip_path)
