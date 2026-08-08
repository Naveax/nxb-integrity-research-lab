[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._:-]+$')]
    [ValidateLength(1, 128)]
    [string]$ExperimentId,

    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int]$ProcessId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbMemoryTextSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $algorithm = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        return -join @($algorithm.ComputeHash($bytes) | ForEach-Object {
            $_.ToString('x2')
        })
    }
    finally {
        $algorithm.Dispose()
    }
}

function ConvertTo-NxbMemorySource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('native_api', 'cim_snapshot', 'process_snapshot')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$ProvenanceSha256
    )

    return [ordered]@{
        collector = 'New-NxbMemorySnapshot.ps1'
        kind = $Kind
        provenance_sha256 = $ProvenanceSha256
    }
}

function ConvertTo-NxbMemoryMeasured {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(0, [long]::MaxValue)]
        [long]$Value,

        [Parameter(Mandatory)]
        [ValidateSet('bytes', 'count')]
        [string]$Unit,

        [Parameter(Mandatory)]
        [ValidateSet('native_api', 'cim_snapshot', 'process_snapshot')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [string]$ProvenanceSha256
    )

    return [ordered]@{
        status = 'measured'
        value = $Value
        unit = $Unit
        source = ConvertTo-NxbMemorySource `
            -Kind $Kind `
            -ProvenanceSha256 $ProvenanceSha256
        reason = $null
    }
}

function ConvertTo-NxbMemoryUnmeasured {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('unsupported', 'unavailable', 'failed', 'not_assessed')]
        [string]$Status,

        [Parameter(Mandatory)]
        [ValidateSet('bytes', 'count')]
        [string]$Unit,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason
    )

    return [ordered]@{
        status = $Status
        value = $null
        unit = $Unit
        source = $null
        reason = $Reason
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Memory snapshot collector yalnız gerçek Windows üzerinde çalışır.'
}
if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or
    -not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
    throw 'Collector provenance yolu çözümlenemedi.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$validatorPath = Join-Path $PSScriptRoot 'Test-MemorySnapshot.ps1'
$schemaPath = Join-Path $repositoryRoot 'schemas\memory-snapshot.schema.json'
foreach ($requiredPath in @($validatorPath, $schemaPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Memory snapshot collector girdisi bulunamadı: $requiredPath"
    }
}

$outputFull = [IO.Path]::GetFullPath($OutputPath)
$outputParent = Split-Path -Parent $outputFull
if ([string]::IsNullOrWhiteSpace($outputParent)) {
    throw "Output parent çözümlenemedi: $outputFull"
}
[IO.Directory]::CreateDirectory($outputParent) | Out-Null
if (Test-Path -LiteralPath $outputFull) {
    if (-not $Force) {
        throw "Output zaten var; üzerine yazmak için -Force gerekir: $outputFull"
    }
    if (-not (Test-Path -LiteralPath $outputFull -PathType Leaf)) {
        throw "Output yolu normal dosya değil: $outputFull"
    }
}

$collectorHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant()

if ($null -eq ('NxbMemoryNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class NxbMemoryNative
{
    [StructLayout(LayoutKind.Sequential)]
    public struct PERFORMANCE_INFORMATION
    {
        public uint cb;
        public UIntPtr CommitTotal;
        public UIntPtr CommitLimit;
        public UIntPtr CommitPeak;
        public UIntPtr PhysicalTotal;
        public UIntPtr PhysicalAvailable;
        public UIntPtr SystemCache;
        public UIntPtr KernelTotal;
        public UIntPtr KernelPaged;
        public UIntPtr KernelNonpaged;
        public UIntPtr PageSize;
        public uint HandleCount;
        public uint ProcessCount;
        public uint ThreadCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_MEMORY_COUNTERS_EX
    {
        public uint cb;
        public uint PageFaultCount;
        public UIntPtr PeakWorkingSetSize;
        public UIntPtr WorkingSetSize;
        public UIntPtr QuotaPeakPagedPoolUsage;
        public UIntPtr QuotaPagedPoolUsage;
        public UIntPtr QuotaPeakNonPagedPoolUsage;
        public UIntPtr QuotaNonPagedPoolUsage;
        public UIntPtr PagefileUsage;
        public UIntPtr PeakPagefileUsage;
        public UIntPtr PrivateUsage;
    }

    [DllImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetPerformanceInfo(
        out PERFORMANCE_INFORMATION performanceInformation,
        uint size);

    [DllImport("psapi.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool GetProcessMemoryInfo(
        IntPtr process,
        out PROCESS_MEMORY_COUNTERS_EX counters,
        uint size);
}
'@
}

$capturedUtc = [DateTime]::UtcNow
$process = Get-Process -Id $ProcessId -ErrorAction Stop
try {
    $processStartUtc = $process.StartTime.ToUniversalTime()
    $imagePath = [string]$process.Path
    if ([string]::IsNullOrWhiteSpace($imagePath)) {
        $imagePath = [string]$process.MainModule.FileName
    }
    if ([string]::IsNullOrWhiteSpace($imagePath) -or
        -not (Test-Path -LiteralPath $imagePath -PathType Leaf)) {
        throw "Target image yolu çözümlenemedi: PID $ProcessId"
    }
    $imageHash = (Get-FileHash -LiteralPath $imagePath -Algorithm SHA256).Hash.ToLowerInvariant()

    $performance = New-Object NxbMemoryNative+PERFORMANCE_INFORMATION
    $performanceSize = [Runtime.InteropServices.Marshal]::SizeOf($performance)
    if (-not [NxbMemoryNative]::GetPerformanceInfo(
        [ref]$performance,
        [uint32]$performanceSize)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "GetPerformanceInfo başarısız: Win32Error=$code"
    }

    $processCounters = New-Object NxbMemoryNative+PROCESS_MEMORY_COUNTERS_EX
    $processCounters.cb = [uint32][Runtime.InteropServices.Marshal]::SizeOf($processCounters)
    if (-not [NxbMemoryNative]::GetProcessMemoryInfo(
        $process.Handle,
        [ref]$processCounters,
        $processCounters.cb)) {
        $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "GetProcessMemoryInfo başarısız: PID=$ProcessId Win32Error=$code"
    }

    $process.Refresh()
    $confirmStartUtc = $process.StartTime.ToUniversalTime()
    if ($confirmStartUtc.Ticks -ne $processStartUtc.Ticks) {
        throw "Target process identity capture sırasında değişti: PID $ProcessId"
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $lastBootUtc = if ($os.LastBootUpTime -is [datetime]) {
        ([datetime]$os.LastBootUpTime).ToUniversalTime()
    }
    else {
        [Management.ManagementDateTimeConverter]::ToDateTime(
            [string]$os.LastBootUpTime
        ).ToUniversalTime()
    }
    $machineId = if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
        [Environment]::MachineName
    }
    else {
        $env:COMPUTERNAME
    }
    $bootId = Get-NxbMemoryTextSha256 -Value (
        "machine=$machineId`nlast_boot_utc=$($lastBootUtc.ToString('o'))"
    )

    $pageSize = [long]$performance.PageSize.ToUInt64()
    $system = [ordered]@{
        physical_memory_total_bytes = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$performance.PhysicalTotal.ToUInt64() * $pageSize) `
            -Unit bytes `
            -Kind native_api `
            -ProvenanceSha256 $collectorHash
        physical_memory_available_bytes = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$performance.PhysicalAvailable.ToUInt64() * $pageSize) `
            -Unit bytes `
            -Kind native_api `
            -ProvenanceSha256 $collectorHash
        commit_limit_bytes = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$performance.CommitLimit.ToUInt64() * $pageSize) `
            -Unit bytes `
            -Kind native_api `
            -ProvenanceSha256 $collectorHash
        commit_used_bytes = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$performance.CommitTotal.ToUInt64() * $pageSize) `
            -Unit bytes `
            -Kind native_api `
            -ProvenanceSha256 $collectorHash
        standby_cache_bytes = ConvertTo-NxbMemoryUnmeasured `
            -Status not_assessed `
            -Unit bytes `
            -Reason 'Standby-list attribution requires a dedicated memory-list counter or ETW adapter.'
        modified_page_list_bytes = ConvertTo-NxbMemoryUnmeasured `
            -Status not_assessed `
            -Unit bytes `
            -Reason 'Modified-page-list attribution requires a dedicated memory-list counter or ETW adapter.'
        compression_store_bytes = ConvertTo-NxbMemoryUnmeasured `
            -Status not_assessed `
            -Unit bytes `
            -Reason 'Memory compression-store size is not exposed by this minimal native snapshot collector.'
    }

    $processRecord = [ordered]@{
        process_id = $ProcessId
        process_start_utc = $processStartUtc.ToString('o')
        image_sha256 = $imageHash
        is_target = $true
        working_set_bytes = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$processCounters.WorkingSetSize.ToUInt64()) `
            -Unit bytes `
            -Kind native_api `
            -ProvenanceSha256 $collectorHash
        peak_working_set_bytes = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$processCounters.PeakWorkingSetSize.ToUInt64()) `
            -Unit bytes `
            -Kind native_api `
            -ProvenanceSha256 $collectorHash
        private_bytes = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$processCounters.PrivateUsage.ToUInt64()) `
            -Unit bytes `
            -Kind native_api `
            -ProvenanceSha256 $collectorHash
        virtual_size_bytes = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$process.VirtualMemorySize64) `
            -Unit bytes `
            -Kind process_snapshot `
            -ProvenanceSha256 $collectorHash
        peak_virtual_size_bytes = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$process.PeakVirtualMemorySize64) `
            -Unit bytes `
            -Kind process_snapshot `
            -ProvenanceSha256 $collectorHash
        paged_memory_bytes = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$processCounters.PagefileUsage.ToUInt64()) `
            -Unit bytes `
            -Kind native_api `
            -ProvenanceSha256 $collectorHash
        page_fault_count = ConvertTo-NxbMemoryMeasured `
            -Value ([long]$processCounters.PageFaultCount) `
            -Unit count `
            -Kind native_api `
            -ProvenanceSha256 $collectorHash
        hard_fault_count = ConvertTo-NxbMemoryUnmeasured `
            -Status not_assessed `
            -Unit count `
            -Reason 'Hard-fault attribution requires ETW summary evidence.'
        soft_fault_count = ConvertTo-NxbMemoryUnmeasured `
            -Status not_assessed `
            -Unit count `
            -Reason 'Soft-fault attribution requires ETW summary evidence.'
    }

    $document = [ordered]@{
        schema_version = 1
        snapshot_id = 'memory-snapshot-' + [guid]::NewGuid().ToString('N')
        experiment_id = $ExperimentId
        experiment_relative_path = "experiments/$ExperimentId"
        machine_id = $machineId
        boot_id = $bootId
        captured_utc = $capturedUtc.ToString('o')
        target = [ordered]@{
            process_id = $ProcessId
            process_start_utc = $processStartUtc.ToString('o')
            image_sha256 = $imageHash
        }
        system = $system
        processes = @($processRecord)
        summary = [ordered]@{
            system_measurement_count = 4
            process_count = 1
            process_measurement_count = 7
            failed_measurement_count = 0
            evidence_completeness = 'partial'
        }
        claims = [ordered]@{
            working_set_equals_total_memory_cost = $false
            memory_pressure_absence = $false
            page_fault_absence = $false
            capture_completeness = 'not_claimed'
        }
    }

    $temporaryPath = Join-Path `
        $outputParent `
        ('.' + [IO.Path]::GetFileName($outputFull) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText(
            $temporaryPath,
            ($document | ConvertTo-Json -Depth 32),
            [Text.UTF8Encoding]::new($false)
        )
        & $validatorPath -Path $temporaryPath -SchemaPath $schemaPath
        Move-Item -LiteralPath $temporaryPath -Destination $outputFull -Force:$Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}
finally {
    if ($null -ne $process) {
        $process.Dispose()
    }
}

Write-Host "Memory snapshot yazıldı: $outputFull"
if ($PassThru) {
    Get-Content -LiteralPath $outputFull -Raw | ConvertFrom-Json
}
