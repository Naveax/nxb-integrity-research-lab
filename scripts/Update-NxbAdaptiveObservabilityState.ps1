[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PolicyPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SignalsPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StatePath,
    [Parameter()][DateTime]$NowUtc = ([DateTime]::UtcNow),
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbAdaptiveStateCondition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Trigger,
        [Parameter(Mandatory)][object]$Signals
    )
    if (-not [bool]$Trigger.enabled) { return $false }
    $signalProperty = $Signals.PSObject.Properties[[string]$Trigger.signal]
    $present = ($null -ne $signalProperty)
    if ([string]$Trigger.operator -ceq 'present') { return $present }
    if (-not $present) { return $false }
    $actual = $signalProperty.Value
    $expected = $Trigger.threshold
    switch ([string]$Trigger.operator) {
        'eq' { return ($actual -eq $expected) }
        'ne' { return ($actual -ne $expected) }
        'gt' { return ([double]$actual -gt [double]$expected) }
        'ge' { return ([double]$actual -ge [double]$expected) }
        'lt' { return ([double]$actual -lt [double]$expected) }
        'le' { return ([double]$actual -le [double]$expected) }
        'changed' { return [bool]$actual }
        default { throw ('Unsupported trigger operator: {0}' -f $Trigger.operator) }
    }
}

function ConvertTo-NxbAdaptiveStateUtc {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return [DateTime]::MinValue }
    return [DateTime]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToUniversalTime()
}

function Get-NxbAdaptivePreviousTriggerState {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$PreviousState,
        [Parameter(Mandatory)][string]$TriggerId
    )
    if ($null -eq $PreviousState) { return $null }
    return @($PreviousState.triggers | Where-Object { [string]$_.id -ceq $TriggerId } | Select-Object -First 1)
}

$policyFull = [IO.Path]::GetFullPath($PolicyPath)
$signalsFull = [IO.Path]::GetFullPath($SignalsPath)
$stateFull = [IO.Path]::GetFullPath($StatePath)
if (-not (Test-Path -LiteralPath $policyFull -PathType Leaf)) { throw ('Policy missing: {0}' -f $policyFull) }
if (-not (Test-Path -LiteralPath $signalsFull -PathType Leaf)) { throw ('Signals missing: {0}' -f $signalsFull) }

$policy = Get-Content -LiteralPath $policyFull -Raw | ConvertFrom-Json
$signals = Get-Content -LiteralPath $signalsFull -Raw | ConvertFrom-Json
$previousState = $null
if (Test-Path -LiteralPath $stateFull -PathType Leaf) {
    try { $previousState = Get-Content -LiteralPath $stateFull -Raw | ConvertFrom-Json }
    catch { Write-Verbose -Message 'Previous adaptive trigger state is unreadable; starting from empty state.' }
}

$now = $NowUtc.ToUniversalTime()
$triggerStates = [Collections.Generic.List[object]]::new()
foreach ($trigger in @($policy.triggers | Sort-Object -Property @{Expression='priority';Descending=$true}, @{Expression='id';Descending=$false})) {
    $id = [string]$trigger.id
    $previousItems = @(Get-NxbAdaptivePreviousTriggerState -PreviousState $previousState -TriggerId $id)
    $previous = $null
    if ($previousItems.Count -gt 0) { $previous = $previousItems[0] }
    $wasActive = $false
    $previousHoldUntil = [DateTime]::MinValue
    $previousCooldownUntil = [DateTime]::MinValue
    $lastMatchUtc = $null
    $lastTransitionUtc = $null
    if ($null -ne $previous) {
        $wasActive = [bool]$previous.active
        $previousHoldUntil = ConvertTo-NxbAdaptiveStateUtc -Value $previous.hold_until_utc
        $previousCooldownUntil = ConvertTo-NxbAdaptiveStateUtc -Value $previous.cooldown_until_utc
        $lastMatchUtc = $previous.last_match_utc
        $lastTransitionUtc = $previous.last_transition_utc
    }

    $matched = Test-NxbAdaptiveStateCondition -Trigger $trigger -Signals $signals
    $active = $wasActive
    $holdUntil = $previousHoldUntil
    $cooldownUntil = $previousCooldownUntil
    $transition = 'none'

    if ($wasActive) {
        if ($matched) {
            $candidateHold = $now.AddSeconds([int]$trigger.hold_seconds)
            if ($candidateHold -gt $holdUntil) { $holdUntil = $candidateHold }
            $lastMatchUtc = $now.ToString('o')
        }
        elseif ($now -ge $holdUntil) {
            $active = $false
            $cooldownUntil = $now.AddSeconds([int]$trigger.cooldown_seconds)
            $lastTransitionUtc = $now.ToString('o')
            $transition = 'deactivated'
        }
    }
    elseif ($matched -and $now -ge $cooldownUntil) {
        $active = $true
        $holdUntil = $now.AddSeconds([int]$trigger.hold_seconds)
        $lastMatchUtc = $now.ToString('o')
        $lastTransitionUtc = $now.ToString('o')
        $transition = 'activated'
    }

    $holdText = $null
    if ($holdUntil -ne [DateTime]::MinValue) { $holdText = $holdUntil.ToString('o') }
    $cooldownText = $null
    if ($cooldownUntil -ne [DateTime]::MinValue) { $cooldownText = $cooldownUntil.ToString('o') }

    $triggerStates.Add([pscustomobject][ordered]@{
        id = $id
        priority = [int]$trigger.priority
        matched_now = $matched
        active = $active
        transition = $transition
        hold_until_utc = $holdText
        cooldown_until_utc = $cooldownText
        last_match_utc = $lastMatchUtc
        last_transition_utc = $lastTransitionUtc
    })
}

$activeIds = @($triggerStates | Where-Object { [bool]$_.active } | ForEach-Object { [string]$_.id })
$result = [pscustomobject][ordered]@{
    schema_version = 1
    evaluated_utc = $now.ToString('o')
    policy_id = [string]$policy.policy_id
    active_trigger_ids = $activeIds
    triggers = @($triggerStates.ToArray())
}

$parent = Split-Path -Parent $stateFull
if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText(
    $stateFull,
    (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 20
