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

function Write-NxbMemoryFoundationUtf8NoBom {
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

function ConvertTo-NxbMemoryFoundationLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "'$($Value.Replace("'", "''"))'"
}

function Resolve-NxbMemoryFoundationExecutable {
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

function Test-NxbMemoryFoundationAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-NxbMemoryFoundationChild {
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
    Write-NxbMemoryFoundationUtf8NoBom -Path $LogPath -Content $text

    return [pscustomobject]@{
        exit_code = $exitCode
        text = $text
    }
}

function Add-NxbMemoryFoundationGate {
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
    throw 'Memory foundation validation yalnız gerçek Windows ortamında çalışır.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Memory foundation validation PowerShell 7 içinde çalıştırılmalıdır.'
}
if (-not (Test-NxbMemoryFoundationAdministrator)) {
    throw 'Memory foundation validation için yönetici PowerShell 7 gereklidir.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitPath = Resolve-NxbMemoryFoundationExecutable -Candidate @('git.exe', 'git')
$pwshPath = Resolve-NxbMemoryFoundationExecutable -Candidate @('pwsh.exe', 'pwsh')
$pythonPath = Resolve-NxbMemoryFoundationExecutable -Candidate @(
    'python.exe',
    'python',
    'py.exe',
    'py'
)
$wprPath = Resolve-NxbMemoryFoundationExecutable -Candidate @('wpr.exe', 'wpr')
$windowsPowerShellPath = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'

$requiredPaths = [ordered]@{
    git = $gitPath
    pwsh = $pwshPath
    python = $pythonPath
    wpr = $wprPath
    windows_powershell = $windowsPowerShellPath
}
foreach ($entry in $requiredPaths.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$entry.Value) -or
        -not (Test-Path -LiteralPath $entry.Value -PathType Leaf)) {
        throw "Gerekli executable bulunamadı: $($entry.Key)"
    }
}

$currentHead = (
    & $gitPath -C $repositoryRoot rev-parse HEAD 2>&1 |
        Out-String
).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch '^[0-9a-f]{40}$') {
    throw "Git HEAD çözümlenemedi: $currentHead"
}
if ($currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw (
        "Exact-head uyuşmazlığı. Beklenen: $ExpectedHead; " +
        "mevcut: $currentHead"
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
    throw 'Git çalışma ağacı durumu okunamadı.'
}
if ($workingTree.Count -gt 0) {
    throw (
        "Exact-head validation için çalışma ağacı temiz olmalıdır:`n" +
        ($workingTree -join [Environment]::NewLine)
    )
}

if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $ResultsRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "nxb-memory-foundation-$($currentHead.Substring(0, 12))-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)
if (Test-Path -LiteralPath $resultsFull) {
    throw "Validation sonuç dizini zaten var: $resultsFull"
}
[IO.Directory]::CreateDirectory($resultsFull) | Out-Null
$logsRoot = Join-Path $resultsFull 'logs'
[IO.Directory]::CreateDirectory($logsRoot) | Out-Null
$profileResultsRoot = Join-Path $resultsFull 'profile-validation'
$summaryPath = Join-Path $resultsFull 'memory-foundation-validation-summary.json'
$reviewZip = Join-Path $HOME (
    'Downloads\' +
    (Split-Path -Leaf $resultsFull) +
    '-review.zip'
)
$ps7XmlPath = Join-Path $resultsFull 'pester-memory-snapshot-pwsh.xml'
$ps51XmlPath = Join-Path $resultsFull 'pester-memory-snapshot-ps51.xml'
$gates = [Collections.Generic.List[object]]::new()
$validationStartedUtc = [DateTime]::UtcNow
$failureMessage = $null
$profileSummary = $null

$repositoryLiteral = ConvertTo-NxbMemoryFoundationLiteral -Value $repositoryRoot
$pythonLiteral = ConvertTo-NxbMemoryFoundationLiteral -Value $pythonPath
$settingsLiteral = ConvertTo-NxbMemoryFoundationLiteral -Value (
    Join-Path $repositoryRoot '.github\PSScriptAnalyzerSettings.psd1'
)
$snapshotTestLiteral = ConvertTo-NxbMemoryFoundationLiteral -Value (
    Join-Path $repositoryRoot 'tests\MemorySnapshot.Tests.ps1'
)
$ps7XmlLiteral = ConvertTo-NxbMemoryFoundationLiteral -Value $ps7XmlPath
$ps51XmlLiteral = ConvertTo-NxbMemoryFoundationLiteral -Value $ps51XmlPath

try {
    $pythonLog = Join-Path $logsRoot 'python-jsonschema.log'
    $pythonBootstrapCommand = if ($BootstrapDependencies) {
        @"
`$ErrorActionPreference = 'Stop'
& $pythonLiteral -c 'import jsonschema'
if (`$LASTEXITCODE -ne 0) {
    & $pythonLiteral -m pip install --user jsonschema
    if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
}
& $pythonLiteral -c 'import jsonschema; print(jsonschema.__version__)'
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
"@
    }
    else {
        @"
`$ErrorActionPreference = 'Stop'
& $pythonLiteral -c 'import jsonschema; print(jsonschema.__version__)'
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
"@
    }
    $pythonGate = Invoke-NxbMemoryFoundationChild `
        -ExecutablePath $pwshPath `
        -CommandText $pythonBootstrapCommand `
        -LogPath $pythonLog
    Add-NxbMemoryFoundationGate `
        -GateList $gates `
        -Name 'python-jsonschema' `
        -Status $(if ($pythonGate.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $pythonGate.exit_code `
        -LogPath $pythonLog `
        -Reason $(if ($pythonGate.exit_code -eq 0) {
            $null
        }
        else {
            'Python jsonschema doğrulama bağımlılığı kullanılamıyor.'
        })

    $profileLog = Join-Path $logsRoot 'profile-foundation.log'
    try {
        $profileSummary = & (Join-Path `
            $repositoryRoot `
            'scripts\Invoke-NxbMemoryProfileLocalValidation.ps1') `
            -ExpectedHead $currentHead `
            -ResultsRoot $profileResultsRoot `
            -BootstrapDependencies:$BootstrapDependencies `
            -PassThru 2>&1
        $profileText = @($profileSummary | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        Write-NxbMemoryFoundationUtf8NoBom -Path $profileLog -Content $profileText
        Add-NxbMemoryFoundationGate `
            -GateList $gates `
            -Name 'profile-foundation' `
            -Status passed `
            -ExitCode 0 `
            -LogPath $profileLog
    }
    catch {
        Write-NxbMemoryFoundationUtf8NoBom -Path $profileLog -Content ($_ | Out-String)
        Add-NxbMemoryFoundationGate `
            -GateList $gates `
            -Name 'profile-foundation' `
            -Status failed `
            -ExitCode 1 `
            -LogPath $profileLog `
            -Reason 'Bounded memory profile exact-head validation başarısız.'
    }

    $parserLog = Join-Path $logsRoot 'memory-snapshot-parser.log'
    $parser = Invoke-NxbMemoryFoundationChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
`$paths = @(
    (Join-Path $repositoryLiteral 'scripts\Test-MemorySnapshot.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Test-MemoryProfileRepositorySmoke.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Invoke-NxbMemoryFoundationLocalValidation.ps1'),
    (Join-Path $repositoryLiteral 'tests\MemorySnapshot.Tests.ps1')
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
Write-Output 'Memory snapshot PowerShell parser clean.'
"@ `
        -LogPath $parserLog
    Add-NxbMemoryFoundationGate `
        -GateList $gates `
        -Name 'memory-snapshot-parser' `
        -Status $(if ($parser.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $parser.exit_code `
        -LogPath $parserLog `
        -Reason $(if ($parser.exit_code -eq 0) {
            $null
        }
        else {
            'Memory snapshot PowerShell parser başarısız.'
        })

    $analyzerLog = Join-Path $logsRoot 'memory-snapshot-psscriptanalyzer.log'
    $analyzer = Invoke-NxbMemoryFoundationChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -Force
`$paths = @(
    (Join-Path $repositoryLiteral 'scripts\Test-MemorySnapshot.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Test-MemoryProfileRepositorySmoke.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Invoke-NxbMemoryFoundationLocalValidation.ps1'),
    (Join-Path $repositoryLiteral 'tests\MemorySnapshot.Tests.ps1')
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
    throw "PSScriptAnalyzer `$(`$findings.Count) bulgu üretti."
}
Write-Output 'Memory snapshot PSScriptAnalyzer: 0 findings.'
"@ `
        -LogPath $analyzerLog
    Add-NxbMemoryFoundationGate `
        -GateList $gates `
        -Name 'memory-snapshot-psscriptanalyzer' `
        -Status $(if ($analyzer.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $analyzer.exit_code `
        -LogPath $analyzerLog `
        -Reason $(if ($analyzer.exit_code -eq 0) {
            $null
        }
        else {
            'Memory snapshot PSScriptAnalyzer başarısız.'
        })

    $contractLog = Join-Path $logsRoot 'memory-snapshot-contract.log'
    $contract = Invoke-NxbMemoryFoundationChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $repositoryLiteral
& ./scripts/Test-MemorySnapshot.ps1 `
    -Path ./tests/fixtures/memory-snapshot.valid.json `
    -SchemaPath ./schemas/memory-snapshot.schema.json
"@ `
        -LogPath $contractLog
    Add-NxbMemoryFoundationGate `
        -GateList $gates `
        -Name 'memory-snapshot-contract' `
        -Status $(if ($contract.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $contract.exit_code `
        -LogPath $contractLog `
        -Reason $(if ($contract.exit_code -eq 0) {
            $null
        }
        else {
            'Memory snapshot schema veya semantic contract başarısız.'
        })

    $ps7Log = Join-Path $logsRoot 'pester-memory-snapshot-pwsh.log'
    $ps7 = Invoke-NxbMemoryFoundationChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
`$module = Get-Module -ListAvailable Pester |
    Where-Object Version -GE ([version]'5.0.0') |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (`$null -eq `$module) { throw 'PowerShell 7 için Pester >= 5 bulunamadı.' }
Import-Module `$module.Path -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($snapshotTestLiteral)
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputPath = $ps7XmlLiteral
`$configuration.TestResult.OutputFormat = 'NUnitXml'
Invoke-Pester -Configuration `$configuration
"@ `
        -LogPath $ps7Log
    Add-NxbMemoryFoundationGate `
        -GateList $gates `
        -Name 'pester-memory-snapshot-pwsh' `
        -Status $(if ($ps7.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $ps7.exit_code `
        -LogPath $ps7Log `
        -Reason $(if ($ps7.exit_code -eq 0) {
            $null
        }
        else {
            'PowerShell 7 memory snapshot Pester başarısız.'
        })

    $ps51ModulePath = Join-Path `
        ([Environment]::GetFolderPath('MyDocuments')) `
        'WindowsPowerShell\Modules\Pester\5.7.1\Pester.psd1'
    $ps51ModuleLiteral = ConvertTo-NxbMemoryFoundationLiteral -Value $ps51ModulePath
    $ps51Log = Join-Path $logsRoot 'pester-memory-snapshot-ps51.log'
    $ps51 = Invoke-NxbMemoryFoundationChild `
        -ExecutablePath $windowsPowerShellPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ps51ModuleLiteral -PathType Leaf)) {
    throw 'Windows PowerShell Pester 5.7.1 bulunamadı.'
}
Import-Module $ps51ModuleLiteral -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($snapshotTestLiteral)
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputPath = $ps51XmlLiteral
`$configuration.TestResult.OutputFormat = 'NUnitXml'
Invoke-Pester -Configuration `$configuration
"@ `
        -LogPath $ps51Log
    Add-NxbMemoryFoundationGate `
        -GateList $gates `
        -Name 'pester-memory-snapshot-ps51' `
        -Status $(if ($ps51.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $ps51.exit_code `
        -LogPath $ps51Log `
        -Reason $(if ($ps51.exit_code -eq 0) {
            $null
        }
        else {
            'Windows PowerShell 5.1 memory snapshot Pester başarısız.'
        })
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    $validationStoppedUtc = [DateTime]::UtcNow
    $failedGates = @($gates | Where-Object status -eq 'failed')
    $status = if ([string]::IsNullOrWhiteSpace($failureMessage) -and $failedGates.Count -eq 0) {
        'passed'
    }
    else {
        'failed'
    }

    $profileSummaryPath = Join-Path `
        $profileResultsRoot `
        'memory-profile-validation-summary.json'
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
        profile_validation_summary_path = if (
            Test-Path -LiteralPath $profileSummaryPath -PathType Leaf
        ) {
            $profileSummaryPath
        }
        else {
            $null
        }
        gates = @($gates)
    }
    Write-NxbMemoryFoundationUtf8NoBom `
        -Path $summaryPath `
        -Content ($summary | ConvertTo-Json -Depth 32)

    $reviewFiles = @(
        $summaryPath,
        $profileSummaryPath,
        $ps7XmlPath,
        $ps51XmlPath
    )
    $reviewFiles += @(
        Get-ChildItem -LiteralPath $logsRoot -File -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty FullName
    )
    $existingReviewFiles = @($reviewFiles | Where-Object {
        Test-Path -LiteralPath $_ -PathType Leaf
    })
    if ($existingReviewFiles.Count -gt 0) {
        if (Test-Path -LiteralPath $reviewZip -PathType Leaf) {
            Remove-Item -LiteralPath $reviewZip -Force
        }
        Compress-Archive `
            -LiteralPath $existingReviewFiles `
            -DestinationPath $reviewZip `
            -CompressionLevel Optimal
    }

    Write-Host "Memory foundation validation summary: $summaryPath"
    if (Test-Path -LiteralPath $reviewZip -PathType Leaf) {
        Write-Host "Review ZIP: $reviewZip"
    }
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
        "Memory foundation exact-head validation başarısız:`n" +
        ($reasons -join [Environment]::NewLine)
    )
}

Write-Host 'Memory foundation exact-head validation tamamlandı.'
if ($PassThru) {
    $finalSummary
}
