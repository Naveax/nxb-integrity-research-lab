[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
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
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbUtf8NoBom {
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

function ConvertTo-NxbLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "'$($Value.Replace("'", "''"))'"
}

function Resolve-NxbExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
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

function Test-NxbAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-NxbChild {
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

    $text = @(
        $output | ForEach-Object { [string]$_ }
    ) -join [Environment]::NewLine
    Write-NxbUtf8NoBom -Path $LogPath -Content $text

    return [pscustomobject]@{
        exit_code = $exitCode
        text      = $text
    }
}

function Add-NxbGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$GateList,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('passed', 'failed', 'skipped')]
        [string]$Status,

        [Parameter()]
        [Nullable[int]]$ExitCode,

        [Parameter()]
        [string]$LogPath,

        [Parameter()]
        [string]$Reason
    )

    $GateList.Add([pscustomobject][ordered]@{
        name      = $Name
        status    = $Status
        exit_code = if ($PSBoundParameters.ContainsKey('ExitCode')) {
            $ExitCode
        }
        else {
            $null
        }
        log_path  = $LogPath
        reason    = $Reason
    })
}

if ($env:OS -cne 'Windows_NT') {
    throw 'NXB local validation yalnız gerçek Windows ortamında çalışır.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'NXB local validation PowerShell 7 içinde çalıştırılmalıdır.'
}
if (-not (Test-NxbAdministrator)) {
    throw 'Native WPR validation için yönetici PowerShell 7 gereklidir.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitPath = Resolve-NxbExecutable -Candidate @('git.exe', 'git')
$pwshPath = Resolve-NxbExecutable -Candidate @('pwsh.exe', 'pwsh')
$pythonPath = Resolve-NxbExecutable -Candidate @(
    'python.exe',
    'python',
    'py.exe',
    'py'
)
$wprPath = Resolve-NxbExecutable -Candidate @('wpr.exe', 'wpr')
$windowsPowerShellPath = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'

$requiredPaths = [ordered]@{
    git                 = $gitPath
    pwsh                = $pwshPath
    python              = $pythonPath
    wpr                 = $wprPath
    windows_powershell  = $windowsPowerShellPath
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
        "nxb-validation-$($currentHead.Substring(0, 12))-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)
if (Test-Path -LiteralPath $resultsFull) {
    throw "Validation sonuç dizini zaten var: $resultsFull"
}
[IO.Directory]::CreateDirectory($resultsFull) | Out-Null
$logsRoot = Join-Path $resultsFull 'logs'
[IO.Directory]::CreateDirectory($logsRoot) | Out-Null

$summaryPath = Join-Path $resultsFull 'validation-summary.json'
$reviewZip = Join-Path $HOME (
    'Downloads\' +
    (Split-Path -Leaf $resultsFull) +
    '-review.zip'
)
$gates = [Collections.Generic.List[object]]::new()
$failureMessage = $null
$validationStartedUtc = [DateTime]::UtcNow

$repositoryLiteral = ConvertTo-NxbLiteral -Value $repositoryRoot
$testsLiteral = ConvertTo-NxbLiteral -Value (
    Join-Path $repositoryRoot 'tests'
)
$settingsLiteral = ConvertTo-NxbLiteral -Value (
    Join-Path $repositoryRoot '.github\PSScriptAnalyzerSettings.psd1'
)
$ps7XmlPath = Join-Path $resultsFull 'pester-pwsh.xml'
$ps51XmlPath = Join-Path $resultsFull 'pester-ps51.xml'
$ps7XmlLiteral = ConvertTo-NxbLiteral -Value $ps7XmlPath
$ps51XmlLiteral = ConvertTo-NxbLiteral -Value $ps51XmlPath

try {
    if ($BootstrapDependencies) {
        $bootstrapPwshLog = Join-Path $logsRoot 'bootstrap-pwsh.log'
        $bootstrapPwsh = Invoke-NxbChild `
            -ExecutablePath $pwshPath `
            -CommandText @'
$ErrorActionPreference = 'Stop'
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
if ($null -eq (
    Get-Module -ListAvailable Pester |
        Where-Object Version -GE ([version]'5.0.0') |
        Select-Object -First 1
)) {
    Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0 -Force -SkipPublisherCheck -AllowClobber
}
if ($null -eq (Get-Module -ListAvailable PSScriptAnalyzer | Select-Object -First 1)) {
    Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
}
'@ `
            -LogPath $bootstrapPwshLog
        Add-NxbGate `
            -GateList $gates `
            -Name 'bootstrap-pwsh' `
            -Status $(if ($bootstrapPwsh.exit_code -eq 0) {
                'passed'
            }
            else {
                'failed'
            }) `
            -ExitCode $bootstrapPwsh.exit_code `
            -LogPath $bootstrapPwshLog `
            -Reason $(if ($bootstrapPwsh.exit_code -eq 0) {
                $null
            }
            else {
                'PowerShell 7 dependency bootstrap başarısız.'
            })

        $bootstrapPs51Log = Join-Path $logsRoot 'bootstrap-ps51.log'
        $bootstrapPs51 = Invoke-NxbChild `
            -ExecutablePath $windowsPowerShellPath `
            -CommandText @'
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
$required = [version]'5.7.1'
$selected = Get-Module -ListAvailable Pester |
    Where-Object Version -GE $required |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $selected) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Scope CurrentUser -Force | Out-Null
    Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force -SkipPublisherCheck -AllowClobber
}
$selected = Get-Module -ListAvailable Pester |
    Where-Object Version -GE $required |
    Sort-Object Version -Descending |
    Select-Object -First 1
if ($null -eq $selected) {
    throw 'Pester 5.7.1 kurulamadı.'
}
Write-Output ('PesterPath=' + $selected.Path)
Write-Output ('PesterVersion=' + $selected.Version)
'@ `
            -LogPath $bootstrapPs51Log
        Add-NxbGate `
            -GateList $gates `
            -Name 'bootstrap-ps51' `
            -Status $(if ($bootstrapPs51.exit_code -eq 0) {
                'passed'
            }
            else {
                'failed'
            }) `
            -ExitCode $bootstrapPs51.exit_code `
            -LogPath $bootstrapPs51Log `
            -Reason $(if ($bootstrapPs51.exit_code -eq 0) {
                $null
            }
            else {
                'Windows PowerShell 5.1 Pester bootstrap başarısız.'
            })
    }

    $publicLog = Join-Path $logsRoot 'public-repository-content.log'
    $public = Invoke-NxbChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $repositoryLiteral
& ./scripts/Test-PublicRepositoryContent.ps1 -RepositoryRoot $repositoryLiteral
if (`$LASTEXITCODE -ne 0) { exit `$LASTEXITCODE }
"@ `
        -LogPath $publicLog
    Add-NxbGate `
        -GateList $gates `
        -Name 'public-repository-content' `
        -Status $(if ($public.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $public.exit_code `
        -LogPath $publicLog `
        -Reason $(if ($public.exit_code -eq 0) {
            $null
        }
        else {
            'Public repository guard başarısız.'
        })

    $profileLog = Join-Path $logsRoot 'native-wpr-profile-parser.log'
    $profilePath = Join-Path `
        $repositoryRoot `
        'profiles\Nxb.MinimalCpuScheduler.wprp'
    $profileOutput = @(& $wprPath -profiles $profilePath 2>&1)
    $profileExit = if ($null -eq $LASTEXITCODE) {
        1
    }
    else {
        [int]$LASTEXITCODE
    }
    $profileText = @(
        $profileOutput | ForEach-Object { [string]$_ }
    ) -join [Environment]::NewLine
    if ($profileExit -eq 0 -and
        $profileText -notmatch 'NxbMinimalCpuScheduler') {
        $profileExit = 1
        $profileText += (
            [Environment]::NewLine +
            'Profile kimliği native WPR çıktısında bulunamadı.'
        )
    }
    Write-NxbUtf8NoBom -Path $profileLog -Content $profileText
    Add-NxbGate `
        -GateList $gates `
        -Name 'native-wpr-profile-parser' `
        -Status $(if ($profileExit -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $profileExit `
        -LogPath $profileLog `
        -Reason $(if ($profileExit -eq 0) {
            $null
        }
        else {
            'Native WPR profile parser başarısız.'
        })

    $analyzerLog = Join-Path $logsRoot 'psscriptanalyzer.log'
    $analyzer = Invoke-NxbChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -Force
Set-Location -LiteralPath $repositoryLiteral
`$findings = [Collections.Generic.List[object]]::new()
foreach (`$scanPath in @('./scripts', './tests')) {
    `$parameters = @{
        Path = `$scanPath
        Recurse = `$true
        Settings = $settingsLiteral
    }
    foreach (`$finding in @(Invoke-ScriptAnalyzer @parameters)) {
        `$findings.Add(`$finding)
    }
}
`$ordered = @(`$findings | Sort-Object ScriptName, Line, Column, RuleName)
foreach (`$finding in `$ordered) {
    `$fields = @(
        `$finding.Severity,
        `$finding.ScriptName,
        `$finding.Line,
        `$finding.Column,
        `$finding.RuleName,
        (([string]`$finding.Message).Replace("`r", ' ').Replace("`n", ' '))
    )
    Write-Output ('ANALYZER|' + (`$fields -join '|'))
}
if (`$ordered.Count -gt 0) { exit 1 }
Write-Output 'PSScriptAnalyzer: 0 Error/Warning findings.'
"@ `
        -LogPath $analyzerLog
    Add-NxbGate `
        -GateList $gates `
        -Name 'psscriptanalyzer' `
        -Status $(if ($analyzer.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $analyzer.exit_code `
        -LogPath $analyzerLog `
        -Reason $(if ($analyzer.exit_code -eq 0) {
            $null
        }
        else {
            'Analyzer bulgusu veya invocation hatası.'
        })

    $smokeLog = Join-Path $logsRoot 'repository-smoke.log'
    $smoke = Invoke-NxbChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $repositoryLiteral
& ./scripts/Test-Repository.ps1
"@ `
        -LogPath $smokeLog
    Add-NxbGate `
        -GateList $gates `
        -Name 'repository-smoke' `
        -Status $(if ($smoke.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $smoke.exit_code `
        -LogPath $smokeLog `
        -Reason $(if ($smoke.exit_code -eq 0) {
            $null
        }
        else {
            'Repository smoke başarısız.'
        })

    $pester7Log = Join-Path $logsRoot 'pester-pwsh.log'
    $pester7 = Invoke-NxbChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
`$module = Get-Module -ListAvailable Pester |
    Where-Object Version -GE ([version]'5.0.0') |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (`$null -eq `$module) { throw 'Pester >= 5 bulunamadı.' }
Import-Module `$module.Path -Force
Write-Output ('PesterPath=' + `$module.Path)
Write-Output ('PesterVersion=' + `$module.Version)
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($testsLiteral)
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputFormat = 'NUnitXml'
`$configuration.TestResult.OutputPath = $ps7XmlLiteral
Invoke-Pester -Configuration `$configuration
"@ `
        -LogPath $pester7Log
    Add-NxbGate `
        -GateList $gates `
        -Name 'pester-pwsh' `
        -Status $(if ($pester7.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $pester7.exit_code `
        -LogPath $pester7Log `
        -Reason $(if ($pester7.exit_code -eq 0) {
            $null
        }
        else {
            'PowerShell 7 Pester matrisi başarısız.'
        })

    $pester51Log = Join-Path $logsRoot 'pester-ps51.log'
    $pester51 = Invoke-NxbChild `
        -ExecutablePath $windowsPowerShellPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
`$module = Get-Module -ListAvailable Pester |
    Where-Object Version -GE ([version]'5.0.0') |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (`$null -eq `$module) {
    throw 'Windows PowerShell 5.1 için Pester >= 5 bulunamadı.'
}
Import-Module `$module.Path -Force
`$loaded = Get-Module Pester
if (`$loaded.Version -lt ([version]'5.0.0')) {
    throw ('Yanlış Pester sürümü yüklendi: ' + `$loaded.Version)
}
Write-Output ('PesterPath=' + `$loaded.Path)
Write-Output ('PesterVersion=' + `$loaded.Version)
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($testsLiteral)
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputFormat = 'NUnitXml'
`$configuration.TestResult.OutputPath = $ps51XmlLiteral
Invoke-Pester -Configuration `$configuration
"@ `
        -LogPath $pester51Log
    Add-NxbGate `
        -GateList $gates `
        -Name 'pester-ps51' `
        -Status $(if ($pester51.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $pester51.exit_code `
        -LogPath $pester51Log `
        -Reason $(if ($pester51.exit_code -eq 0) {
            $null
        }
        else {
            'Windows PowerShell 5.1 Pester matrisi başarısız.'
        })

    $failedBeforeNative = @(
        $gates | Where-Object status -eq 'failed'
    ).Count
    $nativeLog = Join-Path $logsRoot 'native-wpr-calibration.log'
    if ($failedBeforeNative -gt 0) {
        Add-NxbGate `
            -GateList $gates `
            -Name 'native-wpr-calibration' `
            -Status 'skipped' `
            -LogPath $nativeLog `
            -Reason 'Earlier required gates failed.'
    }
    elseif ($PSCmdlet.ShouldProcess(
        $resultsFull,
        "Run $RepetitionCount native WPR control/capture pairs"
    )) {
        $labRoot = Join-Path $resultsFull 'native-calibration-lab'
        $parentPathFile = Join-Path $resultsFull 'native-parent-path.txt'
        $labLiteral = ConvertTo-NxbLiteral -Value $labRoot
        $parentFileLiteral = ConvertTo-NxbLiteral -Value $parentPathFile
        $wprLiteral = ConvertTo-NxbLiteral -Value $wprPath
        $native = Invoke-NxbChild `
            -ExecutablePath $pwshPath `
            -CommandText @"
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $repositoryLiteral
`$labParameters = @{
    Root = $labLiteral
    Role = 'Target'
}
& ./scripts/Initialize-Lab.ps1 @labParameters | Out-Null
`$experimentParameters = @{
    Root = $labLiteral
    Name = 'NXB-IRL-004-Final-$($currentHead.Substring(0, 12))'
    Hypothesis = 'Measure bounded CPU/scheduler WPR overhead on exact final head'
}
`$parent = & ./scripts/New-Experiment.ps1 @experimentParameters
[IO.File]::WriteAllText(
    $parentFileLiteral,
    [string]`$parent,
    [Text.UTF8Encoding]::new(`$false)
)
`$calibrationParameters = @{
    ExperimentPath = `$parent
    RepetitionCount = $RepetitionCount
    WarmupCount = $WarmupCount
    Ordering = '$Ordering'
    Iterations = $Iterations
    Seed = $Seed
    WprExecutablePath = $wprLiteral
    Confirm = `$false
}
& ./scripts/Invoke-CollectorOverheadCalibration.ps1 @calibrationParameters
"@ `
            -LogPath $nativeLog
        Add-NxbGate `
            -GateList $gates `
            -Name 'native-wpr-calibration' `
            -Status $(if ($native.exit_code -eq 0) { 'passed' } else { 'failed' }) `
            -ExitCode $native.exit_code `
            -LogPath $nativeLog `
            -Reason $(if ($native.exit_code -eq 0) {
                $null
            }
            else {
                'Native WPR calibration başarısız.'
            })

        if ($native.exit_code -eq 0 -and
            (Test-Path -LiteralPath $parentPathFile -PathType Leaf)) {
            $parentPath = (
                Get-Content -LiteralPath $parentPathFile -Raw
            ).Trim()
            $nativeEvidence = Join-Path `
                $parentPath `
                'analysis\collector-overhead-calibration.json'
            if (Test-Path -LiteralPath $nativeEvidence -PathType Leaf) {
                Copy-Item `
                    -LiteralPath $nativeEvidence `
                    -Destination (
                        Join-Path $resultsFull 'native-calibration.json'
                    )
            }
        }
    }
    else {
        Add-NxbGate `
            -GateList $gates `
            -Name 'native-wpr-calibration' `
            -Status 'skipped' `
            -LogPath $nativeLog `
            -Reason 'ShouldProcess approval was not granted.'
    }

    $failed = @($gates | Where-Object status -eq 'failed').Count
    $skippedNative = @(
        $gates |
            Where-Object {
                $_.name -eq 'native-wpr-calibration' -and
                $_.status -eq 'skipped'
            }
    ).Count
    if ($failed -gt 0) {
        $failureMessage = "$failed validation gate(s) failed."
    }
    elseif ($skippedNative -gt 0) {
        $failureMessage = 'Native WPR calibration gate was skipped.'
    }
}
catch {
    $failureMessage = $_.Exception.Message
}
finally {
    $summary = [ordered]@{
        schema_version    = 2
        status            = if (
            [string]::IsNullOrWhiteSpace($failureMessage)
        ) {
            'passed'
        }
        else {
            'failed'
        }
        failure_reason    = if (
            [string]::IsNullOrWhiteSpace($failureMessage)
        ) {
            $null
        }
        else {
            $failureMessage
        }
        repository        = 'Naveax/nxb-integrity-research-lab'
        branch            = (
            & $gitPath -C $repositoryRoot branch --show-current |
                Out-String
        ).Trim()
        head_sha          = $currentHead
        expected_head_sha = $ExpectedHead.ToLowerInvariant()
        started_utc       = $validationStartedUtc.ToString('o')
        stopped_utc       = [DateTime]::UtcNow.ToString('o')
        results_root      = $resultsFull
        protocol          = [ordered]@{
            repetition_count = $RepetitionCount
            warmup_count     = $WarmupCount
            ordering         = $Ordering
            iterations       = $Iterations
            seed             = $Seed
        }
        gates             = @($gates)
    }
    Write-NxbUtf8NoBom `
        -Path $summaryPath `
        -Content ($summary | ConvertTo-Json -Depth 32)

    $reviewItems = @(
        $summaryPath,
        $logsRoot,
        $ps7XmlPath,
        $ps51XmlPath,
        (Join-Path $resultsFull 'native-calibration.json')
    ) | Where-Object {
        Test-Path -LiteralPath $_
    }
    if ($reviewItems.Count -gt 0) {
        Compress-Archive `
            -Path $reviewItems `
            -DestinationPath $reviewZip `
            -Force
    }
}

Write-Host "Validation summary: $summaryPath"
Write-Host "Review ZIP: $reviewZip"

if (-not [string]::IsNullOrWhiteSpace($failureMessage)) {
    throw $failureMessage
}

if ($PassThru) {
    return [pscustomobject]$summary
}
Write-Output $summaryPath
