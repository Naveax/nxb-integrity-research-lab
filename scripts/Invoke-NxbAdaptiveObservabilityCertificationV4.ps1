[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbAdaptiveV4Json {
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

function Invoke-NxbAdaptiveV4Pester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-adaptive-v4-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
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
        $output = @(& $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath -ExpectedCount $ExpectedCount 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $output) { Write-Information -InformationAction Continue -MessageData ([string]$line) }
        if ($exitCode -ne 0) { throw ('{0} Pester failed: exit={1}' -f $Label,$exitCode) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Adaptive observability V4 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Adaptive observability V4 certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Adaptive V4 exact-head mismatch. Expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Adaptive V4 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) { throw ('OutputDirectory already exists: {0}' -f $outputFull) }

$manifestResolver = Join-Path $PSScriptRoot 'Resolve-NxbAdaptiveCaptureManifest.ps1'
$manifestTest = Join-Path $repositoryRoot 'tests\AdaptiveCaptureManifest.Tests.ps1'
$manifestValidator = Join-Path $repositoryRoot 'tools\validate_adaptive_capture_manifest.py'
$domainMap = Join-Path $repositoryRoot 'config\adaptive-observability-domain-map.json'
$v3Runner = Join-Path $PSScriptRoot 'Invoke-NxbAdaptiveObservabilityCertificationV3.ps1'
foreach ($requiredPath in @($manifestResolver,$manifestTest,$manifestValidator,$domainMap,$v3Runner,$PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Adaptive V4 component missing: {0}' -f $requiredPath) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-005 ADAPTIVE OBSERVABILITY CONTROL-PLANE CERTIFICATION V4 ==='
Write-Information -InformationAction Continue -MessageData '[1/4] Capture-manifest parser/analyzer + dual-runtime 10-test contract'
$analyzerPaths = @($manifestResolver,$manifestTest,$PSCommandPath)
foreach ($scriptPath in $analyzerPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('Adaptive V4 parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join "`n")) }
}
if (-not (Get-Module -Name PSScriptAnalyzer)) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
}
$manifestFindings = @(foreach ($scriptPath in $analyzerPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($manifestFindings.Count -gt 0) { throw ('Adaptive V4 PSScriptAnalyzer findings: {0}`n{1}' -f $manifestFindings.Count,(@($manifestFindings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")) }

$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = $pythonCommand.Source
& $pythonPath -m py_compile $manifestValidator
if ($LASTEXITCODE -ne 0) { throw 'Adaptive V4 manifest-validator Python syntax check failed.' }
[void](Get-Content -LiteralPath $domainMap -Raw | ConvertFrom-Json)

$previousRoot = [Environment]::GetEnvironmentVariable('NXB_ADAPTIVE_REPOSITORY_ROOT','Process')
$env:NXB_ADAPTIVE_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Manifest = Invoke-NxbAdaptiveV4Pester -Executable $pwshPath -TestPath $manifestTest -ExpectedCount 10 -Label 'PowerShell 7 adaptive manifest'
    $ps51Manifest = Invoke-NxbAdaptiveV4Pester -Executable $ps51Path -TestPath $manifestTest -ExpectedCount 10 -Label 'Windows PowerShell 5.1 adaptive manifest'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_ADAPTIVE_REPOSITORY_ROOT -ErrorAction SilentlyContinue }
    else { $env:NXB_ADAPTIVE_REPOSITORY_ROOT = $previousRoot }
}

Write-Information -InformationAction Continue -MessageData '[2/4] Run V3 adaptive core + security + hysteresis certification'
$v3Pipeline = @(& $v3Runner -ExpectedHead $ExpectedHead -OutputDirectory $outputFull -PassThru)
$v3Result = $null
foreach ($item in $v3Pipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $v3Result = $item }
}
if ($null -eq $v3Result) { throw 'Adaptive V3 child certification returned no passed result.' }
if ([string]$v3Result.head_sha -cne $currentHead) { throw 'Adaptive V3 child head mismatch.' }
if ([string]$v3Result.ps7_tests -cne '38/38' -or [string]$v3Result.ps51_tests -cne '38/38') { throw 'Adaptive V3 child test contract mismatch.' }
if ([int]$v3Result.psscriptanalyzer_findings -ne 0) { throw 'Adaptive V3 child analyzer findings were nonzero.' }
if (-not [bool]$v3Result.hysteresis_validated) { throw 'Adaptive V3 hysteresis validation was not passed.' }

Write-Information -InformationAction Continue -MessageData '[3/4] Resolve root-cause plan to repo-owned capture manifest + independent Python replay'
$reviewRoot = Join-Path $outputFull 'review'
$rootCausePlan = Join-Path $reviewRoot 'adaptive-plan-rootcause.json'
if (-not (Test-Path -LiteralPath $rootCausePlan -PathType Leaf)) { throw 'Adaptive root-cause plan is missing from V3 review evidence.' }
$manifestPath = Join-Path $reviewRoot 'adaptive-capture-manifest-rootcause.json'
$manifestValidationPath = Join-Path $reviewRoot 'adaptive-capture-manifest-validation-rootcause.json'
$manifest = & $manifestResolver -PlanPath $rootCausePlan -DomainMapPath $domainMap -OutputPath $manifestPath -PassThru
$validatorOutput = @(& $pythonPath $manifestValidator --repo-root $repositoryRoot --plan $rootCausePlan --domain-map $domainMap --manifest $manifestPath --output $manifestValidationPath 2>&1)
$validatorExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
foreach ($line in $validatorOutput) { Write-Information -InformationAction Continue -MessageData ([string]$line) }
if ($validatorExit -ne 0) { throw ('Adaptive V4 manifest Python validation failed: exit={0}' -f $validatorExit) }
$manifestValidation = Get-Content -LiteralPath $manifestValidationPath -Raw | ConvertFrom-Json
if ([string]$manifestValidation.status -cne 'passed') { throw 'Adaptive V4 manifest validation receipt is not passed.' }
if ([string]$manifestValidation.plan_fingerprint_sha256 -cne [string]$manifest.plan_fingerprint_sha256) { throw 'Adaptive V4 manifest plan binding mismatch.' }
if ([int]$manifest.capture.domain_count -ne 8) { throw ('Adaptive V4 root-cause manifest expected 8 bounded domains, got {0}.' -f $manifest.capture.domain_count) }
if ([int]$manifest.capture.unavailable_count -ne 0) { throw 'Adaptive V4 root-cause manifest contains unavailable domains.' }

Write-Information -InformationAction Continue -MessageData '[4/4] Bind manifest validation into final V4 review evidence'
$ps7CombinedPassed = [int]38 + [int]$ps7Manifest.passed
$ps7CombinedTotal = [int]38 + [int]$ps7Manifest.total
$ps51CombinedPassed = [int]38 + [int]$ps51Manifest.passed
$ps51CombinedTotal = [int]38 + [int]$ps51Manifest.total
$ps7Contract = '{0}/{1}' -f $ps7CombinedPassed,$ps7CombinedTotal
$ps51Contract = '{0}/{1}' -f $ps51CombinedPassed,$ps51CombinedTotal
if ($ps7Contract -cne '48/48' -or $ps51Contract -cne '48/48') { throw 'Adaptive V4 combined contract mismatch.' }

$manifestSha = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
$manifestValidationSha = (Get-FileHash -LiteralPath $manifestValidationPath -Algorithm SHA256).Hash.ToLowerInvariant()
$domainMapSha = (Get-FileHash -LiteralPath $domainMap -Algorithm SHA256).Hash.ToLowerInvariant()
$v4ReceiptPath = Join-Path $reviewRoot 'adaptive-control-plane-certification-v4-receipt.json'
$v4Receipt = [pscustomobject][ordered]@{
    schema_version = 4
    status = 'passed'
    head_sha = $currentHead
    static_validation = [pscustomobject][ordered]@{
        ps7_tests = $ps7Contract
        ps51_tests = $ps51Contract
        psscriptanalyzer_findings = 0
        child_v3_tests_per_runtime = 38
        capture_manifest_tests_per_runtime = 10
        python_manifest_validator = 'passed'
    }
    policy_fingerprint_sha256 = [string]$v3Result.policy_fingerprint_sha256
    deterministic_empty_replay = [bool]$v3Result.deterministic_empty_replay
    semantic_targets = [pscustomobject][ordered]@{
        requested = [int]$v3Result.semantic_targets_requested
        validated = [int]$v3Result.semantic_targets_validated
        evidence_required_for_validation = $true
    }
    control_plane = [pscustomobject][ordered]@{
        local_only_panel = [bool]$v3Result.panel_local_only
        mutation_token = [bool]$v3Result.panel_mutation_token
        stateful_hysteresis = [bool]$v3Result.hysteresis_validated
        adaptive_capture_manifest = $true
        unavailable_domain_visibility = $true
        pending_semantic_adapter_visibility = $true
    }
    capture_manifest = [pscustomobject][ordered]@{
        scenario = 'rootcause'
        domain_count = [int]$manifest.capture.domain_count
        ready_count = [int]$manifest.capture.ready_count
        pending_count = [int]$manifest.capture.pending_count
        unavailable_count = [int]$manifest.capture.unavailable_count
        domain_map_sha256 = $domainMapSha
        manifest_sha256 = $manifestSha
        validation_sha256 = $manifestValidationSha
    }
}
Write-NxbAdaptiveV4Json -Path $v4ReceiptPath -InputObject $v4Receipt

$forbiddenExtensions = @('.etl','.evtx','.xml','.jsonl','.exe','.obj','.pdb')
foreach ($file in @(Get-ChildItem -LiteralPath $reviewRoot -File -Recurse)) {
    if ($forbiddenExtensions -contains $file.Extension.ToLowerInvariant()) { throw ('Forbidden adaptive V4 review artifact: {0}' -f $file.FullName) }
    $text = Get-Content -LiteralPath $file.FullName -Raw
    foreach ($pattern in @('PCI\VEN_','USB\VID_','PNPDeviceID','DeviceID','X-NXB-Panel-Token','__NXB_PANEL_TOKEN__')) {
        if ($text -match [regex]::Escape($pattern)) { throw ('Forbidden adaptive V4 review content in {0}: {1}' -f $file.Name,$pattern) }
    }
}

$reviewZip = [IO.Path]::GetFullPath([string]$v3Result.review_zip_path)
if (Test-Path -LiteralPath $reviewZip) { Remove-Item -LiteralPath $reviewZip -Force }
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
$reviewZipSha = (Get-FileHash -LiteralPath $reviewZip -Algorithm SHA256).Hash.ToLowerInvariant()
$v4ReceiptSha = (Get-FileHash -LiteralPath $v4ReceiptPath -Algorithm SHA256).Hash.ToLowerInvariant()

Write-Information -InformationAction Continue -MessageData ('NXB adaptive V4 certification passed: PS7={0} PS5.1={1} manifest={2}/{3}/{4} targets=8/validated=0' -f $ps7Contract,$ps51Contract,$manifest.capture.ready_count,$manifest.capture.pending_count,$manifest.capture.unavailable_count)

$result = [pscustomobject][ordered]@{
    status = 'passed'
    head_sha = $currentHead
    ps7_tests = $ps7Contract
    ps51_tests = $ps51Contract
    psscriptanalyzer_findings = 0
    policy_fingerprint_sha256 = [string]$v3Result.policy_fingerprint_sha256
    deterministic_empty_replay = [bool]$v3Result.deterministic_empty_replay
    semantic_targets_requested = 8
    semantic_targets_validated = 0
    panel_local_only = [bool]$v3Result.panel_local_only
    panel_mutation_token = [bool]$v3Result.panel_mutation_token
    hysteresis_validated = [bool]$v3Result.hysteresis_validated
    capture_manifest_validated = $true
    capture_manifest_ready_count = [int]$manifest.capture.ready_count
    capture_manifest_pending_count = [int]$manifest.capture.pending_count
    capture_manifest_unavailable_count = [int]$manifest.capture.unavailable_count
    capture_manifest_sha256 = $manifestSha
    capture_manifest_validation_sha256 = $manifestValidationSha
    domain_map_sha256 = $domainMapSha
    receipt_sha256 = $v4ReceiptSha
    review_zip_sha256 = $reviewZipSha
    review_zip_path = $reviewZip
}
if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 20
