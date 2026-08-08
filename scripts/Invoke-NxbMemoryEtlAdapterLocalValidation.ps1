[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [string]$ResultsRoot,

    [Parameter()]
    [switch]$BootstrapDependencies,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbMemoryEtlUtf8NoBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [IO.File]::WriteAllText(
        $Path,
        $Content,
        [Text.UTF8Encoding]::new($false)
    )
}

function ConvertTo-NxbMemoryEtlLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "'$($Value.Replace("'", "''"))'"
}

function Resolve-NxbMemoryEtlExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Candidate
    )

    foreach ($name in $Candidate) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [string]$command.Source
        }
    }
    return $null
}

function Test-NxbMemoryEtlAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-NxbMemoryEtlChild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [string]$CommandText,

        [Parameter(Mandatory)]
        [string]$LogPath
    )

    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($CommandText)
    )
    $output = @()
    $exitCode = 1
    try {
        $output = @(
            & $ExecutablePath `
                -NoLogo `
                -NoProfile `
                -NonInteractive `
                -ExecutionPolicy Bypass `
                -EncodedCommand $encoded 2>&1
        )
        $exitCode = if ($null -eq $LASTEXITCODE) {
            1
        }
        else {
            [int]$LASTEXITCODE
        }
    }
    catch {
        $output += ($_ | Out-String)
    }

    $text = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    Write-NxbMemoryEtlUtf8NoBom -Path $LogPath -Content $text

    return [pscustomobject]@{
        exit_code = $exitCode
        text = $text
    }
}

function Add-NxbMemoryEtlGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$GateList,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('passed', 'failed')]
        [string]$Status,

        [Parameter()]
        [Nullable[int]]$ExitCode,

        [Parameter()]
        [string]$LogPath,

        [Parameter()]
        [string]$Reason
    )

    $GateList.Add([pscustomobject][ordered]@{
        name = $Name
        status = $Status
        exit_code = if ($PSBoundParameters.ContainsKey('ExitCode')) {
            $ExitCode
        }
        else {
            $null
        }
        log_path = $LogPath
        reason = $Reason
    })
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Memory ETL adapter validation requires real Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Memory ETL adapter validation must run in PowerShell 7.'
}
if (-not (Test-NxbMemoryEtlAdministrator)) {
    throw 'Memory ETL adapter validation requires elevated PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitPath = Resolve-NxbMemoryEtlExecutable -Candidate @('git.exe', 'git')
$pwshPath = Resolve-NxbMemoryEtlExecutable -Candidate @('pwsh.exe', 'pwsh')
$pythonPath = Resolve-NxbMemoryEtlExecutable -Candidate @(
    'python.exe',
    'python',
    'py.exe',
    'py'
)
$wprPath = Resolve-NxbMemoryEtlExecutable -Candidate @('wpr.exe', 'wpr')
$windowsPowerShellPath = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'

$requiredExecutables = [ordered]@{
    git = $gitPath
    pwsh = $pwshPath
    python = $pythonPath
    wpr = $wprPath
    windows_powershell = $windowsPowerShellPath
}
foreach ($entry in $requiredExecutables.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value) -or
        -not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
        throw "Required executable not found: $($entry.Key)"
    }
}

$currentHead = (
    & $gitPath -C $repositoryRoot rev-parse HEAD 2>&1 |
        Out-String
).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch '^[0-9a-f]{40}$') {
    throw "Git HEAD could not be resolved: $currentHead"
}
if ($currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw (
        "Exact-head mismatch. Expected: $ExpectedHead; " +
        "actual: $currentHead"
    )
}

$workingTree = @(
    & $gitPath `
        -C $repositoryRoot `
        status `
        --porcelain=v1 `
        --untracked-files=all 2>&1
)
if ($LASTEXITCODE -ne 0) {
    throw 'Git working-tree status could not be read.'
}
if ($workingTree.Count -gt 0) {
    throw (
        "Exact-head validation requires a clean working tree:`n" +
        ($workingTree -join [Environment]::NewLine)
    )
}

$collectorRunner = Join-Path `
    $PSScriptRoot `
    'Invoke-NxbMemoryCollectorLocalValidation.ps1'
$validatorWrapper = Join-Path $PSScriptRoot 'Test-MemoryEtlSummary.ps1'
$adapterPath = Join-Path `
    $PSScriptRoot `
    'ConvertFrom-NxbMemoryEventExport.ps1'
$pythonValidator = Join-Path `
    $repositoryRoot `
    'tools\validate_memory_etl_summary.py'
$contractTests = Join-Path `
    $repositoryRoot `
    'tests\MemoryEtlSummary.Tests.ps1'
$adapterTests = Join-Path `
    $repositoryRoot `
    'tests\MemoryEventExportAdapter.Tests.ps1'
$settingsPath = Join-Path `
    $repositoryRoot `
    '.github\PSScriptAnalyzerSettings.psd1'

$requiredFiles = @(
    $collectorRunner,
    $validatorWrapper,
    $adapterPath,
    $pythonValidator,
    $contractTests,
    $adapterTests,
    $settingsPath,
    $PSCommandPath
)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Memory ETL validation input not found: $requiredFile"
    }
}

if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $ResultsRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "nxb-memory-etl-adapter-$($currentHead.Substring(0, 12))-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)
if (Test-Path -LiteralPath $resultsFull) {
    throw "Validation results directory already exists: $resultsFull"
}
[IO.Directory]::CreateDirectory($resultsFull) | Out-Null
$logsRoot = Join-Path $resultsFull 'logs'
[IO.Directory]::CreateDirectory($logsRoot) | Out-Null
$collectorResultsRoot = Join-Path $resultsFull 'collector-validation'
$summaryPath = Join-Path `
    $resultsFull `
    'memory-etl-adapter-validation-summary.json'
$reviewZip = Join-Path $HOME (
    'Downloads\' +
    (Split-Path -Leaf $resultsFull) +
    '-review.zip'
)
$ps7XmlPath = Join-Path $resultsFull 'pester-memory-etl-pwsh.xml'
$ps51XmlPath = Join-Path $resultsFull 'pester-memory-etl-ps51.xml'
$gates = [Collections.Generic.List[object]]::new()
$validationStartedUtc = [DateTime]::UtcNow
$failureMessage = $null

$pythonLiteral = ConvertTo-NxbMemoryEtlLiteral -Value $pythonPath
$pythonValidatorLiteral = ConvertTo-NxbMemoryEtlLiteral -Value $pythonValidator
$validatorWrapperLiteral = ConvertTo-NxbMemoryEtlLiteral -Value $validatorWrapper
$settingsLiteral = ConvertTo-NxbMemoryEtlLiteral -Value $settingsPath
$ps7XmlLiteral = ConvertTo-NxbMemoryEtlLiteral -Value $ps7XmlPath
$ps51XmlLiteral = ConvertTo-NxbMemoryEtlLiteral -Value $ps51XmlPath
$contractTestsLiteral = ConvertTo-NxbMemoryEtlLiteral -Value $contractTests
$adapterTestsLiteral = ConvertTo-NxbMemoryEtlLiteral -Value $adapterTests
$validationFiles = @(
    $validatorWrapper,
    $adapterPath,
    $PSCommandPath,
    $contractTests,
    $adapterTests
)
$validationFileLiterals = @(
    $validationFiles | ForEach-Object {
        ConvertTo-NxbMemoryEtlLiteral -Value $_
    }
)
$validationFilesCommand = $validationFileLiterals -join ', '

try {
    $collectorLog = Join-Path $logsRoot 'memory-collector-foundation.log'
    try {
        $collectorSummary = & $collectorRunner `
            -ExpectedHead $currentHead `
            -ResultsRoot $collectorResultsRoot `
            -BootstrapDependencies:$BootstrapDependencies `
            -PassThru
        if ([string]$collectorSummary.status -cne 'passed') {
            throw 'Nested collector summary is not passed.'
        }
        Write-NxbMemoryEtlUtf8NoBom `
            -Path $collectorLog `
            -Content ($collectorSummary | ConvertTo-Json -Depth 32)
        Add-NxbMemoryEtlGate `
            -GateList $gates `
            -Name 'memory-collector-foundation' `
            -Status passed `
            -ExitCode 0 `
            -LogPath $collectorLog
    }
    catch {
        Write-NxbMemoryEtlUtf8NoBom `
            -Path $collectorLog `
            -Content ($_ | Out-String)
        Add-NxbMemoryEtlGate `
            -GateList $gates `
            -Name 'memory-collector-foundation' `
            -Status failed `
            -ExitCode 1 `
            -LogPath $collectorLog `
            -Reason 'Nested memory collector validation failed.'
    }

    $pythonLog = Join-Path $logsRoot 'memory-etl-python-compile.log'
    $pythonCompile = Invoke-NxbMemoryEtlChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
& $pythonLiteral -m py_compile $pythonValidatorLiteral
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
Write-Output 'Memory ETL Python compile passed.'
"@ `
        -LogPath $pythonLog
    Add-NxbMemoryEtlGate `
        -GateList $gates `
        -Name 'memory-etl-python-compile' `
        -Status $(if ($pythonCompile.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $pythonCompile.exit_code `
        -LogPath $pythonLog `
        -Reason $(if ($pythonCompile.exit_code -eq 0) {
            $null
        }
        else {
            'Memory ETL Python validator did not compile.'
        })

    $parserLog = Join-Path $logsRoot 'memory-etl-powershell-parser.log'
    $parser = Invoke-NxbMemoryEtlChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
`$paths = @($validationFilesCommand)
foreach (`$path in `$paths) {
    `$tokens = `$null
    `$errors = `$null
    [Management.Automation.Language.Parser]::ParseFile(
        `$path,
        [ref]`$tokens,
        [ref]`$errors
    ) | Out-Null
    if (@(`$errors).Count -gt 0) {
        throw ((@(`$errors | ForEach-Object { `$_.Message })) -join [Environment]::NewLine)
    }
}
Write-Output 'Memory ETL PowerShell parser passed.'
"@ `
        -LogPath $parserLog
    Add-NxbMemoryEtlGate `
        -GateList $gates `
        -Name 'memory-etl-powershell-parser' `
        -Status $(if ($parser.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $parser.exit_code `
        -LogPath $parserLog `
        -Reason $(if ($parser.exit_code -eq 0) {
            $null
        }
        else {
            'Memory ETL PowerShell parser failed.'
        })

    $analyzerLog = Join-Path $logsRoot 'memory-etl-psscriptanalyzer.log'
    $analyzer = Invoke-NxbMemoryEtlChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -Force
`$paths = @($validationFilesCommand)
`$findings = @(
    foreach (`$path in `$paths) {
        Invoke-ScriptAnalyzer -Path `$path -Settings $settingsLiteral
    }
)
if (`$findings.Count -gt 0) {
    `$findings |
        Select-Object Severity, ScriptName, Line, Column, RuleName, Message |
        Format-Table -Wrap -AutoSize |
        Out-String |
        Write-Output
    throw "PSScriptAnalyzer `$(`$findings.Count) finding(s)."
}
Write-Output 'Memory ETL PSScriptAnalyzer: 0 findings.'
"@ `
        -LogPath $analyzerLog
    Add-NxbMemoryEtlGate `
        -GateList $gates `
        -Name 'memory-etl-psscriptanalyzer' `
        -Status $(if ($analyzer.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $analyzer.exit_code `
        -LogPath $analyzerLog `
        -Reason $(if ($analyzer.exit_code -eq 0) {
            $null
        }
        else {
            'Memory ETL PSScriptAnalyzer failed.'
        })

    $contractLog = Join-Path $logsRoot 'memory-etl-contract.log'
    $contract = Invoke-NxbMemoryEtlChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
& $validatorWrapperLiteral
Write-Output 'Memory ETL contract passed.'
"@ `
        -LogPath $contractLog
    Add-NxbMemoryEtlGate `
        -GateList $gates `
        -Name 'memory-etl-contract' `
        -Status $(if ($contract.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $contract.exit_code `
        -LogPath $contractLog `
        -Reason $(if ($contract.exit_code -eq 0) {
            $null
        }
        else {
            'Memory ETL schema or semantic contract failed.'
        })

    $ps7Log = Join-Path $logsRoot 'pester-memory-etl-pwsh.log'
    $ps7 = Invoke-NxbMemoryEtlChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
`$module = Get-Module -ListAvailable Pester |
    Where-Object Version -GE ([version]'5.0.0') |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (`$null -eq `$module) { throw 'PowerShell 7 Pester >= 5 not found.' }
Import-Module `$module.Path -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($contractTestsLiteral, $adapterTestsLiteral)
`$configuration.Run.Exit = `$false
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputPath = $ps7XmlLiteral
`$configuration.TestResult.OutputFormat = 'NUnitXml'
`$result = Invoke-Pester -Configuration `$configuration
if (`$result.TotalCount -ne 18 -or `$result.FailedCount -ne 0 -or `$result.SkippedCount -ne 0 -or `$result.NotRunCount -ne 0) {
    throw "Unexpected Pester result: total=`$(`$result.TotalCount) failed=`$(`$result.FailedCount) skipped=`$(`$result.SkippedCount) notrun=`$(`$result.NotRunCount)"
}
"@ `
        -LogPath $ps7Log
    Add-NxbMemoryEtlGate `
        -GateList $gates `
        -Name 'pester-memory-etl-pwsh' `
        -Status $(if ($ps7.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $ps7.exit_code `
        -LogPath $ps7Log `
        -Reason $(if ($ps7.exit_code -eq 0) {
            $null
        }
        else {
            'PowerShell 7 memory ETL Pester failed.'
        })

    $ps51ModulePath = Join-Path `
        ([Environment]::GetFolderPath('MyDocuments')) `
        'WindowsPowerShell\Modules\Pester\5.7.1\Pester.psd1'
    $ps51ModuleLiteral = ConvertTo-NxbMemoryEtlLiteral -Value $ps51ModulePath
    $ps51Log = Join-Path $logsRoot 'pester-memory-etl-ps51.log'
    $ps51 = Invoke-NxbMemoryEtlChild `
        -ExecutablePath $windowsPowerShellPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ps51ModuleLiteral -PathType Leaf)) {
    throw 'Windows PowerShell Pester 5.7.1 not found.'
}
Import-Module $ps51ModuleLiteral -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($contractTestsLiteral, $adapterTestsLiteral)
`$configuration.Run.Exit = `$false
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputPath = $ps51XmlLiteral
`$configuration.TestResult.OutputFormat = 'NUnitXml'
`$result = Invoke-Pester -Configuration `$configuration
if (`$result.TotalCount -ne 18 -or `$result.FailedCount -ne 0 -or `$result.SkippedCount -ne 0 -or `$result.NotRunCount -ne 0) {
    throw "Unexpected Pester result: total=`$(`$result.TotalCount) failed=`$(`$result.FailedCount) skipped=`$(`$result.SkippedCount) notrun=`$(`$result.NotRunCount)"
}
"@ `
        -LogPath $ps51Log
    Add-NxbMemoryEtlGate `
        -GateList $gates `
        -Name 'pester-memory-etl-ps51' `
        -Status $(if ($ps51.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $ps51.exit_code `
        -LogPath $ps51Log `
        -Reason $(if ($ps51.exit_code -eq 0) {
            $null
        }
        else {
            'Windows PowerShell 5.1 memory ETL Pester failed.'
        })
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    $validationStoppedUtc = [DateTime]::UtcNow
    $failedGates = @($gates | Where-Object status -eq 'failed')
    $status = if (
        [string]::IsNullOrWhiteSpace($failureMessage) -and
        $failedGates.Count -eq 0
    ) {
        'passed'
    }
    else {
        'failed'
    }

    $collectorSummaryPath = Join-Path `
        $collectorResultsRoot `
        'memory-collector-validation-summary.json'
    $summary = [ordered]@{
        schema_version = 1
        status = $status
        head_sha = $currentHead
        expected_head_sha = $ExpectedHead.ToLowerInvariant()
        validation_started_utc = $validationStartedUtc.ToUniversalTime().ToString('o')
        validation_stopped_utc = $validationStoppedUtc.ToUniversalTime().ToString('o')
        failure_message = $failureMessage
        environment = [ordered]@{
            os = [Environment]::OSVersion.VersionString
            powershell = $PSVersionTable.PSVersion.ToString()
            edition = $PSVersionTable.PSEdition
            elevated = $true
            python_path = $pythonPath
            wpr_path = $wprPath
        }
        collector_validation_summary_path = if (
            Test-Path -LiteralPath $collectorSummaryPath -PathType Leaf
        ) {
            $collectorSummaryPath
        }
        else {
            $null
        }
        gates = @($gates)
    }
    Write-NxbMemoryEtlUtf8NoBom `
        -Path $summaryPath `
        -Content ($summary | ConvertTo-Json -Depth 32)

    if (Test-Path -LiteralPath $reviewZip -PathType Leaf) {
        Remove-Item -LiteralPath $reviewZip -Force
    }
    Compress-Archive `
        -Path (Join-Path $resultsFull '*') `
        -DestinationPath $reviewZip `
        -CompressionLevel Optimal

    Write-Host "Memory ETL adapter validation summary: $summaryPath"
    Write-Host "Review ZIP: $reviewZip"
}

$finalSummary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
if ([string]$finalSummary.status -cne 'passed') {
    $reasons = @(
        $finalSummary.gates |
            Where-Object status -eq 'failed' |
            ForEach-Object { "{0}: {1}" -f $_.name, $_.reason }
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$finalSummary.failure_message)) {
        $reasons += [string]$finalSummary.failure_message
    }
    throw (
        "Memory ETL adapter exact-head validation failed:`n" +
        ($reasons -join [Environment]::NewLine)
    )
}

Write-Host 'Memory ETL adapter exact-head validation completed.'
if ($PassThru) {
    $finalSummary
}
