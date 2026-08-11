[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbAdaptiveV2Json {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-NxbAdaptiveV2Pester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-adaptive-v2-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $childPath = Join-Path $tempRoot 'run.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
$ErrorActionPreference = 'Stop'
Import-Module Pester -ErrorAction Stop
$result = Invoke-Pester -Path $TestPath -PassThru
$summary = [pscustomobject]@{
    passed = [int]$result.PassedCount
    failed = [int]$result.FailedCount
    skipped = [int]$result.SkippedCount
    total = [int]$result.TotalCount
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($summary.passed -ne $ExpectedCount -or $summary.total -ne $ExpectedCount -or $summary.failed -ne 0 -or $summary.skipped -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8
    try {
        $childOutput = @(& $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath -ExpectedCount $ExpectedCount 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $childOutput) { Write-Information -InformationAction Continue -MessageData ([string]$line) }
        if ($exitCode -ne 0) { throw ('{0} Pester failed: exit={1}' -f $Label,$exitCode) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Invoke-NxbAdaptiveV2PythonValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$ValidatorPath,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $toolOutput = @(& $PythonPath $ValidatorPath $PolicyPath --plan $PlanPath --output $OutputPath 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    foreach ($line in $toolOutput) { Write-Information -InformationAction Continue -MessageData ([string]$line) }
    if ($exitCode -ne 0) { throw ('Adaptive V2 Python validation failed: exit={0}' -f $exitCode) }
    return (Get-Content -LiteralPath $OutputPath -Raw | ConvertFrom-Json)
}

function Invoke-NxbAdaptiveV2Scenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][hashtable]$Signals,
        [Parameter(Mandatory)][string]$ExpectedMode,
        [Parameter(Mandatory)][string]$ExpectedDetail,
        [Parameter()][string]$ExpectedTrigger,
        [Parameter()][string]$ExpectedFirstDomain,
        [Parameter()][string]$OperatorMode,
        [Parameter(Mandatory)][string]$ResolverPath,
        [Parameter(Mandatory)][string]$PolicyPath,
        [Parameter(Mandatory)][string]$ValidatorPath,
        [Parameter(Mandatory)][string]$PythonPath,
        [Parameter(Mandatory)][string]$WorkRoot,
        [Parameter(Mandatory)][string]$ReviewRoot
    )
    $signalsPath = Join-Path $WorkRoot ('signals-{0}.json' -f $Name)
    $planPath = Join-Path $ReviewRoot ('adaptive-plan-{0}.json' -f $Name)
    $validationPath = Join-Path $ReviewRoot ('adaptive-validation-{0}.json' -f $Name)
    Write-NxbAdaptiveV2Json -Path $signalsPath -InputObject ([pscustomobject]$Signals)

    if ([string]::IsNullOrWhiteSpace($OperatorMode)) {
        $plan = & $ResolverPath -PolicyPath $PolicyPath -SignalsPath $signalsPath -OutputPath $planPath -PassThru
    }
    else {
        $plan = & $ResolverPath -PolicyPath $PolicyPath -SignalsPath $signalsPath -OperatorMode $OperatorMode -OutputPath $planPath -PassThru
    }

    if ([string]$plan.effective_mode -cne $ExpectedMode) { throw ('Scenario {0} mode mismatch: {1}' -f $Name,$plan.effective_mode) }
    if ([string]$plan.detail -cne $ExpectedDetail) { throw ('Scenario {0} detail mismatch: {1}' -f $Name,$plan.detail) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedTrigger) -and @($plan.active_trigger_ids) -notcontains $ExpectedTrigger) {
        throw ('Scenario {0} missing trigger: {1}' -f $Name,$ExpectedTrigger)
    }
    $firstDomain = ''
    if (@($plan.active_domains).Count -gt 0) { $firstDomain = [string](@($plan.active_domains)[0]) }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedFirstDomain) -and $firstDomain -cne $ExpectedFirstDomain) {
        throw ('Scenario {0} first domain mismatch: {1}' -f $Name,$firstDomain)
    }

    $validation = Invoke-NxbAdaptiveV2PythonValidation -PythonPath $PythonPath -ValidatorPath $ValidatorPath -PolicyPath $PolicyPath -PlanPath $planPath -OutputPath $validationPath
    if ([string]$validation.status -cne 'passed') { throw ('Scenario {0} independent validation did not pass.' -f $Name) }
    if ([string]$validation.plan_fingerprint_sha256 -cne [string]$plan.plan_fingerprint_sha256) { throw ('Scenario {0} plan fingerprint mismatch.' -f $Name) }

    return [pscustomobject][ordered]@{
        name = $Name
        effective_mode = [string]$plan.effective_mode
        detail = [string]$plan.detail
        first_domain = $firstDomain
        active_domains = @($plan.active_domains)
        active_trigger_ids = @($plan.active_trigger_ids)
        plan_fingerprint_sha256 = [string]$plan.plan_fingerprint_sha256
        plan_sha256 = (Get-FileHash -LiteralPath $planPath -Algorithm SHA256).Hash.ToLowerInvariant()
        validation_sha256 = (Get-FileHash -LiteralPath $validationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Adaptive observability V2 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Adaptive observability V2 certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Adaptive V2 exact-head mismatch. Expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Adaptive V2 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repoPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repoPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Adaptive V2 output must remain outside the repository.' }
if (Test-Path -LiteralPath $outputFull) { throw ('OutputDirectory already exists: {0}' -f $outputFull) }
$reviewRoot = Join-Path $outputFull 'review'
$workRoot = Join-Path $outputFull 'work'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$policyPath = Join-Path $repositoryRoot 'config\adaptive-observability-policy.default.json'
$schemaPath = Join-Path $repositoryRoot 'schemas\adaptive-observability-policy.schema.json'
$resolverPath = Join-Path $PSScriptRoot 'Resolve-NxbAdaptiveObservabilityPlan.ps1'
$panelPath = Join-Path $PSScriptRoot 'Start-NxbAdaptiveObservabilityPanel.ps1'
$coreTestPath = Join-Path $repositoryRoot 'tests\AdaptiveObservabilityControlPlane.Tests.ps1'
$securityTestPath = Join-Path $repositoryRoot 'tests\AdaptiveObservabilityPanelSecurity.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_adaptive_observability_policy.py'
$panelHtmlPath = Join-Path $repositoryRoot 'ui\adaptive-observability-panel.html'
foreach ($requiredPath in @($policyPath,$schemaPath,$resolverPath,$panelPath,$coreTestPath,$securityTestPath,$validatorPath,$panelHtmlPath,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Adaptive V2 component missing: {0}' -f $requiredPath) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-005 ADAPTIVE OBSERVABILITY CONTROL-PLANE CERTIFICATION V2 ==='
Write-Information -InformationAction Continue -MessageData '[1/5] Parser/analyzer + dual-runtime 30-test contract'
$analyzerPaths = @($resolverPath,$panelPath,$coreTestPath,$securityTestPath,$PSCommandPath)
foreach ($scriptPath in $analyzerPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('PowerShell parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join "`n")) }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(foreach ($scriptPath in $analyzerPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($findings.Count -gt 0) { throw ('Adaptive V2 PSScriptAnalyzer findings: {0}`n{1}' -f $findings.Count,(@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")) }

$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = $pythonCommand.Source
& $pythonPath -m py_compile $validatorPath
if ($LASTEXITCODE -ne 0) { throw 'Adaptive V2 Python syntax check failed.' }
[void](Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json)
[void](Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json)

$previousRoot = [Environment]::GetEnvironmentVariable('NXB_ADAPTIVE_REPOSITORY_ROOT','Process')
$env:NXB_ADAPTIVE_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Core = Invoke-NxbAdaptiveV2Pester -Executable $pwshPath -TestPath $coreTestPath -ExpectedCount 25 -Label 'PowerShell 7 adaptive core'
    $ps7Security = Invoke-NxbAdaptiveV2Pester -Executable $pwshPath -TestPath $securityTestPath -ExpectedCount 5 -Label 'PowerShell 7 adaptive security'
    $ps51Core = Invoke-NxbAdaptiveV2Pester -Executable $ps51Path -TestPath $coreTestPath -ExpectedCount 25 -Label 'Windows PowerShell 5.1 adaptive core'
    $ps51Security = Invoke-NxbAdaptiveV2Pester -Executable $ps51Path -TestPath $securityTestPath -ExpectedCount 5 -Label 'Windows PowerShell 5.1 adaptive security'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_ADAPTIVE_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_ADAPTIVE_REPOSITORY_ROOT = $previousRoot }
}
$ps7Passed = [int]$ps7Core.passed + [int]$ps7Security.passed
$ps7Total = [int]$ps7Core.total + [int]$ps7Security.total
$ps51Passed = [int]$ps51Core.passed + [int]$ps51Security.passed
$ps51Total = [int]$ps51Core.total + [int]$ps51Security.total
$ps7Contract = '{0}/{1}' -f $ps7Passed,$ps7Total
$ps51Contract = '{0}/{1}' -f $ps51Passed,$ps51Total
if ($ps7Contract -cne '30/30' -or $ps51Contract -cne '30/30') { throw 'Adaptive V2 combined dual-runtime contract mismatch.' }

Write-Information -InformationAction Continue -MessageData '[2/5] Independent policy validation'
$policyOnlyValidationPath = Join-Path $reviewRoot 'adaptive-policy-validation.json'
$policyToolOutput = @(& $pythonPath $validatorPath $policyPath --output $policyOnlyValidationPath 2>&1)
$policyExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
foreach ($line in $policyToolOutput) { Write-Information -InformationAction Continue -MessageData ([string]$line) }
if ($policyExitCode -ne 0) { throw ('Adaptive V2 policy-only Python validation failed: exit={0}' -f $policyExitCode) }
$policyValidation = Get-Content -LiteralPath $policyOnlyValidationPath -Raw | ConvertFrom-Json
if ([string]$policyValidation.status -cne 'passed') { throw 'Adaptive V2 policy validation receipt is not passed.' }

Write-Information -InformationAction Continue -MessageData '[3/5] Deterministic scenario matrix + independent plan validation'
$scenarioResults = [Collections.Generic.List[object]]::new()
$scenarioResults.Add((Invoke-NxbAdaptiveV2Scenario -Name 'empty-a' -Signals @{} -ExpectedMode 'minimal' -ExpectedDetail 'summary' -ResolverPath $resolverPath -PolicyPath $policyPath -ValidatorPath $validatorPath -PythonPath $pythonPath -WorkRoot $workRoot -ReviewRoot $reviewRoot))
$scenarioResults.Add((Invoke-NxbAdaptiveV2Scenario -Name 'empty-b' -Signals @{} -ExpectedMode 'minimal' -ExpectedDetail 'summary' -ResolverPath $resolverPath -PolicyPath $policyPath -ValidatorPath $validatorPath -PythonPath $pythonPath -WorkRoot $workRoot -ReviewRoot $reviewRoot))
$scenarioResults.Add((Invoke-NxbAdaptiveV2Scenario -Name 'frame' -Signals @{ frame_time_ms = 40 } -ExpectedMode 'deep' -ExpectedDetail 'semantic' -ExpectedTrigger 'frame-spike' -ExpectedFirstDomain 'gpu' -ResolverPath $resolverPath -PolicyPath $policyPath -ValidatorPath $validatorPath -PythonPath $pythonPath -WorkRoot $workRoot -ReviewRoot $reviewRoot))
$scenarioResults.Add((Invoke-NxbAdaptiveV2Scenario -Name 'security' -Signals @{ security_state_changed = $true } -ExpectedMode 'forensic' -ExpectedDetail 'semantic' -ExpectedTrigger 'security-state-change' -ExpectedFirstDomain 'security' -ResolverPath $resolverPath -PolicyPath $policyPath -ValidatorPath $validatorPath -PythonPath $pythonPath -WorkRoot $workRoot -ReviewRoot $reviewRoot))
$scenarioResults.Add((Invoke-NxbAdaptiveV2Scenario -Name 'rootcause' -Signals @{ root_cause_request = $true } -ExpectedMode 'forensic' -ExpectedDetail 'semantic' -ExpectedTrigger 'root-cause-request' -ExpectedFirstDomain 'cpu' -ResolverPath $resolverPath -PolicyPath $policyPath -ValidatorPath $validatorPath -PythonPath $pythonPath -WorkRoot $workRoot -ReviewRoot $reviewRoot))
$scenarioResults.Add((Invoke-NxbAdaptiveV2Scenario -Name 'operator-forensic' -Signals @{} -ExpectedMode 'forensic' -ExpectedDetail 'semantic' -OperatorMode 'forensic' -ExpectedFirstDomain 'cpu' -ResolverPath $resolverPath -PolicyPath $policyPath -ValidatorPath $validatorPath -PythonPath $pythonPath -WorkRoot $workRoot -ReviewRoot $reviewRoot))

$emptyA = @($scenarioResults | Where-Object { $_.name -ceq 'empty-a' })[0]
$emptyB = @($scenarioResults | Where-Object { $_.name -ceq 'empty-b' })[0]
$deterministicReplay = ([string]$emptyA.plan_sha256 -ceq [string]$emptyB.plan_sha256)
if (-not $deterministicReplay) { throw 'Adaptive V2 empty-signal plan replay was not byte-identical.' }

Write-Information -InformationAction Continue -MessageData '[4/5] Certification receipt + claim discipline audit'
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
$targetCount = @($policy.claim_targets | Where-Object { [bool]$_.target_requested }).Count
$validatedCount = @($policy.claim_targets | Where-Object { [bool]$_.validated }).Count
if ($targetCount -ne 8) { throw ('Adaptive V2 semantic target count must equal eight: {0}' -f $targetCount) }
if ($validatedCount -ne 0) { throw 'Adaptive V2 foundation must not pre-certify semantic claims.' }
if (-not [bool]$policy.panel.local_only) { throw 'Adaptive V2 panel local-only boundary is not enabled.' }

$receiptPath = Join-Path $reviewRoot 'adaptive-control-plane-certification-receipt.json'
$receipt = [pscustomobject][ordered]@{
    schema_version = 2
    status = 'passed'
    head_sha = $currentHead
    static_validation = [pscustomobject][ordered]@{
        ps7_tests = $ps7Contract
        ps51_tests = $ps51Contract
        core_tests_per_runtime = 25
        panel_security_tests_per_runtime = 5
        psscriptanalyzer_findings = [int]$findings.Count
        python_syntax = 'passed'
    }
    policy = [pscustomobject][ordered]@{
        policy_id = [string]$policy.policy_id
        default_mode = [string]$policy.default_mode
        maximum_mode = [string]$policy.maximum_mode
        local_only_panel = [bool]$policy.panel.local_only
        mutation_token_required = $true
        policy_fingerprint_sha256 = [string]$policyValidation.policy_fingerprint_sha256
        policy_file_sha256 = (Get-FileHash -LiteralPath $policyPath -Algorithm SHA256).Hash.ToLowerInvariant()
        schema_file_sha256 = (Get-FileHash -LiteralPath $schemaPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    scenario_count = [int]$scenarioResults.Count
    deterministic_empty_replay = $deterministicReplay
    scenarios = @($scenarioResults.ToArray())
    semantic_targets = [pscustomobject][ordered]@{
        requested = $targetCount
        validated = $validatedCount
        evidence_required_for_validation = $true
    }
    claims = [pscustomobject][ordered]@{
        adaptive_control_plane_foundation = $true
        selective_escalation_policy = $true
        deterministic_plan_resolution = $true
        panel_local_only = $true
        panel_mutation_token = $true
        generalized_semantic_claims_prevalidated = $false
    }
}
Write-NxbAdaptiveV2Json -Path $receiptPath -InputObject $receipt

Write-Information -InformationAction Continue -MessageData '[5/5] Bounded review ZIP + content audit'
$forbiddenExtensions = @('.etl','.evtx','.xml','.jsonl','.exe','.obj','.pdb')
foreach ($file in @(Get-ChildItem -LiteralPath $reviewRoot -File -Recurse)) {
    if ($forbiddenExtensions -contains $file.Extension.ToLowerInvariant()) { throw ('Forbidden adaptive V2 review artifact: {0}' -f $file.FullName) }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in @('PCI\VEN_','USB\VID_','PNPDeviceID','DeviceID','X-NXB-Panel-Token')) {
        if ($text -match [regex]::Escape($pattern)) { throw ('Forbidden adaptive V2 review content in {0}: {1}' -f $file.Name,$pattern) }
    }
}

$reviewZip = '{0}-review.zip' -f $outputFull.TrimEnd('\')
if (Test-Path -LiteralPath $reviewZip) { Remove-Item -LiteralPath $reviewZip -Force }
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
$reviewZipSha = (Get-FileHash -LiteralPath $reviewZip -Algorithm SHA256).Hash.ToLowerInvariant()
$receiptSha = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Information -InformationAction Continue -MessageData ('NXB adaptive V2 certification passed: scenarios={0} replay={1} targets={2}/validated={3}' -f $scenarioResults.Count,$deterministicReplay,$targetCount,$validatedCount)

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    ps7_tests = $ps7Contract
    ps51_tests = $ps51Contract
    psscriptanalyzer_findings = [int]$findings.Count
    policy_fingerprint_sha256 = [string]$policyValidation.policy_fingerprint_sha256
    scenario_count = [int]$scenarioResults.Count
    deterministic_empty_replay = $deterministicReplay
    semantic_targets_requested = $targetCount
    semantic_targets_validated = $validatedCount
    panel_local_only = $true
    panel_mutation_token = $true
    receipt_sha256 = $receiptSha
    review_zip_sha256 = $reviewZipSha
    review_zip_path = [IO.Path]::GetFullPath($reviewZip)
}
if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 20
