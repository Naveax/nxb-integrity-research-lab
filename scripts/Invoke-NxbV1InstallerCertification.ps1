[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Invoke-NxbV1InstallerNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string[]]$ArgumentList)
    $previousErrorActionPreference=$ErrorActionPreference
    $nativePreferenceVariable=Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativePreferenceAvailable=($null -ne $nativePreferenceVariable)
    $previousNativePreference=if ($nativePreferenceAvailable) { [bool]$nativePreferenceVariable.Value } else { $null }
    try {
        $ErrorActionPreference='Continue'
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local }
        $nativeOutput=@(& $Executable @ArgumentList 2>&1)
        $nativeExitCode=if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference=$previousErrorActionPreference
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local }
    }
    return [pscustomobject][ordered]@{ exit_code=$nativeExitCode; output=(@($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
}

function Invoke-NxbV1InstallerPester {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string]$TestPath,[Parameter(Mandatory)][int]$ExpectedCount,[Parameter(Mandatory)][string]$Label)
    $tempRoot=Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('nxb-v1-installer-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $runnerPath=Join-Path -Path $tempRoot -ChildPath 'run.ps1'
    $resultPath=Join-Path -Path $tempRoot -ChildPath 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
$ErrorActionPreference='Stop'
Import-Module Pester -ErrorAction Stop
$result=Invoke-Pester -Path $TestPath -PassThru
$summary=[pscustomobject]@{ passed=[int]$result.PassedCount; failed=[int]$result.FailedCount; skipped=[int]$result.SkippedCount; total=[int]$result.TotalCount }
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($summary.passed -ne $ExpectedCount -or $summary.total -ne $ExpectedCount -or $summary.failed -ne 0 -or $summary.skipped -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $runnerPath -Encoding UTF8
    try {
        $native=Invoke-NxbV1InstallerNative -Executable $Executable -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,'-TestPath',$TestPath,'-ResultPath',$resultPath,'-ExpectedCount',[string]$ExpectedCount)
        if ($native.exit_code -ne 0) { throw ('{0} Pester failed: exit={1}{2}{3}' -f $Label,$native.exit_code,[Environment]::NewLine,$native.output) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force } }
}

function Get-NxbV1InstallerCertSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-NxbV1InstallerSuccessorScan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$ConfigurationPath,
        [Parameter(Mandatory)][string]$ExpectedContractId,
        [Parameter(Mandatory)][string]$OutputPath
    )
    $document=Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
    if ([int]$document.schema_version -ne 1 -or [string]$document.contract_id -cne $ExpectedContractId) { throw ('Successor signature identity drift: {0}' -f $ExpectedContractId) }
    $findings=[Collections.Generic.List[object]]::new()
    foreach ($rule in @($document.rules)) {
        $regex=[regex]::new([string]$rule.regex,[Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($relativeObject in @($rule.include)) {
            $relative=[string]$relativeObject
            $nativeRelative=$relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            $fullPath=Join-Path -Path $RepositoryRoot -ChildPath $nativeRelative
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                $findings.Add([pscustomobject][ordered]@{ id=[string]$rule.id; path=$relative; line=0; preview='missing authority path' })
                continue
            }
            $lines=@(Get-Content -LiteralPath $fullPath)
            for ($index=0; $index -lt $lines.Count; $index++) {
                $line=[string]$lines[$index]
                if ($regex.IsMatch($line)) { $findings.Add([pscustomobject][ordered]@{ id=[string]$rule.id; path=$relative; line=($index+1); preview=$line.Trim() }) }
            }
        }
    }
    $scanStatus='failed'
    if ($findings.Count -eq 0) { $scanStatus='passed' }
    $receipt=[pscustomobject][ordered]@{ schema_version=1; status=$scanStatus; contract_id=$ExpectedContractId; rule_count=@($document.rules).Count; finding_count=$findings.Count; findings=@($findings) }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),(($receipt | ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    return $receipt
}

if ($env:OS -cne 'Windows_NT') { throw 'NXB v1 installer certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'NXB v1 installer certification requires PowerShell 7.' }
$repositoryRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Installer.Common.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Installer.State.ps1')

$gitCommand=Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $gitCommand=Get-Command git -ErrorAction Stop }
$git=[string]$gitCommand.Source
$currentHeadRun=Invoke-NxbV1InstallerNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'rev-parse','HEAD')
if ($currentHeadRun.exit_code -ne 0) { throw ('Unable to resolve installer HEAD: {0}' -f $currentHeadRun.output) }
$currentHead=$currentHeadRun.output.Trim().ToLowerInvariant()
if ($currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Installer exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirtyRun=Invoke-NxbV1InstallerNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'status','--porcelain=v1','--untracked-files=all')
if ($dirtyRun.exit_code -ne 0 -or -not [string]::IsNullOrWhiteSpace($dirtyRun.output)) { throw 'Installer certification requires a clean exact-head worktree.' }

$outputFull=[IO.Path]::GetFullPath($OutputDirectory)
$workRoot=$outputFull+'-work'
$reviewRoot=$outputFull+'-review'
$reviewZip=$outputFull+'-review.zip'
foreach ($reserved in @($outputFull,$workRoot,$reviewRoot,$reviewZip)) { if (Test-Path -LiteralPath $reserved) { throw ('Reserved installer output already exists: {0}' -f $reserved) } }
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$policyPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-installer-policy.json'
$packageSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-package-manifest.schema.json'
$stateSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-install-state.schema.json'
$operationSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-installer-operation-receipt.schema.json'
$lifecycleSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-installer-lifecycle.schema.json'
$certificationSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-installer-certification-receipt.schema.json'
$commonPath=Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Installer.Common.ps1'
$statePath=Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Installer.State.ps1'
$exporterPath=Join-Path -Path $PSScriptRoot -ChildPath 'Export-NxbV1PackageManifest.ps1'
$hostPath=Join-Path -Path $PSScriptRoot -ChildPath 'Test-NxbV1InstallerHost.ps1'
$operatorPath=Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-NxbV1Installer.ps1'
$testPath=Join-Path -Path $repositoryRoot -ChildPath 'tests\V1Installer.Tests.ps1'
$validatorPath=Join-Path -Path $repositoryRoot -ChildPath 'tools\validate_v1_installer.py'
$baseScannerPath=Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-NxbKnownErrorScan.ps1'
$baseSignaturePath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-known-error-signatures.json'
$productionScannerPath=Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-NxbProductionKnownErrorScan.ps1'
$productionConfigPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-production-known-error-extension.json'
$releaseErrorPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-release-known-error-signatures.json'
$signingErrorPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-signing-known-error-signatures.json'
$installerErrorPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-installer-known-error-signatures.json'
$requiredPaths=@($policyPath,$packageSchemaPath,$stateSchemaPath,$operationSchemaPath,$lifecycleSchemaPath,$certificationSchemaPath,$commonPath,$statePath,$exporterPath,$hostPath,$operatorPath,$testPath,$validatorPath,$baseScannerPath,$baseSignaturePath,$productionScannerPath,$productionConfigPath,$releaseErrorPath,$signingErrorPath,$installerErrorPath)
foreach ($requiredPath in $requiredPaths) { if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Installer authority component missing: {0}' -f $requiredPath) } }

Write-Information '=== NXB V1 INSTALLER CERTIFICATION ==='
Write-Information '[1/8] Exact-tree parser, analyzer, policy/schema, Python and known-error gates'
$authorityPaths=@($PSCommandPath,$commonPath,$statePath,$exporterPath,$hostPath,$operatorPath,$testPath)
foreach ($scriptPath in $authorityPaths) {
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('Installer parser failed: {0}{1}{2}' -f $scriptPath,[Environment]::NewLine,(@($parseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine)) }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$analyzerFindings=@(foreach ($scriptPath in $authorityPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFindings.Count -gt 0) { throw ('Installer PSScriptAnalyzer findings: {0}{1}{2}' -f $analyzerFindings.Count,[Environment]::NewLine,(@($analyzerFindings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join [Environment]::NewLine)) }
$policy=Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
if ([string]$policy.contract_id -cne 'nxb-v1-installer-v1' -or [int]$policy.schema_version -ne 1) { throw 'Installer policy identity drift.' }
$predecessor=[string]$policy.predecessor_production_signing_head
$releaseIntegration=[string]$policy.release_integration_head
$certifiedImplementation=[string]$policy.certified_implementation_head
foreach ($ancestor in @($predecessor,$releaseIntegration,$certifiedImplementation)) {
    $ancestorRun=Invoke-NxbV1InstallerNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'merge-base','--is-ancestor',$ancestor,$currentHead)
    if ($ancestorRun.exit_code -ne 0) { throw ('Installer required ancestor missing: {0}' -f $ancestor) }
}
foreach ($schemaPath in @($packageSchemaPath,$stateSchemaPath,$operationSchemaPath,$lifecycleSchemaPath,$certificationSchemaPath)) {
    $schema=Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json
    if ([bool]$schema.additionalProperties) { throw ('Installer schema permits unknown fields: {0}' -f $schemaPath) }
}
$pythonCommand=Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand=Get-Command python -ErrorAction Stop }
$pythonPath=[string]$pythonCommand.Source
$compile=Invoke-NxbV1InstallerNative -Executable $pythonPath -ArgumentList @('-m','py_compile',$validatorPath)
if ($compile.exit_code -ne 0) { throw ('Installer Python syntax failed:{0}{1}' -f [Environment]::NewLine,$compile.output) }
$baseScanPath=Join-Path -Path $workRoot -ChildPath 'base-known-error-scan.json'
$baseScan=& $baseScannerPath -RepositoryRoot $repositoryRoot -SignaturePath $baseSignaturePath -OutputPath $baseScanPath -NoThrow -PassThru
if ([string]$baseScan.status -cne 'passed' -or [int]$baseScan.rule_count -lt 23 -or [int]$baseScan.finding_count -ne 0) { throw 'Installer inherited base known-error gate failed.' }
$productionScanPath=Join-Path -Path $workRoot -ChildPath 'production-known-error-scan.json'
$productionScan=& $productionScannerPath -RepositoryRoot $repositoryRoot -ConfigurationPath $productionConfigPath -OutputPath $productionScanPath -NoThrow -PassThru
if ([string]$productionScan.status -cne 'passed' -or [int]$productionScan.extension_rule_count -ne 9 -or [int]$productionScan.schema_contract_count -ne 1 -or [int]$productionScan.guard_contract_count -ne 1 -or [int]$productionScan.finding_count -ne 0) { throw 'Installer inherited production known-error gate failed.' }
$releaseScanPath=Join-Path -Path $workRoot -ChildPath 'release-known-error-scan.json'
$releaseScan=Invoke-NxbV1InstallerSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $releaseErrorPath -ExpectedContractId 'nxb-v1-release-known-error-signatures-v1' -OutputPath $releaseScanPath
$signingScanPath=Join-Path -Path $workRoot -ChildPath 'signing-known-error-scan.json'
$signingScan=Invoke-NxbV1InstallerSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $signingErrorPath -ExpectedContractId 'nxb-v1-signing-known-error-signatures-v1' -OutputPath $signingScanPath
$installerScanPath=Join-Path -Path $workRoot -ChildPath 'installer-known-error-scan.json'
$installerScan=Invoke-NxbV1InstallerSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $installerErrorPath -ExpectedContractId 'nxb-v1-installer-known-error-signatures-v1' -OutputPath $installerScanPath
if ([string]$releaseScan.status -cne 'passed' -or [int]$releaseScan.rule_count -ne 1 -or [int]$releaseScan.finding_count -ne 0) { throw 'Installer release successor scanner failed.' }
if ([string]$signingScan.status -cne 'passed' -or [int]$signingScan.rule_count -ne 2 -or [int]$signingScan.finding_count -ne 0) { throw 'Installer signing successor scanner failed.' }
if ([string]$installerScan.status -cne 'passed' -or [int]$installerScan.rule_count -ne 4 -or [int]$installerScan.finding_count -ne 0) { throw 'Installer successor scanner failed.' }

Write-Information '[2/8] Dual-runtime 22-test installer contract'
$testSource=Get-Content -LiteralPath $testPath -Raw
if ([regex]::Matches($testSource,"(?m)^\s*It\s+'").Count -ne 22) { throw 'Installer source test-count drift.' }
$previousRoot=[Environment]::GetEnvironmentVariable('NXB_V1_INSTALLER_REPOSITORY_ROOT','Process')
$env:NXB_V1_INSTALLER_REPOSITORY_ROOT=$repositoryRoot
try {
    $pwshPath=(Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path=Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Contract=Invoke-NxbV1InstallerPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 22 -Label 'NXB v1 installer PS7'
    $ps51Contract=Invoke-NxbV1InstallerPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 22 -Label 'NXB v1 installer PS5.1'
}
finally { if ($null -eq $previousRoot) { Remove-Item Env:NXB_V1_INSTALLER_REPOSITORY_ROOT -ErrorAction SilentlyContinue } else { $env:NXB_V1_INSTALLER_REPOSITORY_ROOT=$previousRoot } }
$ps7Summary=('{0}/{1}' -f [int]$ps7Contract.passed,[int]$ps7Contract.total)
$ps51Summary=('{0}/{1}' -f [int]$ps51Contract.passed,[int]$ps51Contract.total)
if ($ps7Summary -cne '22/22' -or $ps51Summary -cne '22/22') { throw 'Installer dual-runtime summary drift.' }

Write-Information '[3/8] Host dependency preflight'
$hostReceiptPath=Join-Path -Path $workRoot -ChildPath 'installer-host-preflight.json'
$hostPipeline=@(& $hostPath -OutputPath $hostReceiptPath -PassThru)
$hostReceipt=$null
foreach ($item in $hostPipeline) { if ($null -ne $item -and $null -ne $item.PSObject.Properties['authority']) { $hostReceipt=$item } }
if ($null -eq $hostReceipt -or [string]$hostReceipt.status -cne 'passed') { throw 'Installer host preflight did not return PASS.' }

Write-Information '[4/8] Build fixture package and deterministic manifest'
$fixtureRoot=Join-Path -Path $workRoot -ChildPath 'fixture'
$packageRoot=Join-Path -Path $fixtureRoot -ChildPath 'package'
[IO.Directory]::CreateDirectory((Join-Path -Path $packageRoot -ChildPath 'bin')) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path -Path $packageRoot -ChildPath 'config')) | Out-Null
$fixtureScript=Join-Path -Path $packageRoot -ChildPath 'bin\nxb.ps1'
$fixtureConfig=Join-Path -Path $packageRoot -ChildPath 'config\default.json'
[IO.File]::WriteAllText($fixtureScript,"Write-Output 'NXB installer fixture'`n",[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($fixtureConfig,"{`"schema_version`":1,`"fixture`":true}`n",[Text.UTF8Encoding]::new($false))
$manifestPath=Join-Path -Path $fixtureRoot -ChildPath 'package-manifest.json'
& $exporterPath -PackageRoot $packageRoot -SourceHead $currentHead -OutputPath $manifestPath
$manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (-not (Test-NxbV1PackageManifestObject -Manifest $manifest -MaximumFiles ([int]$policy.maximum_files) -MaximumBytes ([int64]$policy.maximum_package_bytes))) { throw 'Installer fixture manifest failed strict contract.' }
if (-not (Test-NxbV1PackageAgainstManifest -PackageRoot $packageRoot -Manifest $manifest)) { throw 'Installer fixture package does not match manifest.' }
$manifestSha=Get-NxbV1InstallerCertSha256 -Path $manifestPath

Write-Information '[5/8] Execute Portable Stage and PerUser install-corrupt-repair-uninstall lifecycle'
$stageRoot=Join-Path -Path $fixtureRoot -ChildPath 'portable-stage'
$installRoot=Join-Path -Path $fixtureRoot -ChildPath 'per-user-install'
$dataRoot=Join-Path -Path $fixtureRoot -ChildPath 'external-data'
$evidenceRoot=Join-Path -Path $fixtureRoot -ChildPath 'external-evidence'
[IO.Directory]::CreateDirectory($dataRoot) | Out-Null
[IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
$dataSentinel=Join-Path -Path $dataRoot -ChildPath 'keep.bin'
$evidenceSentinel=Join-Path -Path $evidenceRoot -ChildPath 'keep.bin'
[IO.File]::WriteAllBytes($dataSentinel,[Text.UTF8Encoding]::new($false).GetBytes("NXB-DATA-KEEP`n"))
[IO.File]::WriteAllBytes($evidenceSentinel,[Text.UTF8Encoding]::new($false).GetBytes("NXB-EVIDENCE-KEEP`n"))
$dataHashBefore=Get-NxbV1InstallerCertSha256 -Path $dataSentinel
$evidenceHashBefore=Get-NxbV1InstallerCertSha256 -Path $evidenceSentinel
$stageReceiptPath=Join-Path -Path $outputFull -ChildPath 'stage-receipt.json'
$installReceiptPath=Join-Path -Path $outputFull -ChildPath 'install-receipt.json'
$repairReceiptPath=Join-Path -Path $outputFull -ChildPath 'repair-receipt.json'
$uninstallReceiptPath=Join-Path -Path $outputFull -ChildPath 'uninstall-receipt.json'
& $operatorPath -Action Stage -Mode Portable -PackageRoot $packageRoot -ManifestPath $manifestPath -InstallRoot $stageRoot -ReceiptPath $stageReceiptPath -Confirm:$false
$portableStagePassed=(Test-NxbV1InstalledRootAgainstManifest -InstallRoot $stageRoot -Manifest $manifest)
if (-not $portableStagePassed) { throw 'Portable Stage lifecycle verification failed.' }
Remove-Item -LiteralPath $stageRoot -Recurse -Force
& $operatorPath -Action Install -Mode PerUser -PackageRoot $packageRoot -ManifestPath $manifestPath -InstallRoot $installRoot -ReceiptPath $installReceiptPath -Confirm:$false
$perUserInstallPassed=(Test-NxbV1InstalledRootAgainstManifest -InstallRoot $installRoot -Manifest $manifest)
if (-not $perUserInstallPassed) { throw 'PerUser Install lifecycle verification failed.' }
$corruptPath=Join-Path -Path $installRoot -ChildPath 'bin\nxb.ps1'
[IO.File]::WriteAllBytes($corruptPath,[Text.UTF8Encoding]::new($false).GetBytes("CORRUPTED`n"))
$corruptionDetected=(-not (Test-NxbV1InstalledRootAgainstManifest -InstallRoot $installRoot -Manifest $manifest))
if (-not $corruptionDetected) { throw 'Installer corruption negative control was not detected.' }
& $operatorPath -Action Repair -Mode PerUser -PackageRoot $packageRoot -ManifestPath $manifestPath -InstallRoot $installRoot -ReceiptPath $repairReceiptPath -Confirm:$false
$repairPassed=(Test-NxbV1InstalledRootAgainstManifest -InstallRoot $installRoot -Manifest $manifest)
$repairRestoredBytes=((Get-NxbV1InstallerCertSha256 -Path $corruptPath) -ceq (Get-NxbV1InstallerCertSha256 -Path $fixtureScript))
if (-not $repairPassed -or -not $repairRestoredBytes) { throw 'Installer Repair did not restore exact package bytes.' }
& $operatorPath -Action Uninstall -Mode PerUser -PackageRoot $packageRoot -ManifestPath $manifestPath -InstallRoot $installRoot -ReceiptPath $uninstallReceiptPath -Confirm:$false
$uninstallPassed=(-not (Test-Path -LiteralPath $installRoot))
if (-not $uninstallPassed) { throw 'Installer Uninstall left the managed root behind.' }
$dataPreserved=((Get-NxbV1InstallerCertSha256 -Path $dataSentinel) -ceq $dataHashBefore)
$evidencePreserved=((Get-NxbV1InstallerCertSha256 -Path $evidenceSentinel) -ceq $evidenceHashBefore)
if (-not $dataPreserved -or -not $evidencePreserved) { throw 'Installer lifecycle modified external data/evidence sentinels.' }

$lifecyclePath=Join-Path -Path $outputFull -ChildPath 'installer-lifecycle.json'
$lifecycle=[pscustomobject][ordered]@{
    schema_version=1; authority='nxb-v1-installer-lifecycle-v1'; source_head=$currentHead; package_manifest_sha256=$manifestSha;
    host_preflight_passed=$true; portable_stage_passed=$portableStagePassed; per_user_install_passed=$perUserInstallPassed; corruption_detected=$corruptionDetected;
    repair_passed=$repairPassed; repair_restored_bytes=$repairRestoredBytes; uninstall_passed=$uninstallPassed; install_root_absent_after_uninstall=$uninstallPassed;
    data_preserved=$dataPreserved; evidence_preserved=$evidencePreserved; data_sentinel_sha256=$dataHashBefore; evidence_sentinel_sha256=$evidenceHashBefore;
    machine_install_performed=$false; production_release_installed=$false;
    receipt_hashes=[pscustomobject][ordered]@{ stage=(Get-NxbV1InstallerCertSha256 -Path $stageReceiptPath); install=(Get-NxbV1InstallerCertSha256 -Path $installReceiptPath); repair=(Get-NxbV1InstallerCertSha256 -Path $repairReceiptPath); uninstall=(Get-NxbV1InstallerCertSha256 -Path $uninstallReceiptPath) }
}
[IO.File]::WriteAllText($lifecyclePath,(($lifecycle | ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))

Write-Information '[6/8] Independent Python 14/14 + 10/10 adversarial replay'
$independentPath=Join-Path -Path $outputFull -ChildPath 'installer-independent-validation.json'
$independentRun=Invoke-NxbV1InstallerNative -Executable $pythonPath -ArgumentList @($validatorPath,'--policy',$policyPath,'--manifest',$manifestPath,'--package-root',$packageRoot,'--host',$hostReceiptPath,'--lifecycle',$lifecyclePath,'--stage-receipt',$stageReceiptPath,'--install-receipt',$installReceiptPath,'--repair-receipt',$repairReceiptPath,'--uninstall-receipt',$uninstallReceiptPath,'--data-sentinel',$dataSentinel,'--evidence-sentinel',$evidenceSentinel,'--expected-head',$currentHead,'--output',$independentPath)
if ($independentRun.exit_code -ne 0) { throw ('Installer independent replay failed:{0}{1}' -f [Environment]::NewLine,$independentRun.output) }
$independent=Get-Content -LiteralPath $independentPath -Raw | ConvertFrom-Json
if ([string]$independent.status -cne 'passed' -or [int]$independent.requirements_validated -ne 14 -or [int]$independent.negative_controls_validated -ne 10 -or @($independent.failures).Count -ne 0) { throw 'Installer independent replay is not 14/14 + 10/10.' }

Write-Information '[7/8] Build certification receipt and bounded review ZIP'
$certificationReceiptPath=Join-Path -Path $outputFull -ChildPath 'installer-certification-receipt.json'
$certificationReceipt=[pscustomobject][ordered]@{
    schema_version=1; status='passed'; authority='nxb-v1-installer-certification-v1'; installer_head=$currentHead;
    predecessor_production_signing_head=$predecessor; release_integration_head=$releaseIntegration; certified_implementation_head=$certifiedImplementation;
    ps7=$ps7Summary; ps51=$ps51Summary; independent_requirements=14; independent_negative_controls=10;
    base_known_error_rules=[int]$baseScan.rule_count; production_extension_rules=[int]$productionScan.extension_rule_count; release_known_error_rules=[int]$releaseScan.rule_count;
    signing_known_error_rules=[int]$signingScan.rule_count; installer_known_error_rules=[int]$installerScan.rule_count;
    known_error_findings=([int]$baseScan.finding_count+[int]$productionScan.finding_count+[int]$releaseScan.finding_count+[int]$signingScan.finding_count+[int]$installerScan.finding_count); analyzer_findings=$analyzerFindings.Count;
    host_preflight_passed=$true; portable_stage_passed=$portableStagePassed; per_user_install_passed=$perUserInstallPassed; corruption_detected=$corruptionDetected; repair_passed=$repairPassed; uninstall_passed=$uninstallPassed;
    machine_install_performed=$false; production_release_installed=$false; package_manifest_sha256=$manifestSha; lifecycle_sha256=(Get-NxbV1InstallerCertSha256 -Path $lifecyclePath); created_utc=[DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($certificationReceiptPath,(($certificationReceipt | ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
$reviewFiles=[ordered]@{
    'base-known-error-scan.json'=$baseScanPath; 'production-known-error-scan.json'=$productionScanPath; 'release-known-error-scan.json'=$releaseScanPath; 'signing-known-error-scan.json'=$signingScanPath; 'installer-known-error-scan.json'=$installerScanPath;
    'installer-host-preflight.json'=$hostReceiptPath; 'package-manifest.json'=$manifestPath; 'installer-lifecycle.json'=$lifecyclePath; 'installer-independent-validation.json'=$independentPath; 'installer-certification-receipt.json'=$certificationReceiptPath;
    'stage-receipt.json'=$stageReceiptPath; 'install-receipt.json'=$installReceiptPath; 'repair-receipt.json'=$repairReceiptPath; 'uninstall-receipt.json'=$uninstallReceiptPath;
    'fixture/bin/nxb.ps1'=$fixtureScript; 'fixture/config/default.json'=$fixtureConfig; 'fixture/external-data/keep.bin'=$dataSentinel; 'fixture/external-evidence/keep.bin'=$evidenceSentinel
}
foreach ($entry in $reviewFiles.GetEnumerator()) {
    $sourcePath=[string]($entry.Value); $entryName=[string]($entry.Key); $nativeEntryName=$entryName.Replace('/',[IO.Path]::DirectorySeparatorChar)
    $destinationPath=Join-Path -Path $reviewRoot -ChildPath $nativeEntryName
    $parent=Split-Path -Parent $destinationPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::Copy($sourcePath,$destinationPath,$false)
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($reviewRoot,$reviewZip,[IO.Compression.CompressionLevel]::Optimal,$false)

Write-Information '[8/8] Final review membership and closure summary'
$zip=[IO.Compression.ZipFile]::OpenRead($reviewZip)
try { $entryNames=[string[]]@($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName.Replace('\','/') }) }
finally { $zip.Dispose() }
[Array]::Sort($entryNames,[StringComparer]::Ordinal)
$expectedEntries=[string[]]@($reviewFiles.Keys)
[Array]::Sort($expectedEntries,[StringComparer]::Ordinal)
if ($entryNames.Count -ne 18 -or ($entryNames -join "`n") -cne ($expectedEntries -join "`n")) { throw ('Installer review ZIP content mismatch: {0}' -f ($entryNames -join ', ')) }
$result=[pscustomobject][ordered]@{
    schema_version=1; status='passed'; authority='nxb-v1-installer-certification-v1'; installer_head=$currentHead; predecessor_production_signing_head=$predecessor;
    release_integration_head=$releaseIntegration; certified_implementation_head=$certifiedImplementation; ps7=$ps7Summary; ps51=$ps51Summary;
    independent_requirements=14; independent_negative_controls=10; base_known_error_rules=[int]$baseScan.rule_count; production_extension_rules=[int]$productionScan.extension_rule_count;
    production_schema_contracts=[int]$productionScan.schema_contract_count; production_guard_contracts=[int]$productionScan.guard_contract_count; release_known_error_rules=[int]$releaseScan.rule_count;
    signing_known_error_rules=[int]$signingScan.rule_count; installer_known_error_rules=[int]$installerScan.rule_count; known_error_findings=0; analyzer_findings=0;
    host_preflight_passed=$true; portable_stage_passed=$portableStagePassed; per_user_install_passed=$perUserInstallPassed; corruption_detected=$corruptionDetected; repair_passed=$repairPassed; uninstall_passed=$uninstallPassed;
    data_preserved=$dataPreserved; evidence_preserved=$evidencePreserved; machine_install_performed=$false; production_release_installed=$false; package_manifest_path=$manifestPath; package_manifest_sha256=$manifestSha;
    lifecycle_path=$lifecyclePath; lifecycle_sha256=(Get-NxbV1InstallerCertSha256 -Path $lifecyclePath); receipt_path=$certificationReceiptPath; receipt_sha256=(Get-NxbV1InstallerCertSha256 -Path $certificationReceiptPath);
    review_zip_path=$reviewZip; review_zip_sha256=(Get-NxbV1InstallerCertSha256 -Path $reviewZip)
}
Write-Information ('NXB v1 installer certification passed: head={0} PS7={1} PS5.1={2} independent=14/14 negatives=10/10 lifecycle=stage+install+corrupt+repair+uninstall rules={3}/{4}/{5} findings=0 data_preserved=true evidence_preserved=true machine_install=false production_install=false.' -f $currentHead,$ps7Summary,$ps51Summary,[int]$releaseScan.rule_count,[int]$signingScan.rule_count,[int]$installerScan.rule_count)
if ($PassThru) { $result }
