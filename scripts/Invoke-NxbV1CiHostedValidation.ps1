[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($env:OS -cne 'Windows_NT') { throw 'NXB v1 hosted CI validation requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'NXB v1 hosted CI validation requires PowerShell Core.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $pythonCommand) { $pythonCommand = Get-Command python -ErrorAction Stop }
$python = [string]$pythonCommand.Source

$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Hosted CI exact-head mismatch: expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Hosted CI requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) { throw ('Hosted CI output already exists: {0}' -f $outputFull) }
[IO.Directory]::CreateDirectory($outputFull) | Out-Null

$pester7 = Get-Module -ListAvailable Pester | Where-Object Version -eq ([version]'5.7.1') | Select-Object -First 1
if ($null -eq $pester7) { throw 'Hosted CI requires Pester 5.7.1.' }
$analyzerModule = Get-Module -ListAvailable PSScriptAnalyzer | Where-Object Version -eq ([version]'1.25.0') | Select-Object -First 1
if ($null -eq $analyzerModule) { throw 'Hosted CI requires PSScriptAnalyzer 1.25.0.' }
Import-Module $analyzerModule.Path -Force

$ps51 = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $ps51 -PathType Leaf)) { throw 'Windows PowerShell 5.1 is missing.' }
$ps51Pester = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules\Pester\5.7.1\Pester.psd1'
if (-not (Test-Path -LiteralPath $ps51Pester -PathType Leaf)) { throw 'Windows PowerShell 5.1 Pester 5.7.1 is missing.' }

$pythonVersionText = @(& $python --version 2>&1) -join ' '
if ($LASTEXITCODE -ne 0 -or $pythonVersionText -notmatch '(?i)Python\s+(?<major>\d+)\.(?<minor>\d+)') { throw 'Unable to resolve hosted CI Python version.' }
$pythonMajor = [int]$Matches['major']
$pythonMinor = [int]$Matches['minor']
if ($pythonMajor -lt 3 -or ($pythonMajor -eq 3 -and $pythonMinor -lt 9)) { throw 'Hosted CI requires Python 3.9 or newer.' }

$dependencyProbeCode = 'import importlib.metadata as m; assert m.version("PyYAML") == "6.0.3"; assert m.version("jsonschema") == "4.26.0"; import yaml, jsonschema'
& $python -c $dependencyProbeCode
if ($LASTEXITCODE -ne 0) { throw 'Hosted CI Python dependency closure failed.' }

$testsPath = Join-Path $repositoryRoot 'tests'
$rootVariablePattern = [regex]::new('\$env:(?<name>NXB_[A-Z0-9_]+_REPOSITORY_ROOT)')
$ps51ExcludedTag = 'PS7Only'
$expectedPs51ExcludedTests = 7
$ps51TagPattern = [regex]::new("(?m)^\s*It\s+'[^']+'[^\r\n]*-Tag\s+'PS7Only'(?:\s|$)")
$ps51TaggedTestCount = 0
$rootVariableNames = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
foreach ($testFile in @(Get-ChildItem -LiteralPath $testsPath -Filter '*.ps1' -File)) {
    $testText = Get-Content -LiteralPath $testFile.FullName -Raw
    foreach ($rootVariableMatch in @($rootVariablePattern.Matches($testText))) {
        [void]$rootVariableNames.Add([string]$rootVariableMatch.Groups['name'].Value)
    }
    $ps51TaggedTestCount += $ps51TagPattern.Matches($testText).Count
}
if ($ps51TaggedTestCount -ne $expectedPs51ExcludedTests) {
    throw ('Hosted CI PS5.1 runtime partition drift: tag={0} expected={1} actual={2}' -f $ps51ExcludedTag,$expectedPs51ExcludedTests,$ps51TaggedTestCount)
}
foreach ($rootVariableName in $rootVariableNames) {
    [Environment]::SetEnvironmentVariable($rootVariableName,$repositoryRoot,[EnvironmentVariableTarget]::Process)
}

& (Join-Path $PSScriptRoot 'Test-PublicRepositoryContent.ps1') -RepositoryRoot $repositoryRoot
& (Join-Path $PSScriptRoot 'Test-Repository.ps1')

$settings = Join-Path $repositoryRoot '.github\PSScriptAnalyzerSettings.psd1'
$findings = @(
    Invoke-ScriptAnalyzer -Path (Join-Path $repositoryRoot 'scripts') -Recurse -Settings $settings
    Invoke-ScriptAnalyzer -Path (Join-Path $repositoryRoot 'tests') -Recurse -Settings $settings
)
if ($findings.Count -gt 0) {
    $detail = @($findings | Sort-Object ScriptName,Line,Column,RuleName | ForEach-Object { '{0}:{1}:{2} {3} {4}' -f $_.ScriptName,$_.Line,$_.Column,$_.RuleName,$_.Message }) -join [Environment]::NewLine
    throw ('Hosted CI PSScriptAnalyzer findings: {0}{1}{2}' -f $findings.Count,[Environment]::NewLine,$detail)
}

$tools = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'tools') -Filter '*.py' -File)
foreach ($tool in $tools) {
    & $python -m py_compile $tool.FullName
    if ($LASTEXITCODE -ne 0) { throw ('Python syntax validation failed: {0}' -f $tool.Name) }
}

$ps7ResultPath = Join-Path $outputFull 'pester-ps7.xml'
$ps51ResultPath = Join-Path $outputFull 'pester-ps51.xml'

Import-Module $pester7.Path -Force
$config = New-PesterConfiguration
$config.Run.Path = @($testsPath)
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
$config.TestResult.Enabled = $true
$config.TestResult.OutputFormat = 'NUnitXml'
$config.TestResult.OutputPath = $ps7ResultPath
$ps7Result = Invoke-Pester -Configuration $config
if ([int]$ps7Result.FailedCount -ne 0 -or [int]$ps7Result.SkippedCount -ne 0 -or [int]$ps7Result.NotRunCount -ne 0) { throw 'Hosted CI PS7 Pester failed, skipped, or excluded tests.' }

$runnerPath = Join-Path $outputFull 'run-ps51.ps1'
$summaryPath = Join-Path $outputFull 'ps51-summary.json'
$runner = @'
param([string]$TestsPath,[string]$ModulePath,[string]$ResultPath,[string]$SummaryPath,[string]$ExcludedTag,[int]$ExpectedExcludedCount)
$ErrorActionPreference='Stop'
Import-Module $ModulePath -Force
$config=New-PesterConfiguration
$config.Run.Path=@($TestsPath)
$config.Run.PassThru=$true
$config.Filter.ExcludeTag=@($ExcludedTag)
$config.Output.Verbosity='Normal'
$config.TestResult.Enabled=$true
$config.TestResult.OutputFormat='NUnitXml'
$config.TestResult.OutputPath=$ResultPath
$result=Invoke-Pester -Configuration $config
$summary=[pscustomobject][ordered]@{ passed=[int]$result.PassedCount; failed=[int]$result.FailedCount; skipped=[int]$result.SkippedCount; not_run=[int]$result.NotRunCount; total=[int]$result.TotalCount; excluded_tag=$ExcludedTag; expected_excluded=[int]$ExpectedExcludedCount }
[IO.File]::WriteAllText($SummaryPath,(($summary|ConvertTo-Json -Depth 4)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
if ($summary.failed -ne 0 -or $summary.skipped -ne 0 -or $summary.not_run -ne $ExpectedExcludedCount -or ($summary.passed + $summary.not_run) -ne $summary.total) { exit 1 }
'@
[IO.File]::WriteAllText($runnerPath,$runner,[Text.UTF8Encoding]::new($false))
& $ps51 -NoLogo -NoProfile -ExecutionPolicy Bypass -File $runnerPath -TestsPath $testsPath -ModulePath $ps51Pester -ResultPath $ps51ResultPath -SummaryPath $summaryPath -ExcludedTag $ps51ExcludedTag -ExpectedExcludedCount $expectedPs51ExcludedTests
$ps51Exit = $LASTEXITCODE
if ($ps51Exit -ne 0) { throw ('Hosted CI PS5.1 Pester failed or runtime partition drifted: exit={0}' -f $ps51Exit) }
$ps51Summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
if ([int]$ps51Summary.total -ne [int]$ps7Result.TotalCount) { throw 'Hosted CI PS5.1 discovery cardinality differs from PS7.' }
if ([int]$ps51Summary.not_run -ne $expectedPs51ExcludedTests -or [int]$ps51Summary.passed -ne ([int]$ps7Result.TotalCount - $expectedPs51ExcludedTests)) { throw 'Hosted CI PS5.1 compatible-partition cardinality drift.' }

$receipt = [pscustomobject][ordered]@{
    schema_version=1; status='passed'; authority='nxb-v1-ci-hosted-v1'; head_sha=$currentHead;
    pester_version='5.7.1'; psscriptanalyzer_version='1.25.0'; python_version=$pythonVersionText.Trim();
    pyyaml_version='6.0.3'; jsonschema_version='4.26.0'; test_repository_root_variables=$rootVariableNames.Count;
    analyzer_findings=0; python_files_compiled=$tools.Count;
    ps7_passed=[int]$ps7Result.PassedCount; ps7_total=[int]$ps7Result.TotalCount; ps7_not_run=[int]$ps7Result.NotRunCount;
    ps51_passed=[int]$ps51Summary.passed; ps51_total=[int]$ps51Summary.total; ps51_not_run=[int]$ps51Summary.not_run;
    ps51_excluded_tag=$ps51ExcludedTag; ps51_expected_excluded=$expectedPs51ExcludedTests;
    public_repository_guard=$true; repository_smoke=$true; production_release_updated=$false
}
$receiptPath = Join-Path $outputFull 'hosted-ci-receipt.json'
[IO.File]::WriteAllText($receiptPath,(($receipt|ConvertTo-Json -Depth 8)+[Environment]::NewLine),[Text.UTF8Encoding]::new($false))
if ($PassThru) { $receipt }
