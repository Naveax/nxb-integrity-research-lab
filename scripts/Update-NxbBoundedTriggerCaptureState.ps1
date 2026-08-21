[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PolicyPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StatePath,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateSet('Arm','Trigger','Tick','EmergencyStop','BudgetExhausted','Complete','Fail')][string]$Action,

    [Parameter()][AllowNull()][Nullable[int]]$RequestedPreTriggerSeconds,
    [Parameter()][AllowNull()][Nullable[int]]$RequestedPostTriggerSeconds,
    [Parameter()][ValidateRange(1,128)][int]$MaxCoalescedTriggers = 32,
    [Parameter()][ValidateRange(1,256)][int]$MaxTriggerHistory = 64,

    [Parameter()][string]$TriggerId,
    [Parameter()][string]$TriggerReason,
    [Parameter()][ValidateRange(0,1000)][int]$TriggerPriority = 0,
    [Parameter()][string]$PlanFingerprintSha256,
    [Parameter()][string[]]$Domains = @(),
    [Parameter()][string]$BudgetReason = 'budget_exhausted',
    [Parameter()][string]$EvidenceSha256,
    [Parameter()][string]$FailureReason,

    [Parameter()][DateTime]$NowUtc = ([DateTime]::UtcNow),
    [Parameter()][long]$MonotonicTicks = -1,
    [Parameter()][long]$MonotonicFrequency = -1,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'Nxb.Lab.Common.psm1') -Force

function ConvertTo-NxbBoundedUtc {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Value)
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    return [DateTime]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
}

function Add-NxbBoundedHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$State,
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][int]$Maximum
    )
    $history = [Collections.Generic.List[object]]::new()
    foreach ($item in @($State.trigger_history)) { $history.Add($item) }
    if ($history.Count -lt $Maximum) { $history.Add($Entry) }
    $State.trigger_history = @($history.ToArray())
}

function Set-NxbBoundedProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][AllowNull()][object]$Value
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        $Object | Add-Member -MemberType NoteProperty -Name $Name -Value $Value
    }
    else {
        $property.Value = $Value
    }
}

$policyFull = [IO.Path]::GetFullPath($PolicyPath)
$stateFull = [IO.Path]::GetFullPath($StatePath)
if (-not (Test-Path -LiteralPath $policyFull -PathType Leaf)) { throw ('Policy missing: {0}' -f $policyFull) }
$policy = Get-Content -LiteralPath $policyFull -Raw | ConvertFrom-Json
if ([int]$policy.schema_version -ne 1) { throw 'Unsupported adaptive observability policy schema.' }
if ($null -eq $policy.budgets) { throw 'Adaptive policy budgets are missing.' }

$policyPre = [int]$policy.budgets.pretrigger_seconds
$policyPost = [int]$policy.budgets.posttrigger_seconds
$policySession = [int]$policy.budgets.max_session_seconds
if ($policyPre -lt 0 -or $policyPre -gt 300) { throw 'Policy pretrigger_seconds is outside the bounded schema range.' }
if ($policyPost -lt 0 -or $policyPost -gt 3600) { throw 'Policy posttrigger_seconds is outside the bounded schema range.' }
if ($policySession -lt 10 -or $policySession -gt 86400) { throw 'Policy max_session_seconds is outside the bounded schema range.' }

$policyFingerprint = Get-NxbCanonicalJsonHash -InputObject $policy
$now = $NowUtc.ToUniversalTime()
if ($MonotonicFrequency -le 0) { $MonotonicFrequency = [Diagnostics.Stopwatch]::Frequency }
if ($MonotonicTicks -lt 0) { $MonotonicTicks = [Diagnostics.Stopwatch]::GetTimestamp() }
if ($MonotonicFrequency -le 0 -or $MonotonicTicks -lt 0) { throw 'Monotonic clock metadata is invalid.' }

if ($Action -ceq 'Arm') {
    if (Test-Path -LiteralPath $stateFull) { throw ('Bounded capture state already exists: {0}' -f $stateFull) }

    $requestedPre = if ($null -eq $RequestedPreTriggerSeconds) { $policyPre } else { [int]$RequestedPreTriggerSeconds.Value }
    $requestedPost = if ($null -eq $RequestedPostTriggerSeconds) { $policyPost } else { [int]$RequestedPostTriggerSeconds.Value }
    if ($requestedPre -lt 0 -or $requestedPost -lt 0) { throw 'Requested capture windows cannot be negative.' }

    $effectivePre = [Math]::Min($requestedPre,$policyPre)
    $effectivePost = [Math]::Min($requestedPost,$policyPost)
    $windowClamped = ($effectivePre -ne $requestedPre -or $effectivePost -ne $requestedPost)

    $state = [pscustomobject][ordered]@{
        schema_version = 1
        authority = 'nxb-bounded-trigger-capture-state-v1'
        state = 'armed'
        expected_head = $ExpectedHead.ToLowerInvariant()
        session_id = [Guid]::NewGuid().ToString('D')
        policy_id = [string]$policy.policy_id
        policy_fingerprint_sha256 = $policyFingerprint
        requested_pretrigger_seconds = $requestedPre
        requested_posttrigger_seconds = $requestedPost
        effective_pretrigger_seconds = $effectivePre
        effective_posttrigger_seconds = $effectivePost
        max_session_seconds = $policySession
        window_clamped = $windowClamped
        armed_utc = $now.ToString('o')
        armed_monotonic_ticks = $MonotonicTicks
        monotonic_frequency = $MonotonicFrequency
        last_monotonic_ticks = $MonotonicTicks
        hard_deadline_utc = $now.AddSeconds($policySession).ToString('o')
        trigger_utc = $null
        trigger_monotonic_ticks = $null
        observed_pretrigger_seconds = 0.0
        observed_posttrigger_seconds = 0.0
        post_deadline_utc = $null
        primary_trigger = $null
        selected_trigger = $null
        plan_fingerprint_sha256 = $null
        active_domains = @()
        coalesced_trigger_count = 0
        rejected_trigger_count = 0
        max_coalesced_triggers = $MaxCoalescedTriggers
        max_trigger_history = $MaxTriggerHistory
        trigger_history = @()
        truncation = $false
        budget_state = 'normal'
        termination_reason = $null
        evidence_sha256 = $null
        completed_utc = $null
        failure_reason = $null
    }

    $parent = Split-Path -Parent $stateFull
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    Write-NxbJsonAtomic -Path $stateFull -InputObject $state -Depth 24
    if ($PassThru) { return $state }
    $state | ConvertTo-Json -Depth 24
    return
}

if (-not (Test-Path -LiteralPath $stateFull -PathType Leaf)) { throw ('Bounded capture state missing: {0}' -f $stateFull) }
$state = Get-Content -LiteralPath $stateFull -Raw | ConvertFrom-Json
if ([int]$state.schema_version -ne 1 -or [string]$state.authority -cne 'nxb-bounded-trigger-capture-state-v1') {
    throw 'Unsupported bounded capture state contract.'
}
if ([string]$state.expected_head -cne $ExpectedHead.ToLowerInvariant()) { throw 'Bounded capture exact-head binding is stale.' }
if ([string]$state.policy_fingerprint_sha256 -cne $policyFingerprint) { throw 'Bounded capture policy fingerprint is stale.' }
if ([long]$state.monotonic_frequency -ne $MonotonicFrequency) { throw 'Bounded capture monotonic clock frequency drifted.' }
if ($MonotonicTicks -lt [long]$state.last_monotonic_ticks) { throw 'Bounded capture monotonic timestamp ordering violation.' }
Set-NxbBoundedProperty -Object $state -Name 'last_monotonic_ticks' -Value $MonotonicTicks

$hardDeadline = ConvertTo-NxbBoundedUtc -Value $state.hard_deadline_utc

switch ($Action) {
    'Trigger' {
        if ([string]::IsNullOrWhiteSpace($TriggerId)) { throw 'TriggerId is required for Trigger action.' }
        if ([string]::IsNullOrWhiteSpace($TriggerReason)) { throw 'TriggerReason is required for Trigger action.' }
        if ([string]$PlanFingerprintSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'PlanFingerprintSha256 is required for Trigger action.' }
        $normalizedPlanFingerprint = $PlanFingerprintSha256.ToLowerInvariant()
        $domainSet = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
        foreach ($domain in @($Domains)) {
            if ([string]::IsNullOrWhiteSpace([string]$domain)) { throw 'Trigger domains cannot contain empty values.' }
            [void]$domainSet.Add([string]$domain)
        }
        if ($domainSet.Count -eq 0) { throw 'At least one trigger domain is required.' }

        if ([string]$state.state -ceq 'armed') {
            $armedTicks = [long]$state.armed_monotonic_ticks
            $elapsedPre = [double]($MonotonicTicks - $armedTicks) / [double]$MonotonicFrequency
            if ($elapsedPre -lt 0) { throw 'Observed pre-trigger duration cannot be negative.' }
            $observedPre = [Math]::Min([double]$state.effective_pretrigger_seconds,$elapsedPre)
            $remainingSession = [Math]::Max(0.0,($hardDeadline - $now).TotalSeconds)
            $effectivePost = [Math]::Min([double]$state.effective_posttrigger_seconds,$remainingSession)
            $postDeadline = $now.AddSeconds($effectivePost)

            Set-NxbBoundedProperty -Object $state -Name 'trigger_utc' -Value $now.ToString('o')
            Set-NxbBoundedProperty -Object $state -Name 'trigger_monotonic_ticks' -Value $MonotonicTicks
            Set-NxbBoundedProperty -Object $state -Name 'observed_pretrigger_seconds' -Value $observedPre
            Set-NxbBoundedProperty -Object $state -Name 'post_deadline_utc' -Value $postDeadline.ToString('o')
            Set-NxbBoundedProperty -Object $state -Name 'plan_fingerprint_sha256' -Value $normalizedPlanFingerprint
            Set-NxbBoundedProperty -Object $state -Name 'active_domains' -Value @($domainSet)

            $triggerRecord = [pscustomobject][ordered]@{
                id = $TriggerId
                reason = $TriggerReason
                priority = $TriggerPriority
                utc = $now.ToString('o')
                monotonic_ticks = $MonotonicTicks
                disposition = 'primary'
            }
            Set-NxbBoundedProperty -Object $state -Name 'primary_trigger' -Value $triggerRecord
            Set-NxbBoundedProperty -Object $state -Name 'selected_trigger' -Value $triggerRecord
            Add-NxbBoundedHistory -State $state -Entry $triggerRecord -Maximum ([int]$state.max_trigger_history)

            if ($effectivePost -le 0) {
                Set-NxbBoundedProperty -Object $state -Name 'state' -Value 'finalizing'
                Set-NxbBoundedProperty -Object $state -Name 'termination_reason' -Value 'zero_post_window'
            }
            else {
                Set-NxbBoundedProperty -Object $state -Name 'state' -Value 'post_capture'
            }
        }
        elseif ([string]$state.state -ceq 'post_capture') {
            if ([string]$state.plan_fingerprint_sha256 -cne $normalizedPlanFingerprint) { throw 'Bounded capture plan fingerprint is stale during overlap.' }
            $historyRecord = [pscustomobject][ordered]@{
                id = $TriggerId
                reason = $TriggerReason
                priority = $TriggerPriority
                utc = $now.ToString('o')
                monotonic_ticks = $MonotonicTicks
                disposition = $null
            }
            if ([int]$state.coalesced_trigger_count -lt [int]$state.max_coalesced_triggers) {
                Set-NxbBoundedProperty -Object $state -Name 'coalesced_trigger_count' -Value ([int]$state.coalesced_trigger_count + 1)
                $historyRecord.disposition = 'coalesced'
                $currentDeadline = ConvertTo-NxbBoundedUtc -Value $state.post_deadline_utc
                $candidateDeadline = $now.AddSeconds([double]$state.effective_posttrigger_seconds)
                if ($candidateDeadline -gt $hardDeadline) { $candidateDeadline = $hardDeadline }
                if ($candidateDeadline -gt $currentDeadline) {
                    Set-NxbBoundedProperty -Object $state -Name 'post_deadline_utc' -Value $candidateDeadline.ToString('o')
                }
                if ($TriggerPriority -gt [int]$state.selected_trigger.priority) {
                    Set-NxbBoundedProperty -Object $state -Name 'selected_trigger' -Value $historyRecord
                }
            }
            else {
                Set-NxbBoundedProperty -Object $state -Name 'rejected_trigger_count' -Value ([int]$state.rejected_trigger_count + 1)
                $historyRecord.disposition = 'rejected_storm_limit'
            }
            Add-NxbBoundedHistory -State $state -Entry $historyRecord -Maximum ([int]$state.max_trigger_history)
        }
        else {
            throw ('Trigger action is invalid in bounded capture state: {0}' -f [string]$state.state)
        }
    }

    'Tick' {
        if ([string]$state.state -ceq 'armed' -and $now -ge $hardDeadline) {
            Set-NxbBoundedProperty -Object $state -Name 'state' -Value 'finalizing'
            Set-NxbBoundedProperty -Object $state -Name 'truncation' -Value $true
            Set-NxbBoundedProperty -Object $state -Name 'budget_state' -Value 'session_budget_exhausted'
            Set-NxbBoundedProperty -Object $state -Name 'termination_reason' -Value 'trigger_timeout'
        }
        elseif ([string]$state.state -ceq 'post_capture') {
            $triggerTicks = [long]$state.trigger_monotonic_ticks
            $observedPost = [Math]::Max(0.0,[double]($MonotonicTicks - $triggerTicks) / [double]$MonotonicFrequency)
            Set-NxbBoundedProperty -Object $state -Name 'observed_posttrigger_seconds' -Value $observedPost
            if ($now -ge $hardDeadline) {
                Set-NxbBoundedProperty -Object $state -Name 'state' -Value 'finalizing'
                Set-NxbBoundedProperty -Object $state -Name 'truncation' -Value $true
                Set-NxbBoundedProperty -Object $state -Name 'budget_state' -Value 'session_budget_exhausted'
                Set-NxbBoundedProperty -Object $state -Name 'termination_reason' -Value 'session_budget_exhausted'
            }
            elseif ($now -ge (ConvertTo-NxbBoundedUtc -Value $state.post_deadline_utc)) {
                Set-NxbBoundedProperty -Object $state -Name 'state' -Value 'finalizing'
                Set-NxbBoundedProperty -Object $state -Name 'termination_reason' -Value 'post_window_complete'
            }
        }
    }

    'EmergencyStop' {
        if (@('armed','post_capture') -cnotcontains [string]$state.state) { throw ('EmergencyStop is invalid in state: {0}' -f [string]$state.state) }
        if ($null -ne $state.trigger_monotonic_ticks) {
            $observedPost = [Math]::Max(0.0,[double]($MonotonicTicks - [long]$state.trigger_monotonic_ticks) / [double]$MonotonicFrequency)
            Set-NxbBoundedProperty -Object $state -Name 'observed_posttrigger_seconds' -Value $observedPost
        }
        Set-NxbBoundedProperty -Object $state -Name 'state' -Value 'finalizing'
        Set-NxbBoundedProperty -Object $state -Name 'truncation' -Value $true
        Set-NxbBoundedProperty -Object $state -Name 'termination_reason' -Value 'emergency_stop'
    }

    'BudgetExhausted' {
        if (@('armed','post_capture') -cnotcontains [string]$state.state) { throw ('BudgetExhausted is invalid in state: {0}' -f [string]$state.state) }
        if ($null -ne $state.trigger_monotonic_ticks) {
            $observedPost = [Math]::Max(0.0,[double]($MonotonicTicks - [long]$state.trigger_monotonic_ticks) / [double]$MonotonicFrequency)
            Set-NxbBoundedProperty -Object $state -Name 'observed_posttrigger_seconds' -Value $observedPost
        }
        Set-NxbBoundedProperty -Object $state -Name 'state' -Value 'finalizing'
        Set-NxbBoundedProperty -Object $state -Name 'truncation' -Value $true
        Set-NxbBoundedProperty -Object $state -Name 'budget_state' -Value $BudgetReason
        Set-NxbBoundedProperty -Object $state -Name 'termination_reason' -Value $BudgetReason
    }

    'Complete' {
        if ([string]$state.state -cne 'finalizing') { throw ('Complete is invalid in state: {0}' -f [string]$state.state) }
        if ([string]$EvidenceSha256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'EvidenceSha256 is required for Complete action.' }
        Set-NxbBoundedProperty -Object $state -Name 'state' -Value 'completed'
        Set-NxbBoundedProperty -Object $state -Name 'evidence_sha256' -Value $EvidenceSha256.ToLowerInvariant()
        Set-NxbBoundedProperty -Object $state -Name 'completed_utc' -Value $now.ToString('o')
    }

    'Fail' {
        if ([string]::IsNullOrWhiteSpace($FailureReason)) { throw 'FailureReason is required for Fail action.' }
        Set-NxbBoundedProperty -Object $state -Name 'state' -Value 'failed'
        Set-NxbBoundedProperty -Object $state -Name 'truncation' -Value $true
        Set-NxbBoundedProperty -Object $state -Name 'termination_reason' -Value 'failure'
        Set-NxbBoundedProperty -Object $state -Name 'failure_reason' -Value $FailureReason
        Set-NxbBoundedProperty -Object $state -Name 'completed_utc' -Value $now.ToString('o')
    }
}

Write-NxbJsonAtomic -Path $stateFull -InputObject $state -Depth 24
if ($PassThru) { return $state }
$state | ConvertTo-Json -Depth 24
