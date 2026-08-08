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
$etlSchemaPath = Join-Path $repositoryRoot 'schemas\memory-etl-summary.schema.json'
$etlFixturePath = Join-Path $repositoryRoot 'tests\fixtures\memory-etl-summary.valid.json'
$etlExportFixturePath = Join-Path $repositoryRoot 'tests\fixtures\memory-event-export.valid.csv'
$etlValidatorPath = Join-Path $PSScriptRoot 'Test-MemoryEtlSummary.ps1'
$etlPythonValidatorPath = Join-Path $repositoryRoot 'tools\validate_memory_etl_summary.py'
$etlAdapterPath = Join-Path $PSScriptRoot 'ConvertFrom-NxbMemoryEventExport.ps1'
$etlContractTestPath = Join-Path $repositoryRoot 'tests\MemoryEtlSummary.Tests.ps1'
$etlAdapterTestPath = Join-Path $repositoryRoot 'tests\MemoryEventExportAdapter.Tests.ps1'

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
    $collectorTestPath,
    $etlSchemaPath,
    $etlFixturePath,
    $etlExportFixturePath,
    $etlValidatorPath,
    $etlPythonValidatorPath,
    $etlAdapterPath,
    $etlContractTestPath,
    $etlAdapterTestPath
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
    $collectorTestPath,
    $etlValidatorPath,
    $etlAdapterPath,
    $etlContractTestPath,
    $etlAdapterTestPath
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
Get-Content -LiteralPath $etlSchemaPath -Raw | ConvertFrom-Json | Out-Null
Get-Content -LiteralPath $etlFixturePath -Raw | ConvertFrom-Json | Out-Null

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
& $etlValidatorPath

$smokeRoot = Join-Path `
    ([IO.Path]::GetTempPath()) `
    ('nxb-memory-repository-smoke-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($smokeRoot) | Out-Null
$memoryOutput = Join-Path $smokeRoot 'memory-snapshot.json'
$etlOutput = Join-Path $smokeRoot 'memory-etl-summary.json'
try {
    & $collectorPath `
        -ExperimentId 'repository-smoke' `
        -ProcessId $PID `
        -OutputPath $memoryOutput

    & $memoryValidatorPath -Path $memoryOutput -SchemaPath $memorySchemaPath
    $memoryDocument = Get-Content -LiteralPath $memoryOutput -Raw |
        ConvertFrom-Json
    if ([int]$memoryDocument.target.process_id -ne $PID -or
        [int]$memoryDocument.summary.system_measurement_count -le 0 -or
        [int]$memoryDocument.summary.process_measurement_count -le 0) {
        throw 'Native collector repository smoke produced incomplete identity or measurements.'
    }

    $collectorHash = (
        Get-FileHash -LiteralPath $collectorPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ([string]$memoryDocument.processes[0].working_set_bytes.source.provenance_sha256 -cne
        $collectorHash) {
        throw 'Native collector repository smoke provenance mismatch.'
    }

    & $etlAdapterPath `
        -ExperimentId 'repository-etl-smoke' `
        -InputPath $etlExportFixturePath `
        -OutputPath $etlOutput `
        -MachineId 'repository-smoke-machine' `
        -BootId ('1' * 64) `
        -TraceSha256 ('2' * 64) `
        -ProfileSha256 ('3' * 64) `
        -TraceStartUtc ([datetime]'2026-08-06T22:00:00Z') `
        -TraceEndUtc ([datetime]'2026-08-06T22:00:10Z') `
        -TargetProcessId 4242 `
        -TargetProcessStartUtc ([datetime]'2026-08-06T21:59:00Z') `
        -TargetImageSha256 ('4' * 64) `
        -CoveredEventType @(
            'hard_fault',
            'demand_zero_fault',
            'copy_on_write_fault',
            'transition_fault',
            'guard_page_fault',
            'virtual_allocation',
            'virtual_free',
            'mapped_section_create',
            'mapped_section_delete'
        ) `
        -TraceLoss none `
        -CircularOverwrite none

    & $etlValidatorPath -Path $etlOutput -SchemaPath $etlSchemaPath
    $etlDocument = Get-Content -LiteralPath $etlOutput -Raw |
        ConvertFrom-Json
    if ([int]$etlDocument.events.hard_fault.count -ne 3 -or
        [int]$etlDocument.events.soft_fault_total.count -ne 9 -or
        [int]$etlDocument.summary.measured_event_class_count -ne 10 -or
        [string]$etlDocument.summary.evidence_completeness -cne 'complete') {
        throw 'Memory ETL adapter repository smoke produced incorrect aggregates.'
    }

    $adapterHash = (
        Get-FileHash -LiteralPath $etlAdapterPath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    if ([string]$etlDocument.adapter_sha256 -cne $adapterHash -or
        [string]$etlDocument.events.hard_fault.source.provenance_sha256 -cne
        $adapterHash) {
        throw 'Memory ETL adapter repository smoke provenance mismatch.'
    }
}
finally {
    if (Test-Path -LiteralPath $smokeRoot) {
        Remove-Item -LiteralPath $smokeRoot -Recurse -Force
    }
}

Write-Host 'Memory profile, snapshot, collector, and ETL adapter repository smoke passed.'
