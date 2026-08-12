[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'

function Invoke-NxbV1SigningNative {
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
    return [pscustomobject][ordered]@{ exit_code=$nativeExitCode; output=(@($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine) }
}

function Invoke-NxbV1SigningPester {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string]$TestPath,[Parameter(Mandatory)][int]$ExpectedCount,[Parameter(Mandatory)][string]$Label)
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('nxb-v1-signing-pester-{0}' -f [Guid]::NewGuid().ToString('N'))
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
        $native = Invoke-NxbV1SigningNative -Executable $Executable -ArgumentList @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$runnerPath,'-TestPath',$TestPath,'-ResultPath',$resultPath,'-ExpectedCount',[string]$ExpectedCount)
        if ($native.exit_code -ne 0) { throw ('{0} Pester failed: exit={1}{2}{3}' -f $Label,$native.exit_code,[Environment]::NewLine,$native.output) }
        return (Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json)
    }
    finally { if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force } }
}

function Get-NxbV1SigningFileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Invoke-NxbV1ReleaseKnownErrorScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryRoot,[Parameter(Mandatory)][string]$ConfigurationPath,[Parameter(Mandatory)][string]$OutputPath)
    $document = Get-Content -LiteralPath $ConfigurationPath -Raw | ConvertFrom-Json
    if ([int]$document.schema_version -ne 1 -or [string]$document.contract_id -cne 'nxb-v1-release-known-error-signatures-v1') { throw 'Release known-error signature identity drift.' }
    $findings = [Collections.Generic.List[object]]::new()
    foreach ($rule in @($document.rules)) {
        $regex = [regex]::new([string]$rule.regex,[Text.RegularExpressions.RegexOptions]::Multiline -bor [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        foreach ($relativeObject in @($rule.include)) {
            $relative = [string]$relativeObject
            $fullPath = Join-Path -Path $RepositoryRoot -ChildPath $relative.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) {
                $findings.Add([pscustomobject][ordered]@{ id=[string]$rule.id; path=$relative; line=0; preview='missing authority path' })
                continue
            }
            $lines = @(Get-Content -LiteralPath $fullPath)
            for ($index=0; $index -lt $lines.Count; $index++) {
                $line = [string]$lines[$index]
                if ($regex.IsMatch($line)) { $findings.Add([pscustomobject][ordered]@{ id=[string]$rule.id; path=$relative; line=($index+1); preview=$line.Trim() }) }
            }
        }
    }
    $receipt = [pscustomobject][ordered]@{ schema_version=1; status=(if ($findings.Count -eq 0) { 'passed' } else { 'failed' }); rule_count=@($document.rules).Count; finding_count=$findings.Count; findings=@($findings) }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($OutputPath),(($receipt | ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
    return $receipt
}

if ($env:OS -cne 'Windows_NT') { throw 'NXB v1 production signing certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'NXB v1 production signing certification requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction Stop }
$git = [string]$gitCommand.Source
$currentHeadRun = Invoke-NxbV1SigningNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'rev-parse','HEAD')
if ($currentHeadRun.exit_code -ne 0) { throw ('Unable to resolve production signing HEAD: {0}' -f $currentHeadRun.output) }
$currentHead = $currentHeadRun.output.Trim().ToLowerInvariant()
if ($currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Production signing exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirtyRun = Invoke-NxbV1SigningNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'status','--porcelain=v1','--untracked-files=all')
if ($dirtyRun.exit_code -ne 0 -or -not [string]::IsNullOrWhiteSpace($dirtyRun.output)) { throw 'Production signing certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$workRoot = $outputFull + '-work'
$reviewRoot = $outputFull + '-review'
$reviewZip = $outputFull + '-review.zip'
foreach ($reserved in @($outputFull,$workRoot,$reviewRoot,$reviewZip)) { if (Test-Path -LiteralPath $reserved) { throw ('Reserved production signing output already exists: {0}' -f $reserved) } }
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$policyPath = Join-Path $repositoryRoot 'config\nxb-v1-production-signing-policy.json'
$envelopeSchemaPath = Join-Path $repositoryRoot 'schemas\nxb-v1-release-signature-envelope.schema.json'
$receiptSchemaPath = Join-Path $repositoryRoot 'schemas\nxb-v1-production-signing-certification-receipt.schema.json'
$commonPath = Join-Path $PSScriptRoot 'NxbV1ProductionSigning.Common.ps1'
$operatorPath = Join-Path $PSScriptRoot 'Invoke-NxbV1ReleaseManifestSigning.ps1'
$testPath = Join-Path $repositoryRoot 'tests\V1ProductionSigning.Tests.ps1'
$validatorPath = Join-Path $repositoryRoot 'tools\validate_v1_production_signing.py'
$releaseErrorPath = Join-Path $repositoryRoot 'config\nxb-v1-release-known-error-signatures.json'
$baseScannerPath = Join-Path $PSScriptRoot 'Invoke-NxbKnownErrorScan.ps1'
$baseSignaturePath = Join-Path $repositoryRoot 'config\nxb-known-error-signatures.json'
$productionScannerPath = Join-Path $PSScriptRoot 'Invoke-NxbProductionKnownErrorScan.ps1'
$productionScannerConfigPath = Join-Path $repositoryRoot 'config\nxb-production-known-error-extension.json'
$authorityPaths = @($PSCommandPath,$commonPath,$operatorPath,$testPath)
foreach ($requiredPath in @($policyPath,$envelopeSchemaPath,$receiptSchemaPath,$commonPath,$operatorPath,$testPath,$validatorPath,$releaseErrorPath,$baseScannerPath,$baseSignaturePath,$productionScannerPath,$productionScannerConfigPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Production signing component missing: {0}' -f $requiredPath) }
}

Write-Information '=== NXB V1 PRODUCTION SIGNING CERTIFICATION ==='
Write-Information '[1/7] Exact-tree parser, analyzer, policy/schema, Python and known-error gates'
foreach ($scriptPath in $authorityPaths) {
    $tokens=$null; $parseErrors=$null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw ('Production signing parser failed: {0}{1}{2}' -f $scriptPath,[Environment]::NewLine,(@($parseErrors | ForEach-Object { $_.Message }) -join [Environment]::NewLine)) }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$analyzerFindings = @(foreach ($scriptPath in $authorityPaths) { Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error })
if ($analyzerFindings.Count -gt 0) { throw ('Production signing PSScriptAnalyzer findings: {0}{1}{2}' -f $analyzerFindings.Count,[Environment]::NewLine,(@($analyzerFindings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join [Environment]::NewLine)) }
$policy = Get-Content -LiteralPath $policyPath -Raw | ConvertFrom-Json
$envelopeSchema = Get-Content -LiteralPath $envelopeSchemaPath -Raw | ConvertFrom-Json
$receiptSchema = Get-Content -LiteralPath $receiptSchemaPath -Raw | ConvertFrom-Json
if ([string]$policy.contract_id -cne 'nxb-v1-production-signing-v1' -or [int]$policy.schema_version -ne 1) { throw 'Production signing policy identity drift.' }
if ([bool]$envelopeSchema.additionalProperties -or [bool]$receiptSchema.additionalProperties) { throw 'Production signing schemas must reject unknown fields.' }
$predecessor = [string]$policy.predecessor_release_integration_head
$predecessorRun = Invoke-NxbV1SigningNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'merge-base','--is-ancestor',$predecessor,$currentHead)
if ($predecessorRun.exit_code -ne 0) { throw 'Native-certified release integration predecessor is not an ancestor of production signing head.' }
$certifiedImplementation = [string]$policy.certified_implementation_head
$certifiedRun = Invoke-NxbV1SigningNative -Executable $git -ArgumentList @('-C',$repositoryRoot,'merge-base','--is-ancestor',$certifiedImplementation,$currentHead)
if ($certifiedRun.exit_code -ne 0) { throw 'Certified implementation head is not an ancestor of production signing head.' }
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$pythonPath = [string]$pythonCommand.Source
$compile = Invoke-NxbV1SigningNative -Executable $pythonPath -ArgumentList @('-m','py_compile',$validatorPath)
if ($compile.exit_code -ne 0) { throw ('Production signing Python syntax failed:{0}{1}' -f [Environment]::NewLine,$compile.output) }
$baseScanPath = Join-Path $workRoot 'base-known-error-scan.json'
$baseScan = & $baseScannerPath -RepositoryRoot $repositoryRoot -SignaturePath $baseSignaturePath -OutputPath $baseScanPath -NoThrow -PassThru
if ([string]$baseScan.status -cne 'passed' -or [int]$baseScan.rule_count -lt 23 -or [int]$baseScan.finding_count -ne 0) { throw 'Production signing inherited base known-error gate failed.' }
$productionScanPath = Join-Path $workRoot 'production-known-error-scan.json'
$productionScan = & $productionScannerPath -RepositoryRoot $repositoryRoot -ConfigurationPath $productionScannerConfigPath -OutputPath $productionScanPath -NoThrow -PassThru
if ([string]$productionScan.status -cne 'passed' -or [int]$productionScan.extension_rule_count -ne 9 -or [int]$productionScan.schema_contract_count -ne 1 -or [int]$productionScan.guard_contract_count -ne 1 -or [int]$productionScan.finding_count -ne 0) { throw 'Production signing inherited production known-error gate failed.' }
$releaseScanPath = Join-Path $workRoot 'release-known-error-scan.json'
$releaseScan = Invoke-NxbV1ReleaseKnownErrorScan -RepositoryRoot $repositoryRoot -ConfigurationPath $releaseErrorPath -OutputPath $releaseScanPath
if ([string]$releaseScan.status -cne 'passed' -or [int]$releaseScan.rule_count -ne 1 -or [int]$releaseScan.finding_count -ne 0) { throw 'Production signing release known-error gate failed.' }

Write-Information '[2/7] Dual-runtime 18-test production signing contract'
$testSource = Get-Content -LiteralPath $testPath -Raw
if ([regex]::Matches($testSource,"(?m)^\s*It\s+'").Count -ne 18) { throw 'Production signing source test-count drift.' }
$previousRoot = [Environment]::GetEnvironmentVariable('NXB_V1_SIGNING_REPOSITORY_ROOT','Process')
$env:NXB_V1_SIGNING_REPOSITORY_ROOT = $repositoryRoot
try {
    $pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $ps51Path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $ps51Path -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
    $ps7Contract = Invoke-NxbV1SigningPester -Executable $pwshPath -TestPath $testPath -ExpectedCount 18 -Label 'NXB v1 signing PS7'
    $ps51Contract = Invoke-NxbV1SigningPester -Executable $ps51Path -TestPath $testPath -ExpectedCount 18 -Label 'NXB v1 signing PS5.1'
}
finally { if ($null -eq $previousRoot) { Remove-Item Env:NXB_V1_SIGNING_REPOSITORY_ROOT -ErrorAction SilentlyContinue } else { $env:NXB_V1_SIGNING_REPOSITORY_ROOT=$previousRoot } }

Write-Information '[3/7] Build real-file certification fixture and sign through operator command'
$fixtureRoot = Join-Path $workRoot 'fixture'
$artifactRoot = Join-Path $fixtureRoot 'artifacts'
[IO.Directory]::CreateDirectory((Join-Path $artifactRoot 'packages')) | Out-Null
$packageManifestPath = Join-Path $fixtureRoot 'package-manifest.json'
$releaseNotesPath = Join-Path $fixtureRoot 'release-notes.txt'
$aArtifact = Join-Path $artifactRoot 'packages\a-first.bin'
$zArtifact = Join-Path $artifactRoot 'packages\z-last.bin'
[IO.File]::WriteAllText($packageManifestPath,"{`"schema_version`":1,`"release_version`":`"1.0.0`",`"fixture`":true}`n",[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($releaseNotesPath,"NXB v1 production signing certification fixture`n",[Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllBytes($aArtifact,[Text.UTF8Encoding]::new($false).GetBytes("NXB-A-FIRST`n"))
[IO.File]::WriteAllBytes($zArtifact,[Text.UTF8Encoding]::new($false).GetBytes("NXB-Z-LAST`n"))
$envelopePath = Join-Path $outputFull 'v1-production-signing-envelope.json'
$envelopePipeline = @(& $operatorPath -SignerMode CertificationEphemeral -ReleaseHead $currentHead -CertifiedImplementationHead $certifiedImplementation -PackageManifestPath $packageManifestPath -ReleaseNotesPath $releaseNotesPath -ArtifactRoot $artifactRoot -ArtifactPath @('packages/z-last.bin','packages/a-first.bin') -OutputPath $envelopePath -PassThru)
$envelope = $null
foreach ($item in $envelopePipeline) { if ($null -ne $item -and $null -ne $item.PSObject.Properties['signature_b64']) { $envelope=$item } }
if ($null -eq $envelope) { throw 'Production signing operator returned no signed certification envelope.' }
if ([string]$envelope.signer_mode -cne 'certification-ephemeral' -or [bool]$envelope.private_key_persisted -or [bool]$envelope.production_signer_claimed -or [int]$envelope.key_size_bits -lt 3072) { throw 'Certification signer boundary failed.' }
if ([string]$envelope.package_manifest_sha256 -cne (Get-NxbV1SigningFileSha256 -Path $packageManifestPath)) { throw 'Envelope package manifest hash binding failed.' }
if ([string]$envelope.release_notes_sha256 -cne (Get-NxbV1SigningFileSha256 -Path $releaseNotesPath)) { throw 'Envelope release notes hash binding failed.' }
. $commonPath
if (-not (Test-NxbV1SignedReleaseEnvelope -Envelope $envelope)) { throw 'Authority-level PowerShell signature replay failed.' }

Write-Information '[4/7] Independent Python 12/12 + 8/8 RSA and adversarial replay'
$independentPath = Join-Path $workRoot 'v1-production-signing-independent-validation.json'
$independentRun = Invoke-NxbV1SigningNative -Executable $pythonPath -ArgumentList @($validatorPath,'--policy',$policyPath,'--envelope',$envelopePath,'--expected-release-head',$currentHead,'--expected-certified-head',$certifiedImplementation,'--output',$independentPath)
if ($independentRun.exit_code -ne 0) { throw ('Production signing independent replay failed:{0}{1}' -f [Environment]::NewLine,$independentRun.output) }
$independent = Get-Content -LiteralPath $independentPath -Raw | ConvertFrom-Json
if ([string]$independent.status -cne 'passed' -or [int]$independent.requirements_validated -ne 12 -or [int]$independent.negative_controls_validated -ne 8 -or @($independent.failures).Count -ne 0) { throw 'Production signing independent replay is not 12/12 + 8/8.' }

Write-Information '[5/7] Build production signing certification receipt'
$certificationReceiptPath = Join-Path $outputFull 'v1-production-signing-certification-receipt.json'
$certificationReceipt = [pscustomobject][ordered]@{
    schema_version=1; status='passed'; authority='nxb-v1-production-signing-certification-v1'; release_head=$currentHead;
    certified_implementation_head=$certifiedImplementation; release_integration_predecessor_head=$predecessor;
    ps7=('18/18'); ps51=('18/18'); independent_requirements=12; independent_negative_controls=8;
    base_known_error_rules=[int]$baseScan.rule_count; production_extension_rules=[int]$productionScan.extension_rule_count; release_known_error_rules=[int]$releaseScan.rule_count;
    known_error_findings=([int]$baseScan.finding_count+[int]$productionScan.finding_count+[int]$releaseScan.finding_count); analyzer_findings=$analyzerFindings.Count;
    signing_algorithm=[string]$envelope.signing_algorithm; key_size_bits=[int]$envelope.key_size_bits; public_fingerprint=[string]$envelope.public_key.fingerprint;
    envelope_sha256=(Get-NxbV1SigningFileSha256 -Path $envelopePath); independent_validation_sha256=(Get-NxbV1SigningFileSha256 -Path $independentPath);
    certification_private_key_persisted=$false; production_signer_claimed=$false; actual_production_release_signed=$false; production_signing_pipeline_certified=$true;
    created_utc=[DateTime]::UtcNow.ToString('o')
}
[IO.File]::WriteAllText($certificationReceiptPath,(($certificationReceipt | ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))

Write-Information '[6/7] Build bounded review ZIP with signed fixture bytes'
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
$reviewFiles = [ordered]@{
    'base-known-error-scan.json'=$baseScanPath; 'production-known-error-scan.json'=$productionScanPath; 'release-known-error-scan.json'=$releaseScanPath;
    'v1-production-signing-envelope.json'=$envelopePath; 'v1-production-signing-independent-validation.json'=$independentPath; 'v1-production-signing-certification-receipt.json'=$certificationReceiptPath;
    'fixture/package-manifest.json'=$packageManifestPath; 'fixture/release-notes.txt'=$releaseNotesPath; 'fixture/packages/a-first.bin'=$aArtifact; 'fixture/packages/z-last.bin'=$zArtifact
}
foreach ($entry in $reviewFiles.GetEnumerator()) {
    $sourcePath=[string]($entry.Value); $entryName=[string]($entry.Key); $destinationPath=Join-Path -Path $reviewRoot -ChildPath $entryName.Replace('/',[IO.Path]::DirectorySeparatorChar)
    $parent=Split-Path -Parent $destinationPath; if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::Copy($sourcePath,$destinationPath,$false)
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($reviewRoot,$reviewZip,[IO.Compression.CompressionLevel]::Optimal,$false)

Write-Information '[7/7] Final review membership and closure summary'
$zip=[IO.Compression.ZipFile]::OpenRead($reviewZip)
try { $entries=@($zip.Entries | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { $_.FullName.Replace('\','/') } | Sort-Object) }
finally { $zip.Dispose() }
$expectedEntries=@($reviewFiles.Keys | Sort-Object)
if ($entries.Count -ne 10 -or ($entries -join "`n") -cne ($expectedEntries -join "`n")) { throw ('Production signing review ZIP content mismatch: {0}' -f ($entries -join ', ')) }
$result=[pscustomobject][ordered]@{
    schema_version=1; status='passed'; authority='nxb-v1-production-signing-certification-v1'; release_head=$currentHead; certified_implementation_head=$certifiedImplementation;
    release_integration_predecessor_head=$predecessor; ps7='18/18'; ps51='18/18'; independent_requirements=12; independent_negative_controls=8;
    base_known_error_rules=[int]$baseScan.rule_count; production_extension_rules=[int]$productionScan.extension_rule_count; production_schema_contracts=[int]$productionScan.schema_contract_count;
    production_guard_contracts=[int]$productionScan.guard_contract_count; release_known_error_rules=[int]$releaseScan.rule_count; known_error_findings=0; analyzer_findings=0;
    signing_algorithm='RSA-PKCS1-SHA256'; key_size_bits=[int]$envelope.key_size_bits; public_fingerprint=[string]$envelope.public_key.fingerprint;
    production_signer_claimed=$false; actual_production_release_signed=$false; production_signing_pipeline_certified=$true;
    receipt_path=$certificationReceiptPath; receipt_sha256=(Get-NxbV1SigningFileSha256 -Path $certificationReceiptPath); envelope_path=$envelopePath; envelope_sha256=(Get-NxbV1SigningFileSha256 -Path $envelopePath);
    review_zip_path=$reviewZip; review_zip_sha256=(Get-NxbV1SigningFileSha256 -Path $reviewZip)
}
Write-Information ('NXB v1 production signing certification passed: head={0} PS7=18/18 PS5.1=18/18 independent=12/12 negatives=8/8 RSA={1} release_rules=1 findings=0 production_signer=false actual_release_signed=false.' -f $currentHead,[int]$envelope.key_size_bits)
if ($PassThru) { $result }
