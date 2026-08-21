[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string]$ExperimentPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SignalsPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TriggerId,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,

    [Parameter()][string]$PolicyPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'config\adaptive-observability-policy.default.json'),
    [Parameter()][AllowNull()][Nullable[int]]$RequestedPreTriggerSeconds,
    [Parameter()][AllowNull()][Nullable[int]]$RequestedPostTriggerSeconds,
    [Parameter()][ValidateRange(50,5000)][int]$PollMilliseconds = 200,
    [Parameter()][ValidateRange(1,128)][int]$MaxCoalescedTriggers = 32,
    [Parameter()][ValidateRange(64,1048576)][int]$MinimumFreeDiskMiB = 256,
    [Parameter()][string]$EmergencyStopPath,
    [Parameter()][string]$WprExecutablePath,
    [Parameter()][string]$XperfExecutablePath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function Get-NxbBoundedCounterValue {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Counter)
    if ($null -eq $Counter) { return $null }
    $valueProperty = $Counter.PSObject.Properties['value']
    if ($null -eq $valueProperty -or $null -eq $valueProperty.Value) { return $null }
    return [uint64]$valueProperty.Value
}

function Get-NxbBoundedFreeDiskMiB {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrWhiteSpace($root)) { throw ('Unable to resolve disk root for bounded capture: {0}' -f $full) }
    try {
        $drive = [IO.DriveInfo]::new($root)
        if (-not $drive.IsReady) { throw ('Drive is not ready: {0}' -f $root) }
        return [double]$drive.AvailableFreeSpace / 1MB
    }
    catch {
        throw ('Bounded capture disk-pressure probe failed for {0}: {1}' -f $root,$_.Exception.Message)
    }
}

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$signalsFull = [IO.Path]::GetFullPath($SignalsPath)
$policyFull = [IO.Path]::GetFullPath($PolicyPath)
$expected = $ExpectedHead.ToLowerInvariant()
$boundedSessionId = [Guid]::NewGuid().ToString('D')
$configuredMaxCoalescedTriggers = $MaxCoalescedTriggers

if (-not (Test-Path -LiteralPath $signalsFull -PathType Leaf)) { throw ('Signals file missing: {0}' -f $signalsFull) }
if (-not (Test-Path -LiteralPath $policyFull -PathType Leaf)) { throw ('Policy file missing: {0}' -f $policyFull) }

$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction Stop }
$git = [string]$gitCommand.Source
$currentHead = (@(& $git -C $repositoryRoot rev-parse HEAD 2>&1) -join [Environment]::NewLine).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $expected) { throw ('Bounded capture exact-head mismatch: expected={0} actual={1}' -f $expected,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Bounded capture requires a clean exact-head repository worktree.' }

$policy = Get-Content -LiteralPath $policyFull -Raw | ConvertFrom-Json
if ([int]$policy.schema_version -ne 1) { throw 'Unsupported adaptive observability policy schema.' }
$policyFingerprint = Get-NxbCanonicalJsonHash -InputObject $policy
$targetTriggers = @($policy.triggers | Where-Object { [string]$_.id -ceq $TriggerId })
if ($targetTriggers.Count -ne 1) { throw ('TriggerId must resolve to exactly one policy trigger: {0}' -f $TriggerId) }
$targetTrigger = $targetTriggers[0]
if (-not [bool]$targetTrigger.enabled) { throw ('Target trigger is disabled: {0}' -f $TriggerId) }

$initialFreeDiskMiB = Get-NxbBoundedFreeDiskMiB -Path $experimentFull
if ($initialFreeDiskMiB -lt $MinimumFreeDiskMiB) {
    throw ('Bounded capture disk-pressure preflight failed: free_mib={0:N1} minimum_mib={1}' -f $initialFreeDiskMiB,$MinimumFreeDiskMiB)
}
$minimumObservedFreeDiskMiB = $initialFreeDiskMiB

$analysisRoot = Join-Path $experimentFull 'analysis'
[IO.Directory]::CreateDirectory($analysisRoot) | Out-Null
$boundedStatePath = Join-Path $analysisRoot 'bounded-trigger-capture-state.json'
$adaptiveStatePath = Join-Path $analysisRoot 'bounded-adaptive-trigger-state.json'
$livePlanPath = Join-Path $analysisRoot 'bounded-adaptive-plan.json'
$receiptPath = Join-Path $analysisRoot 'bounded-trigger-capture-receipt.json'
foreach ($path in @($boundedStatePath,$adaptiveStatePath,$livePlanPath,$receiptPath)) {
    if (Test-Path -LiteralPath $path) { throw ('Bounded capture output already exists: {0}' -f $path) }
}

function Invoke-NxbBoundedState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ActionName,
        [Parameter()][hashtable]$Extra = @{}
    )
    $arguments = @{
        PolicyPath = $policyFull
        StatePath = $boundedStatePath
        ExpectedHead = $expected
        SessionId = $boundedSessionId
        Action = $ActionName
        MaxCoalescedTriggers = $configuredMaxCoalescedTriggers
        PassThru = $true
    }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    return & (Join-Path $PSScriptRoot 'Update-NxbBoundedTriggerCaptureState.ps1') @arguments
}

$traceStarted = $false
$traceStopped = $false
$primarySeen = $false
$seenActivation = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$startResult = $null
$finalState = $null

try {
    $startResult = & (Join-Path $PSScriptRoot 'Start-NxbBoundedMemoryTrace.ps1') `
        -ExperimentPath $experimentFull `
        -ExpectedHead $expected `
        -PolicyPath $policyFull `
        -BoundedCaptureSessionId $boundedSessionId `
        -WprExecutablePath $WprExecutablePath `
        -PassThru
    $traceStarted = $true

    $armExtra = @{}
    if ($null -ne $RequestedPreTriggerSeconds) { $armExtra.RequestedPreTriggerSeconds = [int]$RequestedPreTriggerSeconds }
    if ($null -ne $RequestedPostTriggerSeconds) { $armExtra.RequestedPostTriggerSeconds = [int]$RequestedPostTriggerSeconds }
    $finalState = Invoke-NxbBoundedState -ActionName Arm -Extra $armExtra

    if ([string]$startResult.session_id -cne [string]$finalState.session_id -or
        [string]$startResult.expected_head -cne [string]$finalState.expected_head -or
        [string]$startResult.policy_fingerprint_sha256 -cne [string]$finalState.policy_fingerprint_sha256 -or
        [string]$finalState.policy_fingerprint_sha256 -cne $policyFingerprint) {
        throw 'Bounded capture trace/state authority binding mismatch.'
    }

    while ([string]$finalState.state -notin @('finalizing','completed','failed')) {
        if (-not [string]::IsNullOrWhiteSpace($EmergencyStopPath) -and (Test-Path -LiteralPath $EmergencyStopPath -PathType Leaf)) {
            $finalState = Invoke-NxbBoundedState -ActionName EmergencyStop
            break
        }

        $freeDiskMiB = Get-NxbBoundedFreeDiskMiB -Path $experimentFull
        if ($freeDiskMiB -lt $minimumObservedFreeDiskMiB) { $minimumObservedFreeDiskMiB = $freeDiskMiB }
        if ($freeDiskMiB -lt $MinimumFreeDiskMiB) {
            $finalState = Invoke-NxbBoundedState -ActionName BudgetExhausted -Extra @{ BudgetReason = 'disk_pressure' }
            break
        }

        # Re-read atomically published signals while the Memory WPR ring remains armed.
        try {
            [void](Get-Content -LiteralPath $signalsFull -Raw | ConvertFrom-Json)
        }
        catch {
            throw ('Signals document became unreadable during bounded capture: {0}' -f $_.Exception.Message)
        }

        $adaptiveState = & (Join-Path $PSScriptRoot 'Update-NxbAdaptiveObservabilityState.ps1') `
            -PolicyPath $policyFull `
            -SignalsPath $signalsFull `
            -StatePath $adaptiveStatePath `
            -NowUtc ([DateTime]::UtcNow) `
            -PassThru

        $plan = & (Join-Path $PSScriptRoot 'Resolve-NxbAdaptiveObservabilityPlan.ps1') `
            -PolicyPath $policyFull `
            -SignalsPath $signalsFull `
            -TriggerStatePath $adaptiveStatePath `
            -OutputPath $livePlanPath `
            -PassThru

        $activeSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($activeId in @($adaptiveState.active_trigger_ids)) { [void]$activeSet.Add([string]$activeId) }

        if (-not $primarySeen -and $activeSet.Contains($TriggerId)) {
            $targetState = @($adaptiveState.triggers | Where-Object { [string]$_.id -ceq $TriggerId } | Select-Object -First 1)
            if ($targetState.Count -ne 1) { throw 'Target trigger state disappeared during activation.' }
            $finalState = Invoke-NxbBoundedState -ActionName Trigger -Extra @{
                TriggerId = $TriggerId
                TriggerReason = ('{0}:{1}' -f [string]$targetTrigger.source,[string]$targetTrigger.signal)
                TriggerPriority = [int]$targetTrigger.priority
                PlanFingerprintSha256 = [string]$plan.plan_fingerprint_sha256
                Domains = @($targetTrigger.domains | ForEach-Object { [string]$_ })
            }
            $primarySeen = $true
            [void]$seenActivation.Add($TriggerId)
        }
        elseif ($primarySeen -and [string]$finalState.state -ceq 'post_capture') {
            foreach ($triggerState in @($adaptiveState.triggers | Where-Object { [string]$_.transition -ceq 'activated' })) {
                $id = [string]$triggerState.id
                if ($seenActivation.Contains($id)) { continue }
                $policyRows = @($policy.triggers | Where-Object { [string]$_.id -ceq $id })
                if ($policyRows.Count -ne 1) { throw ('Activated trigger has no unique policy row: {0}' -f $id) }
                $row = $policyRows[0]
                $finalState = Invoke-NxbBoundedState -ActionName Trigger -Extra @{
                    TriggerId = $id
                    TriggerReason = ('{0}:{1}' -f [string]$row.source,[string]$row.signal)
                    TriggerPriority = [int]$row.priority
                    PlanFingerprintSha256 = [string]$plan.plan_fingerprint_sha256
                    Domains = @($row.domains | ForEach-Object { [string]$_ })
                }
                [void]$seenActivation.Add($id)
            }
        }

        $finalState = Invoke-NxbBoundedState -ActionName Tick
        if ([string]$finalState.state -ceq 'finalizing') { break }
        Start-Sleep -Milliseconds $PollMilliseconds
    }

    $stopResult = & (Join-Path $PSScriptRoot 'Stop-PerformanceTraceWithAccounting.ps1') `
        -ExperimentPath $experimentFull `
        -WprExecutablePath $WprExecutablePath `
        -XperfExecutablePath $XperfExecutablePath `
        -Confirm:$false `
        -PassThru
    $traceStopped = $true

    $traceMetadataPath = Join-Path $experimentFull 'traces\performance.etl.json'
    $sessionPath = Join-Path $experimentFull 'trace-session.json'
    foreach ($required in @($traceMetadataPath,$sessionPath,$stopResult.AccountingPath,$stopResult.PostStopStatisticsPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw ('Bounded capture final evidence missing: {0}' -f $required) }
    }

    $traceMetadata = Get-Content -LiteralPath $traceMetadataPath -Raw | ConvertFrom-Json
    $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
    $accounting = Get-Content -LiteralPath $stopResult.AccountingPath -Raw | ConvertFrom-Json
    $statistics = Get-Content -LiteralPath $stopResult.PostStopStatisticsPath -Raw | ConvertFrom-Json

    $sessionBindingValid = (
        [string]$session.bounded_capture_session_id -ceq [string]$finalState.session_id -and
        [string]$session.expected_head -ceq $expected -and
        [string]$session.policy_fingerprint_sha256 -ceq [string]$finalState.policy_fingerprint_sha256
    )
    if (-not $sessionBindingValid) { throw 'Bounded capture finalized trace/session authority binding is stale.' }
    if ([string]$session.profile_provenance.logging_mode -cne 'Memory' -or -not [bool]$session.profile_provenance.bounded) {
        throw 'Bounded trigger capture did not finalize a bounded Memory WPR session.'
    }
    $memoryBudgetMiB = [int]$session.profile_provenance.memory_buffer_budget_mib
    $configuredBuffers = [int]$session.profile_provenance.buffers
    if ($memoryBudgetMiB -ne 64 -or $configuredBuffers -ne 64) {
        throw ('Bounded trigger memory budget drift: memory_mib={0} buffers={1}' -f $memoryBudgetMiB,$configuredBuffers)
    }

    $policyDiskBudgetMiB = [int]$policy.budgets.max_disk_mb_per_hour
    $outputHardBudgetMiB = [Math]::Min($policyDiskBudgetMiB,$memoryBudgetMiB + 8)
    $traceLengthBytes = [int64]$traceMetadata.length
    $outputBudgetBytes = [int64]$outputHardBudgetMiB * 1MB
    $diskBudgetState = if ($traceLengthBytes -le $outputBudgetBytes) {
        if ([string]$finalState.termination_reason -ceq 'disk_pressure') { 'pressure_terminated' } else { 'within_budget' }
    }
    else {
        'exceeded'
    }

    $eventsLost = Get-NxbBoundedCounterValue -Counter $statistics.events_lost
    $buffersLost = Get-NxbBoundedCounterValue -Counter $statistics.buffers_lost
    $buffersWritten = Get-NxbBoundedCounterValue -Counter $statistics.buffers_written
    $realtimeBuffersLost = Get-NxbBoundedCounterValue -Counter $statistics.realtime_buffers_lost
    $estimatedOverwrittenBuffers = if ($null -eq $buffersWritten) {
        $null
    }
    elseif ($buffersWritten -gt [uint64]$configuredBuffers) {
        [uint64]($buffersWritten - [uint64]$configuredBuffers)
    }
    else {
        [uint64]0
    }

    $requestedDomains = @()
    if ($null -ne $finalState.primary_trigger) {
        $requestedDomains = @($finalState.active_domains | ForEach-Object { [string]$_ })
    }
    $capturedDomainSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [void]$capturedDomainSet.Add('cpu')
    [void]$capturedDomainSet.Add('kernel')
    $domainAccounting = @(
        foreach ($domain in $requestedDomains) {
            [pscustomobject][ordered]@{
                domain = $domain
                status = if ($capturedDomainSet.Contains($domain)) { 'captured' } else { 'not_captured_by_minimal_wpr_primitive' }
            }
        }
    )
    $capturedDomainCount = @($domainAccounting | Where-Object { [string]$_.status -ceq 'captured' }).Count
    $uncapturedDomainCount = @($domainAccounting | Where-Object { [string]$_.status -cne 'captured' }).Count
    $coverageStatus = if ($capturedDomainCount -eq 0) { 'none' } elseif ($uncapturedDomainCount -gt 0) { 'partial' } else { 'complete' }

    $accountingSha = (Get-FileHash -LiteralPath $stopResult.AccountingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $statisticsSha = (Get-FileHash -LiteralPath $stopResult.PostStopStatisticsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sessionSha = (Get-FileHash -LiteralPath $sessionPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $normalTermination = ([string]$finalState.termination_reason -ceq 'post_window_complete' -or [string]$finalState.termination_reason -ceq 'zero_post_window')
    $safeDiskState = ([string]$diskBudgetState -in @('within_budget','pressure_terminated'))
    $capturePassed = (
        $primarySeen -and
        $sessionBindingValid -and
        $safeDiskState -and
        $traceLengthBytes -gt 0 -and
        $capturedDomainCount -gt 0 -and
        $null -ne $buffersWritten -and
        [string]$accounting.summary.evidence_completeness -cne 'failed'
    )

    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        authority = 'nxb-bounded-trigger-capture-v1'
        status = if ($capturePassed) { 'passed' } else { 'failed' }
        head_sha = $expected
        session_id = [string]$finalState.session_id
        session_binding_valid = $sessionBindingValid
        policy_id = [string]$finalState.policy_id
        policy_fingerprint_sha256 = [string]$finalState.policy_fingerprint_sha256
        primary_plan_fingerprint_sha256 = [string]$finalState.primary_plan_fingerprint_sha256
        plan_fingerprint_sha256 = [string]$finalState.plan_fingerprint_sha256
        target_trigger_id = $TriggerId
        primary_trigger = $finalState.primary_trigger
        selected_trigger = $finalState.selected_trigger
        trigger_history = @($finalState.trigger_history)
        trigger_history_dropped_count = [int]$finalState.history_dropped_count
        trigger_utc = $finalState.trigger_utc
        capture_mode_before_trigger = 'Memory'
        capture_mode_after_trigger = 'Memory'
        requested_pretrigger_seconds = [int]$finalState.requested_pretrigger_seconds
        requested_posttrigger_seconds = [int]$finalState.requested_posttrigger_seconds
        effective_pretrigger_seconds = [int]$finalState.effective_pretrigger_seconds
        effective_posttrigger_seconds = [int]$finalState.effective_posttrigger_seconds
        observed_pretrigger_seconds = [double]$finalState.observed_pretrigger_seconds
        observed_posttrigger_seconds = [double]$finalState.observed_posttrigger_seconds
        window_clamped = [bool]$finalState.window_clamped
        coalesced_trigger_count = [int]$finalState.coalesced_trigger_count
        rejected_trigger_count = [int]$finalState.rejected_trigger_count
        truncation = [bool]$finalState.truncation
        termination_reason = [string]$finalState.termination_reason
        normal_window_termination = $normalTermination
        budgets = [pscustomobject][ordered]@{
            max_session_seconds = [int]$finalState.max_session_seconds
            memory_buffer_budget_mib = $memoryBudgetMiB
            policy_max_disk_mb_per_hour = $policyDiskBudgetMiB
            output_hard_budget_mib = $outputHardBudgetMiB
            trace_length_bytes = $traceLengthBytes
            disk_state = $diskBudgetState
            state_budget = [string]$finalState.budget_state
            minimum_free_disk_mib_required = $MinimumFreeDiskMiB
            minimum_free_disk_mib_observed = [Math]::Round($minimumObservedFreeDiskMiB,3)
        }
        domain_accounting = $domainAccounting
        domain_coverage = $coverageStatus
        complete_domain_coverage = ($coverageStatus -ceq 'complete')
        captured_domain_count = $capturedDomainCount
        uncaptured_domain_count = $uncapturedDomainCount
        sample_accounting = [pscustomobject][ordered]@{
            configured_buffer_capacity = $configuredBuffers
            expected_minimum_buffers = 1
            observed_buffers_written = $buffersWritten
            dropped_event_count = $eventsLost
            dropped_buffer_count = $buffersLost
            realtime_dropped_buffer_count = $realtimeBuffersLost
            estimated_overwritten_buffer_count = $estimatedOverwrittenBuffers
            overwrite_estimation = 'max(0,buffers_written-configured_buffer_capacity)'
            counter_source = 'TRACE_LOGFILE_HEADER/xperf accounting'
        }
        privacy = [pscustomobject][ordered]@{
            raw_identifiers = [bool]$policy.privacy.raw_identifiers
            formatted_messages = [bool]$policy.privacy.formatted_messages
            payload_fields = [bool]$policy.privacy.payload_fields
            network_payload = [bool]$policy.privacy.network_payload
        }
        evidence = [pscustomobject][ordered]@{
            etl_sha256 = ([string]$traceMetadata.sha256).ToLowerInvariant()
            trace_metadata_sha256 = (Get-FileHash -LiteralPath $traceMetadataPath -Algorithm SHA256).Hash.ToLowerInvariant()
            trace_session_sha256 = $sessionSha
            trace_loss_accounting_sha256 = $accountingSha
            post_stop_statistics_sha256 = $statisticsSha
            profile_sha256 = [string]$session.profile_provenance.sha256
            profile_provenance_sha256 = [string]$session.profile_provenance_sha256
        }
    }

    Write-NxbJsonAtomic -Path $receiptPath -InputObject $receipt -Depth 32
    $receiptSha = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()

    if ($capturePassed) {
        $finalState = Invoke-NxbBoundedState -ActionName Complete -Extra @{ EvidenceSha256 = $receiptSha }
    }
    else {
        $failureDetail = ('Bounded trigger capture finalized but did not satisfy PASS contract: trigger={0} disk={1} coverage={2} buffers_written={3} accounting={4}' -f $primarySeen,$diskBudgetState,$coverageStatus,$buffersWritten,[string]$accounting.summary.evidence_completeness)
        $finalState = Invoke-NxbBoundedState -ActionName Fail -Extra @{ FailureReason = $failureDetail; EvidenceSha256 = $receiptSha }
        throw $failureDetail
    }

    $result = [pscustomobject][ordered]@{
        status = 'passed'
        authority = 'nxb-bounded-trigger-capture-v1'
        head_sha = $expected
        session_id = $boundedSessionId
        receipt_path = $receiptPath
        receipt_sha256 = $receiptSha
        etl_sha256 = ([string]$traceMetadata.sha256).ToLowerInvariant()
        memory_buffer_budget_mib = $memoryBudgetMiB
        observed_pretrigger_seconds = [double]$receipt.observed_pretrigger_seconds
        observed_posttrigger_seconds = [double]$receipt.observed_posttrigger_seconds
        domain_coverage = $coverageStatus
        coalesced_trigger_count = [int]$receipt.coalesced_trigger_count
        rejected_trigger_count = [int]$receipt.rejected_trigger_count
        truncation = [bool]$receipt.truncation
        review_safe_json = $true
    }
    if ($PassThru) { return $result }
    $result | ConvertTo-Json -Depth 12
}
catch {
    $failure = $_.Exception.Message
    if ($traceStarted -and -not $traceStopped) {
        try {
            $wpr = Resolve-NxbExecutablePath -Name 'wpr.exe' -ExplicitPath $WprExecutablePath
            $cancelOutput = & $wpr -cancel 2>&1
            $cancelExit = $LASTEXITCODE
            $idleExit = -984076288
            if ($cancelExit -ne 0 -and $cancelExit -ne $idleExit) {
                Write-Warning ('Bounded capture WPR cleanup failed: exit={0} output={1}' -f $cancelExit,($cancelOutput -join [Environment]::NewLine))
            }
        }
        catch {
            Write-Warning ('Bounded capture WPR cleanup could not run: {0}' -f $_.Exception.Message)
        }
    }
    if (Test-Path -LiteralPath $boundedStatePath -PathType Leaf) {
        try {
            $currentFailureState = Get-Content -LiteralPath $boundedStatePath -Raw | ConvertFrom-Json
            if ([string]$currentFailureState.state -notin @('failed','completed')) {
                [void](Invoke-NxbBoundedState -ActionName Fail -Extra @{ FailureReason = $failure })
            }
        }
        catch { Write-Warning ('Bounded capture failure state could not be written: {0}' -f $_.Exception.Message) }
    }
    throw
}