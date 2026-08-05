[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$ExperimentPath,

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [int]$Iterations = 1000,

    [Parameter()]
    [ValidateRange(1, 255)]
    [int]$Seed = 73,

    [Parameter()]
    [ValidateRange(1, 86400)]
    [int]$TimeoutSeconds = 120,

    [Parameter()]
    [ValidateRange(10, 1000)]
    [int]$SampleIntervalMilliseconds = 50,

    [Parameter()]
    [ValidateNotNullOrEmpty()]
    [string]$WorkloadScriptPath = (Join-Path `
        (Split-Path -Parent $PSScriptRoot) `
        'tools\Invoke-NxbCpuWorkload.ps1'),

    [Parameter()]
    [string]$PowerShellExecutablePath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function ConvertTo-NxbWindowsCommandLineArgument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') {
        return $Value
    }

    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashCount = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashCount++
            continue
        }

        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($backslashCount * 2) + 1)))
            [void]$builder.Append('"')
        }
        else {
            if ($backslashCount -gt 0) {
                [void]$builder.Append(('\' * $backslashCount))
            }
            [void]$builder.Append($character)
        }
        $backslashCount = 0
    }

    if ($backslashCount -gt 0) {
        [void]$builder.Append(('\' * ($backslashCount * 2)))
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function New-NxbMetricMeasurement {
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
            value  = $Value
            unit   = $Unit
            reason = $null
        }
    }

    return [ordered]@{
        status = $Status
        value  = $null
        unit   = $Unit
        reason = $Reason
    }
}

function Resolve-NxbPowerShellHostPath {
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ExplicitPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $explicitFull = Get-NxbFullPath -Path $ExplicitPath
        if (-not (Test-Path -LiteralPath $explicitFull -PathType Leaf)) {
            throw "PowerShell executable bulunamadı: $explicitFull"
        }
        return $explicitFull
    }

    try {
        $currentProcess = Get-Process -Id $PID -ErrorAction Stop
        if (-not [string]::IsNullOrWhiteSpace([string]$currentProcess.Path) -and
            (Test-Path -LiteralPath $currentProcess.Path -PathType Leaf)) {
            return [string]$currentProcess.Path
        }
    }
    catch {
        Write-Verbose "Current PowerShell process path okunamadı: $($_.Exception.Message)"
    }

    foreach ($candidateName in @('pwsh.exe', 'powershell.exe')) {
        $candidate = Join-Path $PSHOME $candidateName
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }

    throw 'PowerShell child-process executable yolu çözümlenemedi.'
}

function Update-NxbProcessPeakSample {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Diagnostics.Process]$Process,

        [Parameter(Mandatory)]
        [ref]$PeakWorkingSetBytes,

        [Parameter(Mandatory)]
        [ref]$PeakPrivateBytes,

        [Parameter(Mandatory)]
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
        $message = "Process metric sample alınamadı: $($_.Exception.Message)"
        if (-not $Diagnostics.Contains($message)) {
            $Diagnostics.Add($message)
        }
    }
}

$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$manifestPath = Join-Path $experimentFull 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Manifest bulunamadı: $manifestPath"
}
$manifest = Read-NxbJson -Path $manifestPath
if ([string]$manifest.status -notin @('prepared', 'recording')) {
    throw "Measured workload yalnız prepared veya recording deneyde çalışabilir. Mevcut durum: $($manifest.status)"
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$toolsRoot = Join-Path $repositoryRoot 'tools'
$workloadFull = Get-NxbFullPath -Path $WorkloadScriptPath
if (-not (Test-Path -LiteralPath $workloadFull -PathType Leaf)) {
    throw "Controlled workload script bulunamadı: $workloadFull"
}
[void](Get-NxbRelativePath -BasePath $toolsRoot -ChildPath $workloadFull)
[void](Test-NxbPathSafety -Path $workloadFull -RootPath $toolsRoot)

$powerShellPath = Resolve-NxbPowerShellHostPath -ExplicitPath $PowerShellExecutablePath
$logsRoot = Join-Path $experimentFull 'logs'
New-Item -ItemType Directory -Path $logsRoot -Force | Out-Null
$resultPath = Join-Path $logsRoot 'cpu-workload-result.json'
$stdoutPath = Join-Path $logsRoot 'cpu-workload.stdout.txt'
$stderrPath = Join-Path $logsRoot 'cpu-workload.stderr.txt'
$measurementPath = Join-Path $logsRoot 'cpu-workload-measurement.json'
foreach ($outputPath in @($resultPath, $stdoutPath, $stderrPath, $measurementPath)) {
    if (Test-Path -LiteralPath $outputPath) {
        throw "Measured workload çıktı dosyası zaten var: $outputPath"
    }
}

$argumentValues = @(
    '-NoLogo',
    '-NoProfile',
    '-NonInteractive',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $workloadFull,
    '-Iterations',
    [string]$Iterations,
    '-Seed',
    [string]$Seed,
    '-OutputPath',
    $resultPath,
    '-Confirm:$false'
)
$commandLine = ($argumentValues | ForEach-Object {
    ConvertTo-NxbWindowsCommandLineArgument -Value ([string]$_)
}) -join ' '

$processStartInfo = [Diagnostics.ProcessStartInfo]::new()
$processStartInfo.FileName = $powerShellPath
$processStartInfo.Arguments = $commandLine
$processStartInfo.UseShellExecute = $false
$processStartInfo.CreateNoWindow = $true
$processStartInfo.RedirectStandardOutput = $true
$processStartInfo.RedirectStandardError = $true

$process = [Diagnostics.Process]::new()
$process.StartInfo = $processStartInfo
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
        throw 'Controlled workload process başlatılamadı.'
    }

    while (-not $process.WaitForExit($SampleIntervalMilliseconds)) {
        Update-NxbProcessPeakSample `
            -Process $process `
            -PeakWorkingSetBytes ([ref]$peakWorkingSetBytes) `
            -PeakPrivateBytes ([ref]$peakPrivateBytes) `
            -Diagnostics $diagnostics

        if ($stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
            $timedOut = $true
            $diagnostics.Add("Workload timeout sınırını aştı: $TimeoutSeconds saniye")
            try {
                $process.Kill()
            }
            catch {
                $diagnostics.Add("Timed-out process sonlandırılamadı: $($_.Exception.Message)")
            }
            break
        }
    }

    $process.WaitForExit()
    Update-NxbProcessPeakSample `
        -Process $process `
        -PeakWorkingSetBytes ([ref]$peakWorkingSetBytes) `
        -PeakPrivateBytes ([ref]$peakPrivateBytes) `
        -Diagnostics $diagnostics

    $exitCode = [int]$process.ExitCode
    try {
        $cpuTimeMs = [double]$process.TotalProcessorTime.TotalMilliseconds
    }
    catch {
        $diagnostics.Add("Process CPU time okunamadı: $($_.Exception.Message)")
    }

    $standardOutput = $process.StandardOutput.ReadToEnd()
    $standardError = $process.StandardError.ReadToEnd()
}
finally {
    $stopwatch.Stop()
    $stoppedUtc = [DateTime]::UtcNow
    $process.Dispose()
}

[IO.File]::WriteAllText($stdoutPath, $standardOutput, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($stderrPath, $standardError, [Text.UTF8Encoding]::new($false))

$resultEvidence = $null
$armStatus = 'failed'
if (-not $timedOut -and $exitCode -eq 0 -and
    (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
    try {
        $workloadResult = Read-NxbJson -Path $resultPath
        if ([int]$workloadResult.schema_version -ne 1 -or
            [string]$workloadResult.workload_id -cne 'nxb.cpu.sha256-chain.v1' -or
            [int]$workloadResult.iterations -ne $Iterations -or
            [int]$workloadResult.seed -ne $Seed -or
            [string]$workloadResult.checksum_sha256 -notmatch '^[0-9a-f]{64}$') {
            throw 'Controlled workload result sözleşmesi uyuşmuyor.'
        }

        $resultEvidence = [ordered]@{
            status = 'measured'
            value  = [string]$workloadResult.checksum_sha256
            unit   = 'sha256'
            reason = $null
        }
        $armStatus = 'measured'
    }
    catch {
        $diagnostics.Add("Controlled workload result doğrulanamadı: $($_.Exception.Message)")
    }
}
else {
    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
        $diagnostics.Add('Controlled workload result dosyası oluşturulmadı.')
    }
}

if ($null -eq $resultEvidence) {
    $resultEvidence = [ordered]@{
        status = 'failed'
        value  = $null
        unit   = 'sha256'
        reason = if ($diagnostics.Count -gt 0) {
            $diagnostics -join '; '
        }
        else {
            'Controlled workload başarısız.'
        }
    }
}

$cpuMeasurement = if ($null -ne $cpuTimeMs) {
    New-NxbMetricMeasurement -Value $cpuTimeMs -Unit 'ms'
}
else {
    New-NxbMetricMeasurement `
        -Status failed `
        -Unit 'ms' `
        -Reason 'Process CPU time ölçülemedi.'
}
$workingSetMeasurement = if ($peakWorkingSetBytes -gt 0) {
    New-NxbMetricMeasurement -Value ([double]$peakWorkingSetBytes) -Unit 'bytes'
}
else {
    New-NxbMetricMeasurement `
        -Status unsupported `
        -Unit 'bytes' `
        -Reason 'Peak working set örneklenemedi.'
}
$privateBytesMeasurement = if ($peakPrivateBytes -gt 0) {
    New-NxbMetricMeasurement -Value ([double]$peakPrivateBytes) -Unit 'bytes'
}
else {
    New-NxbMetricMeasurement `
        -Status unsupported `
        -Unit 'bytes' `
        -Reason 'Peak private bytes örneklenemedi.'
}

$measurement = [ordered]@{
    status        = $armStatus
    started_utc   = $startedUtc.ToString('o')
    stopped_utc   = $stoppedUtc.ToString('o')
    duration_ms   = [Math]::Round($stopwatch.Elapsed.TotalMilliseconds, 6)
    exit_code     = $exitCode
    timed_out     = $timedOut
    result        = $resultEvidence
    process_metrics = [ordered]@{
        cpu_time_ms             = $cpuMeasurement
        peak_working_set_bytes  = $workingSetMeasurement
        peak_private_bytes      = $privateBytesMeasurement
    }
    diagnostics   = @($diagnostics)
    runner_provenance = [ordered]@{
        powershell_executable = $powerShellPath
        workload_relative_path = (Get-NxbRelativePath `
            -BasePath $repositoryRoot `
            -ChildPath $workloadFull).Replace([IO.Path]::DirectorySeparatorChar, [char]'/')
        workload_sha256 = (Get-FileHash `
            -LiteralPath $workloadFull `
            -Algorithm SHA256).Hash.ToLowerInvariant()
        workload_length = [int64](Get-Item -LiteralPath $workloadFull).Length
        iterations = $Iterations
        seed = $Seed
        timeout_seconds = $TimeoutSeconds
        sample_interval_milliseconds = $SampleIntervalMilliseconds
    }
}

Write-NxbJsonAtomic -Path $measurementPath -InputObject $measurement -Depth 16
Write-Host "Measured workload tamamlandı: $measurementPath"

if ($PassThru) {
    return [pscustomobject]$measurement
}

Write-Output $measurementPath
