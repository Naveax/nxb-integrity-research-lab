[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$profilePath = Join-Path $repositoryRoot 'profiles\Nxb.MemoryWorkingSet.wprp'
$profileValidatorPath = Join-Path $PSScriptRoot 'Test-NxbMemoryWprProfile.ps1'
$profileTestPath = Join-Path $repositoryRoot 'tests\MemoryWprProfile.Tests.ps1'
$smokeTestPath = Join-Path $repositoryRoot 'tests\MemoryProfileRepositorySmoke.Tests.ps1'
$profileValidationPath = Join-Path $PSScriptRoot 'Invoke-NxbMemoryProfileLocalValidation.ps1'
$memorySchemaPath = Join-Path $repositoryRoot 'schemas\memory-snapshot.schema.json'
$memoryFixturePath = Join-Path $repositoryRoot 'tests\fixtures\memory-snapshot.valid.json'
$memoryValidatorPath = Join-Path $PSScriptRoot 'Test-MemorySnapshot.ps1'
$memoryPythonValidatorPath = Join-Path $repositoryRoot 'tools\validate_memory_snapshot.py'
$memoryTestPath = Join-Path $repositoryRoot 'tests\MemorySnapshot.Tests.ps1'
$collectorPath = Join-Path $PSScriptRoot 'New-NxbMemorySnapshot.ps1'
$collectorTestPath = Join-Path $repositoryRoot 'tests\MemorySnapshotCollector.Tests.ps1'

$requiredFiles = @(
    $profilePath,
    $profileValidatorPath,
    $profileTestPath,
    $smokeTestPath,
    $profileValidationPath,
    $memorySchemaPath,
    $memoryFixturePath,
    $memoryValidatorPath,
    $memoryPythonValidatorPath,
    $memoryTestPath,
    $collectorPath,
    $collectorTestPath
)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
        throw "Memory repository smoke input missing: $requiredFile"
    }
}

$powerShellFiles = @(
    $profileValidatorPath,
    $profileTestPath,
    $smokeTestPath,
    $profileValidationPath,
    $memoryValidatorPath,
    $memoryTestPath,
    $collectorPath,
    $collectorTestPath
)
foreach ($powerShellFile in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile(
        $powerShellFile,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    if (@($parseErrors).Count -gt 0) {
        $messages = @($parseErrors | ForEach-Object {
            "$(Split-Path -Leaf $powerShellFile):$($_.Extent.StartLineNumber): $($_.Message)"
        })
        throw ($messages -join [Environment]::NewLine)
    }
}

Get-Content -LiteralPath $memorySchemaPath -Raw | ConvertFrom-Json | Out-Null
Get-Content -LiteralPath $memoryFixturePath -Raw | ConvertFrom-Json | Out-Null

$result = & $profileValidatorPath -PassThru
if ([string]$result.RelativePath -cne 'profiles/Nxb.MemoryWorkingSet.wprp' -or
    [string]$result.Name -cne 'NxbMemoryWorkingSet' -or
    [int]$result.BufferSizeKiB -ne 1024 -or
    [int]$result.Buffers -ne 64 -or
    [int]$result.MaximumFileSizeMiB -ne 512 -or
    [string]$result.FileMode -cne 'Circular' -or
    [bool]$result.ReferenceSetEnabled -or
    @($result.Keywords).Count -ne 11 -or
    @($result.Stacks).Count -ne 9) {
    throw 'Memory profile repository smoke contract failed.'
}

foreach ($requiredKeyword in @(
    'AllFaults',
    'HardFaults',
    'MemoryInfo',
    'MemoryInfoWS',
    'ProcessCounter',
    'VAMap',
    'VirtualAllocation'
)) {
    if (@($result.Keywords) -notcontains $requiredKeyword) {
        throw "Memory profile required keyword missing: $requiredKeyword"
    }
}

& $memoryValidatorPath

$smokeRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ('nxb-memory-collector-smoke-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($smokeRoot) | Out-Null
$smokeOutput = Join-Path $smokeRoot 'memory-snapshot.json'
try {
    & $collectorPath `
        -ExperimentId 'repository-smoke' `
        -ProcessId $PID `
        -OutputPath $smokeOutput

    & $memoryValidatorPath -Path $smokeOutput -SchemaPath $memorySchemaPath
    $document = Get-Content -LiteralPath $smokeOutput -Raw | ConvertFrom-Json
    if ([int]$document.target.process_id -ne $PID -or
        [int]$document.summary.system_measurement_count -le 0 -or
        [int]$document.summary.process_measurement_count -le 0) {
        throw 'Native collector repository smoke produced incomplete identity or measurements.'
    }

    $collectorHash = (
        Get-FileHash -LiteralPath $collectorPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ([string]$document.processes[0].working_set_bytes.source.provenance_sha256 -cne
        $collectorHash) {
        throw 'Native collector repository smoke provenance mismatch.'
    }
}
finally {
    if (Test-Path -LiteralPath $smokeRoot) {
        Remove-Item -LiteralPath $smokeRoot -Recurse -Force
    }
}

Write-Host 'Memory profile, snapshot contract, and native collector repository smoke passed.'
