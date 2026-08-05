[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter()]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [string]$ResultsRoot,

    [Parameter()]
    [ValidateRange(1, 20)]
    [int]$RepetitionCount = 3,

    [Parameter()]
    [ValidateRange(0, 5)]
    [int]$WarmupCount = 1,

    [Parameter()]
    [ValidateSet(
        'alternating_control_first',
        'alternating_capture_first',
        'control_then_capture',
        'capture_then_control'
    )]
    [string]$Ordering = 'alternating_control_first',

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [int]$Iterations = 1000,

    [Parameter()]
    [ValidateRange(1, 255)]
    [int]$Seed = 73,

    [Parameter()]
    [switch]$BootstrapDependencies,

    [Parameter()]
    [switch]$SkipNativeCalibration,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Out-NxbUtf8NoBom {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Path,

        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        [IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function ConvertTo-NxbPowerShellLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "'$($Value.Replace("'", "''"))'"
}

function Test-NxbAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Resolve-NxbExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Candidate
    )

    foreach ($name in $Candidate) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return [string]$command.Source
        }
    }
    return $null
}

function Invoke-NxbPowerShellGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$CommandText,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath
    )

    $startedUtc = [DateTime]::UtcNow
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($CommandText)
    )
    $output = @()
    $exitCode = 1
    try {
        $output = @(& $ExecutablePath `
            -NoLogo `
            -NoProfile `
            -NonInteractive `
            -ExecutionPolicy Bypass `
            -EncodedCommand $encoded 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    catch {
        $output += $_ | Out-String
        $exitCode = 1
    }
    finally {
        $stopwatch.Stop()
    }

    $rendered = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    Out-NxbUtf8NoBom -Path $LogPath -Content $rendered

    return [pscustomobject][ordered]@{
        name         = $Name
        status       = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
        exit_code    = $exitCode
        started_utc  = $startedUtc.ToString('o')
        stopped_utc  = [DateTime]::UtcNow.ToString('o')
        duration_ms  = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 3)
        log_path     = $LogPath
        reason       = if ($exitCode -eq 0) { $null } else { "Gate exit code: $exitCode" }
    }
}

function Invoke-NxbNativeGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPath
    )

    $startedUtc = [DateTime]::UtcNow
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $output = @()
    $exitCode = 0
    $reason = $null
    try {
        $output = @(& $Action 2>&1)
    }
    catch {
        $output += $_ | Out-String
        $exitCode = 1
        $reason = $_.Exception.Message
    }
    finally {
        $stopwatch.Stop()
    }

    $rendered = @($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    Out-NxbUtf8NoBom -Path $LogPath -Content $rendered

    return [pscustomobject][ordered]@{
        name         = $Name
        status       = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
        exit_code    = $exitCode
        started_utc  = $startedUtc.ToString('o')
        stopped_utc  = [DateTime]::UtcNow.ToString('o')
        duration_ms  = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 3)
        log_path     = $LogPath
        reason       = $reason
    }
}

function Get-NxbModuleVersion {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ExecutablePath,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$ModuleName
    )

    $moduleLiteral = ConvertTo-NxbPowerShellLiteral -Value $ModuleName
    $commandText = @"
`$module = Get-Module -ListAvailable $moduleLiteral |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (`$null -eq `$module) { exit 1 }
Write-Output `$module.Version.ToString()
"@
    $encoded = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($commandText)
    )
    $output = @(& $ExecutablePath `
        -NoLogo `
        -NoProfile `
        -NonInteractive `
        -ExecutionPolicy Bypass `
        -EncodedCommand $encoded 2>&1)
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return (@($output | ForEach-Object { [string]$_ }) -join '').Trim()
}

if ($env:OS -cne 'Windows_NT') {
    throw 'NXB local validation runner yalnız gerçek Windows ortamında çalışır.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitPath = Resolve-NxbExecutable -Candidate @('git.exe', 'git')
$pwshPath = Resolve-NxbExecutable -Candidate @('pwsh.exe', 'pwsh')
$windowsPowerShellPath = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'
$pythonPath = Resolve-NxbExecutable -Candidate @(
    'python.exe',
    'python',
    'py.exe',
    'py'
)
$wprPath = Resolve-NxbExecutable -Candidate @('wpr.exe', 'wpr')

if ([string]::IsNullOrWhiteSpace($gitPath)) {
    throw 'git executable bulunamadı.'
}
if ([string]::IsNullOrWhiteSpace($pwshPath)) {
    throw 'PowerShell 7 (pwsh.exe) bulunamadı.'
}
if (-not (Test-Path -LiteralPath $windowsPowerShellPath -PathType Leaf)) {
    throw 'Windows PowerShell 5.1 executable bulunamadı.'
}
if ([string]::IsNullOrWhiteSpace($pythonPath)) {
    throw 'Python executable bulunamadı.'
}
if ([string]::IsNullOrWhiteSpace($wprPath)) {
    throw 'wpr.exe bulunamadı.'
}

$currentHead = (& $gitPath -C $repositoryRoot rev-parse HEAD 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch '^[0-9a-f]{40}$') {
    throw "Git HEAD çözümlenemedi: $currentHead"
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedHead) -and
    $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head uyuşmazlığı. Beklenen: $ExpectedHead; mevcut: $currentHead"
}

$currentBranch = (& $gitPath -C $repositoryRoot branch --show-current 2>&1 | Out-String).Trim()
$workingTreeState = @(& $gitPath `
    -C $repositoryRoot `
    status `
    --porcelain=v1 `
    --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw 'Git çalışma ağacı durumu okunamadı.'
}
if ($workingTreeState.Count -gt 0) {
    throw (
        "Exact-head validation için çalışma ağacı temiz olmalıdır:`n" +
        ($workingTreeState -join [Environment]::NewLine)
    )
}

$shortHead = $currentHead.Substring(0, 12)
if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $ResultsRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "nxb-validation-$shortHead-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)
if (Test-Path -LiteralPath $resultsFull) {
    throw "Validation sonuç dizini zaten var: $resultsFull"
}
[IO.Directory]::CreateDirectory($resultsFull) | Out-Null
$logsRoot = Join-Path $resultsFull 'logs'
[IO.Directory]::CreateDirectory($logsRoot) | Out-Null

$gates = [Collections.Generic.List[object]]::new()
$validationStartedUtc = [DateTime]::UtcNow
$summaryPath = Join-Path $resultsFull 'validation-summary.json'
$failureMessage = $null

try {
    if ($BootstrapDependencies) {
        $bootstrapPwsh = @'
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
if (-not (Get-Module -ListAvailable Pester | Where-Object Version -GE 5.0)) {
    Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0 -Force -SkipPublisherCheck
}
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
}
'@
        $bootstrapPs51 = @'
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
if (-not (Get-Module -ListAvailable Pester | Where-Object Version -GE 5.0)) {
    Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0 -Force -SkipPublisherCheck
}
'@
        $gates.Add((Invoke-NxbPowerShellGate `
            -Name 'bootstrap-pwsh-modules' `
            -ExecutablePath $pwshPath `
            -CommandText $bootstrapPwsh `
            -LogPath (Join-Path $logsRoot 'bootstrap-pwsh-modules.log')))
        $gates.Add((Invoke-NxbPowerShellGate `
            -Name 'bootstrap-ps51-modules' `
            -ExecutablePath $windowsPowerShellPath `
            -CommandText $bootstrapPs51 `
            -LogPath (Join-Path $logsRoot 'bootstrap-ps51-modules.log')))

        $pythonOutput = @(& $pythonPath -m pip install --user jsonschema 2>&1)
        $pythonExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        $pythonLog = Join-Path $logsRoot 'bootstrap-python-jsonschema.log'
        Out-NxbUtf8NoBom `
            -Path $pythonLog `
            -Content (@($pythonOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        $gates.Add([pscustomobject][ordered]@{
            name = 'bootstrap-python-jsonschema'
            status = if ($pythonExit -eq 0) { 'passed' } else { 'failed' }
            exit_code = $pythonExit
            started_utc = $validationStartedUtc.ToString('o')
            stopped_utc = [DateTime]::UtcNow.ToString('o')
            duration_ms = $null
            log_path = $pythonLog
            reason = if ($pythonExit -eq 0) { $null } else { "pip exit code: $pythonExit" }
        })
    }

    $pesterPwshVersion = Get-NxbModuleVersion `
        -ExecutablePath $pwshPath `
        -ModuleName 'Pester'
    $pesterPs51Version = Get-NxbModuleVersion `
        -ExecutablePath $windowsPowerShellPath `
        -ModuleName 'Pester'
    $analyzerVersion = Get-NxbModuleVersion `
        -ExecutablePath $pwshPath `
        -ModuleName 'PSScriptAnalyzer'

    if ([string]::IsNullOrWhiteSpace($pesterPwshVersion)) {
        throw 'PowerShell 7 için Pester 5 bulunamadı. -BootstrapDependencies kullanın.'
    }
    if ([string]::IsNullOrWhiteSpace($pesterPs51Version)) {
        throw 'Windows PowerShell 5.1 için Pester 5 bulunamadı. -BootstrapDependencies kullanın.'
    }
    if ([string]::IsNullOrWhiteSpace($analyzerVersion)) {
        throw 'PSScriptAnalyzer bulunamadı. -BootstrapDependencies kullanın.'
    }

    $pythonVersionOutput = @(& $pythonPath -c `
        'import importlib.metadata; print(importlib.metadata.version("jsonschema"))' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw 'Python jsonschema paketi bulunamadı. -BootstrapDependencies kullanın.'
    }
    $jsonSchemaVersion = (@($pythonVersionOutput | ForEach-Object { [string]$_ }) -join '').Trim()

    $repositoryLiteral = ConvertTo-NxbPowerShellLiteral -Value $repositoryRoot
    $testsLiteral = ConvertTo-NxbPowerShellLiteral -Value (Join-Path $repositoryRoot 'tests')
    $settingsLiteral = ConvertTo-NxbPowerShellLiteral -Value (
        Join-Path $repositoryRoot '.github\PSScriptAnalyzerSettings.psd1'
    )
    $ps7XmlLiteral = ConvertTo-NxbPowerShellLiteral -Value (
        Join-Path $resultsFull 'pester-pwsh.xml'
    )
    $ps51XmlLiteral = ConvertTo-NxbPowerShellLiteral -Value (
        Join-Path $resultsFull 'pester-ps51.xml'
    )

    $publicGuardCommand = @"
Set-Location -LiteralPath $repositoryLiteral
& ./scripts/Test-PublicRepositoryContent.ps1 -RepositoryRoot $repositoryLiteral
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
"@
    $gates.Add((Invoke-NxbPowerShellGate `
        -Name 'public-repository-content' `
        -ExecutablePath $pwshPath `
        -CommandText $publicGuardCommand `
        -LogPath (Join-Path $logsRoot 'public-repository-content.log')))

    $profileLiteral = ConvertTo-NxbPowerShellLiteral -Value (
        Join-Path $repositoryRoot 'profiles\Nxb.MinimalCpuScheduler.wprp'
    )
    $wprLiteral = ConvertTo-NxbPowerShellLiteral -Value $wprPath
    $nativeProfileCommand = @"
`$output = @(& $wprLiteral -profiles $profileLiteral 2>&1)
`$exitCode = `$LASTEXITCODE
`$output | ForEach-Object { Write-Output `$_ }
if (`$exitCode -ne 0) { exit `$exitCode }
if ((`$output -join [Environment]::NewLine) -notmatch 'NxbMinimalCpuScheduler') {
    Write-Error 'Native WPR parser profile kimliğini enumerate etmedi.'
    exit 1
}
"@
    $gates.Add((Invoke-NxbPowerShellGate `
        -Name 'native-wpr-profile-parser' `
        -ExecutablePath $pwshPath `
        -CommandText $nativeProfileCommand `
        -LogPath (Join-Path $logsRoot 'native-wpr-profile-parser.log')))

    $analyzerCommand = @"
Import-Module PSScriptAnalyzer -Force
Set-Location -LiteralPath $repositoryLiteral
`$results = @(
    foreach (`$path in @('./scripts', './tests')) {
        Invoke-ScriptAnalyzer `
            -Path `$path `
            -Recurse `
            -Settings $settingsLiteral
    }
) | Sort-Object ScriptName, Line, Column, RuleName
foreach (`$result in `$results) {
    Write-Output ('ANALYZER|{0}|{1}|{2}|{3}|{4}|{5}' -f `
        `$result.Severity,
        `$result.ScriptName,
        `$result.Line,
        `$result.Column,
        `$result.RuleName,
        (([string]`$result.Message).Replace("`r", ' ').Replace("`n", ' ')))
}
if (`$results.Count -gt 0) { exit 1 }
Write-Output 'PSScriptAnalyzer: 0 Error/Warning findings.'
"@
    $gates.Add((Invoke-NxbPowerShellGate `
        -Name 'psscriptanalyzer' `
        -ExecutablePath $pwshPath `
        -CommandText $analyzerCommand `
        -LogPath (Join-Path $logsRoot 'psscriptanalyzer.log')))

    $smokeCommand = @"
Set-Location -LiteralPath $repositoryLiteral
& ./scripts/Test-Repository.ps1
"@
    $gates.Add((Invoke-NxbPowerShellGate `
        -Name 'repository-smoke' `
        -ExecutablePath $pwshPath `
        -CommandText $smokeCommand `
        -LogPath (Join-Path $logsRoot 'repository-smoke.log')))

    $pesterPwshCommand = @"
Import-Module Pester -MinimumVersion 5.0 -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($testsLiteral)
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputFormat = 'NUnitXml'
`$configuration.TestResult.OutputPath = $ps7XmlLiteral
Invoke-Pester -Configuration `$configuration
"@
    $gates.Add((Invoke-NxbPowerShellGate `
        -Name 'pester-pwsh' `
        -ExecutablePath $pwshPath `
        -CommandText $pesterPwshCommand `
        -LogPath (Join-Path $logsRoot 'pester-pwsh.log')))

    $pesterPs51Command = @"
Import-Module Pester -MinimumVersion 5.0 -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($testsLiteral)
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputFormat = 'NUnitXml'
`$configuration.TestResult.OutputPath = $ps51XmlLiteral
Invoke-Pester -Configuration `$configuration
"@
    $gates.Add((Invoke-NxbPowerShellGate `
        -Name 'pester-ps51' `
        -ExecutablePath $windowsPowerShellPath `
        -CommandText $pesterPs51Command `
        -LogPath (Join-Path $logsRoot 'pester-ps51.log')))

    $failedBeforeNative = @($gates | Where-Object status -eq 'failed').Count
    if ($SkipNativeCalibration) {
        $gates.Add([pscustomobject][ordered]@{
            name = 'native-wpr-calibration'
            status = 'skipped'
            exit_code = $null
            started_utc = $null
            stopped_utc = $null
            duration_ms = $null
            log_path = $null
            reason = 'SkipNativeCalibration was specified.'
        })
    }
    elseif ($failedBeforeNative -gt 0) {
        $gates.Add([pscustomobject][ordered]@{
            name = 'native-wpr-calibration'
            status = 'skipped'
            exit_code = $null
            started_utc = $null
            stopped_utc = $null
            duration_ms = $null
            log_path = $null
            reason = 'Earlier required gates failed.'
        })
    }
    elseif (-not (Test-NxbAdministrator)) {
        $gates.Add([pscustomobject][ordered]@{
            name = 'native-wpr-calibration'
            status = 'failed'
            exit_code = 1
            started_utc = $null
            stopped_utc = $null
            duration_ms = $null
            log_path = $null
            reason = 'Native WPR calibration requires an elevated administrator shell.'
        })
    }
    elseif ($PSCmdlet.ShouldProcess(
        $resultsFull,
        "Run $RepetitionCount native WPR control/capture pairs"
    )) {
        $labRoot = Join-Path $resultsFull 'native-calibration-lab'
        $nativeCommand = @"
Set-Location -LiteralPath $repositoryLiteral
& ./scripts/Initialize-Lab.ps1 -Root $(ConvertTo-NxbPowerShellLiteral -Value $labRoot) -Role Target | Out-Null
`$parent = & ./scripts/New-Experiment.ps1 `
    -Root $(ConvertTo-NxbPowerShellLiteral -Value $labRoot) `
    -Name 'NXB-IRL-004-Exact-Head-$shortHead' `
    -Hypothesis 'Measure bounded CPU/scheduler WPR overhead on exact validated head'
`$parent | Set-Content `
    -LiteralPath $(ConvertTo-NxbPowerShellLiteral -Value (Join-Path $resultsFull 'native-parent-path.txt')) `
    -Encoding UTF8
& ./scripts/Invoke-CollectorOverheadCalibration.ps1 `
    -ExperimentPath `$parent `
    -RepetitionCount $RepetitionCount `
    -WarmupCount $WarmupCount `
    -Ordering $Ordering `
    -Iterations $Iterations `
    -Seed $Seed `
    -WprExecutablePath $wprLiteral `
    -Confirm:`$false
"@
        $gates.Add((Invoke-NxbPowerShellGate `
            -Name 'native-wpr-calibration' `
            -ExecutablePath $pwshPath `
            -CommandText $nativeCommand `
            -LogPath (Join-Path $logsRoot 'native-wpr-calibration.log')))
    }
    else {
        $gates.Add([pscustomobject][ordered]@{
            name = 'native-wpr-calibration'
            status = 'skipped'
            exit_code = $null
            started_utc = $null
            stopped_utc = $null
            duration_ms = $null
            log_path = $null
            reason = 'ShouldProcess approval was not granted.'
        })
    }

    $failedCount = @($gates | Where-Object status -eq 'failed').Count
    $skippedRequiredCount = @(
        $gates | Where-Object {
            $_.name -eq 'native-wpr-calibration' -and $_.status -eq 'skipped'
        }
    ).Count
    if ($failedCount -gt 0) {
        $failureMessage = "$failedCount validation gate(s) failed."
    }
    elseif ($skippedRequiredCount -gt 0) {
        $failureMessage = 'Native WPR calibration gate was skipped.'
    }
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    $summary = [ordered]@{
        schema_version = 1
        status = if ([string]::IsNullOrWhiteSpace($failureMessage)) {
            'passed'
        }
        else {
            'failed'
        }
        failure_reason = if ([string]::IsNullOrWhiteSpace($failureMessage)) {
            $null
        }
        else {
            $failureMessage
        }
        repository = 'Naveax/nxb-integrity-research-lab'
        branch = $currentBranch
        head_sha = $currentHead
        expected_head_sha = if ([string]::IsNullOrWhiteSpace($ExpectedHead)) {
            $null
        }
        else {
            $ExpectedHead.ToLowerInvariant()
        }
        started_utc = $validationStartedUtc.ToString('o')
        stopped_utc = [DateTime]::UtcNow.ToString('o')
        results_root = $resultsFull
        tooling = [ordered]@{
            pwsh = $pwshPath
            windows_powershell = $windowsPowerShellPath
            python = $pythonPath
            wpr = $wprPath
            pester_pwsh_version = if (Get-Variable pesterPwshVersion -ErrorAction SilentlyContinue) {
                $pesterPwshVersion
            }
            else {
                $null
            }
            pester_ps51_version = if (Get-Variable pesterPs51Version -ErrorAction SilentlyContinue) {
                $pesterPs51Version
            }
            else {
                $null
            }
            psscriptanalyzer_version = if (Get-Variable analyzerVersion -ErrorAction SilentlyContinue) {
                $analyzerVersion
            }
            else {
                $null
            }
            jsonschema_version = if (Get-Variable jsonSchemaVersion -ErrorAction SilentlyContinue) {
                $jsonSchemaVersion
            }
            else {
                $null
            }
        }
        protocol = [ordered]@{
            repetition_count = $RepetitionCount
            warmup_count = $WarmupCount
            ordering = $Ordering
            iterations = $Iterations
            seed = $Seed
            native_calibration_skipped = [bool]$SkipNativeCalibration
        }
        gates = @($gates)
    }

    Out-NxbUtf8NoBom `
        -Path $summaryPath `
        -Content ($summary | ConvertTo-Json -Depth 32)
}

Write-Host "Validation summary: $summaryPath"
if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
    throw $failureMessage
}

if ($PassThru) {
    return [pscustomobject]$summary
}
Write-Output $summaryPath
