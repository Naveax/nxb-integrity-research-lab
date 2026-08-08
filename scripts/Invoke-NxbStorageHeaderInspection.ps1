[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateRange(4, 64)]
    [int]$FileSizeMiB = 16,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbStorageInspectionAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Write-NxbStorageInspectionJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$InputObject
    )

    [IO.File]::WriteAllText(
        $Path,
        ($InputObject | ConvertTo-Json -Depth 32),
        [Text.UTF8Encoding]::new($false)
    )
}

function Invoke-NxbOwnedStorageProbe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RootPath,

        [Parameter(Mandatory)]
        [ValidateRange(4, 64)]
        [int]$SizeMiB
    )

    $probeRoot = Join-Path $RootPath 'owned-storage-probe'
    if (Test-Path -LiteralPath $probeRoot) {
        throw "Owned storage probe directory already exists: $probeRoot"
    }
    [IO.Directory]::CreateDirectory($probeRoot) | Out-Null

    $probePath = Join-Path $probeRoot 'probe.bin'
    $bufferSize = 1024 * 1024
    $buffer = New-Object byte[] $bufferSize
    for ($index = 0; $index -lt $buffer.Length; $index += 4096) {
        $buffer[$index] = [byte](($index / 4096) % 251)
    }

    $targetBytes = [int64]$SizeMiB * 1024 * 1024
    $written = [int64]0
    $read = [int64]0
    $writeStarted = [DateTime]::UtcNow

    $writeStream = [IO.FileStream]::new(
        $probePath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::Write,
        [IO.FileShare]::None,
        $bufferSize,
        [IO.FileOptions]::SequentialScan
    )
    try {
        while ($written -lt $targetBytes) {
            $remaining = $targetBytes - $written
            $count = [int][Math]::Min([int64]$buffer.Length, $remaining)
            $writeStream.Write($buffer, 0, $count)
            $written += $count
        }
        $writeStream.Flush($true)
    }
    finally {
        $writeStream.Dispose()
    }
    $writeStopped = [DateTime]::UtcNow

    $readStarted = [DateTime]::UtcNow
    $readBuffer = New-Object byte[] $bufferSize
    $readStream = [IO.FileStream]::new(
        $probePath,
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::Read,
        $bufferSize,
        [IO.FileOptions]::SequentialScan
    )
    try {
        while ($true) {
            $count = $readStream.Read($readBuffer, 0, $readBuffer.Length)
            if ($count -le 0) {
                break
            }
            $read += $count
        }
    }
    finally {
        $readStream.Dispose()
    }
    $readStopped = [DateTime]::UtcNow

    $fileHash = (
        Get-FileHash -LiteralPath $probePath -Algorithm SHA256
    ).Hash.ToLowerInvariant()
    $fileLength = (Get-Item -LiteralPath $probePath).Length
    Remove-Item -LiteralPath $probePath -Force
    Remove-Item -LiteralPath $probeRoot -Force

    if ($written -ne $targetBytes -or $read -ne $targetBytes) {
        throw "Owned storage probe byte count mismatch: write=$written read=$read target=$targetBytes"
    }

    return [pscustomobject][ordered]@{
        requested_size_mib = $SizeMiB
        target_bytes = $targetBytes
        written_bytes = $written
        read_bytes = $read
        file_length_before_delete = [int64]$fileLength
        file_sha256_before_delete = $fileHash
        write_started_utc = $writeStarted.ToString('o')
        write_stopped_utc = $writeStopped.ToString('o')
        read_started_utc = $readStarted.ToString('o')
        read_stopped_utc = $readStopped.ToString('o')
        file_deleted = $true
        owned_path_only = $true
    }
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Storage header inspection requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Storage header inspection must run in PowerShell 7.'
}
if (-not (Test-NxbStorageInspectionAdministrator)) {
    throw 'Storage header inspection requires elevated PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$workingTree = @(
    & $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all
)
if ($LASTEXITCODE -ne 0 -or $workingTree.Count -gt 0) {
    throw 'Storage header inspection requires a clean exact-head worktree.'
}

$profileValidator = Join-Path $PSScriptRoot 'Test-NxbStorageWprProfile.ps1'
$headerParser = Join-Path $PSScriptRoot 'Get-NxbXperfStorageHeaderInventory.ps1'
foreach ($requiredPath in @($profileValidator, $headerParser, $PSCommandPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Storage header inspection input not found: $requiredPath"
    }
}

$wpr = Get-Command wpr.exe -ErrorAction Stop
$xperf = Get-Command xperf.exe -ErrorAction Stop
$profileMetadata = & $profileValidator -PassThru
$profileReference = "$($profileMetadata.Path)!NxbStorageIOQueue.Verbose"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-Path `
        (Join-Path $HOME 'Downloads') `
        "nxb-storage-header-inspection-$($currentHead.Substring(0, 12))-$stamp"
}
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputDirectory already exists: $outputFull"
}
[IO.Directory]::CreateDirectory($outputFull) | Out-Null

$etlPath = Join-Path $outputFull 'storage-header-inspection.etl'
$dumperPath = Join-Path $outputFull 'storage-xperf-dumper.txt'
$inventoryPath = Join-Path $outputFull 'storage-xperf-header-inventory.json'
$statusPath = Join-Path $outputFull 'wpr-status-pre-stop.json'
$workloadReceiptPath = Join-Path $outputFull 'storage-probe-receipt.json'
$captureReceiptPath = Join-Path $outputFull 'storage-header-inspection-receipt.json'
$reviewDirectory = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($reviewDirectory) | Out-Null

$traceStartedUtc = $null
$traceStoppedUtc = $null
$wprStarted = $false
$captureStatus = 'failed'
$failureMessage = $null
$probeResult = $null
$inventory = $null

try {
    $traceStartedUtc = [DateTime]::UtcNow
    $startOutput = @(
        & $wpr.Source -start $profileReference -filemode 2>&1
    )
    $startExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($startExit -ne 0) {
        throw (
            'WPR start failed. No existing WPR session was cancelled. ' +
            "exit=$startExit output=$($startOutput -join ' ')"
        )
    }
    $wprStarted = $true

    Start-Sleep -Milliseconds 250
    $probeResult = Invoke-NxbOwnedStorageProbe `
        -RootPath $outputFull `
        -SizeMiB $FileSizeMiB
    Write-NxbStorageInspectionJson `
        -Path $workloadReceiptPath `
        -InputObject $probeResult

    $statusOutput = @(& $wpr.Source -status collectors -details 2>&1)
    $statusExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    Write-NxbStorageInspectionJson -Path $statusPath -InputObject ([ordered]@{
        schema_version = 1
        captured_utc = [DateTime]::UtcNow.ToString('o')
        exit_code = $statusExit
        raw_output = @($statusOutput | ForEach-Object { [string]$_ })
        claims = [ordered]@{
            zero_loss_means_trace_complete = $false
        }
    })

    $stopOutput = @(& $wpr.Source -stop $etlPath 2>&1)
    $stopExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $wprStarted = $false
    $traceStoppedUtc = [DateTime]::UtcNow
    if ($stopExit -ne 0) {
        throw "WPR stop failed: exit=$stopExit output=$($stopOutput -join ' ')"
    }
    if (-not (Test-Path -LiteralPath $etlPath -PathType Leaf)) {
        throw 'WPR did not produce the expected storage ETL file.'
    }

    $dumperOutput = @(
        & $xperf.Source -i $etlPath -o $dumperPath -a dumper 2>&1
    )
    $dumperExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($dumperExit -ne 0) {
        throw "xperf dumper failed: exit=$dumperExit output=$($dumperOutput -join ' ')"
    }
    if (-not (Test-Path -LiteralPath $dumperPath -PathType Leaf)) {
        throw 'xperf dumper did not produce the expected text file.'
    }

    $inventory = & $headerParser `
        -InputPath $dumperPath `
        -OutputPath $inventoryPath `
        -PassThru
    if ([int]$inventory.header_count -le 0) {
        throw 'xperf dumper produced no header rows.'
    }

    $captureStatus = 'passed'
}
catch {
    $failureMessage = $_.Exception.Message
    if ($wprStarted) {
        try {
            & $wpr.Source -cancel 2>&1 | Out-Null
        }
        catch {
            Write-Warning "WPR cleanup cancel failed: $($_.Exception.Message)"
        }
        $wprStarted = $false
    }
}
finally {
    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        status = $captureStatus
        head_sha = $currentHead
        expected_head_sha = $ExpectedHead.ToLowerInvariant()
        trace_started_utc = if ($null -eq $traceStartedUtc) { $null } else { $traceStartedUtc.ToString('o') }
        trace_stopped_utc = if ($null -eq $traceStoppedUtc) { $null } else { $traceStoppedUtc.ToString('o') }
        profile = [ordered]@{
            path = [string]$profileMetadata.Path
            sha256 = [string]$profileMetadata.Sha256
            maximum_file_size_mib = [int]$profileMetadata.MaximumFileSizeMiB
            file_mode = [string]$profileMetadata.FileMode
        }
        workload = $probeResult
        evidence = [ordered]@{
            etl_path = if (Test-Path -LiteralPath $etlPath -PathType Leaf) { $etlPath } else { $null }
            etl_sha256 = if (Test-Path -LiteralPath $etlPath -PathType Leaf) { (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
            dumper_path = if (Test-Path -LiteralPath $dumperPath -PathType Leaf) { $dumperPath } else { $null }
            dumper_sha256 = if (Test-Path -LiteralPath $dumperPath -PathType Leaf) { (Get-FileHash -LiteralPath $dumperPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
            header_inventory_path = if (Test-Path -LiteralPath $inventoryPath -PathType Leaf) { $inventoryPath } else { $null }
            header_count = if ($null -eq $inventory) { $null } else { [int]$inventory.header_count }
            candidate_storage_header_count = if ($null -eq $inventory) { $null } else { [int]$inventory.candidate_storage_header_count }
        }
        failure = $failureMessage
        claims = [ordered]@{
            event_rows_reviewed = $false
            storage_event_mapping = 'not_claimed'
            queue_semantics = 'not_claimed'
            latency_semantics = 'not_claimed'
            throughput_semantics = 'not_claimed'
            iops_semantics = 'not_claimed'
            trace_completeness = 'not_claimed'
            raw_etl_in_review = $false
            full_dumper_in_review = $false
        }
    }
    Write-NxbStorageInspectionJson -Path $captureReceiptPath -InputObject $receipt

    foreach ($reviewPath in @(
        $captureReceiptPath,
        $workloadReceiptPath,
        $statusPath,
        $inventoryPath
    )) {
        if (Test-Path -LiteralPath $reviewPath -PathType Leaf) {
            Copy-Item -LiteralPath $reviewPath -Destination $reviewDirectory -Force
        }
    }
}

Write-Host "Storage header inspection receipt: $captureReceiptPath"
Write-Host "Local capture directory: $outputFull"
Write-Host 'Raw ETL and full xperf dumper remain local and are excluded from review evidence.'

$finalReceipt = Get-Content -LiteralPath $captureReceiptPath -Raw | ConvertFrom-Json
if ([string]$finalReceipt.status -cne 'passed') {
    throw "Storage header inspection failed: $($finalReceipt.failure)"
}

Write-Host 'Bounded storage header inspection completed.'
if ($PassThru) {
    return $finalReceipt
}
