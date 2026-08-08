[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [ValidateRange(4, 128)]
    [int]$PrivateMemoryMiB = 32,

    [Parameter()]
    [ValidateRange(1, 64)]
    [int]$MappedFileMiB = 8,

    [Parameter()]
    [ValidateRange(0, 3000)]
    [int]$HoldMilliseconds = 1000,

    [Parameter()]
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 30,

    [Parameter()]
    [ValidateRange(10, 1000)]
    [int]$SampleIntervalMilliseconds = 25,

    [Parameter()]
    [string]$PowerShellExecutablePath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function ConvertTo-NxbMemoryCommandLineArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $quoteCharacter = [char]34
    $backslashCharacter = [char]92
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append($quoteCharacter)
    $backslashCount = 0

    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq $backslashCharacter) {
            $backslashCount++
            continue
        }
        if ($character -eq $quoteCharacter) {
            [void]$builder.Append(
                ([string]$backslashCharacter * (($backslashCount * 2) + 1))
            )
            [void]$builder.Append($quoteCharacter)
        }
        else {
            if ($backslashCount -gt 0) {
                [void]$builder.Append(
                    ([string]$backslashCharacter * $backslashCount)
                )
            }
            [void]$builder.Append($character)
        }
        $backslashCount = 0
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append(
            ([string]$backslashCharacter * ($backslashCount * 2))
        )
    }
    [void]$builder.Append($quoteCharacter)
    return $builder.ToString()
}

function Get-NxbMemoryMetric {
    [CmdletBinding(DefaultParameterSetName = 'Measured')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Measured')]
        [double]$Value,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Unit,

        [Parameter(Mandatory, ParameterSetName = 'Unavailable')]
        [ValidateSet('unsupported', 'failed')]
        [string]$Status,

        [Parameter(Mandatory, ParameterSetName = 'Unavailable')]
        [ValidateNotNullOrEmpty()]
        [string]$Reason
    )

    if ($PSCmdlet.ParameterSetName -eq 'Measured') {
        return [ordered]@{
            status = 'measured'
            value = $Value
            unit = $Unit
            reason = $null
        }
    }

    return [ordered]@{
        status = $Status
        value = $null
        unit = $Unit
        reason = $Reason
    }
}

function Resolve-NxbMemoryPowerShellPath {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ExplicitPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $full = [IO.Path]::GetFullPath($ExplicitPath)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "PowerShell executable not found: $full"
        }
        return $full
    }

    foreach ($candidate in @('pwsh.exe', 'pwsh')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command -and
            (Test-Path -LiteralPath $command.Source -PathType Leaf)) {
            return [IO.Path]::GetFullPath([string]$command.Source)
        }
    }

    throw 'PowerShell 7 executable could not be resolved.'
}

function Measure-NxbMemoryProcessSample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Diagnostics.Process]$Process,

        [Parameter(Mandatory)]
        [ref]$PeakWorkingSetBytes,

        [Parameter(Mandatory)]
        [ref]$PeakPrivateBytes,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[string]]$Diagnostics
    )

    try {
        $Process.Refresh()
        $workingSet = [int64]$Process.WorkingSet64
        $reportedPeakWorkingSet = [int64]$Process.PeakWorkingSet64
        $privateBytes = [int64]$Process.PrivateMemorySize64
        if ($workingSet -gt [int64]$PeakWorkingSetBytes.Value) {
            $PeakWorkingSetBytes.Value = $workingSet
        }
        if ($reportedPeakWorkingSet -gt [int64]$PeakWorkingSetBytes.Value) {
            $PeakWorkingSetBytes.Value = $reportedPeakWorkingSet
        }
        if ($privateBytes -gt [int64]$PeakPrivateBytes.Value) {
            $PeakPrivateBytes.Value = $privateBytes
        }
    }
    catch {
        $message = "Process metric sample failed: $($_.Exception.Message)"
        if (-not $Diagnostics.Contains($message)) {
            $Diagnostics.Add($message)
        }
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Measured memory workload requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Measured memory workload must run from PowerShell 7.'
}

$experimentFull = [IO.Path]::GetFullPath($ExperimentPath)
$manifestPath = Join-Path $experimentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Experiment manifest not found: $manifestPath"
}
$manifest = Read-NxbJson -Path $manifestPath
if ([string]$manifest.status -notin @('prepared', 'recording')) {
    throw "Measured memory workload requires prepared or recording experiment state: $($manifest.status)"
}

$workloadPath = Join-Path $PSScriptRoot 'Invoke-NxbMemoryProbeWorkload.ps1'
if (-not (Test-Path -LiteralPath $workloadPath -PathType Leaf)) {
    throw "Memory probe workload not found: $workloadPath"
}
$workloadItem = Get-Item -LiteralPath $workloadPath -Force
if (($workloadItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Memory probe workload cannot be a reparse point: $workloadPath"
}

$powerShellPath = Resolve-NxbMemoryPowerShellPath `
    -ExplicitPath $PowerShellExecutablePath
$logsRoot = Join-Path $experimentFull 'logs'
[IO.Directory]::CreateDirectory($logsRoot) | Out-Null
$receiptPath = Join-Path $logsRoot 'memory-probe-workload-receipt.json'
$stdoutPath = Join-Path $logsRoot 'memory-probe-workload.stdout.txt'
$stderrPath = Join-Path $logsRoot 'memory-probe-workload.stderr.txt'
$measurementPath = Join-Path $logsRoot 'memory-probe-workload-measurement.json'
foreach ($outputPath in @(
    $receiptPath,
    $stdoutPath,
    $stderrPath,
    $measurementPath
)) {
    if (Test-Path -LiteralPath $outputPath) {
        throw "Measured memory workload output already exists: $outputPath"
    }
}

$argumentValues = @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $workloadPath,
    '-PrivateMemoryMiB',
    [string]$PrivateMemoryMiB,
    '-MappedFileMiB',
    [string]$MappedFileMiB,
    '-HoldMilliseconds',
    [string]$HoldMilliseconds,
    '-ReceiptPath',
    $receiptPath
)
$commandLine = ($argumentValues | ForEach-Object {
    ConvertTo-NxbMemoryCommandLineArgument -Value ([string]$_)
}) -join ' '

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $powerShellPath
$startInfo.Arguments = $commandLine
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$diagnostics = [Collections.Generic.List[string]]::new()
$peakWorkingSetBytes = [int64]0
$peakPrivateBytes = [int64]0
$cpuTimeMs = $null
$exitCode = $null
$timedOut = $false
$startedUtc = [DateTime]::UtcNow
$stoppedUtc = $startedUtc
$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$standardOutput = ''
$standardError = ''

try {
    if (-not $process.Start()) {
        throw 'Memory probe child process could not be started.'
    }

    while (-not $process.WaitForExit($SampleIntervalMilliseconds)) {
        Measure-NxbMemoryProcessSample `
            -Process $process `
            -PeakWorkingSetBytes ([ref]$peakWorkingSetBytes) `
            -PeakPrivateBytes ([ref]$peakPrivateBytes) `
            -Diagnostics $diagnostics

        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $timedOut = $true
            $diagnostics.Add("Memory probe exceeded timeout: $TimeoutSeconds seconds")
            try {
                $process.Kill()
            }
            catch {
                $diagnostics.Add("Timed-out memory probe could not be killed: $($_.Exception.Message)")
            }
            break
        }
    }

    if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
        throw 'Memory probe did not terminate within teardown timeout.'
    }
    $process.WaitForExit()

    Measure-NxbMemoryProcessSample `
        -Process $process `
        -PeakWorkingSetBytes ([ref]$peakWorkingSetBytes) `
        -PeakPrivateBytes ([ref]$peakPrivateBytes) `
        -Diagnostics $diagnostics

    $exitCode = [int]$process.ExitCode
    try {
        $cpuTimeMs = [double]$process.TotalProcessorTime.TotalMilliseconds
    }
    catch {
        $diagnostics.Add("Process CPU time could not be read: $($_.Exception.Message)")
    }

    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
}
finally {
    $stopwatch.Stop()
    $stoppedUtc = [DateTime]::UtcNow
    $process.Dispose()
}

[IO.File]::WriteAllText(
    $stdoutPath,
    $standardOutput,
    [Text.UTF8Encoding]::new($false)
)
[IO.File]::WriteAllText(
    $stderrPath,
    $standardError,
    [Text.UTF8Encoding]::new($false)
)

$resultEvidence = $null
$armStatus = 'failed'
if (-not $timedOut -and $exitCode -eq 0 -and
    (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    try {
        $receipt = Read-NxbJson -Path $receiptPath
        if ([int]$receipt.schema_version -ne 1 -or
            [int]$receipt.private_memory_mib -ne $PrivateMemoryMiB -or
            [int]$receipt.mapped_file_mib -ne $MappedFileMiB -or
            [int]$receipt.hold_milliseconds -ne $HoldMilliseconds -or
            [int]$receipt.page_stride_bytes -ne 4096 -or
            [string]$receipt.checksum -notmatch '^[0-9]+$') {
            throw 'Memory probe receipt contract mismatch.'
        }
        if ([bool]$receipt.claims.system_memory_exhaustion_attempted) {
            throw 'Memory probe receipt reports a forbidden exhaustion attempt.'
        }

        $resultEvidence = [ordered]@{
            status = 'measured'
            value = [string]$receipt.checksum
            unit = 'checksum'
            reason = $null
        }
        $armStatus = 'measured'
    }
    catch {
        $diagnostics.Add("Memory probe receipt validation failed: $($_.Exception.Message)")
    }
}
else {
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        $diagnostics.Add('Memory probe receipt was not written.')
    }
}

if ($null -eq $resultEvidence) {
    $resultEvidence = [ordered]@{
        status = 'failed'
        value = $null
        unit = 'checksum'
        reason = if ($diagnostics.Count -gt 0) {
            $diagnostics -join '; '
        }
        else {
            'Memory probe workload failed.'
        }
    }
}

$cpuMeasurement = if ($null -ne $cpuTimeMs) {
    Get-NxbMemoryMetric -Value $cpuTimeMs -Unit 'ms'
}
else {
    Get-NxbMemoryMetric `
        -Status failed `
        -Unit 'ms' `
        -Reason 'Process CPU time was not measured.'
}
$workingSetMeasurement = if ($peakWorkingSetBytes -gt 0) {
    Get-NxbMemoryMetric -Value ([double]$peakWorkingSetBytes) -Unit 'bytes'
}
else {
    Get-NxbMemoryMetric `
        -Status unsupported `
        -Unit 'bytes' `
        -Reason 'Peak working set was not sampled.'
}
$privateBytesMeasurement = if ($peakPrivateBytes -gt 0) {
    Get-NxbMemoryMetric -Value ([double]$peakPrivateBytes) -Unit 'bytes'
}
else {
    Get-NxbMemoryMetric `
        -Status unsupported `
        -Unit 'bytes' `
        -Reason 'Peak private bytes were not sampled.'
}

$measurement = [ordered]@{
    status = $armStatus
    started_utc = $startedUtc.ToString('o')
    stopped_utc = $stoppedUtc.ToString('o')
    duration_ms = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 6)
    exit_code = $exitCode
    timed_out = $timedOut
    result = $resultEvidence
    process_metrics = [ordered]@{
        cpu_time_ms = $cpuMeasurement
        peak_working_set_bytes = $workingSetMeasurement
        peak_private_bytes = $privateBytesMeasurement
    }
    diagnostics = @($diagnostics)
    runner_provenance = [ordered]@{
        powershell_executable = $powerShellPath
        workload_relative_path = 'scripts/Invoke-NxbMemoryProbeWorkload.ps1'
        workload_sha256 = (
            Get-FileHash -LiteralPath $workloadPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        workload_length = [int64]$workloadItem.Length
        private_memory_mib = $PrivateMemoryMiB
        mapped_file_mib = $MappedFileMiB
        hold_milliseconds = $HoldMilliseconds
        timeout_seconds = $TimeoutSeconds
        sample_interval_milliseconds = $SampleIntervalMilliseconds
    }
}

Write-NxbJsonAtomic -Path $measurementPath -InputObject $measurement -Depth 16
Write-Information `
    -MessageData "Measured memory workload completed: $measurementPath" `
    -InformationAction Continue

if ($PassThru) {
    return [pscustomobject]$measurement
}

Write-Output $measurementPath
