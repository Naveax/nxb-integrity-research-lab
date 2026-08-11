[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ConfigPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateDirectory,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ReadyPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ResultPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SessionId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string]$KeyHex
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'NxbControllerTargetTransport.Common.ps1')

function Write-NxbTransportTargetJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    $tempPath = $fullPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($tempPath,(($InputObject | ConvertTo-Json -Depth 32) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tempPath -Destination $fullPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tempPath -PathType Leaf) { Remove-Item -LiteralPath $tempPath -Force }
    }
}

function Get-NxbTransportTargetState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$ExpectedSessionId)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{
            schema_version = 1
            session_id = $ExpectedSessionId
            generation = 1
            next_expected_sequence = [int64]1
            response_sequence = [int64]1
            accepted_message_count = 0
            accepted_event_count = 0
            duplicate_count = 0
            gap_count = 0
            auth_failure_count = 0
            overflow_count = 0
            backpressure_count = 0
            backpressure_active = $false
            max_queue_depth_observed = 0
            queue = @()
            resume_count = 0
            disconnect_count = 0
            emergency_stop = $false
            shutdown = $false
        }
    }

    $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ([int]$state.schema_version -ne 1 -or [string]$state.session_id -cne $ExpectedSessionId) {
        throw 'Existing target state does not match the requested transport session.'
    }
    $state.generation = [int]$state.generation + 1
    $state.queue = @($state.queue)
    return $state
}

function Send-NxbTransportTargetResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][IO.StreamWriter]$Writer,
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][string]$KeyHex,
        [Parameter(Mandatory)][ValidateSet('ack','reject','status')][string]$Kind,
        [Parameter(Mandatory)][object]$Payload
    )

    $response = ConvertTo-NxbTransportFrame -SessionId ([string]$State.session_id) -SenderRole target -Sequence ([int64]$State.response_sequence) -Kind $Kind -Payload $Payload -KeyHex $KeyHex
    $Writer.WriteLine((ConvertTo-NxbTransportJsonLine -Frame $response))
    $Writer.Flush()
    $State.response_sequence = [int64]$State.response_sequence + 1
    return $response
}

if ($env:OS -cne 'Windows_NT') { throw 'Controller/target transport target requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Controller/target transport target requires PowerShell 7.' }

$configFull = [IO.Path]::GetFullPath($ConfigPath)
$config = Get-Content -LiteralPath $configFull -Raw | ConvertFrom-Json
if ([int]$config.schema_version -ne 1) { throw 'Unsupported transport contract schema.' }
if ([string]$config.bind_address -cne '127.0.0.1') { throw 'Transport certification target is restricted to 127.0.0.1.' }
$maxFrameBytes = [int]$config.maximum_frame_bytes
$maxQueue = [int]$config.queue.maximum_frames
$highWatermark = [int]$config.queue.high_watermark
$lowWatermark = [int]$config.queue.low_watermark
if ($lowWatermark -lt 0 -or $highWatermark -le $lowWatermark -or $maxQueue -le $highWatermark) { throw 'Transport queue watermarks are invalid.' }

$stateRoot = [IO.Path]::GetFullPath($StateDirectory)
[IO.Directory]::CreateDirectory($stateRoot) | Out-Null
$statePath = Join-Path $stateRoot 'target-state.json'
$state = Get-NxbTransportTargetState -Path $statePath -ExpectedSessionId $SessionId
Write-NxbTransportTargetJson -Path $statePath -InputObject $state

$listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
$listener.Start()
try {
    $port = [int]([Net.IPEndPoint]$listener.LocalEndpoint).Port
    $ready = [pscustomobject][ordered]@{
        schema_version = 1
        status = 'ready'
        session_id = $SessionId
        generation = [int]$state.generation
        bind_address = '127.0.0.1'
        port = $port
        process_id = $PID
        next_expected_sequence = [int64]$state.next_expected_sequence
        response_sequence = [int64]$state.response_sequence
        state_sha256 = Get-NxbTransportSha256Text -Text ((Get-Content -LiteralPath $statePath -Raw).TrimEnd())
    }
    Write-NxbTransportTargetJson -Path $ReadyPath -InputObject $ready

    while (-not [bool]$state.shutdown) {
        $client = $listener.AcceptTcpClient()
        try {
            $client.NoDelay = $true
            $stream = $client.GetStream()
            $reader = [IO.StreamReader]::new($stream,[Text.UTF8Encoding]::new($false),$false,4096,$true)
            $writer = [IO.StreamWriter]::new($stream,[Text.UTF8Encoding]::new($false),4096,$true)
            $writer.NewLine = "`n"
            $writer.AutoFlush = $true
            try {
                while (-not [bool]$state.shutdown) {
                    $line = $reader.ReadLine()
                    if ($null -eq $line) { break }
                    if ([Text.Encoding]::UTF8.GetByteCount($line) -gt $maxFrameBytes) {
                        [void](Send-NxbTransportTargetResponse -Writer $writer -State $state -KeyHex $KeyHex -Kind reject -Payload ([pscustomobject][ordered]@{ reason='frame_too_large'; expected_sequence=[int64]$state.next_expected_sequence; queue_depth=@($state.queue).Count; backpressure=[bool]$state.backpressure_active }))
                        Write-NxbTransportTargetJson -Path $statePath -InputObject $state
                        continue
                    }

                    $frame = $null
                    try { $frame = ConvertFrom-NxbTransportJsonLine -Line $line } catch { $frame = $null }
                    if ($null -eq $frame -or -not (Test-NxbTransportFrame -Frame $frame -KeyHex $KeyHex -ExpectedSessionId $SessionId -ExpectedSenderRole controller)) {
                        $state.auth_failure_count = [int]$state.auth_failure_count + 1
                        [void](Send-NxbTransportTargetResponse -Writer $writer -State $state -KeyHex $KeyHex -Kind reject -Payload ([pscustomobject][ordered]@{ reason='invalid_auth'; expected_sequence=[int64]$state.next_expected_sequence; queue_depth=@($state.queue).Count; backpressure=[bool]$state.backpressure_active }))
                        Write-NxbTransportTargetJson -Path $statePath -InputObject $state
                        continue
                    }

                    $requestSequence = [int64]$frame.sequence
                    $expectedSequence = [int64]$state.next_expected_sequence
                    if ($requestSequence -lt $expectedSequence) {
                        $state.duplicate_count = [int]$state.duplicate_count + 1
                        [void](Send-NxbTransportTargetResponse -Writer $writer -State $state -KeyHex $KeyHex -Kind reject -Payload ([pscustomobject][ordered]@{ reason='duplicate'; request_sequence=$requestSequence; expected_sequence=$expectedSequence; queue_depth=@($state.queue).Count; backpressure=[bool]$state.backpressure_active }))
                        Write-NxbTransportTargetJson -Path $statePath -InputObject $state
                        continue
                    }
                    if ($requestSequence -gt $expectedSequence) {
                        $state.gap_count = [int]$state.gap_count + 1
                        [void](Send-NxbTransportTargetResponse -Writer $writer -State $state -KeyHex $KeyHex -Kind reject -Payload ([pscustomobject][ordered]@{ reason='sequence_gap'; request_sequence=$requestSequence; expected_sequence=$expectedSequence; queue_depth=@($state.queue).Count; backpressure=[bool]$state.backpressure_active }))
                        Write-NxbTransportTargetJson -Path $statePath -InputObject $state
                        continue
                    }

                    $kind = [string]$frame.kind
                    if ([bool]$state.emergency_stop -and $kind -ceq 'event') {
                        [void](Send-NxbTransportTargetResponse -Writer $writer -State $state -KeyHex $KeyHex -Kind reject -Payload ([pscustomobject][ordered]@{ reason='emergency_stop_active'; request_sequence=$requestSequence; expected_sequence=$expectedSequence; queue_depth=@($state.queue).Count; backpressure=[bool]$state.backpressure_active }))
                        Write-NxbTransportTargetJson -Path $statePath -InputObject $state
                        continue
                    }

                    $responsePayload = $null
                    $responseKind = 'ack'
                    switch ($kind) {
                        'event' {
                            $queue = @($state.queue)
                            if ($queue.Count -ge $maxQueue) {
                                $state.overflow_count = [int]$state.overflow_count + 1
                                $responseKind = 'reject'
                                $responsePayload = [pscustomobject][ordered]@{ reason='queue_full'; request_sequence=$requestSequence; expected_sequence=$expectedSequence; queue_depth=$queue.Count; backpressure=$true }
                                break
                            }
                            $queue += $requestSequence
                            $state.queue = @($queue)
                            $state.accepted_event_count = [int]$state.accepted_event_count + 1
                            $state.accepted_message_count = [int]$state.accepted_message_count + 1
                            $state.next_expected_sequence = $expectedSequence + 1
                            if ($queue.Count -gt [int]$state.max_queue_depth_observed) { $state.max_queue_depth_observed = $queue.Count }
                            if ($queue.Count -ge $highWatermark -and -not [bool]$state.backpressure_active) {
                                $state.backpressure_active = $true
                                $state.backpressure_count = [int]$state.backpressure_count + 1
                            }
                            $responsePayload = [pscustomobject][ordered]@{ reason='accepted'; request_sequence=$requestSequence; expected_sequence=[int64]$state.next_expected_sequence; queue_depth=$queue.Count; backpressure=[bool]$state.backpressure_active }
                        }
                        'drain' {
                            $queue = @($state.queue)
                            $before = $queue.Count
                            while ($queue.Count -gt $lowWatermark) {
                                if ($queue.Count -le 1) { $queue = @(); break }
                                $queue = @($queue[1..($queue.Count - 1)])
                            }
                            $state.queue = @($queue)
                            $state.accepted_message_count = [int]$state.accepted_message_count + 1
                            $state.next_expected_sequence = $expectedSequence + 1
                            if ($queue.Count -le $lowWatermark) { $state.backpressure_active = $false }
                            $responsePayload = [pscustomobject][ordered]@{ reason='drained'; request_sequence=$requestSequence; expected_sequence=[int64]$state.next_expected_sequence; drained=($before - $queue.Count); queue_depth=$queue.Count; backpressure=[bool]$state.backpressure_active }
                        }
                        'resume' {
                            $state.resume_count = [int]$state.resume_count + 1
                            $state.accepted_message_count = [int]$state.accepted_message_count + 1
                            $state.next_expected_sequence = $expectedSequence + 1
                            $responsePayload = [pscustomobject][ordered]@{ reason='resumed'; request_sequence=$requestSequence; expected_sequence=[int64]$state.next_expected_sequence; generation=[int]$state.generation; queue_depth=@($state.queue).Count; backpressure=[bool]$state.backpressure_active }
                        }
                        'emergency_stop' {
                            $state.emergency_stop = $true
                            $state.accepted_message_count = [int]$state.accepted_message_count + 1
                            $state.next_expected_sequence = $expectedSequence + 1
                            $responsePayload = [pscustomobject][ordered]@{ reason='emergency_stop_armed'; request_sequence=$requestSequence; expected_sequence=[int64]$state.next_expected_sequence; queue_depth=@($state.queue).Count; backpressure=[bool]$state.backpressure_active }
                        }
                        'shutdown' {
                            $state.shutdown = $true
                            $state.accepted_message_count = [int]$state.accepted_message_count + 1
                            $state.next_expected_sequence = $expectedSequence + 1
                            $responsePayload = [pscustomobject][ordered]@{ reason='shutdown'; request_sequence=$requestSequence; expected_sequence=[int64]$state.next_expected_sequence; queue_depth=@($state.queue).Count; backpressure=[bool]$state.backpressure_active }
                        }
                        default {
                            $responseKind = 'reject'
                            $responsePayload = [pscustomobject][ordered]@{ reason='unsupported_kind'; request_sequence=$requestSequence; expected_sequence=$expectedSequence; queue_depth=@($state.queue).Count; backpressure=[bool]$state.backpressure_active }
                        }
                    }

                    [void](Send-NxbTransportTargetResponse -Writer $writer -State $state -KeyHex $KeyHex -Kind $responseKind -Payload $responsePayload)
                    Write-NxbTransportTargetJson -Path $statePath -InputObject $state
                }
            }
            finally {
                $reader.Dispose()
                $writer.Dispose()
                $stream.Dispose()
            }
        }
        finally {
            $client.Dispose()
            $state.disconnect_count = [int]$state.disconnect_count + 1
            Write-NxbTransportTargetJson -Path $statePath -InputObject $state
        }
    }
}
finally {
    $listener.Stop()
    $finalState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    $result = [pscustomobject][ordered]@{
        schema_version = 1
        status = if ([bool]$finalState.shutdown) { 'passed' } else { 'stopped_without_shutdown' }
        session_id = [string]$finalState.session_id
        key_sha256 = Get-NxbTransportSha256Text -Text $KeyHex.ToLowerInvariant()
        generation = [int]$finalState.generation
        next_expected_sequence = [int64]$finalState.next_expected_sequence
        response_sequence = [int64]$finalState.response_sequence
        accepted_message_count = [int]$finalState.accepted_message_count
        accepted_event_count = [int]$finalState.accepted_event_count
        duplicate_count = [int]$finalState.duplicate_count
        gap_count = [int]$finalState.gap_count
        auth_failure_count = [int]$finalState.auth_failure_count
        overflow_count = [int]$finalState.overflow_count
        backpressure_count = [int]$finalState.backpressure_count
        max_queue_depth_observed = [int]$finalState.max_queue_depth_observed
        final_queue_depth = @($finalState.queue).Count
        resume_count = [int]$finalState.resume_count
        disconnect_count = [int]$finalState.disconnect_count
        emergency_stop = [bool]$finalState.emergency_stop
        shutdown = [bool]$finalState.shutdown
    }
    Write-NxbTransportTargetJson -Path $ResultPath -InputObject $result
}
