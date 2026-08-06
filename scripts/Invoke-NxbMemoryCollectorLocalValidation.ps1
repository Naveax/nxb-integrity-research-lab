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

function Write-NxbMemoryCollectorUtf8NoBom {
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

function ConvertTo-NxbMemoryCollectorLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "'$($Value.Replace("'", "''"))'"
}

function Resolve-NxbMemoryCollectorExecutable {
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

function Test-NxbMemoryCollectorAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-NxbMemoryCollectorChild {
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
    Write-NxbMemoryCollectorUtf8NoBom -Path $LogPath -Content $text

    return [pscustomobject]@{
        exit_code = $exitCode
        text = $text
    }
}

function Add-NxbMemoryCollectorGate {
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
    throw 'Memory collector validation requires real Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Memory collector validation requires PowerShell 7.'
}
if (-not (Test-NxbMemoryCollectorAdministrator)) {
    throw 'Memory collector validation requires elevated PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitPath = Resolve-NxbMemoryCollectorExecutable -Candidate @('git.exe', 'git')
$pwshPath = Resolve-NxbMemoryCollectorExecutable -Candidate @('pwsh.exe', 'pwsh')
$pythonPath = Resolve-NxbMemoryCollectorExecutable -Candidate @(
    'python.exe',
    'python',
    'py.exe',
    'py'
)
$wprPath = Resolve-NxbMemoryCollectorExecutable -Candidate @('wpr.exe', 'wpr')
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
        throw "Required executable missing: $($entry.Key)"
    }
}

$currentHead = (
    & $gitPath -C $repositoryRoot rev-parse HEAD 2>&1 |
        Out-String
).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch '^[0-9a-f]{40}$') {
    throw "Unable to resolve Git HEAD: $currentHead"
}
if ($currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}

$workingTree = @(
    & $gitPath `
        -C $repositoryRoot `
        status `
        --porcelain=v1 `
        --untracked-files=all 2>&1
)
if ($LASTEXITCODE -ne 0) {
    throw 'Unable to inspect Git working tree.'
}
if ($workingTree.Count -gt 0) {
    throw (
        "Exact-head validation requires a clean working tree:`n" +
        ($workingTree -join [Environment]::NewLine)
    )
}

$foundationRunner = Join-Path `
    $PSScriptRoot `
    'Invoke-NxbMemoryFoundationLocalValidationV2.ps1'
$collectorPath = Join-Path $PSScriptRoot 'New-NxbMemorySnapshot.ps1'
$smokePath = Join-Path $PSScriptRoot 'Test-MemoryProfileRepositorySmoke.ps1'
$collectorTestPath = Join-Path `
    $repositoryRoot `
    'tests\MemorySnapshotCollector.Tests.ps1'
$settingsPath = Join-Path `
    $repositoryRoot `
    '.github\PSScriptAnalyzerSettings.psd1'
foreach ($requiredFile in @(
    $foundationRunner,
    $collectorPath,
    $smokePath,
    $collectorTestPath,
    $settingsPath
)) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Required validation input missing: $requiredFile"
    }
}

if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $ResultsRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "nxb-memory-collector-$($currentHead.Substring(0, 12))-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)
if (Test-Path -LiteralPath $resultsFull) {
    throw "Validation results directory already exists: $resultsFull"
}
[IO.Directory]::CreateDirectory($resultsFull) | Out-Null
$logsRoot = Join-Path $resultsFull 'logs'
[IO.Directory]::CreateDirectory($logsRoot) | Out-Null
$foundationResultsRoot = Join-Path $resultsFull 'foundation-validation'
$summaryPath = Join-Path $resultsFull 'memory-collector-validation-summary.json'
$ps7XmlPath = Join-Path $resultsFull 'pester-memory-collector-pwsh.xml'
$ps51XmlPath = Join-Path $resultsFull 'pester-memory-collector-ps51.xml'
$reviewZip = Join-Path $HOME (
    'Downloads\' +
    (Split-Path -Leaf $resultsFull) +
    '-review.zip'
)
$gates = [Collections.Generic.List[object]]::new()
$validationStartedUtc = [DateTime]::UtcNow
$failureMessage = $null

$repositoryLiteral = ConvertTo-NxbMemoryCollectorLiteral -Value $repositoryRoot
$settingsLiteral = ConvertTo-NxbMemoryCollectorLiteral -Value $settingsPath
$collectorTestLiteral = ConvertTo-NxbMemoryCollectorLiteral -Value $collectorTestPath
$ps7XmlLiteral = ConvertTo-NxbMemoryCollectorLiteral -Value $ps7XmlPath
$ps51XmlLiteral = ConvertTo-NxbMemoryCollectorLiteral -Value $ps51XmlPath

try {
    $foundationLog = Join-Path $logsRoot 'memory-foundation-v2.log'
    try {
        $foundationOutput = @(
            & $foundationRunner `
                -ExpectedHead $currentHead `
                -ResultsRoot $foundationResultsRoot `
                -BootstrapDependencies:$BootstrapDependencies `
                -PassThru 2>&1
        )
        Write-NxbMemoryCollectorUtf8NoBom `
            -Path $foundationLog `
            -Content (@($foundationOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        Add-NxbMemoryCollectorGate `
            -GateList $gates `
            -Name 'memory-foundation-v2' `
            -Status passed `
            -ExitCode 0 `
            -LogPath $foundationLog
    }
    catch {
        Write-NxbMemoryCollectorUtf8NoBom `
            -Path $foundationLog `
            -Content ($_ | Out-String)
        Add-NxbMemoryCollectorGate `
            -GateList $gates `
            -Name 'memory-foundation-v2' `
            -Status failed `
            -ExitCode 1 `
            -LogPath $foundationLog `
            -Reason 'Nested memory foundation V2 validation failed.'
    }

    $parserLog = Join-Path $logsRoot 'memory-collector-parser.log'
    $parser = Invoke-NxbMemoryCollectorChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
`$paths = @(
    (Join-Path $repositoryLiteral 'scripts\New-NxbMemorySnapshot.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Test-MemoryProfileRepositorySmoke.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Invoke-NxbMemoryCollectorLocalValidation.ps1'),
    (Join-Path $repositoryLiteral 'tests\MemorySnapshotCollector.Tests.ps1')
)
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
Write-Output 'Memory collector parser clean.'
"@ `
        -LogPath $parserLog
    Add-NxbMemoryCollectorGate `
        -GateList $gates `
        -Name 'memory-collector-parser' `
        -Status $(if ($parser.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $parser.exit_code `
        -LogPath $parserLog `
        -Reason $(if ($parser.exit_code -eq 0) {
            $null
        }
        else {
            'Memory collector PowerShell parser failed.'
        })

    $analyzerLog = Join-Path $logsRoot 'memory-collector-psscriptanalyzer.log'
    $analyzer = Invoke-NxbMemoryCollectorChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -Force
`$paths = @(
    (Join-Path $repositoryLiteral 'scripts\New-NxbMemorySnapshot.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Test-MemoryProfileRepositorySmoke.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Invoke-NxbMemoryCollectorLocalValidation.ps1'),
    (Join-Path $repositoryLiteral 'tests\MemorySnapshotCollector.Tests.ps1')
)
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
    throw "PSScriptAnalyzer produced `$(`$findings.Count) finding(s)."
}
Write-Output 'Memory collector PSScriptAnalyzer: 0 findings.'
"@ `
        -LogPath $analyzerLog
    Add-NxbMemoryCollectorGate `
        -GateList $gates `
        -Name 'memory-collector-psscriptanalyzer' `
        -Status $(if ($analyzer.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $analyzer.exit_code `
        -LogPath $analyzerLog `
        -Reason $(if ($analyzer.exit_code -eq 0) {
            $null
        }
        else {
            'Memory collector PSScriptAnalyzer failed.'
        })

    $ps7Log = Join-Path $logsRoot 'pester-memory-collector-pwsh.log'
    $ps7 = Invoke-NxbMemoryCollectorChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
`$module = Get-Module -ListAvailable Pester |
    Where-Object Version -GE ([version]'5.0.0') |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (`$null -eq `$module) { throw 'Pester >= 5 is missing for PowerShell 7.' }
Import-Module `$module.Path -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($collectorTestLiteral)
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputPath = $ps7XmlLiteral
`$configuration.TestResult.OutputFormat = 'NUnitXml'
Invoke-Pester -Configuration `$configuration
"@ `
        -LogPath $ps7Log
    Add-NxbMemoryCollectorGate `
        -GateList $gates `
        -Name 'pester-memory-collector-pwsh' `
        -Status $(if ($ps7.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $ps7.exit_code `
        -LogPath $ps7Log `
        -Reason $(if ($ps7.exit_code -eq 0) {
            $null
        }
        else {
            'PowerShell 7 memory collector Pester failed.'
        })

    $ps51ModulePath = Join-Path `
        ([Environment]::GetFolderPath('MyDocuments')) `
        'WindowsPowerShell\Modules\Pester\5.7.1\Pester.psd1'
    $ps51ModuleLiteral = ConvertTo-NxbMemoryCollectorLiteral -Value $ps51ModulePath
    $ps51Log = Join-Path $logsRoot 'pester-memory-collector-ps51.log'
    $ps51 = Invoke-NxbMemoryCollectorChild `
        -ExecutablePath $windowsPowerShellPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ps51ModuleLiteral -PathType Leaf)) {
    throw 'Pester 5.7.1 is missing for Windows PowerShell 5.1.'
}
Import-Module $ps51ModuleLiteral -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($collectorTestLiteral)
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputPath = $ps51XmlLiteral
`$configuration.TestResult.OutputFormat = 'NUnitXml'
Invoke-Pester -Configuration `$configuration
"@ `
        -LogPath $ps51Log
    Add-NxbMemoryCollectorGate `
        -GateList $gates `
        -Name 'pester-memory-collector-ps51' `
        -Status $(if ($ps51.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $ps51.exit_code `
        -LogPath $ps51Log `
        -Reason $(if ($ps51.exit_code -eq 0) {
            $null
        }
        else {
            'Windows PowerShell 5.1 memory collector Pester failed.'
        })
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    $validationStoppedUtc = [DateTime]::UtcNow
    $failedGates = @($gates | Where-Object status -eq 'failed')
    $status = if ([string]::IsNullOrWhiteSpace($failureMessage) -and
        $failedGates.Count -eq 0) {
        'passed'
    }
    else {
        'failed'
    }

    $foundationSummaryPath = Join-Path `
        $foundationResultsRoot `
        'memory-foundation-validation-summary.json'
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
        foundation_validation_summary_path = if (
            Test-Path -LiteralPath $foundationSummaryPath -PathType Leaf
        ) {
            $foundationSummaryPath
        }
        else {
            $null
        }
        gates = @($gates)
    }
    Write-NxbMemoryCollectorUtf8NoBom `
        -Path $summaryPath `
        -Content ($summary | ConvertTo-Json -Depth 32)

    if (Test-Path -LiteralPath $reviewZip -PathType Leaf) {
        Remove-Item -LiteralPath $reviewZip -Force
    }
    $reviewInput = Join-Path $resultsFull '*'
    Compress-Archive `
        -Path $reviewInput `
        -DestinationPath $reviewZip `
        -CompressionLevel Optimal

    Write-Host "Memory collector validation summary: $summaryPath"
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
        "Memory collector exact-head validation failed:`n" +
        ($reasons -join [Environment]::NewLine)
    )
}

Write-Host 'Memory collector exact-head validation completed.'
if ($PassThru) {
    $finalSummary
}
