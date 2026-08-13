[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][ValidateRange(1,20)][int]$RepetitionCount = 1,
    [Parameter()][ValidateRange(0,5)][int]$WarmupCount = 0,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbCiNativeSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Write-NxbCiNativeTextNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $stream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None
    )
    try {
        $writer = [IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false))
        try {
            $writer.Write($Text)
            $writer.Flush()
            $stream.Flush($true)
        }
        finally {
            $writer.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

function Write-NxbCiNativeJsonNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )
    Write-NxbCiNativeTextNew -Path $Path -Text (($Value | ConvertTo-Json -Depth 32) + [Environment]::NewLine)
}

function Test-NxbCiNativeAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    finally {
        $identity.Dispose()
    }
}

function Resolve-NxbCiNativeCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Name)
    foreach ($candidate in $Name) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) { return [string]$command.Source }
    }
    return $null
}

function Write-NxbCiNativeReviewZip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][Collections.IDictionary]$Entries
    )

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fileStream = [IO.FileStream]::new(
        $Path,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::None
    )
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $fileStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $true
        )
        try {
            foreach ($entryName in @($Entries.Keys | Sort-Object)) {
                $sourcePath = [string]$Entries[$entryName]
                if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    throw ('Native review source missing: {0}' -f $sourcePath)
                }
                $entry = $archive.CreateEntry([string]$entryName,[IO.Compression.CompressionLevel]::Optimal)
                $entryStream = $entry.Open()
                try {
                    $sourceStream = [IO.File]::Open(
                        $sourcePath,
                        [IO.FileMode]::Open,
                        [IO.FileAccess]::Read,
                        [IO.FileShare]::Read
                    )
                    try { $sourceStream.CopyTo($entryStream) }
                    finally { $sourceStream.Dispose() }
                }
                finally { $entryStream.Dispose() }
            }
        }
        finally { $archive.Dispose() }
        $fileStream.Flush($true)
    }
    finally { $fileStream.Dispose() }
}

if ($env:OS -cne 'Windows_NT') { throw 'NXB v1 CI native validation requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core' -or [int]$PSVersionTable.PSVersion.Major -lt 7) { throw 'NXB v1 CI native validation requires PowerShell 7.' }
if (-not (Test-NxbCiNativeAdministrator)) { throw 'NXB v1 CI native validation requires an Administrator PowerShell 7 session.' }

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$expected = $ExpectedHead.ToLowerInvariant()
$gitPath = Resolve-NxbCiNativeCommand -Name @('git.exe','git')
$wprPath = Resolve-NxbCiNativeCommand -Name @('wpr.exe','wpr')
$xperfPath = Resolve-NxbCiNativeCommand -Name @('xperf.exe','xperf')
$pythonPath = Resolve-NxbCiNativeCommand -Name @('python.exe','python')
$pwshPath = Resolve-NxbCiNativeCommand -Name @('pwsh.exe','pwsh')
foreach ($pair in @(
    @('git',$gitPath),@('wpr',$wprPath),@('xperf',$xperfPath),@('python',$pythonPath),@('pwsh',$pwshPath)
)) {
    if ([string]::IsNullOrWhiteSpace([string]$pair[1]) -or -not (Test-Path -LiteralPath ([string]$pair[1]) -PathType Leaf)) {
        throw ('NXB v1 CI native dependency missing: {0}' -f [string]$pair[0])
    }
}

$currentHead = (@(& $gitPath -C $repositoryRoot rev-parse HEAD 2>&1) -join [Environment]::NewLine).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $expected) { throw ('Native exact-head mismatch: expected={0} actual={1}' -f $expected,$currentHead) }
$dirty = @(& $gitPath -C $repositoryRoot status --porcelain=v1 --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'NXB v1 CI native validation requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = $repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'NXB v1 CI native output must remain outside the repository worktree.' }
if (Test-Path -LiteralPath $outputFull) { throw ('NXB v1 CI native output already exists: {0}' -f $outputFull) }
[IO.Directory]::CreateDirectory($outputFull) | Out-Null
$workRoot = $outputFull + '-work'
if (Test-Path -LiteralPath $workRoot) { throw ('NXB v1 CI native work root already exists: {0}' -f $workRoot) }
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

$pesterModule = Get-Module -ListAvailable Pester | Where-Object Version -eq ([version]'5.7.1') | Select-Object -First 1
if ($null -eq $pesterModule) { throw 'NXB v1 CI native validation requires Pester 5.7.1.' }
$analyzerModule = Get-Module -ListAvailable PSScriptAnalyzer | Where-Object Version -eq ([version]'1.25.0') | Select-Object -First 1
if ($null -eq $analyzerModule) { throw 'NXB v1 CI native validation requires PSScriptAnalyzer 1.25.0.' }

$dependencyProbe = @(& $pythonPath -c 'import importlib.metadata as m; assert m.version("PyYAML") == "6.0.3"; assert m.version("jsonschema") == "4.26.0"; import yaml, jsonschema' 2>&1)
if ($LASTEXITCODE -ne 0) { throw ('NXB v1 CI native Python dependency closure failed: {0}' -f ($dependencyProbe -join ' ')) }

$profileLogPath = Join-Path $outputFull 'native-profile-parser.txt'
$nativeCalibrationPath = Join-Path $outputFull 'native-calibration.json'
$receiptPath = Join-Path $outputFull 'native-ci-receipt.json'
$reviewZipPath = Join-Path $outputFull 'native-ci-review.zip'
$hostedRoot = Join-Path $outputFull 'hosted'
$failurePath = Join-Path $outputFull 'native-ci-failure.json'
$startedUtc = [DateTime]::UtcNow
$completed = $false

try {
    $hostedAuthority = Join-Path $PSScriptRoot 'Invoke-NxbV1CiHostedValidation.ps1'
    $hostedResult = & $hostedAuthority -ExpectedHead $expected -OutputDirectory $hostedRoot -PassThru
    if ([string]$hostedResult.status -cne 'passed' -or [string]$hostedResult.head_sha -cne $expected) { throw 'Native replay of hosted CI authority did not return exact-head PASS.' }
    if ([int]$hostedResult.ps7_total -ne 893 -or [int]$hostedResult.ps7_passed -ne 893 -or [int]$hostedResult.ps7_not_run -ne 0) { throw 'Native hosted-replay PS7 closure drift.' }
    if ([int]$hostedResult.ps51_total -ne 893 -or [int]$hostedResult.ps51_passed -ne 886 -or [int]$hostedResult.ps51_not_run -ne 7) { throw 'Native hosted-replay PS5.1 partition drift.' }

    $captureProfilePath = Join-Path $repositoryRoot 'profiles\Nxb.MinimalCpuScheduler.wprp'
    $profileOutput = @(& $wprPath -profiles $captureProfilePath 2>&1)
    $profileExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $profileText = @($profileOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($profileExit -ne 0 -or $profileText -notmatch 'NxbMinimalCpuScheduler') { throw 'Native WPR profile parser failed or did not expose NxbMinimalCpuScheduler.' }
    Write-NxbCiNativeTextNew -Path $profileLogPath -Text ($profileText + [Environment]::NewLine)

    $labRoot = Join-Path $workRoot 'native-calibration-lab'
    & (Join-Path $PSScriptRoot 'Initialize-Lab.ps1') -Root $labRoot -Role Target | Out-Null
    $parent = & (Join-Path $PSScriptRoot 'New-Experiment.ps1') `
        -Root $labRoot `
        -Name ('NXB-V1-CI-Native-' + $expected.Substring(0,12)) `
        -Hypothesis 'Measure bounded CPU/scheduler WPR overhead on the exact Phase 7 CI native candidate'
    $calibrationParameters = @{
        ExperimentPath = [string]$parent
        RepetitionCount = $RepetitionCount
        WarmupCount = $WarmupCount
        Ordering = 'alternating_control_first'
        Iterations = 1000
        Seed = 73
        WprExecutablePath = $wprPath
        Confirm = $false
    }
    & (Join-Path $PSScriptRoot 'Invoke-CollectorOverheadCalibration.ps1') @calibrationParameters | Out-Null
    $sourceCalibrationPath = Join-Path ([string]$parent) 'analysis\collector-overhead-calibration.json'
    if (-not (Test-Path -LiteralPath $sourceCalibrationPath -PathType Leaf)) { throw 'Native calibration evidence was not produced.' }
    & (Join-Path $PSScriptRoot 'Test-CollectorOverheadCalibration.ps1') -Path $sourceCalibrationPath
    [IO.File]::Copy($sourceCalibrationPath,$nativeCalibrationPath,$false)

    $hostedReceiptPath = Join-Path $hostedRoot 'hosted-ci-receipt.json'
    $ps7XmlPath = Join-Path $hostedRoot 'pester-ps7.xml'
    $ps51XmlPath = Join-Path $hostedRoot 'pester-ps51.xml'
    $ps51SummaryPath = Join-Path $hostedRoot 'ps51-summary.json'
    foreach ($requiredEvidence in @($hostedReceiptPath,$ps7XmlPath,$ps51XmlPath,$ps51SummaryPath,$nativeCalibrationPath,$profileLogPath)) {
        if (-not (Test-Path -LiteralPath $requiredEvidence -PathType Leaf)) { throw ('Required native CI evidence missing: {0}' -f $requiredEvidence) }
    }

    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        status = 'passed'
        authority = 'nxb-v1-ci-native-v1'
        head_sha = $expected
        predecessor_cli_head = 'e665e8c27cb085853d23c8804ffaa97a19807eb9'
        hosted_authority = 'nxb-v1-ci-hosted-v1'
        hosted_receipt_sha256 = Get-NxbCiNativeSha256 -Path $hostedReceiptPath
        ps7 = '893/893'
        ps7_not_run = 0
        ps51 = '886/893'
        ps51_not_run = 7
        ps51_excluded_tag = 'PS7Only'
        native_profile_parser = $true
        native_calibration_valid = $true
        native_calibration_sha256 = Get-NxbCiNativeSha256 -Path $nativeCalibrationPath
        repetition_count = $RepetitionCount
        warmup_count = $WarmupCount
        pester_version = '5.7.1'
        psscriptanalyzer_version = '1.25.0'
        pyyaml_version = '6.0.3'
        jsonschema_version = '4.26.0'
        review_entries = 7
        production_private_key_used = $false
        production_release_updated = $false
        production_tag_created = $false
        production_merge_performed = $false
        started_utc = $startedUtc.ToString('o')
        stopped_utc = [DateTime]::UtcNow.ToString('o')
    }
    Write-NxbCiNativeJsonNew -Path $receiptPath -Value $receipt

    $reviewEntries = [ordered]@{
        'hosted-ci-receipt.json' = $hostedReceiptPath
        'native-calibration.json' = $nativeCalibrationPath
        'native-ci-receipt.json' = $receiptPath
        'native-profile-parser.txt' = $profileLogPath
        'pester-ps51.xml' = $ps51XmlPath
        'pester-ps7.xml' = $ps7XmlPath
        'ps51-summary.json' = $ps51SummaryPath
    }
    Write-NxbCiNativeReviewZip -Path $reviewZipPath -Entries $reviewEntries
    $completed = $true

    if ($PassThru) {
        return [pscustomobject][ordered]@{
            status = 'passed'
            authority = 'nxb-v1-ci-native-v1'
            head_sha = $expected
            ps7 = '893/893'
            ps51 = '886/893'
            ps51_not_run = 7
            native_calibration_valid = $true
            receipt_path = $receiptPath
            receipt_sha256 = Get-NxbCiNativeSha256 -Path $receiptPath
            review_zip = $reviewZipPath
            review_zip_sha256 = Get-NxbCiNativeSha256 -Path $reviewZipPath
            review_entries = 7
            production_release_updated = $false
        }
    }
}
catch {
    if (-not (Test-Path -LiteralPath $failurePath)) {
        $failure = [pscustomobject][ordered]@{
            schema_version = 1
            status = 'failed'
            authority = 'nxb-v1-ci-native-v1'
            head_sha = $expected
            failure = $_.Exception.Message
            production_release_updated = $false
            stopped_utc = [DateTime]::UtcNow.ToString('o')
        }
        Write-NxbCiNativeJsonNew -Path $failurePath -Value $failure
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $workRoot -PathType Container) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force
    }
    if (-not $completed -and (Test-Path -LiteralPath $reviewZipPath -PathType Leaf)) {
        Remove-Item -LiteralPath $reviewZipPath -Force
    }
}
