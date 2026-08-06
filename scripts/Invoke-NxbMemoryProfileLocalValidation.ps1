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

function Write-NxbMemoryUtf8NoBom {
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

function ConvertTo-NxbMemoryLiteral {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "'$($Value.Replace("'", "''"))'"
}

function Resolve-NxbMemoryExecutable {
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

function Test-NxbMemoryAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Invoke-NxbMemoryChild {
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
    Write-NxbMemoryUtf8NoBom -Path $LogPath -Content $text

    return [pscustomobject]@{
        exit_code = $exitCode
        text = $text
    }
}

function Add-NxbMemoryGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
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
    throw 'Memory profile local validation yalnız gerçek Windows ortamında çalışır.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Memory profile local validation PowerShell 7 içinde çalıştırılmalıdır.'
}
if (-not (Test-NxbMemoryAdministrator)) {
    throw 'Native WPR profile validation için yönetici PowerShell 7 gereklidir.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitPath = Resolve-NxbMemoryExecutable -Candidate @('git.exe', 'git')
$pwshPath = Resolve-NxbMemoryExecutable -Candidate @('pwsh.exe', 'pwsh')
$wprPath = Resolve-NxbMemoryExecutable -Candidate @('wpr.exe', 'wpr')
$windowsPowerShellPath = Join-Path `
    $env:SystemRoot `
    'System32\WindowsPowerShell\v1.0\powershell.exe'

$requiredPaths = [ordered]@{
    git = $gitPath
    pwsh = $pwshPath
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
        "nxb-memory-profile-$($currentHead.Substring(0, 12))-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)
if (Test-Path -LiteralPath $resultsFull) {
    throw "Validation sonuç dizini zaten var: $resultsFull"
}
[IO.Directory]::CreateDirectory($resultsFull) | Out-Null
$logsRoot = Join-Path $resultsFull 'logs'
[IO.Directory]::CreateDirectory($logsRoot) | Out-Null

$summaryPath = Join-Path $resultsFull 'memory-profile-validation-summary.json'
$reviewZip = Join-Path $HOME (
    'Downloads\' +
    (Split-Path -Leaf $resultsFull) +
    '-review.zip'
)
$gates = [Collections.Generic.List[object]]::new()
$validationStartedUtc = [DateTime]::UtcNow
$failureMessage = $null
$profileResult = $null

$repositoryLiteral = ConvertTo-NxbMemoryLiteral -Value $repositoryRoot
$settingsLiteral = ConvertTo-NxbMemoryLiteral -Value (
    Join-Path $repositoryRoot '.github\PSScriptAnalyzerSettings.psd1'
)
$profileTestLiteral = ConvertTo-NxbMemoryLiteral -Value (
    Join-Path $repositoryRoot 'tests\MemoryWprProfile.Tests.ps1'
)
$smokeTestLiteral = ConvertTo-NxbMemoryLiteral -Value (
    Join-Path $repositoryRoot 'tests\MemoryProfileRepositorySmoke.Tests.ps1'
)
$ps7XmlPath = Join-Path $resultsFull 'pester-memory-profile-pwsh.xml'
$ps51XmlPath = Join-Path $resultsFull 'pester-memory-profile-ps51.xml'
$ps7XmlLiteral = ConvertTo-NxbMemoryLiteral -Value $ps7XmlPath
$ps51XmlLiteral = ConvertTo-NxbMemoryLiteral -Value $ps51XmlPath

try {
    if ($BootstrapDependencies) {
        $bootstrapPwshLog = Join-Path $logsRoot 'bootstrap-pwsh.log'
        $bootstrapPwsh = Invoke-NxbMemoryChild `
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
        Add-NxbMemoryGate `
            -GateList $gates `
            -Name 'bootstrap-pwsh' `
            -Status $(if ($bootstrapPwsh.exit_code -eq 0) { 'passed' } else { 'failed' }) `
            -ExitCode $bootstrapPwsh.exit_code `
            -LogPath $bootstrapPwshLog `
            -Reason $(if ($bootstrapPwsh.exit_code -eq 0) {
                $null
            }
            else {
                'PowerShell 7 dependency bootstrap başarısız.'
            })

        $bootstrapPs51Log = Join-Path $logsRoot 'bootstrap-ps51.log'
        $bootstrapPs51 = Invoke-NxbMemoryChild `
            -ExecutablePath $pwshPath `
            -CommandText @'
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
$targetRoot = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
[IO.Directory]::CreateDirectory($targetRoot) | Out-Null
$modulePath = Join-Path $targetRoot 'Pester\5.7.1\Pester.psd1'
if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    Save-Module Pester -RequiredVersion 5.7.1 -Path $targetRoot -Force -Repository PSGallery
}
$manifest = Test-ModuleManifest -Path $modulePath
if ($manifest.Version -ne ([version]'5.7.1')) {
    throw "Beklenmeyen Pester sürümü: $($manifest.Version)"
}
Write-Output ('PesterPath=' + $modulePath)
'@ `
            -LogPath $bootstrapPs51Log
        Add-NxbMemoryGate `
            -GateList $gates `
            -Name 'bootstrap-ps51' `
            -Status $(if ($bootstrapPs51.exit_code -eq 0) { 'passed' } else { 'failed' }) `
            -ExitCode $bootstrapPs51.exit_code `
            -LogPath $bootstrapPs51Log `
            -Reason $(if ($bootstrapPs51.exit_code -eq 0) {
                $null
            }
            else {
                'Windows PowerShell 5.1 Pester bootstrap başarısız.'
            })
    }

    $parserLog = Join-Path $logsRoot 'powershell-parser.log'
    $parser = Invoke-NxbMemoryChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
`$paths = @(
    (Join-Path $repositoryLiteral 'scripts\Test-NxbMemoryWprProfile.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Test-MemoryProfileRepositorySmoke.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Invoke-NxbMemoryProfileLocalValidation.ps1'),
    (Join-Path $repositoryLiteral 'tests\MemoryWprProfile.Tests.ps1'),
    (Join-Path $repositoryLiteral 'tests\MemoryProfileRepositorySmoke.Tests.ps1')
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
Write-Output 'PowerShell parser clean.'
"@ `
        -LogPath $parserLog
    Add-NxbMemoryGate `
        -GateList $gates `
        -Name 'powershell-parser' `
        -Status $(if ($parser.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $parser.exit_code `
        -LogPath $parserLog `
        -Reason $(if ($parser.exit_code -eq 0) { $null } else { 'PowerShell parser başarısız.' })

    $analyzerLog = Join-Path $logsRoot 'psscriptanalyzer.log'
    $analyzer = Invoke-NxbMemoryChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
Import-Module PSScriptAnalyzer -Force
`$paths = @(
    (Join-Path $repositoryLiteral 'scripts\Test-NxbMemoryWprProfile.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Test-MemoryProfileRepositorySmoke.ps1'),
    (Join-Path $repositoryLiteral 'scripts\Invoke-NxbMemoryProfileLocalValidation.ps1'),
    (Join-Path $repositoryLiteral 'tests\MemoryWprProfile.Tests.ps1'),
    (Join-Path $repositoryLiteral 'tests\MemoryProfileRepositorySmoke.Tests.ps1')
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
Write-Output 'PSScriptAnalyzer: 0 findings.'
"@ `
        -LogPath $analyzerLog
    Add-NxbMemoryGate `
        -GateList $gates `
        -Name 'psscriptanalyzer' `
        -Status $(if ($analyzer.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $analyzer.exit_code `
        -LogPath $analyzerLog `
        -Reason $(if ($analyzer.exit_code -eq 0) { $null } else { 'PSScriptAnalyzer başarısız.' })

    $smokeLog = Join-Path $logsRoot 'memory-profile-repository-smoke.log'
    $smoke = Invoke-NxbMemoryChild `
        -ExecutablePath $pwshPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $repositoryLiteral
& ./scripts/Test-MemoryProfileRepositorySmoke.ps1
"@ `
        -LogPath $smokeLog
    Add-NxbMemoryGate `
        -GateList $gates `
        -Name 'memory-profile-repository-smoke' `
        -Status $(if ($smoke.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $smoke.exit_code `
        -LogPath $smokeLog `
        -Reason $(if ($smoke.exit_code -eq 0) { $null } else { 'Memory profile repository smoke başarısız.' })

    $profileContractLog = Join-Path $logsRoot 'memory-profile-contract.log'
    try {
        $profileResult = & (Join-Path $repositoryRoot 'scripts\Test-NxbMemoryWprProfile.ps1') -PassThru
        Write-NxbMemoryUtf8NoBom `
            -Path $profileContractLog `
            -Content ($profileResult | ConvertTo-Json -Depth 16)
        Add-NxbMemoryGate `
            -GateList $gates `
            -Name 'memory-profile-contract' `
            -Status passed `
            -ExitCode 0 `
            -LogPath $profileContractLog
    }
    catch {
        Write-NxbMemoryUtf8NoBom -Path $profileContractLog -Content ($_ | Out-String)
        Add-NxbMemoryGate `
            -GateList $gates `
            -Name 'memory-profile-contract' `
            -Status failed `
            -ExitCode 1 `
            -LogPath $profileContractLog `
            -Reason 'Memory profile structural contract başarısız.'
    }

    $nativeLog = Join-Path $logsRoot 'native-memory-wpr-profile-parser.log'
    $profilePath = Join-Path $repositoryRoot 'profiles\Nxb.MemoryWorkingSet.wprp'
    $nativeOutput = @(& $wprPath -profiles $profilePath 2>&1)
    $nativeExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $nativeText = @($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($nativeExit -eq 0 -and $nativeText -notmatch 'NxbMemoryWorkingSet') {
        $nativeExit = 1
        $nativeText += (
            [Environment]::NewLine +
            'NxbMemoryWorkingSet native WPR çıktısında bulunamadı.'
        )
    }
    Write-NxbMemoryUtf8NoBom -Path $nativeLog -Content $nativeText
    Add-NxbMemoryGate `
        -GateList $gates `
        -Name 'native-memory-wpr-profile-parser' `
        -Status $(if ($nativeExit -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $nativeExit `
        -LogPath $nativeLog `
        -Reason $(if ($nativeExit -eq 0) { $null } else { 'Native WPR memory profile parser başarısız.' })

    $ps7Log = Join-Path $logsRoot 'pester-memory-profile-pwsh.log'
    $ps7 = Invoke-NxbMemoryChild `
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
`$configuration.Run.Path = @($profileTestLiteral, $smokeTestLiteral)
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputPath = $ps7XmlLiteral
`$configuration.TestResult.OutputFormat = 'NUnitXml'
Invoke-Pester -Configuration `$configuration
"@ `
        -LogPath $ps7Log
    Add-NxbMemoryGate `
        -GateList $gates `
        -Name 'pester-memory-profile-pwsh' `
        -Status $(if ($ps7.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $ps7.exit_code `
        -LogPath $ps7Log `
        -Reason $(if ($ps7.exit_code -eq 0) { $null } else { 'PowerShell 7 memory profile Pester başarısız.' })

    $ps51ModulePath = Join-Path `
        ([Environment]::GetFolderPath('MyDocuments')) `
        'WindowsPowerShell\Modules\Pester\5.7.1\Pester.psd1'
    $ps51ModuleLiteral = ConvertTo-NxbMemoryLiteral -Value $ps51ModulePath
    $ps51Log = Join-Path $logsRoot 'pester-memory-profile-ps51.log'
    $ps51 = Invoke-NxbMemoryChild `
        -ExecutablePath $windowsPowerShellPath `
        -CommandText @"
`$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $ps51ModuleLiteral -PathType Leaf)) {
    throw 'Windows PowerShell Pester 5.7.1 bulunamadı.'
}
Import-Module $ps51ModuleLiteral -Force
`$configuration = New-PesterConfiguration
`$configuration.Run.Path = @($profileTestLiteral, $smokeTestLiteral)
`$configuration.Run.Exit = `$true
`$configuration.Output.Verbosity = 'Detailed'
`$configuration.TestResult.Enabled = `$true
`$configuration.TestResult.OutputPath = $ps51XmlLiteral
`$configuration.TestResult.OutputFormat = 'NUnitXml'
Invoke-Pester -Configuration `$configuration
"@ `
        -LogPath $ps51Log
    Add-NxbMemoryGate `
        -GateList $gates `
        -Name 'pester-memory-profile-ps51' `
        -Status $(if ($ps51.exit_code -eq 0) { 'passed' } else { 'failed' }) `
        -ExitCode $ps51.exit_code `
        -LogPath $ps51Log `
        -Reason $(if ($ps51.exit_code -eq 0) { $null } else { 'Windows PowerShell 5.1 memory profile Pester başarısız.' })
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
            wpr_path = $wprPath
        }
        profile = if ($null -eq $profileResult) {
            $null
        }
        else {
            [ordered]@{
                relative_path = [string]$profileResult.RelativePath
                name = [string]$profileResult.Name
                sha256 = [string]$profileResult.Sha256
                length = [int64]$profileResult.Length
                buffer_size_kib = [int]$profileResult.BufferSizeKiB
                buffers = [int]$profileResult.Buffers
                maximum_file_size_mib = [int]$profileResult.MaximumFileSizeMiB
                file_mode = [string]$profileResult.FileMode
                keyword_count = @($profileResult.Keywords).Count
                stack_count = @($profileResult.Stacks).Count
                reference_set_enabled = [bool]$profileResult.ReferenceSetEnabled
            }
        }
        gates = @($gates)
    }
    Write-NxbMemoryUtf8NoBom `
        -Path $summaryPath `
        -Content ($summary | ConvertTo-Json -Depth 32)

    $reviewFiles = @(
        $summaryPath,
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

    Write-Host "Memory profile validation summary: $summaryPath"
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
        "Memory profile exact-head validation başarısız:`n" +
        ($reasons -join [Environment]::NewLine)
    )
}

Write-Host 'Memory profile exact-head validation tamamlandı.'
if ($PassThru) {
    $finalSummary
}
