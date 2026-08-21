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
        Action = $ActionName
        MaxCoalescedTriggers = $MaxCoalescedTriggers
        PassThru = $true
    }
    foreach ($key in $Extra.Keys) { $arguments[$key] = $Extra[$key] }
    return & (Join-Path $PSScriptRoot 'Update-NxbBoundedTriggerCaptureState.ps1') @arguments
}

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$experimentFull = Get-NxbFullPath -Path $ExperimentPath
$signalsFull = [IO.Path]::GetFullPath($SignalsPath)
$policyFull = [IO.Path]::GetFullPath($PolicyPath)
$expected = $ExpectedHead.ToLowerInvariant()

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
$targetTriggers = @($policy.triggers | Where-Object { [string]$_.id -ceq $TriggerId })
if ($targetTriggers.Count -ne 1) { throw ('TriggerId must resolve to exactly one policy trigger: {0}' -f $TriggerId) }
$targetTrigger = $targetTriggers[0]
if (-not [bool]$targetTrigger.enabled) { throw ('Target trigger is disabled: {0}' -f $TriggerId) }

$analysisRoot = Join-Path $experimentFull 'analysis'
[IO.Directory]::CreateDirectory($analysisRoot) | Out-Null
$boundedStatePath = Join-Path $analysisRoot 'bounded-trigger-capture-state.json'
$adaptiveStatePath = Join-Path $analysisRoot 'bounded-adaptive-trigger-state.json'
$livePlanPath = Join-Path $analysisRoot 'bounded-adaptive-plan.json'
$receiptPath = Join-Path $analysisRoot 'bounded-trigger-capture-receipt.json'
foreach ($path in @($boundedStatePath,$adaptiveStatePath,$livePlanPath,$receiptPath)) {
    if (Test-Path -LiteralPath $path) { throw ('Bounded capture output already exists: {0}' -f $path) }
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
        -WprExecutablePath $WprExecutablePath `
        -PassThru
    $traceStarted = $true

    $armExtra = @{}
    if ($null -ne $RequestedPreTriggerSeconds) { $armExtra.RequestedPreTriggerSeconds = [int]$RequestedPreTriggerSeconds.Value }
    if ($null -ne $RequestedPostTriggerSeconds) { $armExtra.RequestedPostTriggerSeconds = [int]$RequestedPostTriggerSeconds.Value }
    $finalState = Invoke-NxbBoundedState -ActionName Arm -Extra $armExtra

    while ([string]$finalState.state -notin @('finalizing','completed','failed')) {
        if (-not [string]::IsNullOrWhiteSpace($EmergencyStopPath) -and (Test-Path -LiteralPath $EmergencyStopPath -PathType Leaf)) {
            $finalState = Invoke-NxbBoundedState -ActionName EmergencyStop
            break
        }

        # The signals document is intentionally re-read each iteration so an external
        # observer can atomically publish trigger changes while the bounded Memory WPR
        # ring is already armed.
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

    if ([string]$session.profile_provenance.logging_mode -cne 'Memory' -or -not [bool]$session.profile_provenance.bounded) {
        throw 'Bounded trigger capture did not finalize a bounded Memory WPR session.'
    }
    $memoryBudgetMiB = [int]$session.profile_provenance.memory_buffer_budget_mib
    if ($memoryBudgetMiB -ne 64) { throw ('Bounded trigger memory budget drift: {0} MiB' -f $memoryBudgetMiB) }

    $policyDiskBudgetMiB = [int]$policy.budgets.max_disk_mb_per_hour
    $outputHardBudgetMiB = [Math]::Min($policyDiskBudgetMiB,$memoryBudgetMiB + 8)
    $traceLengthBytes = [int64]$traceMetadata.length
    $outputBudgetBytes = [int64]$outputHardBudgetMiB * 1MB
    $diskBudgetState = if ($traceLengthBytes -le $outputBudgetBytes) { 'within_budget' } else { 'exceeded' }

    $eventsLost = Get-NxbBoundedCounterValue -Counter $statistics.events_lost
    $buffersLost = Get-NxbBoundedCounterValue -Counter $statistics.buffers_lost
    $buffersWritten = Get-NxbBoundedCounterValue -Counter $statistics.buffers_written
    $realtimeBuffersLost = Get-NxbBoundedCounterValue -Counter $statistics.realtime_buffers_lost

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
    $uncapturedDomainCount = @($domainAccounting | Where-Object { [string]$_.status -cne 'captured' }).Count

    $accountingSha = (Get-FileHash -LiteralPath $stopResult.AccountingPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $statisticsSha = (Get-FileHash -LiteralPath $stopResult.PostStopStatisticsPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $sessionSha = (Get-FileHash -LiteralPath $sessionPath -Algorithm SHA256).Hash.ToLowerInvariant()

    $normalTermination = ([string]$finalState.termination_reason -ceq 'post_window_complete' -or [string]$finalState.termination_reason -ceq 'zero_post_window')
    $capturePassed = ($primarySeen -and $diskBudgetState -ceq 'within_budget' -and $uncapturedDomainCount -eq 0 -and [string]$accounting.summary.evidence_completeness -cne 'failed')

    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        authority = 'nxb-bounded-trigger-capture-v1'
        status = if ($capturePassed) { 'passed' } else { 'failed' }
        head_sha = $expected
        session_id = [string]$finalState.session_id
        policy_id = [string]$finalState.policy_id
        policy_fingerprint_sha256 = [string]$finalState.policy_fingerprint_sha256
        plan_fingerprint_sha256 = [string]$finalState.plan_fingerprint_sha256
        target_trigger_id = $TriggerId
        primary_trigger = $finalState.primary_trigger
        selected_trigger = $finalState.selected_trigger
        trigger_history = @($finalState.trigger_history)
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
        }
        domain_accounting = $domainAccounting
        complete_domain_coverage = ($uncapturedDomainCount -eq 0)
        sample_accounting = [pscustomobject][ordered]@{
            expected_minimum_buffers = 1
            observed_buffers_written = $buffersWritten
            events_lost = $eventsLost
            buffers_lost = $buffersLost
            realtime_buffers_lost = $realtimeBuffersLost
            counter_source = 'TRACE_LOGFILE_HEADER/xperf accounting'
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
    $finalState = Invoke-NxbBoundedState -ActionName Complete -Extra @{ EvidenceSha256 = $receiptSha }

    if (-not $capturePassed) {
        throw ('Bounded trigger capture finalized but did not satisfy PASS contract: trigger={0} disk={1} uncaptured_domains={2} accounting={3}' -f $primarySeen,$diskBudgetState,$uncapturedDomainCount,[string]$accounting.summary.evidence_completeness)
    }

    $result = [pscustomobject][ordered]@{
        status = 'passed'
        authority = 'nxb-bounded-trigger-capture-v1'
        head_sha = $expected
        receipt_path = $receiptPath
        receipt_sha256 = $receiptSha
        etl_sha256 = ([string]$traceMetadata.sha256).ToLowerInvariant()
        memory_buffer_budget_mib = $memoryBudgetMiB
        observed_pretrigger_seconds = [double]$receipt.observed_pretrigger_seconds
        observed_posttrigger_seconds = [double]$receipt.observed_posttrigger_seconds
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
        try { [void](Invoke-NxbBoundedState -ActionName Fail -Extra @{ FailureReason = $failure }) }
        catch { Write-Warning ('Bounded capture failure state could not be written: {0}' -f $_.Exception.Message) }
    }
    throw
}
