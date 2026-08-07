[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [string]$OutputDirectory,

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
    [ValidateRange(1, 5000000)]
    [int]$MaxEventCount = 1000000,

    [Parameter()]
    [switch]$CancelExistingSession,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbMemoryCaptureAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Get-NxbMemoryCaptureTextSha256 {
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

function Get-NxbMemoryCaptureLostEventState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Lines,

        [Parameter(Mandatory)]
        [int]$ExitCode
    )

    if ($ExitCode -ne 0) {
        return [pscustomobject][ordered]@{
            status = 'unknown'
            value = $null
            reason = "wpr -status failed with exit code $ExitCode."
        }
    }

    $values = [Collections.Generic.List[uint64]]::new()
    foreach ($line in $Lines) {
        $match = [regex]::Match(
            [string]$line,
            '(?i)^\s*Events\s+Lost\s*:\s*([0-9]+)\s*$'
        )
        if ($match.Success) {
            $values.Add([uint64]$match.Groups[1].Value)
        }
    }
    if ($values.Count -eq 0) {
        foreach ($line in $Lines) {
            $match = [regex]::Match(
                [string]$line,
                '(?i)^\s*Dropped\s+event\s*:\s*([0-9]+)\s*$'
            )
            if ($match.Success) {
                $values.Add([uint64]$match.Groups[1].Value)
                break
            }
        }
    }
    if ($values.Count -eq 0) {
        return [pscustomobject][ordered]@{
            status = 'unknown'
            value = $null
            reason = 'No Events Lost or Dropped event field was exposed by WPR status.'
        }
    }

    $total = [uint64]0
    foreach ($value in $values) {
        $total += $value
    }
    return [pscustomobject][ordered]@{
        status = if ($total -eq 0) { 'none' } else { 'present' }
        value = $total
        reason = $null
    }
}

function Write-NxbMemoryCaptureJson {
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

if ($env:OS -cne 'Windows_NT') {
    throw 'Real memory WPR capture requires Windows.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Real memory WPR capture must run in PowerShell 7.'
}
if (-not (Test-NxbMemoryCaptureAdministrator)) {
    throw 'Real memory WPR capture requires elevated PowerShell 7.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or
    $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$workingTree = @(
    & $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all
)
if ($LASTEXITCODE -ne 0 -or $workingTree.Count -gt 0) {
    throw 'Real memory WPR capture requires a clean exact-head worktree.'
}

$profileValidator = Join-Path $PSScriptRoot 'Test-NxbMemoryWprProfile.ps1'
$workloadPath = Join-Path $PSScriptRoot 'Invoke-NxbMemoryProbeWorkload.ps1'
$bridgePath = Join-Path $PSScriptRoot 'ConvertFrom-NxbXperfMemoryDumper.ps1'
$adapterPath = Join-Path $PSScriptRoot 'ConvertFrom-NxbMemoryEventExport.ps1'
foreach ($requiredPath in @(
    $profileValidator,
    $workloadPath,
    $bridgePath,
    $adapterPath,
    $PSCommandPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Real memory capture input not found: $requiredPath"
    }
}

$wpr = Get-Command wpr.exe -ErrorAction Stop
$xperf = Get-Command xperf.exe -ErrorAction Stop
$pwsh = Get-Command pwsh.exe -ErrorAction Stop
$profileMetadata = & $profileValidator -PassThru
$profileReference = "$($profileMetadata.Path)!NxbMemoryWorkingSet.Verbose"

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $OutputDirectory = Join-Path `
        (Join-Path $HOME 'Downloads') `
        "nxb-memory-real-capture-$($currentHead.Substring(0, 12))-$stamp"
}
$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputDirectory already exists: $outputFull"
}
[IO.Directory]::CreateDirectory($outputFull) | Out-Null

$etlPath = Join-Path $outputFull 'memory-real.etl'
$dumperPath = Join-Path $outputFull 'memory-xperf-dumper.txt'
$bridgeDirectory = Join-Path $outputFull 'bridge'
$summaryPath = Join-Path $outputFull 'memory-etl-summary.json'
$workloadReceiptPath = Join-Path $outputFull 'workload-receipt.json'
$statusPath = Join-Path $outputFull 'wpr-status-pre-stop.json'
$captureReceiptPath = Join-Path $outputFull 'memory-real-capture-receipt.json'
$reviewDirectory = Join-Path $outputFull 'review'
[IO.Directory]::CreateDirectory($reviewDirectory) | Out-Null

$machineId = if ([string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
    [Environment]::MachineName
}
else {
    $env:COMPUTERNAME
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
$bootId = Get-NxbMemoryCaptureTextSha256 -Value (
    "machine=$machineId`nlast_boot_utc=$($lastBootUtc.ToString('o'))"
)

$startedUtc = [DateTime]::UtcNow
$traceStartedUtc = $null
$traceStoppedUtc = $null
$targetProcessId = $null
$targetProcessStartUtc = $null
$targetImageSha256 = $null
$wprStarted = $false
$captureStatus = 'failed'
$failureMessage = $null
$traceLoss = 'unknown'
$circularOverwrite = 'unknown'
$coveredEventTypes = @()
$bridgeManifestPath = $null
$normalizedCsvPath = $null

try {
    if ($CancelExistingSession) {
        $cancelOutput = @(& $wpr.Source -cancel 2>&1)
        $cancelExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        $noRunningTraceProfilesExitCode = -984076288
        if ($cancelExit -ne 0 -and $cancelExit -ne $noRunningTraceProfilesExitCode) {
            throw "Existing WPR session could not be cancelled: exit=$cancelExit output=$($cancelOutput -join ' ')"
        }
    }

    $traceStartedUtc = [DateTime]::UtcNow
    $startOutput = @(
        & $wpr.Source -start $profileReference -filemode 2>&1
    )
    $startExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($startExit -ne 0) {
        throw "WPR start failed: exit=$startExit output=$($startOutput -join ' ')"
    }
    $wprStarted = $true

    Start-Sleep -Milliseconds 250

    $workloadArguments = @(
        '-NoLogo',
        '-NoProfile',
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
        $workloadReceiptPath
    )
    $targetProcess = Start-Process `
        -FilePath $pwsh.Source `
        -ArgumentList $workloadArguments `
        -PassThru `
        -WindowStyle Hidden
    try {
        $targetProcessId = [int]$targetProcess.Id
        $targetProcessStartUtc = $targetProcess.StartTime.ToUniversalTime()
        $targetImageSha256 = (
            Get-FileHash -LiteralPath $pwsh.Source -Algorithm SHA256
        ).Hash.ToLowerInvariant()

        if (-not $targetProcess.WaitForExit(15000)) {
            try {
                $targetProcess.Kill()
            }
            catch {
                Write-Warning (
                    'Bounded memory probe could not be terminated after ' +
                    "timeout: $($_.Exception.Message)"
                )
            }
            throw 'Bounded memory probe exceeded the 15 second safety timeout.'
        }
        if ($targetProcess.ExitCode -ne 0) {
            throw "Bounded memory probe failed: exit=$($targetProcess.ExitCode)"
        }
    }
    finally {
        $targetProcess.Dispose()
    }

    if (-not (Test-Path -LiteralPath $workloadReceiptPath -PathType Leaf)) {
        throw 'Bounded memory probe receipt was not written.'
    }

    $statusOutput = @(& $wpr.Source -status collectors -details 2>&1)
    $statusExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $statusLines = @($statusOutput | ForEach-Object { [string]$_ })
    $lostEventState = Get-NxbMemoryCaptureLostEventState `
        -Lines $statusLines `
        -ExitCode $statusExit
    $traceLoss = [string]$lostEventState.status
    Write-NxbMemoryCaptureJson -Path $statusPath -InputObject ([ordered]@{
        schema_version = 1
        captured_utc = [DateTime]::UtcNow.ToString('o')
        exit_code = $statusExit
        raw_output = $statusLines
        events_lost = $lostEventState
    })

    $stopOutput = @(& $wpr.Source -stop $etlPath 2>&1)
    $stopExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    $wprStarted = $false
    $traceStoppedUtc = [DateTime]::UtcNow
    if ($stopExit -ne 0) {
        throw "WPR stop failed: exit=$stopExit output=$($stopOutput -join ' ')"
    }
    if (-not (Test-Path -LiteralPath $etlPath -PathType Leaf)) {
        throw 'WPR did not produce the expected ETL file.'
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

    $bridgeResult = & $bridgePath `
        -InputPath $dumperPath `
        -OutputDirectory $bridgeDirectory `
        -MaxEventCount $MaxEventCount `
        -PassThru
    $coveredEventTypes = [string[]]@($bridgeResult.covered_event_types)
    $bridgeManifestPath = [string]$bridgeResult.manifest_path
    $normalizedCsvPath = [string]$bridgeResult.event_export_path
    if ($coveredEventTypes.Count -eq 0) {
        throw 'Real xperf dumper produced no normalized covered memory event classes.'
    }

    $experimentId = 'memory-real-' + $currentHead.Substring(0, 12)
    & $adapterPath `
        -ExperimentId $experimentId `
        -InputPath $normalizedCsvPath `
        -OutputPath $summaryPath `
        -MachineId $machineId `
        -BootId $bootId `
        -TraceSha256 ((Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant()) `
        -ProfileSha256 ([string]$profileMetadata.Sha256) `
        -TraceStartUtc $traceStartedUtc `
        -TraceEndUtc $traceStoppedUtc `
        -TargetProcessId $targetProcessId `
        -TargetProcessStartUtc $targetProcessStartUtc `
        -TargetImageSha256 $targetImageSha256 `
        -CoveredEventType $coveredEventTypes `
        -TraceLoss $traceLoss `
        -CircularOverwrite $circularOverwrite `
        -MaxEventCount $MaxEventCount

    if (-not (Test-Path -LiteralPath $summaryPath -PathType Leaf)) {
        throw 'Downstream real memory ETL summary was not written.'
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
    $stoppedUtc = [DateTime]::UtcNow
    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        status = $captureStatus
        head_sha = $currentHead
        expected_head_sha = $ExpectedHead.ToLowerInvariant()
        started_utc = $startedUtc.ToString('o')
        stopped_utc = $stoppedUtc.ToString('o')
        trace_started_utc = if ($null -eq $traceStartedUtc) { $null } else { $traceStartedUtc.ToString('o') }
        trace_stopped_utc = if ($null -eq $traceStoppedUtc) { $null } else { $traceStoppedUtc.ToString('o') }
        machine_id = $machineId
        boot_id = $bootId
        profile = [ordered]@{
            path = [string]$profileMetadata.Path
            sha256 = [string]$profileMetadata.Sha256
            maximum_file_size_mib = [int]$profileMetadata.MaximumFileSizeMiB
            file_mode = [string]$profileMetadata.FileMode
        }
        workload = [ordered]@{
            process_id = $targetProcessId
            process_start_utc = if ($null -eq $targetProcessStartUtc) { $null } else { $targetProcessStartUtc.ToString('o') }
            image_sha256 = $targetImageSha256
            private_memory_mib = $PrivateMemoryMiB
            mapped_file_mib = $MappedFileMiB
            hold_milliseconds = $HoldMilliseconds
            receipt_path = if (Test-Path -LiteralPath $workloadReceiptPath -PathType Leaf) { $workloadReceiptPath } else { $null }
        }
        trace_quality = [ordered]@{
            trace_loss = $traceLoss
            circular_overwrite = $circularOverwrite
            trace_completeness = 'not_claimed'
        }
        evidence = [ordered]@{
            etl_path = if (Test-Path -LiteralPath $etlPath -PathType Leaf) { $etlPath } else { $null }
            etl_sha256 = if (Test-Path -LiteralPath $etlPath -PathType Leaf) { (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
            dumper_path = if (Test-Path -LiteralPath $dumperPath -PathType Leaf) { $dumperPath } else { $null }
            dumper_sha256 = if (Test-Path -LiteralPath $dumperPath -PathType Leaf) { (Get-FileHash -LiteralPath $dumperPath -Algorithm SHA256).Hash.ToLowerInvariant() } else { $null }
            bridge_manifest_path = $bridgeManifestPath
            normalized_csv_path = $normalizedCsvPath
            summary_path = if (Test-Path -LiteralPath $summaryPath -PathType Leaf) { $summaryPath } else { $null }
            covered_event_types = @($coveredEventTypes)
        }
        failure = $failureMessage
        claims = [ordered]@{
            hard_faults_guaranteed = $false
            cache_state_controlled = $false
            circular_overwrite_absence = $false
            trace_completeness = 'not_claimed'
            working_set_equals_total_memory_cost = $false
        }
    }
    Write-NxbMemoryCaptureJson -Path $captureReceiptPath -InputObject $receipt

    foreach ($reviewPath in @(
        $captureReceiptPath,
        $workloadReceiptPath,
        $statusPath,
        $bridgeManifestPath,
        $normalizedCsvPath,
        $summaryPath
    )) {
        if (-not [string]::IsNullOrWhiteSpace([string]$reviewPath) -and
            (Test-Path -LiteralPath ([string]$reviewPath) -PathType Leaf)) {
            Copy-Item -LiteralPath ([string]$reviewPath) -Destination $reviewDirectory -Force
        }
    }

    $reviewZip = Join-Path `
        (Join-Path $HOME 'Downloads') `
        ('nxb-memory-real-capture-' + $currentHead.Substring(0, 12) + '-' +
            [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-review.zip')
    if ((Get-ChildItem -LiteralPath $reviewDirectory -File).Count -gt 0) {
        Compress-Archive `
            -Path (Join-Path $reviewDirectory '*') `
            -DestinationPath $reviewZip `
            -Force
    }
}

Write-Host "Memory real capture receipt: $captureReceiptPath"
Write-Host "Local capture directory: $outputFull"
Write-Host 'Raw ETL and full dumper text remain local and are not included in the review ZIP.'

$finalReceipt = Get-Content -LiteralPath $captureReceiptPath -Raw | ConvertFrom-Json
if ([string]$finalReceipt.status -cne 'passed') {
    throw "Real memory capture failed: $($finalReceipt.failure)"
}

Write-Host 'Real bounded memory WPR capture completed.'
if ($PassThru) {
    return $finalReceipt
}
