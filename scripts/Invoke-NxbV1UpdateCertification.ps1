[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$InformationPreference='Continue'

function Invoke-NxbV1UpdateNative {
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

function Invoke-NxbV1UpdatePester {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string]$TestPath,[Parameter(Mandatory)][int]$ExpectedCount,[Parameter(Mandatory)][string]$Label)
    $tempRoot=Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath ('nxb-v1-update-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
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
        $native=Invoke-NxbV1UpdateNative -Executable $Executable -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,'-TestPath',$TestPath,'-ResultPath',$resultPath,'-ExpectedCount',[string]$ExpectedCount)
        if ($native.exit_code -ne 0) { throw ('{0} Pester failed: exit={1}{2}{3}' -f $Label,$native.exit_code,[Environment]::NewLine,$native.output) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force } }
}

function Get-NxbV1UpdateCertSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-NxbV1UpdateSuccessorScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$ConfigurationPath,[Parameter(Mandatory)][string]$ExpectedContractId,[Parameter(Mandatory)][string]$OutputPath)
    $document=Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
    if ([int]$document.schema_version -ne 1 -or [string]$document.contract_id -cne $ExpectedContractId) { throw ('Update successor signature identity drift: {0}' -f $ExpectedContractId) }
    $findings=[Collections.Generic.List[object]]::new()
    foreach ($rule in @($document.rules)) {
        $ruleRegex=[regex]::new([string]$rule.regex,[Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($relativeObject in @($rule.include)) {
            $relative=[string]$relativeObject
            $fullPath=Join-Path -Path $RepositoryRoot -ChildPath $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { $findings.Add([pscustomobject][ordered]@{ id=[string]$rule.id; path=$relative; line=0; preview='missing authority path' }); continue }
            $lines=@(Get-Content -LiteralPath $fullPath)
            for ($index=0; $index -lt $lines.Count; $index++) { if ($ruleRegex.IsMatch([string]$lines[$index])) { $findings.Add([pscustomobject][ordered]@{ id=[string]$rule.id; path=$relative; line=($index+1); preview=([string]$lines[$index]).Trim() }) } }
        }
    }
    $scanStatus='failed'; if ($findings.Count -eq 0) { $scanStatus='passed' }
    $receipt=[pscustomobject][ordered]@{ schema_version=1; status=$scanStatus; contract_id=$ExpectedContractId; rule_count=@($document.rules).Count; finding_count=$findings.Count; findings=@($findings) }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),(($receipt | ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    return $receipt
}

if ($env:OS -cne 'Windows_NT') { throw 'NXB v1 update certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'NXB v1 update certification requires PowerShell 7.' }
$repositoryRoot=Split-Path -Parent $PSScriptRoot
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Update.Common.ps1')
. (Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Update.State.ps1')

$gitCommand=Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $gitCommand=Get-Command git -ErrorAction Stop }
$git=[string]$gitCommand.Source
$currentHeadRun=Invoke-NxbV1UpdateNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'rev-parse','HEAD')
if ($currentHeadRun.exit_code -ne 0) { throw ('Unable to resolve update HEAD: {0}' -f $currentHeadRun.output) }
$currentHead=$currentHeadRun.output.Trim().ToLowerInvariant()
if ($currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Update exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirtyRun=Invoke-NxbV1UpdateNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'status','--porcelain=v1','--untracked-files=all')
if ($dirtyRun.exit_code -ne 0 -or -not [string]::IsNullOrWhiteSpace($dirtyRun.output)) { throw 'Update certification requires a clean exact-head worktree.' }

$outputFull=[IO.Path]::GetFullPath($OutputDirectory)
$workRoot=$outputFull+'-work'; $reviewRoot=$outputFull+'-review'; $reviewZip=$outputFull+'-review.zip'
foreach ($reserved in @($outputFull,$workRoot,$reviewRoot,$reviewZip)) { if (Test-Path -LiteralPath $reserved) { throw ('Reserved update output already exists: {0}' -f $reserved) } }
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$policyPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-update-policy.json'
$descriptorSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-update-descriptor.schema.json'
$trustSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-update-trust.schema.json'
$stageSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-update-stage-state.schema.json'
$updateStateSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-update-state.schema.json'
$operationSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-update-operation-receipt.schema.json'
$lifecycleSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-update-lifecycle.schema.json'
$certificationSchemaPath=Join-Path -Path $repositoryRoot -ChildPath 'schemas\nxb-v1-update-certification-receipt.schema.json'
$commonPath=Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Update.Common.ps1'
$statePath=Join-Path -Path $PSScriptRoot -ChildPath 'NxbV1Update.State.ps1'
$operatorPath=Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-NxbV1Updater.ps1'
$installerOperatorPath=Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-NxbV1Installer.ps1'
$installerExporterPath=Join-Path -Path $PSScriptRoot -ChildPath 'Export-NxbV1PackageManifest.ps1'
$testPath=Join-Path -Path $repositoryRoot -ChildPath 'tests\V1Update.Tests.ps1'
$validatorPath=Join-Path -Path $repositoryRoot -ChildPath 'tools\validate_v1_update.py'
$baseScannerPath=Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-NxbKnownErrorScan.ps1'
$baseSignaturePath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-known-error-signatures.json'
$productionScannerPath=Join-Path -Path $PSScriptRoot -ChildPath 'Invoke-NxbProductionKnownErrorScan.ps1'
$productionConfigPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-production-known-error-extension.json'
$releaseErrorPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-release-known-error-signatures.json'
$signingErrorPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-signing-known-error-signatures.json'
$installerErrorPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-installer-known-error-signatures.json'
$updateErrorPath=Join-Path -Path $repositoryRoot -ChildPath 'config\nxb-v1-update-known-error-signatures.json'
$requiredPaths=@($policyPath,$descriptorSchemaPath,$trustSchemaPath,$stageSchemaPath,$updateStateSchemaPath,$operationSchemaPath,$lifecycleSchemaPath,$certificationSchemaPath,$commonPath,$statePath,$operatorPath,$installerOperatorPath,$installerExporterPath,$testPath,$validatorPath,$baseScannerPath,$baseSignaturePath,$productionScannerPath,$productionConfigPath,$releaseErrorPath,$signingErrorPath,$installerErrorPath,$updateErrorPath)
foreach ($requiredPath in $requiredPaths) { if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Update authority component missing: {0}' -f $requiredPath) } }

Write-Information '=== NXB V1 SIGNED STAGED UPDATE CERTIFICATION ==='
Write-Information '[1/9] Exact-tree parser, analyzer, policy/schema, Python and known-error gates'
$authorityPaths=@($PSCommandPath,$commonPath,$statePath,$operatorPath,$testPath)
foreach ($scriptPath in $authorityPaths) { $tokens=$null; $parseErrors=$null; [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors); if (@($parseErrors).Count -gt 0) { throw ('Update parser failed: {0}{1}{2}' -f $scriptPath,[Environment]::NewLine,(@($parseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine)) } }
Import-Module PSScriptAnalyzer -ErrorAction Stop
$analyzerFindings=@(foreach ($scriptPath in $authorityPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFindings.Count -gt 0) { throw ('Update PSScriptAnalyzer findings: {0}{1}{2}' -f $analyzerFindings.Count,[Environment]::NewLine,(@($analyzerFindings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join [Environment]::NewLine)) }
$policy=Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
if ([string]$policy.contract_id -cne 'nxb-v1-update-v1' -or [string]$policy.predecessor_installer_head -cne 'efdeb275c25a7df1326d7effdddb4af8d83ef81d') { throw 'Update policy identity/predecessor drift.' }
foreach ($schemaPath in @($descriptorSchemaPath,$trustSchemaPath,$stageSchemaPath,$updateStateSchemaPath,$operationSchemaPath,$lifecycleSchemaPath,$certificationSchemaPath)) { $schema=Get-Content -LiteralPath $schemaPath -Raw | ConvertFrom-Json; if ([bool]$schema.additionalProperties) { throw ('Update schema permits unknown fields: {0}' -f $schemaPath) } }
$pythonCommand=Get-Command python.exe -ErrorAction SilentlyContinue; if ($null -eq $pythonCommand) { $pythonCommand=Get-Command python -ErrorAction Stop }; $pythonPath=[string]$pythonCommand.Source
$compile=Invoke-NxbV1UpdateNative -Executable $pythonPath -ArgumentList @('-m','py_compile',$validatorPath); if ($compile.exit_code -ne 0) { throw ('Update Python syntax failed:{0}{1}' -f [Environment]::NewLine,$compile.output) }
$baseScanPath=Join-Path $workRoot 'base-known-error-scan.json'; $baseScan=& $baseScannerPath -RepositoryRoot $repositoryRoot -SignaturePath $baseSignaturePath -OutputPath $baseScanPath -NoThrow -PassThru
$productionScanPath=Join-Path $workRoot 'production-known-error-scan.json'; $productionScan=& $productionScannerPath -RepositoryRoot $repositoryRoot -ConfigurationPath $productionConfigPath -OutputPath $productionScanPath -NoThrow -PassThru
$releaseScanPath=Join-Path $workRoot 'release-known-error-scan.json'; $releaseScan=Invoke-NxbV1UpdateSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $releaseErrorPath -ExpectedContractId 'nxb-v1-release-known-error-signatures-v1' -OutputPath $releaseScanPath
$signingScanPath=Join-Path $workRoot 'signing-known-error-scan.json'; $signingScan=Invoke-NxbV1UpdateSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $signingErrorPath -ExpectedContractId 'nxb-v1-signing-known-error-signatures-v1' -OutputPath $signingScanPath
$installerScanPath=Join-Path $workRoot 'installer-known-error-scan.json'; $installerScan=Invoke-NxbV1UpdateSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $installerErrorPath -ExpectedContractId 'nxb-v1-installer-known-error-signatures-v1' -OutputPath $installerScanPath
$updateScanPath=Join-Path $workRoot 'update-known-error-scan.json'; $updateScan=Invoke-NxbV1UpdateSuccessorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $updateErrorPath -ExpectedContractId 'nxb-v1-update-known-error-signatures-v1' -OutputPath $updateScanPath
if ([string]$baseScan.status -cne 'passed' -or [int]$baseScan.rule_count -lt 23 -or [int]$baseScan.finding_count -ne 0) { throw 'Update inherited base known-error gate failed.' }
if ([string]$productionScan.status -cne 'passed' -or [int]$productionScan.extension_rule_count -ne 9 -or [int]$productionScan.schema_contract_count -ne 1 -or [int]$productionScan.guard_contract_count -ne 1 -or [int]$productionScan.finding_count -ne 0) { throw 'Update inherited production known-error gate failed.' }
if ([int]$releaseScan.rule_count -ne 1 -or [int]$signingScan.rule_count -ne 2 -or [int]$installerScan.rule_count -ne 4 -or [int]$updateScan.rule_count -ne 7 -or [int]$releaseScan.finding_count+[int]$signingScan.finding_count+[int]$installerScan.finding_count+[int]$updateScan.finding_count -ne 0) { throw 'Update successor known-error gate failed.' }

Write-Information '[2/9] Dual-runtime 24-test update contract'
$testSource=Get-Content -LiteralPath $testPath -Raw; if ([regex]::Matches($testSource,"(?m)^\s*It\s+'").Count -ne 24) { throw 'Update source test-count drift.' }
$previousTestRoot=[Environment]::GetEnvironmentVariable('NXB_V1_UPDATE_REPOSITORY_ROOT','Process'); $env:NXB_V1_UPDATE_REPOSITORY_ROOT=$repositoryRoot
try { $pwshPath=(Get-Command pwsh.exe -ErrorAction Stop).Source; $ps51Path=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; if (-not (Test-Path $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 unavailable.' }; $ps7Contract=Invoke-NxbV1UpdatePester -Executable $pwshPath -TestPath $testPath -ExpectedCount 24 -Label 'NXB v1 update PS7'; $ps51Contract=Invoke-NxbV1UpdatePester -Executable $ps51Path -TestPath $testPath -ExpectedCount 24 -Label 'NXB v1 update PS5.1' }
finally { if ($null -eq $previousTestRoot) { Remove-Item Env:NXB_V1_UPDATE_REPOSITORY_ROOT -ErrorAction SilentlyContinue } else { $env:NXB_V1_UPDATE_REPOSITORY_ROOT=$previousTestRoot } }
$ps7Summary=('{0}/{1}' -f [int]$ps7Contract.passed,[int]$ps7Contract.total); $ps51Summary=('{0}/{1}' -f [int]$ps51Contract.passed,[int]$ps51Contract.total)
if ($ps7Summary -cne '24/24' -or $ps51Summary -cne '24/24') { throw 'Update dual-runtime summary drift.' }

Write-Information '[3/9] Build initial managed install and target signed update fixture'
$fixtureRoot=Join-Path $workRoot 'fixture'; $initialPackageRoot=Join-Path $fixtureRoot 'initial-package'; $targetPackageRoot=Join-Path $fixtureRoot 'target-package'; $installRoot=Join-Path $fixtureRoot 'managed-install'; $updateRoot=Join-Path $fixtureRoot 'update-root'; $dataRoot=Join-Path $fixtureRoot 'external-data'; $evidenceRoot=Join-Path $fixtureRoot 'external-evidence'
foreach ($dir in @($initialPackageRoot,$targetPackageRoot,$updateRoot,$dataRoot,$evidenceRoot)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
foreach ($package in @($initialPackageRoot,$targetPackageRoot)) { [IO.Directory]::CreateDirectory((Join-Path $package 'bin')) | Out-Null; [IO.Directory]::CreateDirectory((Join-Path $package 'config')) | Out-Null }
[IO.File]::WriteAllText((Join-Path $initialPackageRoot 'bin\nxb.ps1'),"Write-Output 'NXB initial fixture'`n",[Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllText((Join-Path $initialPackageRoot 'config\default.json'),"{`"schema_version`":1,`"generation`":0}`n",[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $targetPackageRoot 'bin\nxb.ps1'),"Write-Output 'NXB updated fixture'`n",[Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllText((Join-Path $targetPackageRoot 'config\default.json'),"{`"schema_version`":1,`"generation`":1}`n",[Text.UTF8Encoding]::new($false))
$initialManifestPath=Join-Path $fixtureRoot 'initial-package-manifest.json'; $targetManifestPath=Join-Path $fixtureRoot 'target-package-manifest.json'
& $installerExporterPath -PackageRoot $initialPackageRoot -SourceHead 'efdeb275c25a7df1326d7effdddb4af8d83ef81d' -OutputPath $initialManifestPath
& $installerExporterPath -PackageRoot $targetPackageRoot -SourceHead $currentHead -OutputPath $targetManifestPath
$initialInstallReceiptPath=Join-Path $outputFull 'initial-install-receipt.json'; & $installerOperatorPath -Action Install -Mode PerUser -PackageRoot $initialPackageRoot -ManifestPath $initialManifestPath -InstallRoot $installRoot -ReceiptPath $initialInstallReceiptPath -Confirm:$false
$initialInstallStatePath=Join-Path $outputFull 'initial-install-state.json'; [IO.File]::Copy((Get-NxbV1InstallerStatePath -InstallRoot $installRoot),$initialInstallStatePath,$false)
$initialTreeSha=Get-NxbV1UpdateTreeDigest -Root $installRoot
$dataSentinel=Join-Path $dataRoot 'keep.bin'; $evidenceSentinel=Join-Path $evidenceRoot 'keep.bin'; [IO.File]::WriteAllBytes($dataSentinel,[Text.UTF8Encoding]::new($false).GetBytes("NXB-UPDATE-DATA-KEEP`n")); [IO.File]::WriteAllBytes($evidenceSentinel,[Text.UTF8Encoding]::new($false).GetBytes("NXB-UPDATE-EVIDENCE-KEEP`n")); $dataHashBefore=Get-NxbV1UpdateCertSha256 $dataSentinel; $evidenceHashBefore=Get-NxbV1UpdateCertSha256 $evidenceSentinel
$targetManifest=Get-Content $targetManifestPath -Raw | ConvertFrom-Json; $targetManifestSha=Get-NxbV1UpdateCertSha256 $targetManifestPath
$descriptorPath=Join-Path $fixtureRoot 'update-descriptor.json'; $descriptor=[pscustomobject][ordered]@{ schema_version=1; contract_id='nxb-v1-update-descriptor-v1'; channel='stable'; release_version='1.0.0'; release_sequence=1; release_head=$currentHead; certified_implementation_head='a10535b294c4d7ba8a4c3683154609087bf50c4b'; package_manifest_sha256=$targetManifestSha; created_utc=[DateTime]::UtcNow.ToString('o') }; [IO.File]::WriteAllText($descriptorPath,(($descriptor|ConvertTo-Json -Depth 6)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
$signer=Get-NxbV1CertificationSigner -KeySizeBits 3072
try {
    $artifactRows=[Collections.Generic.List[object]]::new(); $artifactRows.Add([pscustomobject][ordered]@{ path='update/update-descriptor.json'; bytes=[int64](Get-Item $descriptorPath).Length; sha256=(Get-NxbV1UpdateCertSha256 $descriptorPath) })
    foreach ($file in @($targetManifest.files)) {
        $nativeRelative=([string]$file.path).Replace('/',[IO.Path]::DirectorySeparatorChar)
        $artifactPath=Join-Path -Path $targetPackageRoot -ChildPath $nativeRelative
        $artifactItem=Get-Item -LiteralPath $artifactPath
        $artifactRows.Add([pscustomobject][ordered]@{ path=('package/'+[string]$file.path); bytes=[int64]$artifactItem.Length; sha256=(Get-NxbV1UpdateCertSha256 -Path $artifactPath) })
    }
    $emptyNotesPath=Join-Path $fixtureRoot 'release-notes.md'; [IO.File]::WriteAllText($emptyNotesPath,'',[Text.UTF8Encoding]::new($false)); $emptyNotesSha=Get-NxbV1UpdateCertSha256 $emptyNotesPath
    $envelope=ConvertTo-NxbV1SignedReleaseEnvelope -Signer $signer -ReleaseHead $currentHead -CertifiedImplementationHead 'a10535b294c4d7ba8a4c3683154609087bf50c4b' -PackageManifestSha256 $targetManifestSha -ReleaseNotesSha256 $emptyNotesSha -Artifacts @($artifactRows)
    $envelopePath=Join-Path $fixtureRoot 'signature-envelope.json'; [IO.File]::WriteAllText($envelopePath,(($envelope|ConvertTo-Json -Depth 12)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    $trust=[pscustomobject][ordered]@{ schema_version=1; contract_id='nxb-v1-update-trust-v1'; channel='stable'; trusted_signer_fingerprint=[string]$signer.public_key.fingerprint; minimum_release_sequence=1; allow_downgrade=$false; revoked_release_heads=@() }
    $trustPath=Join-Path $fixtureRoot 'update-trust.json'; [IO.File]::WriteAllText($trustPath,(($trust|ConvertTo-Json -Depth 6)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    $trustAnchorPassed=Test-NxbV1UpdateBundle -PackageRoot $targetPackageRoot -Manifest $targetManifest -ManifestPath $targetManifestPath -Descriptor $descriptor -DescriptorPath $descriptorPath -Envelope $envelope -Trust $trust -CurrentReleaseSequence 0 -CertificationMode
    if (-not $trustAnchorPassed) { throw 'Certification signed update bundle did not pass trust anchor validation.' }

    Write-Information '[4/9] Exercise trust, revocation, sequence and tamper negative controls'
    $wrongTrust=($trust|ConvertTo-Json -Depth 6|ConvertFrom-Json); $wrongTrust.trusted_signer_fingerprint='0'*64; $wrongSignerRejected=(-not (Test-NxbV1UpdateBundle -PackageRoot $targetPackageRoot -Manifest $targetManifest -ManifestPath $targetManifestPath -Descriptor $descriptor -DescriptorPath $descriptorPath -Envelope $envelope -Trust $wrongTrust -CurrentReleaseSequence 0 -CertificationMode))
    $revokedTrust=($trust|ConvertTo-Json -Depth 6|ConvertFrom-Json); $revokedTrust.revoked_release_heads=@($currentHead); $revokedHeadRejected=(-not (Test-NxbV1UpdateBundle -PackageRoot $targetPackageRoot -Manifest $targetManifest -ManifestPath $targetManifestPath -Descriptor $descriptor -DescriptorPath $descriptorPath -Envelope $envelope -Trust $revokedTrust -CurrentReleaseSequence 0 -CertificationMode))
    $sequenceReplayRejected=(-not (Test-NxbV1UpdateBundle -PackageRoot $targetPackageRoot -Manifest $targetManifest -ManifestPath $targetManifestPath -Descriptor $descriptor -DescriptorPath $descriptorPath -Envelope $envelope -Trust $trust -CurrentReleaseSequence 1 -CertificationMode))
    $downDescriptor=($descriptor|ConvertTo-Json -Depth 6|ConvertFrom-Json); $downDescriptor.release_sequence=0; $downPath=Join-Path $fixtureRoot 'downgrade-descriptor.json'; [IO.File]::WriteAllText($downPath,(($downDescriptor|ConvertTo-Json -Depth 6)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false)); $downgradeRejected=(-not (Test-NxbV1UpdateBundle -PackageRoot $targetPackageRoot -Manifest $targetManifest -ManifestPath $targetManifestPath -Descriptor $downDescriptor -DescriptorPath $downPath -Envelope $envelope -Trust $trust -CurrentReleaseSequence 0 -CertificationMode))
    $tamperedDescriptor=($descriptor|ConvertTo-Json -Depth 6|ConvertFrom-Json); $tamperedDescriptor.channel='beta'; $tamperedDescriptorPath=Join-Path $fixtureRoot 'tampered-descriptor.json'; [IO.File]::WriteAllText($tamperedDescriptorPath,(($tamperedDescriptor|ConvertTo-Json -Depth 6)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false)); $tamperedDescriptorRejected=(-not (Test-NxbV1UpdateBundle -PackageRoot $targetPackageRoot -Manifest $targetManifest -ManifestPath $targetManifestPath -Descriptor $descriptor -DescriptorPath $tamperedDescriptorPath -Envelope $envelope -Trust $trust -CurrentReleaseSequence 0 -CertificationMode))
    $tamperedPackageRoot=Join-Path $fixtureRoot 'tampered-package'; Copy-NxbV1UpdatePackageVerified -PackageRoot $targetPackageRoot -Manifest $targetManifest -DestinationRoot $tamperedPackageRoot; [IO.File]::WriteAllBytes((Join-Path $tamperedPackageRoot 'bin\nxb.ps1'),[Text.UTF8Encoding]::new($false).GetBytes("TAMPERED`n")); $tamperedPackageRejected=(-not (Test-NxbV1UpdateBundle -PackageRoot $tamperedPackageRoot -Manifest $targetManifest -ManifestPath $targetManifestPath -Descriptor $descriptor -DescriptorPath $descriptorPath -Envelope $envelope -Trust $trust -CurrentReleaseSequence 0 -CertificationMode))
    foreach ($flag in @($wrongSignerRejected,$revokedHeadRejected,$sequenceReplayRejected,$downgradeRejected,$tamperedDescriptorRejected,$tamperedPackageRejected)) { if (-not $flag) { throw 'Update trust/tamper negative control failed.' } }

    Write-Information '[5/9] Execute signed Stage and Apply lifecycle'
    $stageReceiptPath=Join-Path $outputFull 'stage-receipt.json'; $applyReceiptPath=Join-Path $outputFull 'apply-receipt.json'; $rollbackReceiptPath=Join-Path $outputFull 'rollback-receipt.json'
    $previousCertMarker=[Environment]::GetEnvironmentVariable('NXB_V1_UPDATE_CERTIFICATION','Process'); $env:NXB_V1_UPDATE_CERTIFICATION='1'
    try {
        & $operatorPath -Action Stage -InstallRoot $installRoot -UpdateRoot $updateRoot -ReceiptPath $stageReceiptPath -PackageRoot $targetPackageRoot -ManifestPath $targetManifestPath -DescriptorPath $descriptorPath -EnvelopePath $envelopePath -TrustPath $trustPath -CertificationMode -Confirm:$false | Out-Null
        & $operatorPath -Action Apply -InstallRoot $installRoot -UpdateRoot $updateRoot -ReceiptPath $applyReceiptPath -TrustPath $trustPath -CertificationMode -Confirm:$false | Out-Null
    }
    finally { if ($null -eq $previousCertMarker) { Remove-Item Env:NXB_V1_UPDATE_CERTIFICATION -ErrorAction SilentlyContinue } else { $env:NXB_V1_UPDATE_CERTIFICATION=$previousCertMarker } }
    $stagePassed=(Test-Path $stageReceiptPath -PathType Leaf); $applyPassed=(Test-Path $applyReceiptPath -PathType Leaf); if (-not $stagePassed -or -not $applyPassed) { throw 'Update Stage/Apply receipt missing.' }
    $postApplyVerified=Test-NxbV1InstalledRootAgainstManifest -InstallRoot $installRoot -Manifest $targetManifest; if (-not $postApplyVerified) { throw 'Applied update does not match target package.' }
    $targetInstallStatePath=Join-Path $outputFull 'target-install-state.json'; [IO.File]::Copy((Get-NxbV1InstallerStatePath -InstallRoot $installRoot),$targetInstallStatePath,$false); $appliedTreeSha=Get-NxbV1UpdateTreeDigest -Root $installRoot
    $appliedState=Get-NxbV1UpdateStateObject -UpdateRoot $updateRoot; $rollbackSnapshotCreated=($null -ne $appliedState -and [bool]$appliedState.rollback_available -and [int]$appliedState.current_release_sequence -eq 1 -and [int]$appliedState.highest_seen_release_sequence -eq 1 -and (Test-Path -LiteralPath ([string]$appliedState.rollback_root) -PathType Container) -and [string]$appliedState.rollback_tree_sha256 -ceq $initialTreeSha); if (-not $rollbackSnapshotCreated) { throw 'Apply did not retain a verified rollback snapshot and anti-replay floor.' }

    Write-Information '[6/9] Exercise automatic failure rollback helper and manual Rollback'
    $failureCurrent=Join-Path $fixtureRoot 'failure-current'; $failureCandidate=Join-Path $fixtureRoot 'failure-candidate'; $failureRollback=Join-Path $fixtureRoot 'failure-rollback'; [IO.Directory]::CreateDirectory($failureCurrent)|Out-Null; [IO.Directory]::CreateDirectory($failureCandidate)|Out-Null; [IO.File]::WriteAllText((Join-Path $failureCurrent 'state.txt'),"old`n",[Text.UTF8Encoding]::new($false)); [IO.File]::WriteAllText((Join-Path $failureCandidate 'state.txt'),"new`n",[Text.UTF8Encoding]::new($false)); $failureBefore=Get-NxbV1UpdateTreeDigest $failureCurrent; $failureThrown=$false; try { Invoke-NxbV1UpdateAtomicSwap -CurrentRoot $failureCurrent -CandidateRoot $failureCandidate -RollbackRoot $failureRollback -PostPublishValidation { param($publishedRoot) if (-not (Test-Path -LiteralPath $publishedRoot -PathType Container)) { throw 'Published failure-test root is missing.' }; return $false } | Out-Null } catch { $failureThrown=$true }; $failureRollbackPassed=($failureThrown -and (Test-Path $failureCurrent -PathType Container) -and (Get-NxbV1UpdateTreeDigest $failureCurrent) -ceq $failureBefore -and -not (Test-Path $failureRollback)); if (-not $failureRollbackPassed) { throw 'Automatic failed-apply rollback helper did not restore original tree.' }
    $previousCertMarker=[Environment]::GetEnvironmentVariable('NXB_V1_UPDATE_CERTIFICATION','Process'); $env:NXB_V1_UPDATE_CERTIFICATION='1'
    try { & $operatorPath -Action Rollback -InstallRoot $installRoot -UpdateRoot $updateRoot -ReceiptPath $rollbackReceiptPath -CertificationMode -Confirm:$false | Out-Null }
    finally { if ($null -eq $previousCertMarker) { Remove-Item Env:NXB_V1_UPDATE_CERTIFICATION -ErrorAction SilentlyContinue } else { $env:NXB_V1_UPDATE_CERTIFICATION=$previousCertMarker } }
    $rolledBackTreeSha=Get-NxbV1UpdateTreeDigest -Root $installRoot; $rolledInstallState=Get-NxbV1InstallerStateObject -InstallRoot $installRoot; $manualRollbackPassed=($rolledBackTreeSha -ceq $initialTreeSha -and [string]$rolledInstallState.source_head -ceq 'efdeb275c25a7df1326d7effdddb4af8d83ef81d'); if (-not $manualRollbackPassed) { throw 'Manual rollback did not restore exact initial installed tree.' }
    $finalUpdateStatePath=Get-NxbV1UpdateStatePath -UpdateRoot $updateRoot; $finalUpdateState=Get-NxbV1UpdateStateObject -UpdateRoot $updateRoot
    $rollbackFloorPreserved=($null -ne $finalUpdateState -and [int]$finalUpdateState.current_release_sequence -eq 0 -and [int]$finalUpdateState.highest_seen_release_sequence -eq 1 -and -not [bool]$finalUpdateState.rollback_available); if (-not $rollbackFloorPreserved) { throw 'Manual rollback lowered or lost the anti-replay sequence floor.' }
    $rollbackReplayRejected=(-not (Test-NxbV1UpdateBundle -PackageRoot $targetPackageRoot -Manifest $targetManifest -ManifestPath $targetManifestPath -Descriptor $descriptor -DescriptorPath $descriptorPath -Envelope $envelope -Trust $trust -CurrentReleaseSequence ([int]$finalUpdateState.highest_seen_release_sequence) -CertificationMode)); if (-not $rollbackReplayRejected) { throw 'Rollback allowed replay of an already-seen signed update sequence.' }
    $sequenceReplayRejected=($sequenceReplayRejected -and $rollbackReplayRejected)
    $dataPreserved=((Get-NxbV1UpdateCertSha256 $dataSentinel) -ceq $dataHashBefore); $evidencePreserved=((Get-NxbV1UpdateCertSha256 $evidenceSentinel) -ceq $evidenceHashBefore); if (-not $dataPreserved -or -not $evidencePreserved) { throw 'Update lifecycle modified external data/evidence.' }

    Write-Information '[7/9] Build lifecycle and run independent Python 16/16 + 12/12 replay'
    $lifecyclePath=Join-Path $outputFull 'update-lifecycle.json'; $lifecycle=[pscustomobject][ordered]@{ schema_version=1; authority='nxb-v1-update-lifecycle-v1'; source_head=$currentHead; channel='stable'; target_release_sequence=1; trust_anchor_passed=$trustAnchorPassed; stage_passed=$stagePassed; apply_passed=$applyPassed; post_apply_verified=$postApplyVerified; rollback_snapshot_created=$rollbackSnapshotCreated; failure_rollback_passed=$failureRollbackPassed; manual_rollback_passed=$manualRollbackPassed; downgrade_rejected=$downgradeRejected; sequence_replay_rejected=$sequenceReplayRejected; revoked_head_rejected=$revokedHeadRejected; wrong_signer_rejected=$wrongSignerRejected; tampered_descriptor_rejected=$tamperedDescriptorRejected; tampered_package_rejected=$tamperedPackageRejected; auto_apply_performed=$false; machine_install_performed=$false; production_release_updated=$false; data_preserved=$dataPreserved; evidence_preserved=$evidencePreserved; data_sentinel_sha256=$dataHashBefore; evidence_sentinel_sha256=$evidenceHashBefore; initial_tree_sha256=$initialTreeSha; applied_tree_sha256=$appliedTreeSha; rolled_back_tree_sha256=$rolledBackTreeSha; receipt_hashes=[pscustomobject][ordered]@{ stage=(Get-NxbV1UpdateCertSha256 $stageReceiptPath); apply=(Get-NxbV1UpdateCertSha256 $applyReceiptPath); rollback=(Get-NxbV1UpdateCertSha256 $rollbackReceiptPath) } }; [IO.File]::WriteAllText($lifecyclePath,(($lifecycle|ConvertTo-Json -Depth 10)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    $independentPath=Join-Path $outputFull 'update-independent-validation.json'; $independentRun=Invoke-NxbV1UpdateNative -Executable $pythonPath -ArgumentList @($validatorPath,'--policy',$policyPath,'--manifest',$targetManifestPath,'--package-root',$targetPackageRoot,'--descriptor',$descriptorPath,'--envelope',$envelopePath,'--trust',$trustPath,'--lifecycle',$lifecyclePath,'--update-state',$finalUpdateStatePath,'--stage-receipt',$stageReceiptPath,'--apply-receipt',$applyReceiptPath,'--rollback-receipt',$rollbackReceiptPath,'--initial-package-root',$initialPackageRoot,'--initial-install-state',$initialInstallStatePath,'--target-install-state',$targetInstallStatePath,'--data-sentinel',$dataSentinel,'--evidence-sentinel',$evidenceSentinel,'--expected-head',$currentHead,'--output',$independentPath); if ($independentRun.exit_code -ne 0) { throw ('Update independent replay failed:{0}{1}' -f [Environment]::NewLine,$independentRun.output) }; $independent=Get-Content $independentPath -Raw|ConvertFrom-Json; if ([string]$independent.status -cne 'passed' -or [int]$independent.requirements_validated -ne 16 -or [int]$independent.negative_controls_validated -ne 12) { throw 'Update independent replay is not 16/16 + 12/12.' }

    Write-Information '[8/9] Build certification receipt and exact 28-entry review ZIP'
    $certificationReceiptPath=Join-Path $outputFull 'update-certification-receipt.json'; $certificationReceipt=[pscustomobject][ordered]@{ schema_version=1; status='passed'; authority='nxb-v1-update-certification-v1'; update_head=$currentHead; predecessor_installer_head='efdeb275c25a7df1326d7effdddb4af8d83ef81d'; production_signing_head='91be58af59d0703de0159fea9d11935805e16022'; release_integration_head='9371399bab4fbb921ad94198aa148c597c7b6261'; certified_implementation_head='a10535b294c4d7ba8a4c3683154609087bf50c4b'; ps7=$ps7Summary; ps51=$ps51Summary; independent_requirements=16; independent_negative_controls=12; base_known_error_rules=[int]$baseScan.rule_count; production_extension_rules=[int]$productionScan.extension_rule_count; release_known_error_rules=[int]$releaseScan.rule_count; signing_known_error_rules=[int]$signingScan.rule_count; installer_known_error_rules=[int]$installerScan.rule_count; update_known_error_rules=[int]$updateScan.rule_count; known_error_findings=0; analyzer_findings=0; trust_anchor_passed=$trustAnchorPassed; stage_passed=$stagePassed; apply_passed=$applyPassed; failure_rollback_passed=$failureRollbackPassed; manual_rollback_passed=$manualRollbackPassed; auto_apply_performed=$false; machine_install_performed=$false; production_release_updated=$false; lifecycle_sha256=(Get-NxbV1UpdateCertSha256 $lifecyclePath); created_utc=[DateTime]::UtcNow.ToString('o') }; [IO.File]::WriteAllText($certificationReceiptPath,(($certificationReceipt|ConvertTo-Json -Depth 10)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    $stageStatePath=Get-NxbV1UpdateStageStatePath -UpdateRoot $updateRoot
    [IO.Directory]::CreateDirectory($reviewRoot)|Out-Null
    $reviewFiles=[ordered]@{ 'base-known-error-scan.json'=$baseScanPath; 'production-known-error-scan.json'=$productionScanPath; 'release-known-error-scan.json'=$releaseScanPath; 'signing-known-error-scan.json'=$signingScanPath; 'installer-known-error-scan.json'=$installerScanPath; 'update-known-error-scan.json'=$updateScanPath; 'update-trust.json'=$trustPath; 'initial-package-manifest.json'=$initialManifestPath; 'target-package-manifest.json'=$targetManifestPath; 'update-descriptor.json'=$descriptorPath; 'signature-envelope.json'=$envelopePath; 'update-lifecycle.json'=$lifecyclePath; 'update-independent-validation.json'=$independentPath; 'update-certification-receipt.json'=$certificationReceiptPath; 'initial-install-receipt.json'=$initialInstallReceiptPath; 'stage-receipt.json'=$stageReceiptPath; 'apply-receipt.json'=$applyReceiptPath; 'rollback-receipt.json'=$rollbackReceiptPath; 'initial-install-state.json'=$initialInstallStatePath; 'target-install-state.json'=$targetInstallStatePath; 'fixture/initial/bin/nxb.ps1'=(Join-Path $initialPackageRoot 'bin\nxb.ps1'); 'fixture/initial/config/default.json'=(Join-Path $initialPackageRoot 'config\default.json'); 'fixture/target/bin/nxb.ps1'=(Join-Path $targetPackageRoot 'bin\nxb.ps1'); 'fixture/target/config/default.json'=(Join-Path $targetPackageRoot 'config\default.json'); 'fixture/external-data/keep.bin'=$dataSentinel; 'fixture/external-evidence/keep.bin'=$evidenceSentinel; 'update-state.json'=$finalUpdateStatePath; 'stage-state.json'=$stageStatePath }
    foreach ($entry in $reviewFiles.GetEnumerator()) { $sourcePath=[string]($entry.Value); $entryName=[string]($entry.Key); $destinationPath=Join-Path -Path $reviewRoot -ChildPath $entryName.Replace('/',[IO.Path]::DirectorySeparatorChar); $parent=Split-Path -Parent $destinationPath; if (-not (Test-Path $parent -PathType Container)) { [IO.Directory]::CreateDirectory($parent)|Out-Null }; [IO.File]::Copy($sourcePath,$destinationPath,$false) }
    Add-Type -AssemblyName System.IO.Compression.FileSystem; [IO.Compression.ZipFile]::CreateFromDirectory($reviewRoot,$reviewZip,[IO.Compression.CompressionLevel]::Optimal,$false)

    Write-Information '[9/9] Final review membership and closure summary'
    $zip=[IO.Compression.ZipFile]::OpenRead($reviewZip); try { $entryNames=[string[]]@($zip.Entries|Where-Object{-not [string]::IsNullOrWhiteSpace($_.Name)}|ForEach-Object{$_.FullName.Replace('\','/')}) } finally { $zip.Dispose() }; [Array]::Sort($entryNames,[StringComparer]::Ordinal); $expectedEntries=[string[]]@($reviewFiles.Keys); [Array]::Sort($expectedEntries,[StringComparer]::Ordinal); if ($entryNames.Count -ne 28 -or ($entryNames -join "`n") -cne ($expectedEntries -join "`n")) { throw ('Update review ZIP content mismatch: {0}' -f ($entryNames -join ', ')) }
    $result=[pscustomobject][ordered]@{ schema_version=1; status='passed'; authority='nxb-v1-update-certification-v1'; update_head=$currentHead; predecessor_installer_head='efdeb275c25a7df1326d7effdddb4af8d83ef81d'; production_signing_head='91be58af59d0703de0159fea9d11935805e16022'; release_integration_head='9371399bab4fbb921ad94198aa148c597c7b6261'; certified_implementation_head='a10535b294c4d7ba8a4c3683154609087bf50c4b'; ps7=$ps7Summary; ps51=$ps51Summary; independent_requirements=16; independent_negative_controls=12; base_known_error_rules=[int]$baseScan.rule_count; production_extension_rules=[int]$productionScan.extension_rule_count; production_schema_contracts=[int]$productionScan.schema_contract_count; production_guard_contracts=[int]$productionScan.guard_contract_count; release_known_error_rules=[int]$releaseScan.rule_count; signing_known_error_rules=[int]$signingScan.rule_count; installer_known_error_rules=[int]$installerScan.rule_count; update_known_error_rules=[int]$updateScan.rule_count; known_error_findings=0; analyzer_findings=0; trust_anchor_passed=$trustAnchorPassed; stage_passed=$stagePassed; apply_passed=$applyPassed; failure_rollback_passed=$failureRollbackPassed; manual_rollback_passed=$manualRollbackPassed; auto_apply_performed=$false; machine_install_performed=$false; production_release_updated=$false; lifecycle_path=$lifecyclePath; lifecycle_sha256=(Get-NxbV1UpdateCertSha256 $lifecyclePath); receipt_path=$certificationReceiptPath; receipt_sha256=(Get-NxbV1UpdateCertSha256 $certificationReceiptPath); review_zip_path=$reviewZip; review_zip_sha256=(Get-NxbV1UpdateCertSha256 $reviewZip) }
    Write-Information ('NXB v1 update certification passed: head={0} PS7={1} PS5.1={2} independent=16/16 negatives=12/12 trust=true stage=true apply=true failure_rollback=true manual_rollback=true rules={3}/{4}/{5}/{6} findings=0 auto_apply=false production_update=false.' -f $currentHead,$ps7Summary,$ps51Summary,[int]$releaseScan.rule_count,[int]$signingScan.rule_count,[int]$installerScan.rule_count,[int]$updateScan.rule_count)
    if ($PassThru) { $result }
}
finally { if ($null -ne $signer -and $null -ne $signer.rsa) { $signer.rsa.Dispose() } }