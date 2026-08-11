[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NxbControllerTargetTransport.Common.ps1')

function Write-NxbTransportExperimentJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText($fullPath,(($InputObject | ConvertTo-Json -Depth 48) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

function Invoke-NxbTransportTargetProcessStart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$TargetScript,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$StateDirectory,
        [Parameter(Mandatory)][string]$ReadyPath,
        [Parameter(Mandatory)][string]$ResultPath,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$KeyHex
    )

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PowerShellPath
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    foreach ($argument in @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$TargetScript,
        '-ConfigPath',$ConfigPath,'-StateDirectory',$StateDirectory,'-ReadyPath',$ReadyPath,
        '-ResultPath',$ResultPath,'-SessionId',$SessionId,'-KeyHex',$KeyHex
    )) {
        [void]$startInfo.ArgumentList.Add([string]$argument)
    }
    $process = [Diagnostics.Process]::Start($startInfo)
    if ($null -eq $process) { throw 'Unable to start controller/target transport target process.' }
    return $process
}

function Wait-NxbTransportReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Diagnostics.Process]$Process,
        [Parameter(Mandatory)][string]$ReadyPath,
        [Parameter()][ValidateRange(1,30)][int]$TimeoutSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        if (Test-Path -LiteralPath $ReadyPath -PathType Leaf) {
            return (Get-Content -LiteralPath $ReadyPath -Raw | ConvertFrom-Json)
        }
        if ($Process.HasExited) { throw ('Transport target exited before ready: exit={0}' -f $Process.ExitCode) }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Timed out waiting for transport target readiness.'
}

function Connect-NxbTransportExperimentClient {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateRange(1,65535)][int]$Port)

    $client = [Net.Sockets.TcpClient]::new()
    $client.NoDelay = $true
    $client.Connect([Net.IPAddress]::Loopback,$Port)
    $stream = $client.GetStream()
    $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$false,4096,$true)
    $writer = [IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false),4096,$true)
    $writer.NewLine = "`n"
    $writer.AutoFlush = $true
    return [pscustomobject][ordered]@{ client=$client; stream=$stream; reader=$reader; writer=$writer }
}

function Close-NxbTransportExperimentClient {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Connection)

    if ($null -eq $Connection) { return }
    foreach ($name in @('reader','writer','stream','client')) {
        $property = $Connection.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) { continue }
        try { $property.Value.Dispose() } catch { Write-Verbose -Message ('Transport client dispose failed for {0}.' -f $name) }
    }
}

function Invoke-NxbTransportExperimentRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Connection,
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][long]$Sequence,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][AllowNull()][object]$Payload,
        [Parameter(Mandatory)][string]$KeyHex,
        [Parameter(Mandatory)][long]$ExpectedResponseSequence,
        [Parameter(Mandatory)][AllowEmptyCollection()][Collections.Generic.List[object]]$Transcript,
        [Parameter()][switch]$TamperAuthentication,
        [Parameter()][AllowNull()][string]$ControlLabel
    )

    $request = ConvertTo-NxbTransportFrame -SessionId $SessionId -SenderRole controller -Sequence $Sequence -Kind $Kind -Payload $Payload -KeyHex $KeyHex
    if ($TamperAuthentication) {
        $replacement = if ($request.auth_tag[0] -ceq '0') { '1' } else { '0' }
        $request.auth_tag = $replacement + $request.auth_tag.Substring(1)
    }
    $Connection.writer.WriteLine((ConvertTo-NxbTransportJsonLine -Frame $request))
    $Connection.writer.Flush()
    $responseLine = $Connection.reader.ReadLine()
    if ([string]::IsNullOrWhiteSpace($responseLine)) { throw 'Transport target returned no response line.' }
    $response = ConvertFrom-NxbTransportJsonLine -Line $responseLine
    if (-not (Test-NxbTransportFrame -Frame $response -KeyHex $KeyHex -ExpectedSessionId $SessionId -ExpectedSenderRole target)) {
        throw 'Transport target response authentication failed.'
    }
    if ([int64]$response.sequence -ne $ExpectedResponseSequence) {
        throw ('Transport response sequence mismatch: expected={0} actual={1}' -f $ExpectedResponseSequence,[int64]$response.sequence)
    }
    $responsePayload = Get-NxbTransportPayloadObject -Frame $response
    $Transcript.Add([pscustomobject][ordered]@{
        label = if ([string]::IsNullOrWhiteSpace($ControlLabel)) { $Kind } else { $ControlLabel }
        request = $request
        request_auth_expected_valid = (-not $TamperAuthentication)
        response = $response
        response_payload = $responsePayload
    })
    return [pscustomobject][ordered]@{ request=$request; response=$response; payload=$responsePayload }
}

function Write-NxbTransportSpool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Records,
        [Parameter(Mandatory)][int]$MaximumRecords,
        [Parameter(Mandatory)][int]$MaximumBytes
    )

    if ($Records.Count -gt $MaximumRecords) { throw 'Transport spool record budget exceeded.' }
    $lines = @($Records | ForEach-Object { $_ | ConvertTo-Json -Depth 8 -Compress })
    $text = ($lines -join [Environment]::NewLine) + [Environment]::NewLine
    $bytes = [Text.Encoding]::UTF8.GetByteCount($text)
    if ($bytes -gt $MaximumBytes) { throw 'Transport spool byte budget exceeded.' }
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),$text,[Text.UTF8Encoding]::new($false))
    return [pscustomobject][ordered]@{ record_count=$Records.Count; byte_count=$bytes; sha256=Get-NxbTransportSha256Text -Text $text }
}

if ($env:OS -cne 'Windows_NT') { throw 'Controller/target transport experiment requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Controller/target transport experiment requires PowerShell 7.' }

$configFull = [IO.Path]::GetFullPath($ConfigPath)
$config = Get-Content -LiteralPath $configFull -Raw | ConvertFrom-Json
if ([int]$config.schema_version -ne 1 -or [string]$config.scope -cne 'loopback-controller-target-certification-only') { throw 'Unexpected Part 3 transport contract.' }
$keyHex = [string]$config.authentication.certification_test_key_hex
if ($keyHex -notmatch '^[0-9a-f]{64}$') { throw 'Transport certification test key is invalid.' }
if ([bool]$config.authentication.production_secret_claimed) { throw 'Certification transport must not claim a production secret.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) { throw ('Transport experiment output already exists: {0}' -f $outputFull) }
$rawRoot = Join-Path $outputFull 'raw-local'
$reviewRoot = Join-Path $outputFull 'review'
$stateRoot = Join-Path $rawRoot 'target-state'
[IO.Directory]::CreateDirectory($rawRoot) | Out-Null
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
[IO.Directory]::CreateDirectory($stateRoot) | Out-Null

$targetScript = Join-Path $PSScriptRoot 'Start-NxbControllerTargetTransportTarget.ps1'
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$sessionId = 'nxb-transport-' + [Guid]::NewGuid().ToString('N')
$readyOnePath = Join-Path $rawRoot 'target-ready-generation-1.json'
$readyTwoPath = Join-Path $rawRoot 'target-ready-generation-2.json'
$targetResultPath = Join-Path $rawRoot 'target-result.json'
$spoolPath = Join-Path $rawRoot 'controller-spool.jsonl'
$cursorPath = Join-Path $rawRoot 'controller-spool-cursor.json'
$reviewPath = Join-Path $reviewRoot 'controller-target-transport-experiment.json'
$transcript = [Collections.Generic.List[object]]::new()
$startedUtc = [DateTime]::UtcNow
$targetProcess = $null
$connection = $null
$nextSequence = [int64]1
$nextResponseSequence = [int64]1
$directEventCount = 0
$spooledRecordCount = 0
$spoolReplayCount = 0
$spoolInfo = $null
$backpressureObserved = $false
$restartPerformed = $false
$checkpointMatched = $false
$resumeObserved = $false
$emergencyStopObserved = $false
$postStopRejected = $false
$invalidAuthRejected = $false
$duplicateRejected = $false
$gapRejected = $false
$restartGeneration = 0

try {
    $targetProcess = Invoke-NxbTransportTargetProcessStart -PowerShellPath $pwsh -TargetScript $targetScript -ConfigPath $configFull -StateDirectory $stateRoot -ReadyPath $readyOnePath -ResultPath $targetResultPath -SessionId $sessionId -KeyHex $keyHex
    $readyOne = Wait-NxbTransportReady -Process $targetProcess -ReadyPath $readyOnePath
    if ([string]$readyOne.status -cne 'ready' -or [int]$readyOne.generation -ne 1) { throw 'Initial transport target readiness contract failed.' }
    $connection = Connect-NxbTransportExperimentClient -Port ([int]$readyOne.port)

    $invalid = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind event -Payload ([pscustomobject]@{ logical_event_id='invalid-auth-control' }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -TamperAuthentication -ControlLabel 'invalid_auth_negative'
    $nextResponseSequence++
    $invalidAuthRejected = ([string]$invalid.response.kind -ceq 'reject' -and [string]$invalid.payload.reason -ceq 'invalid_auth' -and [int64]$invalid.payload.expected_sequence -eq $nextSequence)
    if (-not $invalidAuthRejected) { throw 'Invalid-auth negative control was not rejected without sequence advance.' }

    $eventOne = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind event -Payload ([pscustomobject]@{ logical_event_id='event-001'; value=1 }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel 'event_001'
    $nextResponseSequence++
    if ([string]$eventOne.response.kind -cne 'ack') { throw 'First transport event was not accepted.' }
    $nextSequence++
    $directEventCount++

    $duplicate = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence ($nextSequence - 1) -Kind event -Payload ([pscustomobject]@{ logical_event_id='duplicate-control'; value=1 }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel 'duplicate_negative'
    $nextResponseSequence++
    $duplicateRejected = ([string]$duplicate.response.kind -ceq 'reject' -and [string]$duplicate.payload.reason -ceq 'duplicate' -and [int64]$duplicate.payload.expected_sequence -eq $nextSequence)
    if (-not $duplicateRejected) { throw 'Duplicate negative control was not rejected without sequence advance.' }

    $gap = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence ($nextSequence + 1) -Kind event -Payload ([pscustomobject]@{ logical_event_id='gap-control'; value=3 }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel 'gap_negative'
    $nextResponseSequence++
    $gapRejected = ([string]$gap.response.kind -ceq 'reject' -and [string]$gap.payload.reason -ceq 'sequence_gap' -and [int64]$gap.payload.expected_sequence -eq $nextSequence)
    if (-not $gapRejected) { throw 'Sequence-gap negative control was not rejected without sequence advance.' }

    $eventCount = [int]$config.event_count
    $pending = [Collections.Generic.List[object]]::new()
    foreach ($logicalIndex in 2..$eventCount) {
        $pending.Add([pscustomobject][ordered]@{ logical_event_id=('event-{0:D3}' -f $logicalIndex); value=$logicalIndex })
    }

    while ($pending.Count -gt 0 -and -not $backpressureObserved) {
        $payload = $pending[0]
        $request = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind event -Payload $payload -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel ([string]$payload.logical_event_id)
        $nextResponseSequence++
        if ([string]$request.response.kind -cne 'ack') { throw ('Direct transport event rejected: {0}' -f $payload.logical_event_id) }
        $nextSequence++
        $directEventCount++
        $pending.RemoveAt(0)
        if ([bool]$request.payload.backpressure) { $backpressureObserved = $true }
    }
    if (-not $backpressureObserved) { throw 'Transport backpressure was not observed before pending-event spool.' }

    $spoolRecords = @($pending)
    $spoolInfo = Write-NxbTransportSpool -Path $spoolPath -Records $spoolRecords -MaximumRecords ([int]$config.spool.maximum_records) -MaximumBytes ([int]$config.spool.maximum_bytes)
    $spooledRecordCount = [int]$spoolInfo.record_count
    Write-NxbTransportExperimentJson -Path $cursorPath -InputObject ([pscustomobject][ordered]@{ schema_version=1; acknowledged_records=0; total_records=$spooledRecordCount })

    $drain = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind drain -Payload ([pscustomobject]@{ reason='backpressure_release' }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel 'drain_after_backpressure'
    $nextResponseSequence++
    if ([string]$drain.response.kind -cne 'ack' -or [bool]$drain.payload.backpressure) { throw 'Backpressure drain did not release the queue.' }
    $nextSequence++

    $spoolReplay = @(Get-Content -LiteralPath $spoolPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
    for ($spoolIndex = 0; $spoolIndex -lt $spoolReplay.Count; $spoolIndex++) {
        $payload = $spoolReplay[$spoolIndex]
        $request = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind event -Payload $payload -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel ('spool_replay_' + [string]$payload.logical_event_id)
        $nextResponseSequence++
        if ([string]$request.response.kind -cne 'ack') { throw ('Spooled transport event rejected: {0}' -f $payload.logical_event_id) }
        $nextSequence++
        $spoolReplayCount++
        Write-NxbTransportExperimentJson -Path $cursorPath -InputObject ([pscustomobject][ordered]@{ schema_version=1; acknowledged_records=$spoolReplayCount; total_records=$spooledRecordCount })

        $acceptedLogicalEvents = $directEventCount + $spoolReplayCount
        if (-not $restartPerformed -and $acceptedLogicalEvents -eq [int]$config.recovery.restart_after_accepted_event) {
            Close-NxbTransportExperimentClient -Connection $connection
            $connection = $null
            $targetProcess.Kill()
            if (-not $targetProcess.WaitForExit(10000)) { throw 'Timed out terminating the first transport target generation.' }
            $targetProcess.Dispose()
            $targetProcess = $null
            $restartPerformed = $true

            $targetProcess = Invoke-NxbTransportTargetProcessStart -PowerShellPath $pwsh -TargetScript $targetScript -ConfigPath $configFull -StateDirectory $stateRoot -ReadyPath $readyTwoPath -ResultPath $targetResultPath -SessionId $sessionId -KeyHex $keyHex
            $readyTwo = Wait-NxbTransportReady -Process $targetProcess -ReadyPath $readyTwoPath
            $restartGeneration = [int]$readyTwo.generation
            $checkpointMatched = ([int64]$readyTwo.next_expected_sequence -eq $nextSequence -and [int64]$readyTwo.response_sequence -eq $nextResponseSequence)
            if (-not $checkpointMatched -or $restartGeneration -ne 2) { throw 'Transport target restart did not recover the durable checkpoint.' }
            $connection = Connect-NxbTransportExperimentClient -Port ([int]$readyTwo.port)
            $resume = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind resume -Payload ([pscustomobject]@{ acknowledged_spool_records=$spoolReplayCount }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel 'resume_after_target_restart'
            $nextResponseSequence++
            $resumeObserved = ([string]$resume.response.kind -ceq 'ack' -and [string]$resume.payload.reason -ceq 'resumed' -and [int]$resume.payload.generation -eq 2)
            if (-not $resumeObserved) { throw 'Transport resume after target restart did not pass.' }
            $nextSequence++
            if ([bool]$resume.payload.backpressure) {
                $restartDrain = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind drain -Payload ([pscustomobject]@{ reason='restart_backpressure_release' }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel 'drain_after_restart'
                $nextResponseSequence++
                if ([string]$restartDrain.response.kind -cne 'ack' -or [bool]$restartDrain.payload.backpressure) { throw 'Restart drain did not release backpressure.' }
                $nextSequence++
            }
        }

        if ([bool]$request.payload.backpressure) {
            $replayDrain = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind drain -Payload ([pscustomobject]@{ reason='spool_replay_backpressure_release' }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel 'drain_during_spool_replay'
            $nextResponseSequence++
            if ([string]$replayDrain.response.kind -cne 'ack' -or [bool]$replayDrain.payload.backpressure) { throw 'Spool replay drain did not release backpressure.' }
            $nextSequence++
        }
    }

    if ($directEventCount + $spoolReplayCount -ne $eventCount) { throw 'Transport event accounting did not reach the configured event count.' }
    if (-not $restartPerformed -or -not $checkpointMatched -or -not $resumeObserved) { throw 'Interrupted-transfer recovery controls did not complete.' }

    $emergency = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind emergency_stop -Payload ([pscustomobject]@{ reason='certification_control' }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel 'emergency_stop'
    $nextResponseSequence++
    $emergencyStopObserved = ([string]$emergency.response.kind -ceq 'ack' -and [string]$emergency.payload.reason -ceq 'emergency_stop_armed')
    if (-not $emergencyStopObserved) { throw 'Emergency stop was not armed.' }
    $nextSequence++

    $postStop = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind event -Payload ([pscustomobject]@{ logical_event_id='post-stop-denial-control'; value=999 }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel 'post_stop_event_negative'
    $nextResponseSequence++
    $postStopRejected = ([string]$postStop.response.kind -ceq 'reject' -and [string]$postStop.payload.reason -ceq 'emergency_stop_active' -and [int64]$postStop.payload.expected_sequence -eq $nextSequence)
    if (-not $postStopRejected) { throw 'Emergency stop did not reject later data without sequence advance.' }

    $shutdown = Invoke-NxbTransportExperimentRequest -Connection $connection -SessionId $sessionId -Sequence $nextSequence -Kind shutdown -Payload ([pscustomobject]@{ reason='certification_complete' }) -KeyHex $keyHex -ExpectedResponseSequence $nextResponseSequence -Transcript $transcript -ControlLabel 'shutdown'
    $nextResponseSequence++
    if ([string]$shutdown.response.kind -cne 'ack' -or [string]$shutdown.payload.reason -cne 'shutdown') { throw 'Transport shutdown acknowledgement failed.' }
    $nextSequence++

    Close-NxbTransportExperimentClient -Connection $connection
    $connection = $null
    if (-not $targetProcess.WaitForExit(10000)) { throw 'Transport target did not exit after authenticated shutdown.' }
    if ($targetProcess.ExitCode -ne 0) { throw ('Final transport target exited with code {0}.' -f $targetProcess.ExitCode) }
    $targetProcess.Dispose()
    $targetProcess = $null

    if (-not (Test-Path -LiteralPath $targetResultPath -PathType Leaf)) { throw 'Final target result was not produced.' }
    $targetResult = Get-Content -LiteralPath $targetResultPath -Raw | ConvertFrom-Json
    if ([string]$targetResult.status -cne 'passed') { throw 'Final target result did not pass.' }
    if ([int]$targetResult.accepted_event_count -ne $eventCount) { throw 'Target accepted-event count mismatch.' }
    if ([int]$targetResult.auth_failure_count -lt 1 -or [int]$targetResult.duplicate_count -lt 1 -or [int]$targetResult.gap_count -lt 1) { throw 'Target negative-control counters are incomplete.' }
    if ([int]$targetResult.overflow_count -ne 0) { throw 'Bounded queue overflowed during the transport experiment.' }
    if ([int]$targetResult.backpressure_count -lt 1) { throw 'Target did not record backpressure.' }
    if ([int]$targetResult.max_queue_depth_observed -gt [int]$config.queue.maximum_frames) { throw 'Target queue exceeded the configured bound.' }
    if ([int]$targetResult.resume_count -lt 1 -or [int]$targetResult.generation -ne 2) { throw 'Target restart/resume counters are incomplete.' }
    if (-not [bool]$targetResult.emergency_stop -or -not [bool]$targetResult.shutdown) { throw 'Target emergency-stop/shutdown state is incomplete.' }

    $cursor = Get-Content -LiteralPath $cursorPath -Raw | ConvertFrom-Json
    if ([int]$cursor.acknowledged_records -ne $spooledRecordCount -or $spoolReplayCount -ne $spooledRecordCount) { throw 'Controller spool replay cursor is incomplete.' }
    $spoolCleanup = $false
    Remove-Item -LiteralPath $spoolPath -Force
    $spoolCleanup = (-not (Test-Path -LiteralPath $spoolPath))
    if (-not $spoolCleanup) { throw 'Controller spool cleanup failed.' }

    $endedUtc = [DateTime]::UtcNow
    $result = [pscustomobject][ordered]@{
        schema_version = 1
        status = 'passed'
        started_utc = $startedUtc.ToString('o')
        ended_utc = $endedUtc.ToString('o')
        scope = [string]$config.scope
        protocol = [string]$config.protocol
        bind_address = '127.0.0.1'
        session_id = $sessionId
        session_id_sha256 = Get-NxbTransportSha256Text -Text $sessionId
        certification_key_sha256 = Get-NxbTransportSha256Text -Text $keyHex
        production_secret_claimed = $false
        configured_event_count = $eventCount
        direct_event_count = $directEventCount
        spooled_event_count = $spooledRecordCount
        spool_replayed_event_count = $spoolReplayCount
        controls = [pscustomobject][ordered]@{
            invalid_auth_rejected_without_sequence_advance = $invalidAuthRejected
            duplicate_rejected_without_sequence_advance = $duplicateRejected
            gap_detected_without_sequence_advance = $gapRejected
            bounded_queue_never_overflows = ([int]$targetResult.overflow_count -eq 0 -and [int]$targetResult.max_queue_depth_observed -le [int]$config.queue.maximum_frames)
            backpressure_observed = $backpressureObserved
            pending_events_spooled_locally = ($spooledRecordCount -gt 0)
            spool_replayed_after_drain = ($spoolReplayCount -eq $spooledRecordCount -and $spoolReplayCount -gt 0)
            target_restart_recovers_checkpoint = ($restartPerformed -and $checkpointMatched -and $resumeObserved -and $restartGeneration -eq 2)
            emergency_stop_rejects_later_data = ($emergencyStopObserved -and $postStopRejected)
        }
        queue = [pscustomobject][ordered]@{
            maximum_frames = [int]$config.queue.maximum_frames
            high_watermark = [int]$config.queue.high_watermark
            low_watermark = [int]$config.queue.low_watermark
            max_queue_depth_observed = [int]$targetResult.max_queue_depth_observed
            backpressure_count = [int]$targetResult.backpressure_count
            overflow_count = [int]$targetResult.overflow_count
        }
        spool = [pscustomobject][ordered]@{
            maximum_records = [int]$config.spool.maximum_records
            maximum_bytes = [int]$config.spool.maximum_bytes
            record_count = $spooledRecordCount
            byte_count = [int]$spoolInfo.byte_count
            sha256 = [string]$spoolInfo.sha256
            replayed_count = $spoolReplayCount
            cursor_acknowledged_records = [int]$cursor.acknowledged_records
            cleanup_verified = $spoolCleanup
        }
        recovery = [pscustomobject][ordered]@{
            restart_performed = $restartPerformed
            generation_after_restart = $restartGeneration
            checkpoint_sequence_matched = $checkpointMatched
            resume_observed = $resumeObserved
        }
        target = $targetResult
        transcript = @($transcript)
        key_reviewable = $false
        synthetic_payload_only = $true
    }
    $failedControl = @($result.controls.PSObject.Properties | Where-Object { -not [bool]$_.Value })
    if ($failedControl.Count -gt 0) { throw ('Transport required controls failed: {0}' -f (@($failedControl.Name) -join ', ')) }
    Write-NxbTransportExperimentJson -Path $reviewPath -InputObject $result
    Write-Information -InformationAction Continue -MessageData ('NXB controller/target transport experiment passed: events={0} spooled={1} transcript={2}' -f $eventCount,$spooledRecordCount,$transcript.Count)
    if ($PassThru) { return $result }
    Write-Output $reviewPath
}
finally {
    Close-NxbTransportExperimentClient -Connection $connection
    if ($null -ne $targetProcess) {
        try {
            if (-not $targetProcess.HasExited) { $targetProcess.Kill() }
            [void]$targetProcess.WaitForExit(5000)
        }
        catch { Write-Verbose -Message 'Transport target cleanup encountered a bounded failure.' }
        finally { $targetProcess.Dispose() }
    }
}
