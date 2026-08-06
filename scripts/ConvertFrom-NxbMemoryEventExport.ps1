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

function ConvertTo-NxbMemoryEtlSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProvenanceSha256
    )

    return [ordered]@{
        collector = 'ConvertFrom-NxbMemoryEventExport.ps1'
        kind = 'etw_summary'
        provenance_sha256 = $ProvenanceSha256
    }
}

function ConvertTo-NxbMemoryEtlAggregate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$Count,

        [Parameter()]
        [Nullable[long]]$Bytes,

        [Parameter(Mandatory)]
        [long]$UnattributedCount,

        [Parameter(Mandatory)]
        [ValidateSet('complete', 'partial', 'none')]
        [string]$Attribution,

        [Parameter(Mandatory)]
        [string]$ProvenanceSha256
    )

    return [ordered]@{
        status = 'measured'
        count = $Count
        bytes = if ($null -eq $Bytes) { $null } else { [long]$Bytes }
        unattributed_count = $UnattributedCount
        attribution = $Attribution
        source = ConvertTo-NxbMemoryEtlSource `
            -ProvenanceSha256 $ProvenanceSha256
        reason = $null
    }
}

function ConvertTo-NxbMemoryEtlProcessCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [long]$Count,

        [Parameter()]
        [Nullable[long]]$Bytes,

        [Parameter(Mandatory)]
        [string]$ProvenanceSha256
    )

    return [ordered]@{
        status = 'measured'
        count = $Count
        bytes = if ($null -eq $Bytes) { $null } else { [long]$Bytes }
        source = ConvertTo-NxbMemoryEtlSource `
            -ProvenanceSha256 $ProvenanceSha256
        reason = $null
    }
}

function ConvertTo-NxbMemoryEtlUnmeasuredAggregate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Reason
    )

    return [ordered]@{
        status = 'not_assessed'
        count = $null
        bytes = $null
        unattributed_count = $null
        attribution = 'none'
        source = $null
        reason = $Reason
    }
}

function ConvertTo-NxbMemoryEtlUnmeasuredProcessCount {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Reason
    )

    return [ordered]@{
        status = 'not_assessed'
        count = $null
        bytes = $null
        source = $null
        reason = $Reason
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Memory event export conversion is supported only on Windows.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$validatorPath = Join-Path $PSScriptRoot 'Test-MemoryEtlSummary.ps1'
$schemaPath = Join-Path `
    $repositoryRoot `
    'schemas\memory-etl-summary.schema.json'
foreach ($requiredPath in @($validatorPath, $schemaPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Memory ETL adapter input not found: $requiredPath"
    }
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

$traceStart = $TraceStartUtc.ToUniversalTime()
$traceEnd = $TraceEndUtc.ToUniversalTime()
$targetStart = $TargetProcessStartUtc.ToUniversalTime()
if ($traceStart -gt $traceEnd) {
    throw 'TraceStartUtc cannot be after TraceEndUtc.'
}
if ($targetStart -gt $traceEnd) {
    throw 'TargetProcessStartUtc cannot be after TraceEndUtc.'
}

$expectedHeader = 'event_type,timestamp_us,process_id,thread_id,size_bytes'
$header = Get-Content -LiteralPath $inputFull -TotalCount 1
if ([string]$header -cne $expectedHeader) {
    throw (
        "Memory event export header mismatch. Expected: $expectedHeader"
    )
}

$rows = @(Import-Csv -LiteralPath $inputFull)
if ($rows.Count -gt $MaxEventCount) {
    throw (
        "Memory event export exceeds MaxEventCount: " +
        "$($rows.Count) > $MaxEventCount"
    )
}

$baseEventTypes = @(
    'hard_fault',
    'demand_zero_fault',
    'copy_on_write_fault',
    'transition_fault',
    'guard_page_fault',
    'virtual_allocation',
    'virtual_free',
    'mapped_section_create',
    'mapped_section_delete'
)
$softComponents = @(
    'demand_zero_fault',
    'copy_on_write_fault',
    'transition_fault',
    'guard_page_fault'
)
$allEventTypes = @(
    'hard_fault',
    'demand_zero_fault',
    'copy_on_write_fault',
    'transition_fault',
    'guard_page_fault',
    'soft_fault_total',
    'virtual_allocation',
    'virtual_free',
    'mapped_section_create',
    'mapped_section_delete'
)
$byteEventTypes = @(
    'hard_fault',
    'virtual_allocation',
    'virtual_free'
)
$coverage = @{}
foreach ($eventType in $CoveredEventType) {
    $coverage[$eventType] = $true
}

$durationMicroseconds = [decimal](
    ($traceEnd - $traceStart).TotalMilliseconds * 1000
)
$normalizedRows = [Collections.Generic.List[object]]::new()
foreach ($row in $rows) {
    $eventType = [string]$row.event_type
    if ($baseEventTypes -cnotcontains $eventType) {
        throw "Unsupported memory event_type: $eventType"
    }
    if (-not $coverage.ContainsKey($eventType)) {
        throw "Event type is not declared in CoveredEventType: $eventType"
    }

    $timestampUs = 0L
    if (-not [long]::TryParse(
        [string]$row.timestamp_us,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$timestampUs
    ) -or $timestampUs -lt 0) {
        throw "Invalid timestamp_us: $($row.timestamp_us)"
    }
    if ([decimal]$timestampUs -gt $durationMicroseconds) {
        throw "timestamp_us exceeds the declared trace range: $timestampUs"
    }

    $processId = 0
    if (-not [int]::TryParse(
        [string]$row.process_id,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$processId
    ) -or $processId -lt 0) {
        throw "Invalid process_id: $($row.process_id)"
    }

    $threadId = 0
    if (-not [int]::TryParse(
        [string]$row.thread_id,
        [Globalization.NumberStyles]::None,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$threadId
    ) -or $threadId -lt 0) {
        throw "Invalid thread_id: $($row.thread_id)"
    }

    $sizeBytes = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$row.size_bytes)) {
        $parsedSize = 0L
        if (-not [long]::TryParse(
            [string]$row.size_bytes,
            [Globalization.NumberStyles]::None,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$parsedSize
        ) -or $parsedSize -lt 0) {
            throw "Invalid size_bytes: $($row.size_bytes)"
        }
        $sizeBytes = [long]$parsedSize
    }

    $normalizedRows.Add([pscustomobject]@{
        event_type = $eventType
        timestamp_us = $timestampUs
        process_id = $processId
        thread_id = $threadId
        size_bytes = $sizeBytes
    })
}

$adapterHash = (
    Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256
).Hash.ToLowerInvariant()
$eventExportHash = (
    Get-FileHash -LiteralPath $inputFull -Algorithm SHA256
).Hash.ToLowerInvariant()

$processIds = @(
    @($normalizedRows | Where-Object process_id -gt 0 |
        Select-Object -ExpandProperty process_id -Unique) +
    @($TargetProcessId)
) | Sort-Object -Unique

$processes = [Collections.Generic.List[object]]::new()
foreach ($processId in $processIds) {
    $isTarget = [int]$processId -eq $TargetProcessId
    $processEvents = [ordered]@{}

    foreach ($eventType in $baseEventTypes) {
        if ($coverage.ContainsKey($eventType)) {
            $matches = @(
                $normalizedRows |
                    Where-Object {
                        $_.event_type -ceq $eventType -and
                        [int]$_.process_id -eq [int]$processId
                    }
            )
            $bytes = $null
            if ($byteEventTypes -ccontains $eventType) {
                $bytes = [long](
                    @($matches | Where-Object size_bytes -ne $null |
                        Measure-Object -Property size_bytes -Sum).Sum
                )
            }
            $processEvents[$eventType] = ConvertTo-NxbMemoryEtlProcessCount `
                -Count $matches.Count `
                -Bytes $bytes `
                -ProvenanceSha256 $adapterHash
        }
        else {
            $processEvents[$eventType] =
                ConvertTo-NxbMemoryEtlUnmeasuredProcessCount `
                    -Reason "Event class was not declared in CoveredEventType."
        }
    }

    if (@($softComponents | Where-Object {
        -not $coverage.ContainsKey($_)
    }).Count -eq 0) {
        $softCount = [long]0
        foreach ($component in $softComponents) {
            $softCount += [long]$processEvents[$component].count
        }
        $processEvents['soft_fault_total'] =
            ConvertTo-NxbMemoryEtlProcessCount `
                -Count $softCount `
                -Bytes $null `
                -ProvenanceSha256 $adapterHash
    }
    else {
        $processEvents['soft_fault_total'] =
            ConvertTo-NxbMemoryEtlUnmeasuredProcessCount `
                -Reason 'Soft-fault total requires coverage of all component classes.'
    }

    $orderedEvents = [ordered]@{}
    foreach ($eventType in $allEventTypes) {
        $orderedEvents[$eventType] = $processEvents[$eventType]
    }

    $processes.Add([ordered]@{
        process_id = [int]$processId
        process_start_utc = if ($isTarget) {
            $targetStart.ToString('o')
        }
        else {
            $null
        }
        image_sha256 = if ($isTarget) {
            $TargetImageSha256
        }
        else {
            $null
        }
        identity_status = if ($isTarget) { 'complete' } else { 'partial' }
        is_target = $isTarget
        events = $orderedEvents
    })
}

$events = [ordered]@{}
foreach ($eventType in $baseEventTypes) {
    if ($coverage.ContainsKey($eventType)) {
        $matches = @(
            $normalizedRows |
                Where-Object event_type -CEQ $eventType
        )
        $unattributed = @(
            $matches |
                Where-Object process_id -eq 0
        ).Count
        $bytes = $null
        if ($byteEventTypes -ccontains $eventType) {
            $bytes = [long](
                @($matches | Where-Object size_bytes -ne $null |
                    Measure-Object -Property size_bytes -Sum).Sum
            )
        }
        $events[$eventType] = ConvertTo-NxbMemoryEtlAggregate `
            -Count $matches.Count `
            -Bytes $bytes `
            -UnattributedCount $unattributed `
            -Attribution $(if ($unattributed -eq 0) {
                'complete'
            }
            elseif ($unattributed -eq $matches.Count) {
                'none'
            }
            else {
                'partial'
            }) `
            -ProvenanceSha256 $adapterHash
    }
    else {
        $events[$eventType] =
            ConvertTo-NxbMemoryEtlUnmeasuredAggregate `
                -Reason "Event class was not declared in CoveredEventType."
    }
}

if (@($softComponents | Where-Object {
    -not $coverage.ContainsKey($_)
}).Count -eq 0) {
    $softCount = [long]0
    $softUnattributed = [long]0
    foreach ($component in $softComponents) {
        $softCount += [long]$events[$component].count
        $softUnattributed += [long]$events[$component].unattributed_count
    }
    $events['soft_fault_total'] = ConvertTo-NxbMemoryEtlAggregate `
        -Count $softCount `
        -Bytes $null `
        -UnattributedCount $softUnattributed `
        -Attribution $(if ($softUnattributed -eq 0) {
            'complete'
        }
        elseif ($softUnattributed -eq $softCount) {
            'none'
        }
        else {
            'partial'
        }) `
        -ProvenanceSha256 $adapterHash
}
else {
    $events['soft_fault_total'] =
        ConvertTo-NxbMemoryEtlUnmeasuredAggregate `
            -Reason 'Soft-fault total requires coverage of all component classes.'
}

$orderedAggregates = [ordered]@{}
foreach ($eventType in $allEventTypes) {
    $orderedAggregates[$eventType] = $events[$eventType]
}

$measuredEventClassCount = @(
    $orderedAggregates.GetEnumerator() |
        Where-Object { $_.Value.status -ceq 'measured' }
).Count
$failedEventClassCount = @(
    $orderedAggregates.GetEnumerator() |
        Where-Object { $_.Value.status -ceq 'failed' }
).Count
$parserCompleteness = if ($coverage.Count -eq $baseEventTypes.Count) {
    'complete'
}
else {
    'partial'
}
$evidenceCompleteness = if ($failedEventClassCount -gt 0) {
    'failed'
}
elseif (
    $measuredEventClassCount -eq $allEventTypes.Count -and
    $TraceLoss -ceq 'none' -and
    $CircularOverwrite -ceq 'none' -and
    $parserCompleteness -ceq 'complete'
) {
    'complete'
}
elseif ($measuredEventClassCount -gt 0) {
    'partial'
}
else {
    'unavailable'
}

$document = [ordered]@{
    schema_version = 1
    summary_id = 'memory-etl-summary-' + [guid]::NewGuid().ToString('N')
    experiment_id = $ExperimentId
    experiment_relative_path = "experiments/$ExperimentId"
    machine_id = $MachineId
    boot_id = $BootId
    trace_sha256 = $TraceSha256
    profile_sha256 = $ProfileSha256
    event_export_sha256 = $eventExportHash
    adapter_sha256 = $adapterHash
    source_format = 'nxb_memory_event_export_v1'
    trace_start_utc = $traceStart.ToString('o')
    trace_end_utc = $traceEnd.ToString('o')
    target = [ordered]@{
        process_id = $TargetProcessId
        process_start_utc = $targetStart.ToString('o')
        image_sha256 = $TargetImageSha256
    }
    quality = [ordered]@{
        trace_loss = $TraceLoss
        circular_overwrite = $CircularOverwrite
        parser_completeness = $parserCompleteness
        unsupported_event_types = @()
    }
    events = $orderedAggregates
    processes = @($processes)
    summary = [ordered]@{
        process_count = $processes.Count
        measured_event_class_count = $measuredEventClassCount
        failed_event_class_count = $failedEventClassCount
        evidence_completeness = $evidenceCompleteness
    }
    claims = [ordered]@{
        hard_fault_absence = $false
        soft_fault_absence = $false
        virtual_memory_balance = $false
        trace_completeness = 'not_claimed'
    }
}

$temporaryPath = Join-Path `
    $outputParent `
    ('.' + [IO.Path]::GetFileName($outputFull) + '.' +
        [guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText(
        $temporaryPath,
        ($document | ConvertTo-Json -Depth 64),
        [Text.UTF8Encoding]::new($false)
    )
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
