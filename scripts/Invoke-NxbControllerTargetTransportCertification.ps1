[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbTransportCertificationAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-NxbTransportCertificationNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string[]]$ArgumentList)

    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativePreferenceAvailable = ($null -ne $nativePreferenceVariable)
    $previousNativePreference = if ($nativePreferenceAvailable) { [bool]$nativePreferenceVariable.Value } else { $null }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local }
        $nativeOutput = @(& $Executable @ArgumentList 2>&1)
        $nativeExitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local }
    }
    return [pscustomobject][ordered]@{ exit_code=$nativeExitCode; output=(@($nativeOutput | ForEach-Object { [string]$_ }) -join "`n") }
}

function Invoke-NxbTransportCertificationPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-transport-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
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
        $native = Invoke-NxbTransportCertificationNative -Executable $Executable -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,'-TestPath',$TestPath,'-ResultPath',$resultPath,'-ExpectedCount',[string]$ExpectedCount)
        if ($native.exit_code -ne 0) { throw ('{0} Pester failed: exit={1}`n{2}' -f $Label,$native.exit_code,$native.output) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Write-NxbTransportCertificationJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($fullPath,(($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

if ($env:OS -cne 'Windows_NT') { throw 'Part 3 controller/target transport certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Part 3 controller/target transport certification requires PowerShell 7.' }
if (-not (Test-NxbTransportCertificationAdministrator)) { throw 'Part 3 certification requires elevated PowerShell 7 because inherited Part 2 native authority is mandatory.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Part 3 exact-head mismatch. Expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Part 3 certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$workRoot = $outputFull + '-work'
$part2Output = $outputFull + '-part2'
$transportOutput = $outputFull + '-transport'
$reviewZip = $outputFull + '-review.zip'
foreach ($reserved in @($outputFull,$workRoot,$part2Output,$transportOutput,$reviewZip)) {
    if (Test-Path -LiteralPath $reserved) { throw ('Part 3 reserved output already exists: {0}' -f $reserved) }
}
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$configPath = Join-Path $repositoryRoot 'config\nxb-controller-target-transport.json'
$commonPath = Join-Path $PSScriptRoot 'NxbControllerTargetTransport.Common.ps1'
$targetPath = Join-Path $PSScriptRoot 'Start-NxbControllerTargetTransportTarget.ps1'
$experimentPath = Join-Path $PSScriptRoot 'Invoke-NxbControllerTargetTransportExperiment.ps1'
$testPath = Join-Path $repositoryRoot 'tests\ControllerTargetTransport.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_controller_target_transport.py'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$signaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$part2Runner = Join-Path $PSScriptRoot 'Invoke-NxbSemanticHardeningCertificationV2.ps1'
$authorityPaths = @($PSCommandPath,$commonPath,$targetPath,$experimentPath,$testPath)
foreach ($requiredPath in @($configPath,$validatorPath,$scannerPath,$signaturePath,$part2Runner) + $authorityPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Part 3 component missing: {0}' -f $requiredPath) }
}

Write-Information -InformationAction Continue -MessageData '=== NXB IRL-006 PART 3 CONTROLLER/TARGET TRANSPORT CERTIFICATION ==='
Write-Information -InformationAction Continue -MessageData '[1/7] Parser + PSScriptAnalyzer + JSON/Python syntax + known-error preflight'
foreach ($scriptPath in $authorityPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('Part 3 parser failed: {0}`n{1}' -f $scriptPath,(@($parseErrors | ForEach-Object { $_.Message }) -join "`n")) }
}
if (-not (Get-Module -Name PSScriptAnalyzer)) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
}
$analyzerFinding = @(foreach ($scriptPath in $authorityPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFinding.Count -gt 0) { throw ('Part 3 PSScriptAnalyzer findings: {0}`n{1}' -f $analyzerFinding.Count,(@($analyzerFinding | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")) }
[void](Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json)
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = [string]$pythonCommand.Source
$compile = Invoke-NxbTransportCertificationNative -Executable $pythonPath -ArgumentList @('-m','py_compile',$validatorPath)
if ($compile.exit_code -ne 0) { throw ('Part 3 Python validator syntax failed: {0}' -f $compile.output) }
$scanPath = Join-Path $workRoot 'known-error-scan.json'
$scan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -OutputPath $scanPath -NoThrow -PassThru
if ([string]$scan.status -cne 'passed' -or [int]$scan.finding_count -ne 0) {
    $detail = @($scan.findings | ForEach-Object { '{0} {1}:{2} {3}' -f $_.id,$_.path,$_.line,$_.preview }) -join [Environment]::NewLine
    throw ('Part 3 known-error preflight failed: findings={0}{1}{2}' -f [int]$scan.finding_count,[Environment]::NewLine,$detail)
}

Write-Information -InformationAction Continue -MessageData '[2/7] Dual-runtime Part 3 source contract'
$previousTransportRoot = [Environment]::GetEnvironmentVariable('NXB_TRANSPORT_REPOSITORY_ROOT','Process')
$env:NXB_TRANSPORT_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Contract = Invoke-NxbTransportCertificationPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 16 -Label 'Part 3 PS7'
    $ps51Contract = Invoke-NxbTransportCertificationPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 16 -Label 'Part 3 PS5.1'
}
finally {
    if ($null -eq $previousTransportRoot) { Remove-Item Env:NXB_TRANSPORT_REPOSITORY_ROOT -ErrorAction SilentlyContinue } else { $env:NXB_TRANSPORT_REPOSITORY_ROOT = $previousTransportRoot }
}

Write-Information -InformationAction Continue -MessageData '[3/7] Re-certify inherited Part 2 semantic hardening on the same exact head'
$part2Pipeline = @(& $part2Runner -ExpectedHead $ExpectedHead -OutputDirectory $part2Output -PassThru)
$part2Result = $null
foreach ($item in $part2Pipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $part2Result = $item }
}
if ($null -eq $part2Result -or [string]$part2Result.head_sha -cne $currentHead -or [int]$part2Result.requested -ne 8 -or [int]$part2Result.validated -ne 8) {
    throw 'Inherited Part 2 semantic-hardening authority did not pass 8/8 on the Part 3 exact head.'
}

Write-Information -InformationAction Continue -MessageData '[4/7] Real loopback controller/target transport experiment'
$experimentPipeline = @(& $experimentPath -ConfigPath $configPath -OutputDirectory $transportOutput -PassThru)
$experiment = $null
foreach ($item in $experimentPipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $experiment = $item }
}
if ($null -eq $experiment) { throw 'Part 3 transport experiment returned no passed result.' }
$experimentReviewPath = Join-Path $transportOutput 'review\controller-target-transport-experiment.json'
if (-not (Test-Path -LiteralPath $experimentReviewPath -PathType Leaf)) { throw 'Part 3 transport experiment review evidence is missing.' }

Write-Information -InformationAction Continue -MessageData '[5/7] Independent transport evidence replay'
$validationPath = Join-Path $workRoot 'controller-target-transport-validation.json'
$validationRun = Invoke-NxbTransportCertificationNative -Executable $pythonPath -ArgumentList @($validatorPath,'--config',$configPath,'--experiment',$experimentReviewPath,'--output',$validationPath)
if ($validationRun.exit_code -ne 0) { throw ('Independent Part 3 transport validator failed: {0}' -f $validationRun.output) }
$validation = Get-Content -LiteralPath $validationPath -Raw | ConvertFrom-Json
if ([string]$validation.status -cne 'passed' -or [int]$validation.negative_controls_validated -ne 9) { throw 'Independent Part 3 transport validation did not pass 9/9 fail-closed controls.' }
foreach ($name in @('authenticated_channel','monotonic_sequence','duplicate_detection','loss_detection','bounded_queue','backpressure','local_spool','emergency_stop','interrupted_transfer_recovery')) {
    if (-not [bool]$validation.PSObject.Properties[$name].Value) { throw ('Part 3 transport requirement did not validate: {0}' -f $name) }
}

Write-Information -InformationAction Continue -MessageData '[6/7] Build bounded JSON-only review evidence'
$reviewRoot = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
$reviewExperimentPath = Join-Path $reviewRoot 'controller-target-transport-experiment.json'
$reviewValidationPath = Join-Path $reviewRoot 'controller-target-transport-validation.json'
$reviewScanPath = Join-Path $reviewRoot 'known-error-scan.json'
Copy-Item -LiteralPath $experimentReviewPath -Destination $reviewExperimentPath
Copy-Item -LiteralPath $validationPath -Destination $reviewValidationPath
Copy-Item -LiteralPath $scanPath -Destination $reviewScanPath
$receiptPath = Join-Path $reviewRoot 'controller-target-transport-certification-receipt.json'
$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    contract_id = [string]$validation.contract_id
    scope = [string]$validation.scope
    part3_contract = [pscustomobject][ordered]@{
        ps7 = ('{0}/{1}' -f $ps7Contract.passed,$ps7Contract.total)
        ps51 = ('{0}/{1}' -f $ps51Contract.passed,$ps51Contract.total)
        psscriptanalyzer_findings = 0
        known_error_rule_count = [int]$scan.rule_count
        known_error_findings = [int]$scan.finding_count
    }
    inherited_part2 = [pscustomobject][ordered]@{
        status = [string]$part2Result.status
        head_sha = [string]$part2Result.head_sha
        requested = [int]$part2Result.requested
        validated = [int]$part2Result.validated
        ps7 = [string]$part2Result.ps7_tests
        ps51 = [string]$part2Result.ps51_tests
    }
    transport = [pscustomobject][ordered]@{
        authenticated_channel = [bool]$validation.authenticated_channel
        monotonic_sequence = [bool]$validation.monotonic_sequence
        duplicate_detection = [bool]$validation.duplicate_detection
        loss_detection = [bool]$validation.loss_detection
        bounded_queue = [bool]$validation.bounded_queue
        backpressure = [bool]$validation.backpressure
        local_spool = [bool]$validation.local_spool
        emergency_stop = [bool]$validation.emergency_stop
        interrupted_transfer_recovery = [bool]$validation.interrupted_transfer_recovery
        negative_controls_validated = [int]$validation.negative_controls_validated
    }
    experiment_sha256 = (Get-FileHash -LiteralPath $reviewExperimentPath -Algorithm SHA256).Hash.ToLowerInvariant()
    validation_sha256 = (Get-FileHash -LiteralPath $reviewValidationPath -Algorithm SHA256).Hash.ToLowerInvariant()
    validator_implementation_sha256 = (Get-FileHash -LiteralPath $validatorPath -Algorithm SHA256).Hash.ToLowerInvariant()
    production_secret_claimed = $false
}
Write-NxbTransportCertificationJson -Path $receiptPath -InputObject $receipt
Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZip -CompressionLevel Optimal
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($reviewZip)
try {
    $zipEntries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName.Replace('\','/') } | Sort-Object)
}
finally { $zip.Dispose() }
$expectedEntries = @('controller-target-transport-certification-receipt.json','controller-target-transport-experiment.json','controller-target-transport-validation.json','known-error-scan.json')
if (($zipEntries -join "`n") -cne (($expectedEntries | Sort-Object) -join "`n")) { throw ('Part 3 review ZIP content mismatch: {0}' -f ($zipEntries -join ', ')) }
if (@($zipEntries | Where-Object { -not $_.EndsWith('.json',[StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { throw 'Part 3 review ZIP contains non-JSON content.' }

Write-Information -InformationAction Continue -MessageData '[7/7] Final exact-tree zero-error scan'
$finalScan = & $scannerPath -RepositoryRoot $repositoryRoot -SignaturePath $signaturePath -NoThrow -PassThru
if ([string]$finalScan.status -cne 'passed' -or [int]$finalScan.finding_count -ne 0) { throw ('Part 3 final known-error scan failed: findings={0}' -f [int]$finalScan.finding_count) }

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    ps7_tests = ('{0}/{1}' -f $ps7Contract.passed,$ps7Contract.total)
    ps51_tests = ('{0}/{1}' -f $ps51Contract.passed,$ps51Contract.total)
    psscriptanalyzer_findings = 0
    known_error_rule_count = [int]$finalScan.rule_count
    known_error_finding_count = [int]$finalScan.finding_count
    inherited_part2_status = [string]$part2Result.status
    inherited_part2_head = [string]$part2Result.head_sha
    inherited_part2_requested = [int]$part2Result.requested
    inherited_part2_validated = [int]$part2Result.validated
    authenticated_channel = [bool]$validation.authenticated_channel
    monotonic_sequence = [bool]$validation.monotonic_sequence
    duplicate_detection = [bool]$validation.duplicate_detection
    loss_detection = [bool]$validation.loss_detection
    bounded_queue = [bool]$validation.bounded_queue
    backpressure = [bool]$validation.backpressure
    local_spool = [bool]$validation.local_spool
    emergency_stop = [bool]$validation.emergency_stop
    interrupted_transfer_recovery = [bool]$validation.interrupted_transfer_recovery
    negative_controls_validated = [int]$validation.negative_controls_validated
    review_zip_path = $reviewZip
    review_zip_sha256 = (Get-FileHash -LiteralPath $reviewZip -Algorithm SHA256).Hash.ToLowerInvariant()
    receipt_path = $receiptPath
    receipt_sha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    transport_output = $transportOutput
    part2_output = $part2Output
    work_root = $workRoot
}
Write-Information -InformationAction Continue -MessageData 'NXB IRL-006 Part 3 controller/target transport certification passed: requirements=9/9 negative_controls=9/9.'
if ($PassThru) { return $result }
Write-Output $reviewZip
