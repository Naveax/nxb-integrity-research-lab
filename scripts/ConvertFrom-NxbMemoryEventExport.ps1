[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z0-9._:-]+$')]
    [ValidateLength(1, 128)]
    [string]$ExperimentId,

    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$InputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$MachineId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$BootId,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$TraceSha256,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$ProfileSha256,

    [Parameter(Mandatory)]
    [datetime]$TraceStartUtc,

    [Parameter(Mandatory)]
    [datetime]$TraceEndUtc,

    [Parameter(Mandatory)]
    [ValidateRange(1, 2147483647)]
    [int]$TargetProcessId,

    [Parameter(Mandatory)]
    [datetime]$TargetProcessStartUtc,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-f]{64}$')]
    [string]$TargetImageSha256,

    [Parameter(Mandatory)]
    [ValidateCount(1, 9)]
    [ValidateSet(
        'hard_fault',
        'demand_zero_fault',
        'copy_on_write_fault',
        'transition_fault',
        'guard_page_fault',
        'virtual_allocation',
        'virtual_free',
        'mapped_section_create',
        'mapped_section_delete'
    )]
    [string[]]$CoveredEventType,

    [Parameter(Mandatory)]
    [ValidateSet('none', 'present', 'unknown')]
    [string]$TraceLoss,

    [Parameter(Mandatory)]
    [ValidateSet('none', 'possible', 'confirmed', 'unknown')]
    [string]$CircularOverwrite,

    [Parameter()]
    [ValidateRange(1, 5000000)]
    [int]$MaxEventCount = 1000000,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-NxbMemoryEventPython {
    [CmdletBinding()]
    param()

    foreach ($candidate in @('python.exe', 'python', 'py.exe', 'py')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -ne $command) {
            return [string]$command.Source
        }
    }
    return $null
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Memory event export conversion is supported only on Windows.'
}
if ([string]::IsNullOrWhiteSpace($PSCommandPath) -or
    -not (Test-Path -LiteralPath $PSCommandPath -PathType Leaf)) {
    throw 'Memory ETL adapter provenance path could not be resolved.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$pythonConverter = Join-Path `
    $repositoryRoot `
    'tools\convert_memory_event_export.py'
$validatorPath = Join-Path $PSScriptRoot 'Test-MemoryEtlSummary.ps1'
$schemaPath = Join-Path `
    $repositoryRoot `
    'schemas\memory-etl-summary.schema.json'
foreach ($requiredPath in @($pythonConverter, $validatorPath, $schemaPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Memory ETL adapter input not found: $requiredPath"
    }
}

$pythonPath = Resolve-NxbMemoryEventPython
if ([string]::IsNullOrWhiteSpace($pythonPath)) {
    throw 'Python not found. Memory event export conversion requires Python.'
}

$inputFull = [IO.Path]::GetFullPath($InputPath)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
if ($inputFull -ceq $outputFull) {
    throw 'InputPath and OutputPath must be different files.'
}

$inputItem = Get-Item -LiteralPath $inputFull -Force
if (($inputItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
    throw "InputPath cannot be a reparse point: $inputFull"
}

$outputParent = Split-Path -Parent $outputFull
if ([string]::IsNullOrWhiteSpace($outputParent)) {
    throw "Output parent could not be resolved: $outputFull"
}
[IO.Directory]::CreateDirectory($outputParent) | Out-Null
if (Test-Path -LiteralPath $outputFull) {
    if (-not $Force) {
        throw "Output already exists; use -Force to overwrite: $outputFull"
    }
    if (-not (Test-Path -LiteralPath $outputFull -PathType Leaf)) {
        throw "OutputPath is not a normal file: $outputFull"
    }
}

$adapterHash = (
    Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$temporaryPath = Join-Path `
    $outputParent `
    ('.' + [IO.Path]::GetFileName($outputFull) + '.' +
        [guid]::NewGuid().ToString('N') + '.tmp')

$arguments = @(
    $pythonConverter,
    '--input',
    $inputFull,
    '--output',
    $temporaryPath,
    '--experiment-id',
    $ExperimentId,
    '--machine-id',
    $MachineId,
    '--boot-id',
    $BootId,
    '--trace-sha256',
    $TraceSha256,
    '--profile-sha256',
    $ProfileSha256,
    '--adapter-sha256',
    $adapterHash,
    '--trace-start-utc',
    $TraceStartUtc.ToUniversalTime().ToString(
        "yyyy-MM-ddTHH:mm:ss.ffffff'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    ),
    '--trace-end-utc',
    $TraceEndUtc.ToUniversalTime().ToString(
        "yyyy-MM-ddTHH:mm:ss.ffffff'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    ),
    '--target-process-id',
    [string]$TargetProcessId,
    '--target-process-start-utc',
    $TargetProcessStartUtc.ToUniversalTime().ToString(
        "yyyy-MM-ddTHH:mm:ss.ffffff'Z'",
        [Globalization.CultureInfo]::InvariantCulture
    ),
    '--target-image-sha256',
    $TargetImageSha256,
    '--trace-loss',
    $TraceLoss,
    '--circular-overwrite',
    $CircularOverwrite,
    '--max-event-count',
    [string]$MaxEventCount
)
foreach ($eventType in $CoveredEventType) {
    $arguments += @('--covered-event-type', $eventType)
}

$previousErrorActionPreference = $ErrorActionPreference
$nativePreferenceVariable = Get-Variable `
    -Name PSNativeCommandUseErrorActionPreference `
    -ErrorAction SilentlyContinue
$nativePreferenceAvailable = $null -ne $nativePreferenceVariable
$previousNativePreference = if ($nativePreferenceAvailable) {
    [bool]$nativePreferenceVariable.Value
}
else {
    $null
}

$output = @()
$exitCode = 1
try {
    $ErrorActionPreference = 'Continue'
    if ($nativePreferenceAvailable) {
        Set-Variable `
            -Name PSNativeCommandUseErrorActionPreference `
            -Value $false `
            -Scope Local
    }
    $output = @(& $pythonPath @arguments 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) {
        1
    }
    else {
        [int]$LASTEXITCODE
    }
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
    if ($nativePreferenceAvailable) {
        Set-Variable `
            -Name PSNativeCommandUseErrorActionPreference `
            -Value $previousNativePreference `
            -Scope Local
    }
}

try {
    if ($exitCode -ne 0) {
        $message = @($output | ForEach-Object { [string]$_ }) -join `
            [Environment]::NewLine
        throw (
            "Memory event export conversion failed (exit $exitCode):`n" +
            $message
        )
    }

    & $validatorPath -Path $temporaryPath -SchemaPath $schemaPath
    Move-Item `
        -LiteralPath $temporaryPath `
        -Destination $outputFull `
        -Force:$Force
}
finally {
    if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
        Remove-Item -LiteralPath $temporaryPath -Force
    }
}

Write-Host "Memory ETL summary written: $outputFull"
if ($PassThru) {
    Get-Content -LiteralPath $outputFull -Raw | ConvertFrom-Json
}
