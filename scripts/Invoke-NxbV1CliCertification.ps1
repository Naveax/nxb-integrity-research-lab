[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Invoke-NxbV1CliNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string[]]$ArgumentList)
    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativePreferenceAvailable = ($null -ne $nativePreferenceVariable)
    $previousNativePreference = $null
    if ($nativePreferenceAvailable) { $previousNativePreference = [bool]$nativePreferenceVariable.Value }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local }
        $nativeOutput = @(& $Executable @ArgumentList 2>&1)
        $nativeExitCode = 1
        if ($null -ne $LASTEXITCODE) { $nativeExitCode = [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local }
    }
    return [pscustomobject][ordered]@{ exit_code=$nativeExitCode; output=(@($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
}

function Invoke-NxbV1CliPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$TestPath,
        [Parameter(Mandatory)][int]$ExpectedCount,
        [Parameter(Mandatory)][string]$Label
    )
    $tempRoot = Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('nxb-v1-cli-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $runnerPath = Join-Path -Path $tempRoot -ChildPath 'run.ps1'
    $resultPath = Join-Path -Path $tempRoot -ChildPath 'result.json'
    @'
param([string]$RepositoryRoot,[string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
$ErrorActionPreference='Stop'
$env:NXB_V1_CLI_REPOSITORY_ROOT=$RepositoryRoot
Import-Module Pester -ErrorAction Stop
$result=Invoke-Pester -Path $TestPath -PassThru
$summary=[pscustomobject][ordered]@{ passed=[int]$result.PassedCount; failed=[int]$result.FailedCount; skipped=[int]$result.SkippedCount; total=[int]$result.TotalCount }
[IO.File]::WriteAllText($ResultPath,(($summary|ConvertTo-Json -Depth 4)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
if ($summary.passed -ne $ExpectedCount -or $summary.total -ne $ExpectedCount -or $summary.failed -ne 0 -or $summary.skipped -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $runnerPath -Encoding UTF8
    try {
        $native = Invoke-NxbV1CliNative -Executable $Executable -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,'-RepositoryRoot',$RepositoryRoot,'-TestPath',$TestPath,'-ResultPath',$resultPath,'-ExpectedCount',[string]$ExpectedCount)
        if ($native.exit_code -ne 0) { throw ('{0} Pester failed: exit={1}{2}{3}' -f $Label,$native.exit_code,[Environment]::NewLine,$native.output) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force } }
}

function Get-NxbV1CliCertSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-NxbV1CliCertJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$Value)
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),(($Value | ConvertTo-Json -Depth 32)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

function Invoke-NxbV1CliSuccessorScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [Parameter(Mandatory)][string]$ExpectedContractId,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $document = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
    if ([int]$document.schema_version -ne 1 -or [string]$document.contract_id -cne $ExpectedContractId) { throw ('CLI successor signature identity drift: {0}' -f $ExpectedContractId) }
    $findings = [Collections.Generic.List[object]]::new()
    foreach ($rule in @($document.rules)) {
        $ruleRegex = [regex]::new([string]$rule.regex,[Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($relativeObject in @($rule.include)) {
            $relative = [string]$relativeObject
            $fullPath = Join-Path -Path $RepositoryRoot -ChildPath $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                $findings.Add([pscustomobject][ordered]@{ id=[string]$rule.id; path=$relative; line=0; preview='missing authority path' })
                continue
            }
            $lines = @(Get-Content -LiteralPath $fullPath)
            for ($index=0; $index -lt $lines.Count; $index++) {
                if ($ruleRegex.IsMatch([string]$lines[$index])) {
                    $findings.Add([pscustomobject][ordered]@{ id=[string]$rule.id; path=$relative; line=($index+1); preview=([string]$lines[$index]).Trim() })
                }
            }
        }
    }
    $scanStatus = 'failed'
    if ($findings.Count -eq 0) { $scanStatus = 'passed' }
    $receipt = [pscustomobject][ordered]@{ schema_version=1; status=$scanStatus; contract_id=$ExpectedContractId; rule_count=@($document.rules).Count; finding_count=$findings.Count; findings=@($findings) }
    Write-NxbV1CliCertJson -Path $OutputPath -Value $receipt
    return $receipt
}

function Invoke-NxbV1CliJsonCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string]$CliPath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][int]$ExpectedExitCode,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $nativeArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$CliPath,'-CliProcess','-Json') + $Arguments
    $run = Invoke-NxbV1CliNative -Executable $Executable -ArgumentList $nativeArgs
    if ($run.exit_code -ne $ExpectedExitCode) { throw ('CLI native exit drift: expected={0} actual={1}{2}{3}' -f $ExpectedExitCode,$run.exit_code,[Environment]::NewLine,$run.output) }
    try { $document = $run.output | ConvertFrom-Json }
    catch { throw ('CLI native JSON output is not a single valid document:{0}{1}' -f [Environment]::NewLine,$run.output) }
    if ([int]$document.exit_code -ne $ExpectedExitCode) { throw 'CLI JSON exit-code field does not match native process exit code.' }
    Write-NxbV1CliCertJson -Path $OutputPath -Value $document
    return $document
}

function Write-NxbV1CliReviewZip {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReviewRoot,[Parameter(Mandatory)][string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression
    $files = @(Get-ChildItem -LiteralPath $ReviewRoot -File)
    $names = [string[]]@($files.Name)
    [Array]::Sort($names,[StringComparer]::Ordinal)
    $stream = [IO.File]::Open($ZipPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
        try {
            foreach ($name in $names) {
                $sourcePath = Join-Path -Path $ReviewRoot -ChildPath $name
                $entry = $archive.CreateEntry($name,[IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980,1,1,0,0,0,[TimeSpan]::Zero)
                $input = [IO.File]::OpenRead($sourcePath)
                try {
                    $output = $entry.Open()
                    try { $input.CopyTo($output) }
                    finally { $output.Dispose() }
                }
                finally { $input.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }
}

if ($env:OS -cne 'Windows_NT') { throw 'NXB v1 CLI certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'NXB v1 CLI certification requires PowerShell 7.' }
$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbProductionFinalization.Common.ps1')

$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction Stop }
$git = [string]$gitCommand.Source
$currentHeadRun = Invoke-NxbV1CliNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'rev-parse','HEAD')
if ($currentHeadRun.exit_code -ne 0) { throw ('Unable to resolve CLI HEAD: {0}' -f $currentHeadRun.output) }
$currentHead = $currentHeadRun.output.Trim().ToLowerInvariant()
if ($currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('CLI exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirtyRun = Invoke-NxbV1CliNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'status','--porcelain=v1','--untracked-files=all')
if ($dirtyRun.exit_code -ne 0 -or -not [string]::IsNullOrWhiteSpace($dirtyRun.output)) { throw 'CLI certification requires a clean exact-head worktree.' }
$ancestorRun = Invoke-NxbV1CliNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'merge-base','--is-ancestor','27507531154099ab28a05cfe8e4e900d72f22e7b',$ExpectedHead)
if ($ancestorRun.exit_code -ne 0) { throw 'Native-certified update predecessor is not an ancestor of CLI candidate.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$workRoot = $outputFull + '-work'
$reviewRoot = $outputFull + '-review'
$reviewZip = $outputFull + '-review.zip'
foreach ($reserved in @($outputFull,$workRoot,$reviewRoot,$reviewZip)) { if (Test-Path -LiteralPath $reserved) { throw ('Reserved CLI output already exists: {0}' -f $reserved) } }
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$policyPath = Join-Path $repositoryRoot 'config\nxb-v1-cli-policy.json'
$outputSchemaPath = Join-Path $repositoryRoot 'schemas\nxb-v1-cli-output.schema.json'
$configSchemaPath = Join-Path $repositoryRoot 'schemas\nxb-v1-cli-config.schema.json'
$certificationSchemaPath = Join-Path $repositoryRoot 'schemas\nxb-v1-cli-certification-receipt.schema.json'
$exampleConfigPath = Join-Path $repositoryRoot 'config\nxb-v1-cli.example.json'
$cliErrorPath = Join-Path $repositoryRoot 'config\nxb-v1-cli-known-error-signatures.json'
$releaseErrorPath = Join-Path $repositoryRoot 'config\nxb-v1-release-known-error-signatures.json'
$signingErrorPath = Join-Path $repositoryRoot 'config\nxb-v1-signing-known-error-signatures.json'
$installerErrorPath = Join-Path $repositoryRoot 'config\nxb-v1-installer-known-error-signatures.json'
$updateErrorPath = Join-Path $repositoryRoot 'config\nxb-v1-update-known-error-signatures.json'
$baseSignaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$productionConfigPath = Join-Path $repositoryRoot 'config\nxb-production-known-error-extension.json'
$commonPath = Join-Path $PSScriptRoot 'NxbV1Cli.Common.ps1'
$cliPath = Join-Path $PSScriptRoot 'nxb.ps1'
$scannerPath = Join-Path $PSScriptRoot 'Invoke-NxbV1CliKnownErrorScan.ps1'
$testPath = Join-Path $repositoryRoot 'tests\V1Cli.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_v1_cli.py'
$baseScannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$productionScannerPath = Join-Path $PSScriptRoot 'Invoke-NxbProductionKnownErrorScan.ps1'
foreach ($requiredPath in @($policyPath,$outputSchemaPath,$configSchemaPath,$certificationSchemaPath,$exampleConfigPath,$cliErrorPath,$releaseErrorPath,$signingErrorPath,$installerErrorPath,$updateErrorPath,$baseSignaturePath,$productionConfigPath,$commonPath,$cliPath,$scannerPath,$testPath,$validatorPath,$baseScannerPath,$productionScannerPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('CLI authority component missing: {0}' -f $requiredPath) }
}

Write-Information '=== NXB V1 CLI CERTIFICATION ==='
Write-Information '[1/7] Parser, analyzer, policy/schema, Python and all known-error gates'
$authorityPaths = @($PSCommandPath,$commonPath,$cliPath,$scannerPath,$testPath)
foreach ($scriptPath in $authorityPaths) {
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('CLI parser failed: {0}{1}{2}' -f $scriptPath,[Environment]::NewLine,(@($parseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine)) }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$analyzerFindings = @(foreach ($scriptPath in $authorityPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFindings.Count -gt 0) { throw ('CLI PSScriptAnalyzer findings: {0}{1}{2}' -f $analyzerFindings.Count,[Environment]::NewLine,(@($analyzerFindings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join [Environment]::NewLine)) }
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
if ([string]$policy.contract_id -cne 'nxb-v1-cli-v1' -or [string]$policy.predecessor_update_head -cne '27507531154099ab28a05cfe8e4e900d72f22e7b' -or @($policy.commands).Count -ne 13) { throw 'CLI policy identity/predecessor/command drift.' }
foreach ($schemaPath in @($outputSchemaPath,$configSchemaPath,$certificationSchemaPath)) { $schema=Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json; if ([bool]$schema.additionalProperties) { throw ('CLI schema permits unknown fields: {0}' -f $schemaPath) } }
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = [string]$pythonCommand.Source
$compile = Invoke-NxbV1CliNative -Executable $pythonPath -ArgumentList @('-m','py_compile',$validatorPath)
if ($compile.exit_code -ne 0) { throw ('CLI Python syntax failed:{0}{1}' -f [Environment]::NewLine,$compile.output) }

$baseScanPath = Join-Path $workRoot 'base-known-error-scan.json'
$baseScan = & $baseScannerPath -RepositoryRoot $repositoryRoot -SignaturePath $baseSignaturePath -OutputPath $baseScanPath -NoThrow -PassThru
$productionScanPath = Join-Path $workRoot 'production-known-error-scan.json'
$productionScan = & $productionScannerPath -RepositoryRoot $repositoryRoot -ConfigurationPath $productionConfigPath -OutputPath $productionScanPath -NoThrow -PassThru
$releaseScanPath = Join-Path $workRoot 'release-known-error-scan.json'
$releaseScan = Invoke-NxbV1CliSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $releaseErrorPath -ExpectedContractId 'nxb-v1-release-known-error-signatures-v1' -OutputPath $releaseScanPath
$signingScanPath = Join-Path $workRoot 'signing-known-error-scan.json'
$signingScan = Invoke-NxbV1CliSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $signingErrorPath -ExpectedContractId 'nxb-v1-signing-known-error-signatures-v1' -OutputPath $signingScanPath
$installerScanPath = Join-Path $workRoot 'installer-known-error-scan.json'
$installerScan = Invoke-NxbV1CliSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $installerErrorPath -ExpectedContractId 'nxb-v1-installer-known-error-signatures-v1' -OutputPath $installerScanPath
$updateScanPath = Join-Path $workRoot 'update-known-error-scan.json'
$updateScan = Invoke-NxbV1CliSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $updateErrorPath -ExpectedContractId 'nxb-v1-update-known-error-signatures-v1' -OutputPath $updateScanPath
$cliScanPath = Join-Path $workRoot 'cli-known-error-scan.json'
$cliScan = & $scannerPath -RepositoryRoot $repositoryRoot -ConfigurationPath $cliErrorPath -NoThrow -PassThru
Write-NxbV1CliCertJson -Path $cliScanPath -Value $cliScan
if ([string]$baseScan.status -cne 'passed' -or [int]$baseScan.rule_count -lt 23 -or [int]$baseScan.finding_count -ne 0) { throw 'CLI inherited base known-error gate failed.' }
if ([string]$productionScan.status -cne 'passed' -or [int]$productionScan.extension_rule_count -ne 9 -or [int]$productionScan.schema_contract_count -ne 1 -or [int]$productionScan.guard_contract_count -ne 1 -or [int]$productionScan.finding_count -ne 0) { throw 'CLI inherited production known-error gate failed.' }
if ([string]$releaseScan.status -cne 'passed' -or [int]$releaseScan.rule_count -ne 1 -or [int]$releaseScan.finding_count -ne 0) { throw 'CLI release known-error gate failed.' }
if ([string]$signingScan.status -cne 'passed' -or [int]$signingScan.rule_count -ne 2 -or [int]$signingScan.finding_count -ne 0) { throw 'CLI signing known-error gate failed.' }
if ([string]$installerScan.status -cne 'passed' -or [int]$installerScan.rule_count -ne 4 -or [int]$installerScan.finding_count -ne 0) { throw 'CLI installer known-error gate failed.' }
if ([string]$updateScan.status -cne 'passed' -or [int]$updateScan.rule_count -ne 7 -or [int]$updateScan.finding_count -ne 0) { throw 'CLI update known-error gate failed.' }
if ([string]$cliScan.status -cne 'passed' -or [int]$cliScan.rule_count -ne 4 -or [int]$cliScan.finding_count -ne 0) { throw 'CLI successor known-error gate failed.' }

Write-Information '[2/7] Dual-runtime exact 24-test CLI contract'
$pwshCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -eq $pwshCommand) { $pwshCommand = Get-Command pwsh -ErrorAction Stop }
$pwshPath = [string]$pwshCommand.Source
$ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 executable is missing.' }
$ps7Result = Invoke-NxbV1CliPester -Executable $pwshPath -RepositoryRoot $repositoryRoot -TestPath $testPath -ExpectedCount 24 -Label 'PS7'
$ps51Result = Invoke-NxbV1CliPester -Executable $ps51Path -RepositoryRoot $repositoryRoot -TestPath $testPath -ExpectedCount 24 -Label 'PS5.1'
if ([int]$ps7Result.passed -ne 24 -or [int]$ps7Result.total -ne 24 -or [int]$ps7Result.failed -ne 0 -or [int]$ps7Result.skipped -ne 0) { throw 'CLI PS7 24-test summary drift.' }
if ([int]$ps51Result.passed -ne 24 -or [int]$ps51Result.total -ne 24 -or [int]$ps51Result.failed -ne 0 -or [int]$ps51Result.skipped -ne 0) { throw 'CLI PS5.1 24-test summary drift.' }

Write-Information '[3/7] Native JSON and exit-code contract on PS7 and PS5.1'
$versionPs7Path = Join-Path $workRoot 'version-ps7.json'
$versionPs7 = Invoke-NxbV1CliJsonCommand -Executable $pwshPath -CliPath $cliPath -Arguments @('-Command','version','-NonInteractive') -ExpectedExitCode 0 -OutputPath $versionPs7Path
$versionPs51Path = Join-Path $workRoot 'version-ps51.json'
$versionPs51 = Invoke-NxbV1CliJsonCommand -Executable $ps51Path -CliPath $cliPath -Arguments @('-Command','version','-NonInteractive') -ExpectedExitCode 0 -OutputPath $versionPs51Path
$usagePs7Path = Join-Path $workRoot 'usage-ps7.json'
$usagePs7 = Invoke-NxbV1CliJsonCommand -Executable $pwshPath -CliPath $cliPath -Arguments @('-Command','hash') -ExpectedExitCode 2 -OutputPath $usagePs7Path
$usagePs51Path = Join-Path $workRoot 'usage-ps51.json'
$usagePs51 = Invoke-NxbV1CliJsonCommand -Executable $ps51Path -CliPath $cliPath -Arguments @('-Command','hash') -ExpectedExitCode 2 -OutputPath $usagePs51Path
$configPs7Path = Join-Path $workRoot 'config-ps7.json'
$configPs7 = Invoke-NxbV1CliJsonCommand -Executable $pwshPath -CliPath $cliPath -Arguments @('-Command','config-validate','-ConfigPath',$exampleConfigPath) -ExpectedExitCode 0 -OutputPath $configPs7Path
$configPs51Path = Join-Path $workRoot 'config-ps51.json'
$configPs51 = Invoke-NxbV1CliJsonCommand -Executable $ps51Path -CliPath $cliPath -Arguments @('-Command','config-validate','-ConfigPath',$exampleConfigPath) -ExpectedExitCode 0 -OutputPath $configPs51Path
if ([string]$versionPs7.status -cne 'passed' -or [string]$versionPs51.status -cne 'passed' -or [string]$usagePs7.category -cne 'usage' -or [string]$usagePs51.category -cne 'usage') { throw 'CLI cross-runtime JSON/exit contract failed.' }
if ([string]$configPs7.status -cne 'passed' -or -not [bool]$configPs7.data.valid -or [string]$configPs51.status -cne 'passed' -or -not [bool]$configPs51.data.valid) { throw 'CLI cross-runtime config-validation contract failed.' }

Write-Information '[4/7] Doctor and bounded legacy stage-update dry-run'
$doctorRun = Invoke-NxbV1CliNative -Executable $pwshPath -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$cliPath,'-CliProcess','-Json','-Command','doctor','-NonInteractive')
if ($doctorRun.exit_code -ne 0) { throw ('CLI doctor failed:{0}{1}' -f [Environment]::NewLine,$doctorRun.output) }
$doctorDoc = $doctorRun.output | ConvertFrom-Json
if ([string]$doctorDoc.status -cne 'passed' -or [string]$doctorDoc.data.status -cne 'passed') { throw 'CLI doctor output contract failed.' }
$legacyManifestPath = Join-Path $workRoot 'legacy-package-manifest.json'
$cliItem = Get-Item -LiteralPath $cliPath
$legacyManifest = [pscustomobject][ordered]@{
    schema_version=1
    version='1.0.0'
    exact_head=$ExpectedHead.ToLowerInvariant()
    signer_fingerprint_sha256=Get-NxbFinalSha256Text -Text 'nxb-v1-cli-certification-legacy-stage-v1'
    staged_only=$true
    auto_apply=$false
    rollback=[pscustomobject][ordered]@{ previous_certified_head='27507531154099ab28a05cfe8e4e900d72f22e7b'; rollback_requires_explicit_operator=$true }
    files=@([pscustomobject][ordered]@{ path='scripts/nxb.ps1'; name='nxb.ps1'; bytes=[int64]$cliItem.Length; sha256=Get-NxbFinalFileSha256 -Path $cliPath })
}
if (-not (Test-NxbFinalPackageManifest -Manifest $legacyManifest -ExpectedVersion '1.0.0')) { throw 'CLI bounded legacy stage fixture manifest is invalid.' }
Write-NxbV1CliCertJson -Path $legacyManifestPath -Value $legacyManifest
$legacyStageRoot = Join-Path $workRoot 'legacy-stage-root'
$dryRunPs7Path = Join-Path $workRoot 'dry-run-stage-ps7.json'
$dryRunPs7 = Invoke-NxbV1CliJsonCommand -Executable $pwshPath -CliPath $cliPath -Arguments @('-Command','stage-update','-Path',$legacyManifestPath,'-ExpectedVersion','1.0.0','-StagingRoot',$legacyStageRoot,'-DryRun','-NonInteractive') -ExpectedExitCode 0 -OutputPath $dryRunPs7Path
if ([bool]$dryRunPs7.mutation_performed -or [bool]$dryRunPs7.data.auto_apply -or -not [bool]$dryRunPs7.data.dry_run -or (Test-Path -LiteralPath $legacyStageRoot)) { throw 'CLI dry-run mutation boundary failed.' }

Write-Information '[5/7] Build certification receipt and independent Python 14/14 + 10/10 replay'
$receiptPath = Join-Path $outputFull 'cli-certification-receipt.json'
$receipt = [pscustomobject][ordered]@{
    schema_version=1; status='passed'; contract_id='nxb-v1-cli-certification-v1'; head_sha=$ExpectedHead.ToLowerInvariant(); predecessor_update_head='27507531154099ab28a05cfe8e4e900d72f22e7b';
    ps7='24/24'; ps51='24/24'; independent_requirements=14; independent_negative_controls=10;
    base_known_error_rules=[int]$baseScan.rule_count; production_known_error_rules=[int]$productionScan.extension_rule_count; production_schema_contracts=[int]$productionScan.schema_contract_count; production_guard_contracts=[int]$productionScan.guard_contract_count;
    release_known_error_rules=[int]$releaseScan.rule_count; signing_known_error_rules=[int]$signingScan.rule_count; installer_known_error_rules=[int]$installerScan.rule_count; update_known_error_rules=[int]$updateScan.rule_count; cli_known_error_rules=[int]$cliScan.rule_count;
    known_error_findings=0; analyzer_findings=0; legacy_commands_preserved=$true; signed_update_delegation=$true; stable_json_output=$true; stable_exit_codes=$true; explicit_mutation_confirmation=$true; dry_run_supported=$true; auto_apply=$false; production_release_updated=$false; review_entries=20
}
Write-NxbV1CliCertJson -Path $receiptPath -Value $receipt
$independentPath = Join-Path $outputFull 'cli-independent-validation.json'
$independentRun = Invoke-NxbV1CliNative -Executable $pythonPath -ArgumentList @($validatorPath,'--repository-root',$repositoryRoot,'--expected-head',$ExpectedHead.ToLowerInvariant(),'--receipt',$receiptPath,'--version-json',$versionPs7Path,'--usage-json',$usagePs7Path,'--config-json',$configPs7Path,'--dry-run-json',$dryRunPs7Path)
if ($independentRun.exit_code -ne 0) { throw ('CLI independent validator failed:{0}{1}' -f [Environment]::NewLine,$independentRun.output) }
try { $independent = $independentRun.output | ConvertFrom-Json }
catch { throw ('CLI independent validator output is invalid JSON:{0}{1}' -f [Environment]::NewLine,$independentRun.output) }
if ([string]$independent.status -cne 'passed' -or [int]$independent.requirements_validated -ne 14 -or [int]$independent.negative_controls_validated -ne 10 -or -not [bool]$independent.receipt_valid) { throw 'CLI independent validation closure failed.' }
Write-NxbV1CliCertJson -Path $independentPath -Value $independent

Write-Information '[6/7] Build exact 20-entry review ZIP'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
$reviewMap = [ordered]@{
    'base-known-error-scan.json'=$baseScanPath; 'production-known-error-scan.json'=$productionScanPath; 'release-known-error-scan.json'=$releaseScanPath; 'signing-known-error-scan.json'=$signingScanPath; 'installer-known-error-scan.json'=$installerScanPath;
    'update-known-error-scan.json'=$updateScanPath; 'cli-known-error-scan.json'=$cliScanPath; 'cli-policy.json'=$policyPath; 'cli-output-schema.json'=$outputSchemaPath; 'cli-config-schema.json'=$configSchemaPath;
    'cli-certification-schema.json'=$certificationSchemaPath; 'version-ps7.json'=$versionPs7Path; 'version-ps51.json'=$versionPs51Path; 'usage-ps7.json'=$usagePs7Path; 'usage-ps51.json'=$usagePs51Path;
    'config-ps7.json'=$configPs7Path; 'config-ps51.json'=$configPs51Path; 'dry-run-stage-ps7.json'=$dryRunPs7Path; 'cli-independent-validation.json'=$independentPath; 'cli-certification-receipt.json'=$receiptPath
}
if ($reviewMap.Count -ne 20) { throw 'CLI review map cardinality drift.' }
foreach ($entry in $reviewMap.GetEnumerator()) { [IO.File]::Copy([string]$entry.Value,(Join-Path -Path $reviewRoot -ChildPath ([string]$entry.Key)),$false) }
Write-NxbV1CliReviewZip -ReviewRoot $reviewRoot -ZipPath $reviewZip

Write-Information '[7/7] Final CLI certification closure'
$zipEntries = @()
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($reviewZip)
try { $zipEntries = @($zip.Entries | ForEach-Object { [string]$_.FullName }) }
finally { $zip.Dispose() }
if ($zipEntries.Count -ne 20) { throw ('CLI review ZIP cardinality drift: {0}' -f $zipEntries.Count) }
$expectedNames = [string[]]@($reviewMap.Keys)
[Array]::Sort($expectedNames,[StringComparer]::Ordinal)
$actualNames = [string[]]@($zipEntries)
[Array]::Sort($actualNames,[StringComparer]::Ordinal)
if (($expectedNames -join "`n") -cne ($actualNames -join "`n")) { throw 'CLI review ZIP membership drift.' }
$receiptSha = Get-NxbV1CliCertSha256 -Path $receiptPath
$reviewSha = Get-NxbV1CliCertSha256 -Path $reviewZip
Write-Information ('NXB v1 CLI certification passed: head={0} PS7=24/24 PS5.1=24/24 independent=14/14 negatives=10/10 rules=23+/9+1+1/1/2/4/7/4 findings=0 analyzer=0 review=20.' -f $ExpectedHead.ToLowerInvariant())
if ($PassThru) {
    return [pscustomobject][ordered]@{
        status='passed'; head_sha=$ExpectedHead.ToLowerInvariant(); predecessor_update_head='27507531154099ab28a05cfe8e4e900d72f22e7b'; ps7='24/24'; ps51='24/24'; independent='14/14'; negatives='10/10';
        cli_known_error_rules=4; known_error_findings=0; analyzer_findings=0; review_entries=20; receipt_path=$receiptPath; receipt_sha256=$receiptSha; review_zip=$reviewZip; review_zip_sha256=$reviewSha
    }
}
