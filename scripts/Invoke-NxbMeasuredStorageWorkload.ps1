[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [ValidateRange(1, 16)]
    [int]$FileSizeMiB = 16,

    [Parameter()]
    [ValidateRange(64, 1024)]
    [int]$BlockSizeKiB = 256,

    [Parameter()]
    [ValidateRange(1, 120)]
    [int]$TimeoutSeconds = 30,

    [Parameter()]
    [ValidateRange(5, 1000)]
    [int]$SampleIntervalMilliseconds = 10,

    [Parameter()]
    [string]$PowerShellExecutablePath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function ConvertTo-NxbStorageCalibrationCommandLineArgument {
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

function Get-NxbStorageCalibrationMetric {
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

function Resolve-NxbStorageCalibrationPowerShellPath {
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

function Measure-NxbStorageCalibrationProcessSample {
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
    throw 'Measured storage workload requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Measured storage workload must run from PowerShell 7.'
}

$experimentFull = [IO.Path]::GetFullPath($ExperimentPath)
$manifestPath = Join-Path $experimentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Experiment manifest not found: $manifestPath"
}
$manifest = Read-NxbJson -Path $manifestPath
if ([string]$manifest.status -notin @('prepared', 'recording')) {
    throw "Measured storage workload requires prepared or recording experiment state: $($manifest.status)"
}

$workloadPath = Join-Path $PSScriptRoot 'Invoke-NxbStorageHeaderProbeWorkload.ps1'
if (-not (Test-Path -LiteralPath $workloadPath -PathType Leaf)) {
    throw "Storage workload not found: $workloadPath"
}
$workloadItem = Get-Item -LiteralPath $workloadPath -Force
if (($workloadItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "Storage workload cannot be a reparse point: $workloadPath"
}

$powerShellPath = Resolve-NxbStorageCalibrationPowerShellPath `
    -ExplicitPath $PowerShellExecutablePath
$logsRoot = Join-Path $experimentFull 'logs'
[IO.Directory]::CreateDirectory($logsRoot) | Out-Null
$workloadOutputDirectory = Join-Path $logsRoot 'storage-calibration-workload'
$receiptPath = Join-Path $logsRoot 'storage-calibration-workload-receipt.json'
$stdoutPath = Join-Path $logsRoot 'storage-calibration-workload.stdout.txt'
$stderrPath = Join-Path $logsRoot 'storage-calibration-workload.stderr.txt'
$measurementPath = Join-Path $logsRoot 'storage-calibration-workload-measurement.json'
foreach ($outputPath in @(
    $workloadOutputDirectory,
    $receiptPath,
    $stdoutPath,
    $stderrPath,
    $measurementPath
)) {
    if (Test-Path -LiteralPath $outputPath) {
        throw "Measured storage workload output already exists: $outputPath"
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
    '-OutputDirectory',
    $workloadOutputDirectory,
    '-FileSizeMiB',
    [string]$FileSizeMiB,
    '-BlockSizeKiB',
    [string]$BlockSizeKiB,
    '-ReceiptPath',
    $receiptPath
)
$commandLine = ($argumentValues | ForEach-Object {
    ConvertTo-NxbStorageCalibrationCommandLineArgument -Value ([string]$_)
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
        throw 'Storage workload child process could not be started.'
    }

    while (-not $process.WaitForExit($SampleIntervalMilliseconds)) {
        Measure-NxbStorageCalibrationProcessSample `
            -Process $process `
            -PeakWorkingSetBytes ([ref]$peakWorkingSetBytes) `
            -PeakPrivateBytes ([ref]$peakPrivateBytes) `
            -Diagnostics $diagnostics

        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $timedOut = $true
            $diagnostics.Add("Storage workload exceeded timeout: $TimeoutSeconds seconds")
            try {
                $process.Kill()
            }
            catch {
                $diagnostics.Add("Timed-out storage workload could not be killed: $($_.Exception.Message)")
            }
            break
        }
    }

    if (-not $process.HasExited -and -not $process.WaitForExit(5000)) {
        throw 'Storage workload did not terminate within teardown timeout.'
    }
    $process.WaitForExit()

    Measure-NxbStorageCalibrationProcessSample `
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
        $expectedBytes = [int64]$FileSizeMiB * 1MB
        if ([int]$receipt.schema_version -ne 1 -or
            [string]$receipt.status -cne 'passed' -or
            [int]$receipt.requested_file_size_mib -ne $FileSizeMiB -or
            [int]$receipt.block_size_kib -ne $BlockSizeKiB -or
            [int64]$receipt.bytes_written -ne $expectedBytes -or
            [int64]$receipt.bytes_read -ne $expectedBytes -or
            [int]$receipt.flush_count -lt 1 -or
            -not [bool]$receipt.renamed -or
            -not [bool]$receipt.deleted) {
            throw 'Storage workload receipt contract mismatch.'
        }
        if ([bool]$receipt.claims.benchmark -or
            [bool]$receipt.claims.representative_throughput -or
            [bool]$receipt.claims.representative_iops -or
            [bool]$receipt.claims.cache_state_controlled) {
            throw 'Storage workload receipt enabled a forbidden benchmark/representativeness claim.'
        }

        $resultMaterial = [ordered]@{
            file_size_mib = $FileSizeMiB
            block_size_kib = $BlockSizeKiB
            bytes_written = [int64]$receipt.bytes_written
            bytes_read = [int64]$receipt.bytes_read
            flush_count = [int]$receipt.flush_count
            renamed = [bool]$receipt.renamed
            deleted = [bool]$receipt.deleted
        }
        $resultEvidence = [ordered]@{
            status = 'measured'
            value = Get-NxbCanonicalJsonHash -InputObject $resultMaterial
            unit = 'sha256'
            reason = $null
        }
        $armStatus = 'measured'
    }
    catch {
        $diagnostics.Add("Storage workload receipt validation failed: $($_.Exception.Message)")
    }
}
else {
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        $diagnostics.Add('Storage workload receipt was not written.')
    }
}

if ($null -eq $resultEvidence) {
    $resultEvidence = [ordered]@{
        status = 'failed'
        value = $null
        unit = 'sha256'
        reason = if ($diagnostics.Count -gt 0) {
            $diagnostics -join '; '
        }
        else {
            'Storage workload failed.'
        }
    }
}

$cpuMeasurement = if ($null -ne $cpuTimeMs) {
    Get-NxbStorageCalibrationMetric -Value $cpuTimeMs -Unit 'ms'
}
else {
    Get-NxbStorageCalibrationMetric `
        -Status failed `
        -Unit 'ms' `
        -Reason 'Process CPU time was not measured.'
}
$workingSetMeasurement = if ($peakWorkingSetBytes -gt 0) {
    Get-NxbStorageCalibrationMetric -Value ([double]$peakWorkingSetBytes) -Unit 'bytes'
}
else {
    Get-NxbStorageCalibrationMetric `
        -Status unsupported `
        -Unit 'bytes' `
        -Reason 'Peak working set was not sampled.'
}
$privateBytesMeasurement = if ($peakPrivateBytes -gt 0) {
    Get-NxbStorageCalibrationMetric -Value ([double]$peakPrivateBytes) -Unit 'bytes'
}
else {
    Get-NxbStorageCalibrationMetric `
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
        workload_relative_path = 'scripts/Invoke-NxbStorageHeaderProbeWorkload.ps1'
        workload_sha256 = (
            Get-FileHash -LiteralPath $workloadPath -Algorithm SHA256
        ).Hash.ToLowerInvariant()
        workload_length = [int64]$workloadItem.Length
        file_size_mib = $FileSizeMiB
        block_size_kib = $BlockSizeKiB
        timeout_seconds = $TimeoutSeconds
        sample_interval_milliseconds = $SampleIntervalMilliseconds
    }
}

Write-NxbJsonAtomic -Path $measurementPath -InputObject $measurement -Depth 16
Write-Information `
    -MessageData "Measured storage workload completed: $measurementPath" `
    -InformationAction Continue

if ($PassThru) {
    return [pscustomobject]$measurement
}

Write-Output $measurementPath
