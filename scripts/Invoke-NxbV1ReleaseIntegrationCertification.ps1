[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Invoke-NxbV1CertificationNative {
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
    }
}

function Invoke-NxbV1CertificationPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v1-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $runnerPath = Join-Path $tempRoot 'run.ps1'
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
'@ | Set-Content -LiteralPath $runnerPath -Encoding UTF8

    try {
        $native = Invoke-NxbV1CertificationNative -Executable $Executable -ArgumentList @(
            '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,
            '-TestPath',$TestPath,'-ResultPath',$resultPath,'-ExpectedCount',[string]$ExpectedCount
        )
        if ($native.exit_code -ne 0) {
            throw ('{0} Pester failed: exit={1}{2}{3}' -f $Label,$native.exit_code,[Environment]::NewLine,$native.output)
        }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

function Get-NxbV1CertificationSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

if ($env:OS -cne 'Windows_NT') { throw 'NXB v1 release integration certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'NXB v1 release integration certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction Stop }
$git = [string]$gitCommand.Source

$currentHeadRun = Invoke-NxbV1CertificationNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'rev-parse','HEAD')
if ($currentHeadRun.exit_code -ne 0) { throw ('Unable to resolve release certification HEAD: {0}' -f $currentHeadRun.output) }
$currentHead = $currentHeadRun.output.Trim().ToLowerInvariant()
if ($currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw ('NXB v1 release integration exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead)
}
$dirtyRun = Invoke-NxbV1CertificationNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'status','--porcelain=v1','--untracked-files=all')
if ($dirtyRun.exit_code -ne 0 -or -not [string]::IsNullOrWhiteSpace($dirtyRun.output)) {
    throw 'NXB v1 release integration certification requires a clean exact-head worktree.'
}

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$workRoot = $outputFull + '-work'
$reviewRoot = $outputFull + '-review'
$reviewZip = $outputFull + '-review.zip'
foreach ($reserved in @($outputFull,$workRoot,$reviewRoot,$reviewZip)) {
    if (Test-Path -LiteralPath $reserved) { throw ('NXB v1 release integration reserved output already exists: {0}' -f $reserved) }
}
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$policyPath = Join-Path $repositoryRoot 'config\nxb-v1-release-integration-policy.json'
$schemaPath = Join-Path $repositoryRoot 'schemas\nxb-v1-release-integration-receipt.schema.json'
$releaseSignaturePath = Join-Path $repositoryRoot 'config\nxb-v1-release-known-error-signatures.json'
$releaseKnownErrorDocPath = Join-Path $repositoryRoot 'docs\NXB-V1-RELEASE-KNOWN-ERRORS.md'
$preflightPath = Join-Path $PSScriptRoot 'Test-NxbV1ReleaseIntegration.ps1'
$testPath = Join-Path $repositoryRoot 'tests\V1ReleaseIntegration.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_v1_release_integration.py'
$docsPath = Join-Path $repositoryRoot 'docs\NXB-V1-RELEASE-INTEGRATION.md'
$baseScannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$baseSignaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$productionScannerPath = Join-Path $PSScriptRoot 'Invoke-NxbProductionKnownErrorScan.ps1'
$productionScannerConfigPath = Join-Path $repositoryRoot 'config\nxb-production-known-error-extension.json'
$authorityPaths = @($PSCommandPath,$preflightPath,$testPath)
foreach ($requiredPath in @(
    $policyPath,$schemaPath,$releaseSignaturePath,$releaseKnownErrorDocPath,$preflightPath,$testPath,$validatorPath,$docsPath,
    $baseScannerPath,$baseSignaturePath,$productionScannerPath,$productionScannerConfigPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw ('NXB v1 release integration component missing: {0}' -f $requiredPath)
    }
}

Write-Information '=== NXB V1 RELEASE INTEGRATION CERTIFICATION ==='
Write-Information '[1/6] Parser, analyzer, JSON/Python syntax and inherited/release known-error gates'
foreach ($scriptPath in $authorityPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw ('NXB v1 release integration parser failed: {0}{1}{2}' -f $scriptPath,[Environment]::NewLine,(@($parseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine))
    }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$analyzerFindings = @(foreach ($scriptPath in $authorityPaths) {
    Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error
})
if ($analyzerFindings.Count -gt 0) {
    throw ('NXB v1 release integration PSScriptAnalyzer findings: {0}{1}{2}' -f $analyzerFindings.Count,[Environment]::NewLine,(@($analyzerFindings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join [Environment]::NewLine))
}

$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
$schema = Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
if ([int]$policy.schema_version -ne 1 -or [string]$policy.contract_id -cne 'nxb-v1-release-integration-v1') {
    throw 'NXB v1 release integration policy identity drift.'
}
if ([bool]$schema.additionalProperties) { throw 'NXB v1 release integration receipt schema must reject unknown fields.' }

$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = [string]$pythonCommand.Source
$compile = Invoke-NxbV1CertificationNative -Executable $pythonPath -ArgumentList @('-m','py_compile',$validatorPath)
if ($compile.exit_code -ne 0) {
    throw ('NXB v1 release integration Python syntax failed:{0}{1}' -f [Environment]::NewLine,$compile.output)
}

$baseScanPath = Join-Path $workRoot 'base-known-error-scan.json'
$baseScan = & $baseScannerPath -RepositoryRoot $repositoryRoot -SignaturePath $baseSignaturePath -OutputPath $baseScanPath -NoThrow -PassThru
if ([string]$baseScan.status -cne 'passed' -or [int]$baseScan.finding_count -ne 0 -or [int]$baseScan.rule_count -lt 23) {
    throw ('NXB v1 inherited known-error gate failed: rules={0} findings={1}' -f [int]$baseScan.rule_count,[int]$baseScan.finding_count)
}
$productionScanPath = Join-Path $workRoot 'production-known-error-scan.json'
$productionScan = & $productionScannerPath -RepositoryRoot $repositoryRoot -ConfigurationPath $productionScannerConfigPath -OutputPath $productionScanPath -NoThrow -PassThru
if ([string]$productionScan.status -cne 'passed' -or [int]$productionScan.finding_count -ne 0 -or
    [int]$productionScan.extension_rule_count -ne 9 -or [int]$productionScan.schema_contract_count -ne 1 -or [int]$productionScan.guard_contract_count -ne 1) {
    throw ('NXB v1 production extension gate failed: rules={0} schemas={1} guards={2} findings={3}' -f [int]$productionScan.extension_rule_count,[int]$productionScan.schema_contract_count,[int]$productionScan.guard_contract_count,[int]$productionScan.finding_count)
}

$releaseSignatures = Get-Content -LiteralPath $releaseSignaturePath -Raw | ConvertFrom-Json
$releaseRules = @($releaseSignatures.rules)
if ($releaseRules.Count -ne 1 -or [string]$releaseRules[0].id -cne 'NXB-ERR-036') {
    throw 'NXB v1 release known-error signature contract drift.'
}
$releaseKnownErrorFindings = [Collections.Generic.List[string]]::new()
foreach ($rule in $releaseRules) {
    $regexText = [string]$rule.regex
    foreach ($relativeObject in @($rule.include)) {
        $relativePath = [string]$relativeObject
        $sourcePath = Join-Path $repositoryRoot $relativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            $releaseKnownErrorFindings.Add(('missing:{0}:{1}' -f [string]$rule.id,$relativePath))
            continue
        }
        $sourceText = Get-Content -LiteralPath $sourcePath -Raw
        if ([regex]::IsMatch($sourceText,$regexText)) {
            $releaseKnownErrorFindings.Add(('{0}:{1}' -f [string]$rule.id,$relativePath))
        }
    }
}
if ($releaseKnownErrorFindings.Count -ne 0) {
    throw ('NXB v1 release known-error gate failed: {0}' -f (@($releaseKnownErrorFindings) -join ', '))
}

$testSource = Get-Content -LiteralPath $testPath -Raw
$testCount = [regex]::Matches($testSource,"(?m)^\s*It\s+'").Count
if ($testCount -ne 16) { throw ('NXB v1 release integration test-count drift: expected=16 actual={0}' -f $testCount) }

Write-Information '[2/6] Dual-runtime 16-test release integration contract'
$previousRoot = [Environment]::GetEnvironmentVariable('NXB_V1_RELEASE_REPOSITORY_ROOT','Process')
$env:NXB_V1_RELEASE_REPOSITORY_ROOT = [IO.Path]::GetFullPath($repositoryRoot)
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Contract = Invoke-NxbV1CertificationPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 16 -Label 'NXB v1 release integration PS7'
    $ps51Contract = Invoke-NxbV1CertificationPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 16 -Label 'NXB v1 release integration PS5.1'
}
finally {
    if ($null -eq $previousRoot) { Remove-Item Env:NXB_V1_RELEASE_REPOSITORY_ROOT -ErrorAction SilentlyContinue } else { $env:NXB_V1_RELEASE_REPOSITORY_ROOT = $previousRoot }
}

Write-Information '[3/6] Execute fail-closed release integration preflight'
$preflightReceiptPath = Join-Path $workRoot 'v1-release-integration-preflight-receipt.json'
$preflightPipeline = @(& $preflightPath -RepositoryRoot $repositoryRoot -PolicyPath $policyPath -MainRef 'main' -OutputPath $preflightReceiptPath -PassThru -NoThrow)
$preflight = $null
foreach ($item in $preflightPipeline) {
    if ($null -eq $item) { continue }
    $statusProperty = $item.PSObject.Properties['status']
    if ($null -ne $statusProperty -and [string]$statusProperty.Value -ceq 'passed') { $preflight = $item }
}
if ($null -eq $preflight -or [int]$preflight.failure_count -ne 0) {
    $failureText = if ($null -eq $preflight) { 'no passed preflight result' } else { @($preflight.failures) -join ', ' }
    throw ('NXB v1 release integration preflight failed: {0}' -f $failureText)
}
if ([string]$preflight.release_head -cne $currentHead) { throw 'NXB v1 preflight release-head binding failed.' }

Write-Information '[4/6] Independent Python 10/10 + 6/6 adversarial replay'
$independentPath = Join-Path $workRoot 'v1-release-integration-independent-validation.json'
$independentRun = Invoke-NxbV1CertificationNative -Executable $pythonPath -ArgumentList @(
    $validatorPath,
    '--policy',$policyPath,
    '--receipt',$preflightReceiptPath,
    '--expected-certified-head',([string]$policy.certified_implementation_head),
    '--expected-release-head',$currentHead,
    '--output',$independentPath
)
if ($independentRun.exit_code -ne 0) {
    throw ('NXB v1 independent release integration replay failed:{0}{1}' -f [Environment]::NewLine,$independentRun.output)
}
$independent = Get-Content -LiteralPath $independentPath -Raw | ConvertFrom-Json
if ([string]$independent.status -cne 'passed' -or [int]$independent.requirements_validated -ne 10 -or
    [int]$independent.negative_controls_validated -ne 6 -or @($independent.failures).Count -ne 0) {
    throw 'NXB v1 independent release integration replay is not 10/10 + 6/6.'
}

Write-Information '[5/6] Build release integration certification receipt and bounded review ZIP'
$certificationReceiptPath = Join-Path $outputFull 'v1-release-integration-certification-receipt.json'
$certificationReceipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    authority = 'nxb-v1-release-integration-certification-v1'
    certified_implementation_head = [string]$policy.certified_implementation_head
    release_head = $currentHead
    main_head = [string]$preflight.main_head
    candidate_version = [string]$policy.candidate_version
    target_version = [string]$policy.target_version
    ps7 = ('{0}/{1}' -f [int]$ps7Contract.passed,[int]$ps7Contract.total)
    ps51 = ('{0}/{1}' -f [int]$ps51Contract.passed,[int]$ps51Contract.total)
    independent_requirements = [int]$independent.requirements_validated
    independent_negative_controls = [int]$independent.negative_controls_validated
    base_known_error_rules = [int]$baseScan.rule_count
    base_known_error_findings = [int]$baseScan.finding_count
    production_extension_rules = [int]$productionScan.extension_rule_count
    production_schema_contracts = [int]$productionScan.schema_contract_count
    production_guard_contracts = [int]$productionScan.guard_contract_count
    production_extension_findings = [int]$productionScan.finding_count
    release_known_error_rules = $releaseRules.Count
    release_known_error_findings = $releaseKnownErrorFindings.Count
    analyzer_findings = $analyzerFindings.Count
    changed_path_count = @($preflight.changed_paths).Count
    production_merge_performed = $false
    release_tag_created = $false
    production_signer_claimed = $false
    release_ready_for_integration = $true
    preflight_receipt_sha256 = Get-NxbV1CertificationSha256 -Path $preflightReceiptPath
    independent_validation_sha256 = Get-NxbV1CertificationSha256 -Path $independentPath
    created_utc = [DateTime]::UtcNow.ToString('o')
}
$certificationJson = ($certificationReceipt | ConvertTo-Json -Depth 8) + [Environment]::NewLine
[IO.File]::WriteAllText($certificationReceiptPath,$certificationJson,[Text.UTF8Encoding]::new($false))

[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
$reviewFiles = [ordered]@{
    'base-known-error-scan.json' = $baseScanPath
    'production-known-error-scan.json' = $productionScanPath
    'v1-release-integration-preflight-receipt.json' = $preflightReceiptPath
    'v1-release-integration-independent-validation.json' = $independentPath
    'v1-release-integration-certification-receipt.json' = $certificationReceiptPath
}
foreach ($entry in $reviewFiles.GetEnumerator()) {
    $sourcePath = [string]($entry.Value)
    $entryName = [string]($entry.Key)
    $destinationPath = Join-Path -Path $reviewRoot -ChildPath $entryName
    [IO.File]::Copy($sourcePath,$destinationPath,$false)
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($reviewRoot,$reviewZip,[IO.Compression.CompressionLevel]::Optimal,$false)

Write-Information '[6/6] Final review content and hash audit'
$zip = [IO.Compression.ZipFile]::OpenRead($reviewZip)
try {
    $entries = @($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName.Replace('\','/') } | Sort-Object)
}
finally {
    $zip.Dispose()
}
$expectedEntries = @($reviewFiles.Keys | Sort-Object)
if ($entries.Count -ne 5 -or ($entries -join "`n") -cne ($expectedEntries -join "`n")) {
    throw ('NXB v1 release integration review ZIP content mismatch: {0}' -f ($entries -join ', '))
}

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    authority = 'nxb-v1-release-integration-certification-v1'
    certified_implementation_head = [string]$policy.certified_implementation_head
    release_head = $currentHead
    main_head = [string]$preflight.main_head
    candidate_version = [string]$policy.candidate_version
    target_version = [string]$policy.target_version
    ps7 = '16/16'
    ps51 = '16/16'
    independent_requirements = 10
    independent_negative_controls = 6
    base_known_error_rules = [int]$baseScan.rule_count
    production_extension_rules = [int]$productionScan.extension_rule_count
    production_schema_contracts = [int]$productionScan.schema_contract_count
    production_guard_contracts = [int]$productionScan.guard_contract_count
    release_known_error_rules = $releaseRules.Count
    known_error_findings = ([int]$baseScan.finding_count + [int]$productionScan.finding_count + $releaseKnownErrorFindings.Count)
    analyzer_findings = $analyzerFindings.Count
    production_merge_performed = $false
    release_tag_created = $false
    production_signer_claimed = $false
    release_ready_for_integration = $true
    receipt_path = $certificationReceiptPath
    receipt_sha256 = Get-NxbV1CertificationSha256 -Path $certificationReceiptPath
    review_zip_path = $reviewZip
    review_zip_sha256 = Get-NxbV1CertificationSha256 -Path $reviewZip
}

Write-Information ('NXB v1 release integration certification passed: head={0} PS7=16/16 PS5.1=16/16 independent=10/10 negatives=6/6 base_rules={1} production=9+1+1 release_rules=1 findings=0 merge=false tag=false.' -f $currentHead,[int]$baseScan.rule_count)
if ($PassThru) { $result }
