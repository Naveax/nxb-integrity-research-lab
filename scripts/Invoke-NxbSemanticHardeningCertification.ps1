[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbSemanticPart2Administrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NxbSemanticPart2Sha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Get-NxbSemanticPart2CanonicalMaterial {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Receipt)
    $scopeHash = Get-NxbSemanticPart2Sha256Text -Text ([string]$Receipt.capture.scope)
    $limitationArray = @($Receipt.validation.limitations | ForEach-Object { [string]$_ })
    $limitationHash = Get-NxbSemanticPart2Sha256Text -Text ($limitationArray -join "`n")
    $negativeText = ([bool]$Receipt.validation.negative_controls_passed).ToString().ToLowerInvariant()
    $cleanupText = ([bool]$Receipt.validation.cleanup_verified).ToString().ToLowerInvariant()
    $independentText = ([bool]$Receipt.validation.independent_validation_passed).ToString().ToLowerInvariant()
    return (@(
        'schema=1',
        ('receipt_id={0}' -f [string]$Receipt.receipt_id),
        ('claim_name={0}' -f [string]$Receipt.claim_name),
        ('status={0}' -f [string]$Receipt.status),
        ('repository={0}' -f [string]$Receipt.authority.repository),
        ('exact_head={0}' -f [string]$Receipt.authority.exact_head),
        ('policy_sha256={0}' -f [string]$Receipt.authority.policy_sha256),
        ('machine_id_sha256={0}' -f [string]$Receipt.machine.machine_id_sha256),
        ('scope_sha256={0}' -f $scopeHash),
        ('source_kind={0}' -f [string]$Receipt.capture.source_kind),
        ('bounded_session_seconds={0}' -f [int64]$Receipt.capture.bounded_session_seconds),
        ('artifact_count={0}' -f [int64]$Receipt.evidence.artifact_count),
        ('artifact_index_sha256={0}' -f [string]$Receipt.evidence.artifact_index_sha256),
        ('negative_controls_passed={0}' -f $negativeText),
        ('cleanup_verified={0}' -f $cleanupText),
        ('independent_validation_passed={0}' -f $independentText),
        ('validator_name={0}' -f [string]$Receipt.validation.validator_name),
        ('validator_version={0}' -f [string]$Receipt.validation.validator_version),
        ('validator_implementation_sha256={0}' -f [string]$Receipt.validation.validator_implementation_sha256),
        ('limitations_sha256={0}' -f $limitationHash)
    ) -join "`n")
}

function Write-NxbSemanticPart2Json {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($fullPath,(($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

function Invoke-NxbSemanticPart2Native {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string[]]$ArgumentList)
    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativePreferenceAvailable = ($null -ne $nativePreferenceVariable)
    $previousNativePreference = if ($nativePreferenceAvailable) { [bool]$nativePreferenceVariable.Value } else { $null }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local }
        $output = @(& $Executable @ArgumentList 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local }
    }
    return [pscustomobject][ordered]@{ exit_code=$exitCode; output=($output | ForEach-Object { [string]$_ }) -join "`n" }
}

function Invoke-NxbSemanticPart2Pester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-semantic-part2-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $runnerPath = Join-Path $tempRoot 'run.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
$ErrorActionPreference = 'Stop'
Import-Module Pester -ErrorAction Stop
$result = Invoke-Pester -Path $TestPath -PassThru
$summary = [pscustomobject]@{ passed=[int]$result.PassedCount; failed=[int]$result.FailedCount; skipped=[int]$result.SkippedCount; total=[int]$result.TotalCount }
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($summary.passed -ne $ExpectedCount -or $summary.total -ne $ExpectedCount -or $summary.failed -ne 0 -or $summary.skipped -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $runnerPath -Encoding UTF8
    try {
        $native = Invoke-NxbSemanticPart2Native -Executable $Executable -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,'-TestPath',$TestPath,'-ResultPath',$resultPath,'-ExpectedCount',[string]$ExpectedCount)
        if ($native.exit_code -ne 0) { throw ('{0} Pester failed: exit={1}`n{2}' -f $Label,$native.exit_code,$native.output) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force } }
}

function New-NxbSemanticPart2ReceiptDocument {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ClaimName,
        [Parameter(Mandatory)][string]$SourceKind,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$StartedUtc,
        [Parameter(Mandatory)][string]$EndedUtc,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$IndexPath,
        [Parameter(Mandatory)][string]$ReceiptPath,
        [Parameter(Mandatory)][string]$Head,
        [Parameter(Mandatory)][string]$PolicySha256,
        [Parameter(Mandatory)][string]$MachineIdSha256,
        [Parameter(Mandatory)][string]$ValidatorSha256,
        [Parameter(Mandatory)][string[]]$Limitations
    )
    if (-not $PSCmdlet.ShouldProcess($ReceiptPath,'Write bounded semantic evidence receipt')) { return }
    $artifactSha = (Get-FileHash -LiteralPath $ArtifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $index = [pscustomobject][ordered]@{
        schema_version=1
        claim_name=$ClaimName
        artifacts=@([pscustomobject][ordered]@{ file_name=[IO.Path]::GetFileName($ArtifactPath); sha256=$artifactSha })
    }
    Write-NxbSemanticPart2Json -Path $IndexPath -InputObject $index
    $indexSha = (Get-FileHash -LiteralPath $IndexPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $start = [DateTimeOffset]::Parse($StartedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $end = [DateTimeOffset]::Parse($EndedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
    $durationSeconds = [int][Math]::Ceiling(($end - $start).TotalSeconds)
    if ($durationSeconds -lt 1) { $durationSeconds = 1 }
    $receipt = [pscustomobject][ordered]@{
        schema_version=1
        receipt_id=('part2-{0}-{1}' -f $ClaimName,$Head.Substring(0,12))
        claim_name=$ClaimName
        status='validated'
        authority=[pscustomobject][ordered]@{ repository='Naveax/nxb-integrity-research-lab'; exact_head=$Head; policy_sha256=$PolicySha256 }
        machine=[pscustomobject][ordered]@{ machine_id_sha256=$MachineIdSha256 }
        capture=[pscustomobject][ordered]@{ scope=$Scope; source_kind=$SourceKind; started_utc=$StartedUtc; ended_utc=$EndedUtc; bounded_session_seconds=$durationSeconds }
        evidence=[pscustomobject][ordered]@{ artifact_count=1; artifact_index_sha256=$indexSha }
        validation=[pscustomobject][ordered]@{
            negative_controls_passed=$true
            cleanup_verified=$true
            independent_validation_passed=$true
            validator_name='nxb-semantic-hardening-independent'
            validator_version='1.0.0'
            validator_implementation_sha256=$ValidatorSha256
            limitations=@($Limitations)
        }
        receipt_fingerprint_sha256='0000000000000000000000000000000000000000000000000000000000000000'
    }
    $receipt.receipt_fingerprint_sha256 = Get-NxbSemanticPart2Sha256Text -Text (Get-NxbSemanticPart2CanonicalMaterial -Receipt $receipt)
    Write-NxbSemanticPart2Json -Path $ReceiptPath -InputObject $receipt
    return $receipt
}

if ($env:OS -cne 'Windows_NT') { throw 'Part 2 semantic hardening certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Part 2 semantic hardening certification requires PowerShell 7.' }
if (-not (Test-NxbSemanticPart2Administrator)) { throw 'Part 2 semantic hardening certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Part 2 exact-head mismatch. Expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Part 2 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$workRoot = $outputFull + '-work'
$part1Output = $outputFull + '-part1'
$rootTraceOutput = $outputFull + '-roottrace'
$reviewZip = $outputFull + '-review.zip'
foreach ($reserved in @($outputFull,$workRoot,$part1Output,$part1Output + '-foundation-v5',$part1Output + '-review.zip',$rootTraceOutput,$reviewZip)) {
    if (Test-Path -LiteralPath $reserved) { throw ('Part 2 reserved output already exists: {0}' -f $reserved) }
}
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$configPath = Join-Path $repositoryRoot 'config\nxb-semantic-hardening-experiments.json'
$pnpScript = Join-Path $PSScriptRoot 'Invoke-NxbSemanticPnpEventExperiment.ps1'
$pcieScript = Join-Path $PSScriptRoot 'Invoke-NxbSemanticPcieBdfExperiment.ps1'
$powerScript = Join-Path $PSScriptRoot 'Invoke-NxbSemanticPowerFirmwareExperiment.ps1'
$rootTraceScript = Join-Path $PSScriptRoot 'Invoke-NxbSemanticRootTraceExperiment.ps1'
$testPath = Join-Path $repositoryRoot 'tests\SemanticHardening.Tests.ps1'
$pythonValidator = Join-Path $repositoryRoot 'tools\validate_semantic_hardening.py'
$receiptValidator = Join-Path $PSScriptRoot 'Test-NxbSemanticEvidenceReceipt.ps1'
$pythonReceiptValidator = Join-Path $repositoryRoot 'tools\validate_semantic_evidence_receipt.py'
$part1Runner = Join-Path $PSScriptRoot 'Invoke-NxbSemanticEvidenceAuthorityCertification.ps1'
$bindingScript = Join-Path $PSScriptRoot 'Get-NxbPlatformBindingSnapshotV2.ps1'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$signaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$ledgerPath = Join-Path $repositoryRoot 'docs\NXB-KNOWN-ERROR-LEDGER.md'
$profilePath = Join-Path $repositoryRoot 'profiles\Nxb.SemanticHardeningSequential.wprp'
$authorityPaths = @($PSCommandPath,$pnpScript,$pcieScript,$powerScript,$rootTraceScript,$testPath,$receiptValidator)
foreach ($requiredPath in @($configPath,$pythonValidator,$pythonReceiptValidator,$part1Runner,$bindingScript,$scannerPath,$signaturePath,$ledgerPath,$profilePath) + $authorityPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Part 2 component missing: {0}' -f $requiredPath) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-006 PART 2 8/8 SEMANTIC HARDENING CERTIFICATION ==='
Write-Information -InformationAction Continue -MessageData '[1/8] Parser + analyzer + JSON/XML/Python syntax preflight'
foreach ($scriptPath in $authorityPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('Part 2 parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join "`n")) }
}
if (-not (Get-Module -Name PSScriptAnalyzer)) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
}
$analyzerFinding = @(foreach ($scriptPath in $authorityPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFinding.Count -gt 0) { throw ('Part 2 PSScriptAnalyzer findings: {0}`n{1}' -f $analyzerFinding.Count,(@($analyzerFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")) }
[void](Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json)
[void]([xml](Get-Content -LiteralPath $profilePath -Raw))
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = [string]$pythonCommand.Source
foreach ($pythonFile in @($pythonValidator,$pythonReceiptValidator)) {
    $compile = Invoke-NxbSemanticPart2Native -Executable $pythonPath -ArgumentList @('-m','py_compile',$pythonFile)
    if ($compile.exit_code -ne 0) { throw ('Part 2 Python syntax failed: {0}`n{1}' -f $pythonFile,$compile.output) }
}

Write-Information -InformationAction Continue -MessageData '[2/8] Inherited known-error exact-tree scan + dual-runtime Part 2 contract'
$scanPath = Join-Path $workRoot 'known-error-scan.json'
$scan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -OutputPath $scanPath -PassThru
if ([string]$scan.status -cne 'passed' -or [int]$scan.finding_count -ne 0) { throw ('Part 2 known-error scan failed: findings={0}' -f $scan.finding_count) }
$previousRoot = [Environment]::GetEnvironmentVariable('NXB_SEMANTIC_REPOSITORY_ROOT','Process')
$env:NXB_SEMANTIC_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Contract = Invoke-NxbSemanticPart2Pester -Executable $pwshPath -TestPath $testPath -ExpectedCount 12 -Label 'Part 2 PS7'
    $ps51Contract = Invoke-NxbSemanticPart2Pester -Executable $ps51Path -TestPath $testPath -ExpectedCount 12 -Label 'Part 2 PS5.1'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_SEMANTIC_REPOSITORY_ROOT -ErrorAction SilentlyContinue } else { $env:NXB_SEMANTIC_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -InformationAction Continue -MessageData '[3/8] Re-certify inherited Part 1 authority on the same exact head'
$part1Pipeline = @(& $part1Runner -ExpectedHead $ExpectedHead -OutputDirectory $part1Output -PassThru)
$part1Result = $null
foreach ($item in $part1Pipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $part1Result = $item }
}
if ($null -eq $part1Result -or [string]$part1Result.head_sha -cne $currentHead) { throw 'Inherited Part 1 authority did not pass on the Part 2 head.' }
$policySha = [string]$part1Result.policy_fingerprint_sha256

Write-Information -InformationAction Continue -MessageData '[4/8] Machine binding + four bounded native experiment families'
$platformPath = Join-Path $workRoot 'platform-binding.json'
$platform = & $bindingScript -OutputPath $platformPath -PassThru
$machineIdSha = [string]$platform.identity.machine_id_sha256
if ($machineIdSha -notmatch '^[0-9a-f]{64}$') { throw 'Part 2 machine binding SHA-256 is invalid.' }
$pnpPath = Join-Path $workRoot 'pnp-event-experiment.json'
$pciePath = Join-Path $workRoot 'pcie-bdf-experiment.json'
$powerPath = Join-Path $workRoot 'power-firmware-experiment.json'
$pnp = & $pnpScript -OutputPath $pnpPath -PassThru
$pcie = & $pcieScript -OutputPath $pciePath -PassThru
$power = & $powerScript -OutputPath $powerPath -PassThru
$rootTrace = & $rootTraceScript -ExpectedHead $ExpectedHead -OutputDirectory $rootTraceOutput -PassThru
$rootTracePath = Join-Path $rootTraceOutput 'review\root-trace-experiment.json'
if ([string]$pnp.status -cne 'passed' -or [string]$pcie.status -cne 'passed' -or [string]$power.status -cne 'passed' -or [string]$rootTrace.status -cne 'passed') { throw 'One or more Part 2 experiment families did not pass.' }

Write-Information -InformationAction Continue -MessageData '[5/8] Independent Python 8/8 replay'
$matrixPath = Join-Path $workRoot 'semantic-hardening-matrix.json'
$matrixRun = Invoke-NxbSemanticPart2Native -Executable $pythonPath -ArgumentList @($pythonValidator,'--pnp',$pnpPath,'--pcie',$pciePath,'--power-firmware',$powerPath,'--root-trace',$rootTracePath,'--output',$matrixPath)
if ($matrixRun.exit_code -ne 0) { throw ('Independent Part 2 validator failed: {0}' -f $matrixRun.output) }
$matrix = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json
if ([string]$matrix.status -cne 'passed' -or [int]$matrix.requested -ne 8 -or [int]$matrix.validated -ne 8) { throw 'Independent Part 2 validator did not return requested=8 validated=8.' }

Write-Information -InformationAction Continue -MessageData '[6/8] Generate and independently validate eight Part 1-compatible receipts'
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
$reviewRoot = Join-Path $outputFull 'review'
$receiptRoot = Join-Path $reviewRoot 'semantic-receipts'
$indexRoot = Join-Path $reviewRoot 'artifact-indexes'
[IO.Directory]::CreateDirectory($receiptRoot) | Out-Null
[IO.Directory]::CreateDirectory($indexRoot) | Out-Null
$reviewExperiment = [ordered]@{}
foreach ($entry in @(
    [pscustomobject]@{ name='pnp-event-experiment.json'; source=$pnpPath },
    [pscustomobject]@{ name='pcie-bdf-experiment.json'; source=$pciePath },
    [pscustomobject]@{ name='power-firmware-experiment.json'; source=$powerPath },
    [pscustomobject]@{ name='root-trace-experiment.json'; source=$rootTracePath }
)) {
    $destination = Join-Path $reviewRoot $entry.name
    Copy-Item -LiteralPath $entry.source -Destination $destination
    $reviewExperiment[$entry.name] = $destination
}
Copy-Item -LiteralPath $matrixPath -Destination (Join-Path $reviewRoot 'semantic-hardening-matrix.json')
Copy-Item -LiteralPath $scanPath -Destination (Join-Path $reviewRoot 'known-error-scan.json')
$validatorSha = (Get-FileHash -LiteralPath $pythonValidator -Algorithm SHA256).Hash.ToLowerInvariant()
$claimDefinition = @(
    [pscustomobject]@{ claim='pnp_lifecycle_semantics'; artifact='pnp-event-experiment.json'; kind='owned_software_device_lifecycle'; scope=[string]$pnp.scope; start=[string]$pnp.started_utc; end=[string]$pnp.ended_utc; limits=@('owned ephemeral software-device repeats only','no generalized physical-device lifecycle claim') },
    [pscustomobject]@{ claim='event_id_semantics'; artifact='pnp-event-experiment.json'; kind='owned_pnp_event_differential'; scope=[string]$pnp.scope; start=[string]$pnp.started_utc; end=[string]$pnp.ended_utc; limits=@('provider/log/id mappings only for the owned repeated fixture','raw event payload and formatted message excluded') },
    [pscustomobject]@{ claim='event_task_opcode_semantics'; artifact='pnp-event-experiment.json'; kind='owned_pnp_event_shape_differential'; scope=[string]$pnp.scope; start=[string]$pnp.started_utc; end=[string]$pnp.ended_utc; limits=@('id/version/level/task/opcode shape only for observed fixture events','unobserved labels are not promoted') },
    [pscustomobject]@{ claim='pcie_bdf_semantics'; artifact='pcie-bdf-experiment.json'; kind='bounded_pcie_inventory'; scope=[string]$pcie.scope; start=[string]$pcie.started_utc; end=[string]$pcie.ended_utc; limits=@('same boot only','cross-boot BDF stability not claimed') },
    [pscustomobject]@{ claim='power_causality'; artifact='power-firmware-experiment.json'; kind='owned_power_scheme_transition'; scope=[string]$power.scope; start=[string]$power.started_utc; end=[string]$power.ended_utc; limits=@('temporary owned power-scheme activation only','general system power causality not claimed') },
    [pscustomobject]@{ claim='firmware_causality'; artifact='power-firmware-experiment.json'; kind='ephemeral_hyperv_gen2_firmware'; scope=[string]$power.scope; start=[string]$power.started_utc; end=[string]$power.ended_utc; limits=@('ephemeral Generation 2 Hyper-V VM firmware only','host firmware and Secure Boot are not changed') },
    [pscustomobject]@{ claim='root_cause_validated'; artifact='root-trace-experiment.json'; kind='repeated_superblock_controls'; scope=[string]$rootTrace.scope; start=[string]$rootTrace.started_utc; end=[string]$rootTrace.ended_utc; limits=@('bounded owned all_on hypothesis only','no generalized machine root-cause claim') },
    [pscustomobject]@{ claim='continuous_trace_completeness'; artifact='root-trace-experiment.json'; kind='sequential_wpr_control_session'; scope=[string]$rootTrace.scope; start=[string]$rootTrace.started_utc; end=[string]$rootTrace.ended_utc; limits=@('bounded ten-scenario sequential WPR session only','unbounded or system-wide completeness not claimed') }
)
$receiptShaMap = [ordered]@{}
foreach ($definition in $claimDefinition) {
    $artifactPath = [string]$reviewExperiment[[string]$definition.artifact]
    $indexPath = Join-Path $indexRoot (([string]$definition.claim) + '.json')
    $receiptPath = Join-Path $receiptRoot (([string]$definition.claim) + '.json')
    [void](New-NxbSemanticPart2ReceiptDocument -ClaimName $definition.claim -SourceKind $definition.kind -Scope $definition.scope -StartedUtc $definition.start -EndedUtc $definition.end -ArtifactPath $artifactPath -IndexPath $indexPath -ReceiptPath $receiptPath -Head $currentHead -PolicySha256 $policySha -MachineIdSha256 $machineIdSha -ValidatorSha256 $validatorSha -Limitations $definition.limits -Confirm:$false)
    $psReceipt = & $receiptValidator -ReceiptPath $receiptPath -ExpectedHead $currentHead -ExpectedPolicySha256 $policySha -ExpectedMachineIdSha256 $machineIdSha -PassThru
    if ([string]$psReceipt.status -cne 'passed' -or -not [bool]$psReceipt.promotable) { throw ('PowerShell receipt validation failed: {0}' -f $definition.claim) }
    $pyReceipt = Invoke-NxbSemanticPart2Native -Executable $pythonPath -ArgumentList @($pythonReceiptValidator,$receiptPath,'--expected-head',$currentHead,'--expected-policy-sha256',$policySha,'--expected-machine-id-sha256',$machineIdSha)
    if ($pyReceipt.exit_code -ne 0) { throw ('Python receipt validation failed: {0}`n{1}' -f $definition.claim,$pyReceipt.output) }
    $pyReceiptObject = $pyReceipt.output | ConvertFrom-Json
    if ([string]$pyReceiptObject.status -cne 'passed' -or -not [bool]$pyReceiptObject.promotable) { throw ('Python receipt did not promote: {0}' -f $definition.claim) }
    $receiptShaMap[[string]$definition.claim] = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
}

Write-Information -InformationAction Continue -MessageData '[7/8] Build bounded claim matrix receipt + review ZIP'
$finalReceiptPath = Join-Path $reviewRoot 'semantic-hardening-part2-certification-receipt.json'
$finalReceipt = [pscustomobject][ordered]@{
    schema_version=1
    status='passed'
    head_sha=$currentHead
    requested=8
    validated=8
    part2_contract=[pscustomobject][ordered]@{ ps7=('{0}/{1}' -f $ps7Contract.passed,$ps7Contract.total); ps51=('{0}/{1}' -f $ps51Contract.passed,$ps51Contract.total); analyzer_findings=0; known_error_findings=[int]$scan.finding_count; known_error_rules=[int]$scan.rule_count }
    inherited_part1=[pscustomobject][ordered]@{ status=[string]$part1Result.status; head_sha=[string]$part1Result.head_sha; semantic_ps7=[string]$part1Result.semantic_ps7_tests; semantic_ps51=[string]$part1Result.semantic_ps51_tests; inherited_v5_ps7=[string]$part1Result.inherited_v5_ps7_tests; inherited_v5_ps51=[string]$part1Result.inherited_v5_ps51_tests }
    policy_fingerprint_sha256=$policySha
    machine_id_sha256=$machineIdSha
    independent_matrix_sha256=(Get-FileHash -LiteralPath (Join-Path $reviewRoot 'semantic-hardening-matrix.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    semantic_receipt_sha256=$receiptShaMap
    raw_etl_in_review=$false
    raw_event_payload_in_review=$false
    raw_device_identifier_in_review=$false
}
Write-NxbSemanticPart2Json -Path $finalReceiptPath -InputObject $finalReceipt
$expectedEntries = @(
    'known-error-scan.json','pcie-bdf-experiment.json','pnp-event-experiment.json','power-firmware-experiment.json','root-trace-experiment.json','semantic-hardening-matrix.json','semantic-hardening-part2-certification-receipt.json'
)
$expectedEntries += @($claimDefinition | ForEach-Object { 'artifact-indexes/' + $_.claim + '.json' })
$expectedEntries += @($claimDefinition | ForEach-Object { 'semantic-receipts/' + $_.claim + '.json' })
$expectedEntries = @($expectedEntries | Sort-Object)
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($reviewZip)
try {
    $observedEntries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName.Replace('\','/') } | Sort-Object)
}
finally { $zip.Dispose() }
if (($observedEntries -join "`n") -cne ($expectedEntries -join "`n")) { throw ('Part 2 review ZIP content mismatch.`nObserved: {0}' -f ($observedEntries -join ', ')) }
if (@($observedEntries | Where-Object { -not $_.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { throw 'Part 2 review ZIP contains a non-JSON artifact.' }

Write-Information -InformationAction Continue -MessageData '[8/8] Final exact-tree zero-error re-scan'
$finalScanPath = Join-Path $workRoot 'known-error-final-scan.json'
$finalScan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -OutputPath $finalScanPath -PassThru
if ([string]$finalScan.status -cne 'passed' -or [int]$finalScan.finding_count -ne 0) { throw ('Part 2 final known-error scan failed: findings={0}' -f $finalScan.finding_count) }

$result = [pscustomobject][ordered]@{
    schema_version=1
    status='passed'
    head_sha=$currentHead
    requested=8
    validated=8
    ps7_tests=('{0}/{1}' -f $ps7Contract.passed,$ps7Contract.total)
    ps51_tests=('{0}/{1}' -f $ps51Contract.passed,$ps51Contract.total)
    psscriptanalyzer_findings=0
    known_error_rule_count=[int]$finalScan.rule_count
    known_error_finding_count=[int]$finalScan.finding_count
    independent_validation=$true
    inherited_part1_status=[string]$part1Result.status
    inherited_part1_head=[string]$part1Result.head_sha
    policy_fingerprint_sha256=$policySha
    review_zip_path=$reviewZip
    review_zip_sha256=(Get-FileHash -LiteralPath $reviewZip -Algorithm SHA256).Hash.ToLowerInvariant()
    receipt_path=$finalReceiptPath
    receipt_sha256=(Get-FileHash -LiteralPath $finalReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    work_root=$workRoot
    part1_output=$part1Output
    root_trace_output=$rootTraceOutput
}
Write-Information -InformationAction Continue -MessageData ('NXB IRL-006 Part 2 semantic hardening passed: requested={0} validated={1}' -f $result.requested,$result.validated)
if ($PassThru) { return $result }
Write-Output $reviewZip
