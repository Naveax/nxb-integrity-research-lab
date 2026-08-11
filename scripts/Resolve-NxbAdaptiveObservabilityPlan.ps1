[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PolicyPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SignalsPath,
    [Parameter()][ValidateNotNullOrEmpty()][string]$TriggerStatePath,
    [Parameter()][ValidateSet('off','minimal','normal','deep','forensic')][string]$OperatorMode,
    [Parameter()][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ModeOrder = @('off','minimal','normal','deep','forensic')
$DomainOrder = @(
    'cpu','memory','storage','gpu','network','pnp','pcie','kernel','registry',
    'power','thermal','firmware','security','correlation'
)

function Get-NxbModeRank {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Mode)
    $rank = [Array]::IndexOf($ModeOrder,$Mode)
    if ($rank -lt 0) { throw "Unknown mode: $Mode" }
    return $rank
}

function Get-NxbSha256Text {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally { $sha.Dispose() }
}

function Test-NxbTriggerCondition {
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
        default { throw "Unsupported trigger operator: $($Trigger.operator)" }
    }
}

function Get-NxbStableUniqueDomain {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Domains)
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $ordered = [Collections.Generic.List[string]]::new()
    foreach ($domain in $Domains) {
        if ([Array]::IndexOf($DomainOrder,$domain) -lt 0) { throw "Unknown domain: $domain" }
        if ($seen.Add($domain)) { $ordered.Add($domain) }
    }
    return $ordered.ToArray()
}

$policyFull = [IO.Path]::GetFullPath($PolicyPath)
$signalsFull = [IO.Path]::GetFullPath($SignalsPath)
if (-not (Test-Path -LiteralPath $policyFull -PathType Leaf)) { throw "Policy missing: $policyFull" }
if (-not (Test-Path -LiteralPath $signalsFull -PathType Leaf)) { throw "Signals missing: $signalsFull" }

$policy = Get-Content -LiteralPath $policyFull -Raw | ConvertFrom-Json
$signals = Get-Content -LiteralPath $signalsFull -Raw | ConvertFrom-Json
if ([int]$policy.schema_version -ne 1) { throw 'Unsupported adaptive observability policy schema.' }

$stateActiveSet = $null
if (-not [string]::IsNullOrWhiteSpace($TriggerStatePath)) {
    $stateFull = [IO.Path]::GetFullPath($TriggerStatePath)
    if (-not (Test-Path -LiteralPath $stateFull -PathType Leaf)) { throw "Trigger state missing: $stateFull" }
    $triggerState = Get-Content -LiteralPath $stateFull -Raw | ConvertFrom-Json
    if ([string]$triggerState.policy_id -cne [string]$policy.policy_id) { throw 'Trigger state policy_id does not match policy.' }
    $stateActiveSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($triggerId in @($triggerState.active_trigger_ids)) { [void]$stateActiveSet.Add([string]$triggerId) }
}

$defaultRank = Get-NxbModeRank -Mode ([string]$policy.default_mode)
$maximumRank = Get-NxbModeRank -Mode ([string]$policy.maximum_mode)
if ($defaultRank -gt $maximumRank) { throw 'default_mode cannot exceed maximum_mode.' }

$effectiveRank = $defaultRank
$reasons = [Collections.Generic.List[string]]::new()
$reasons.Add("default:$($policy.default_mode)")

if (-not [string]::IsNullOrWhiteSpace($OperatorMode)) {
    $operatorRank = Get-NxbModeRank -Mode $OperatorMode
    $clampedOperatorRank = [Math]::Min($operatorRank,$maximumRank)
    if ($clampedOperatorRank -gt $effectiveRank) { $effectiveRank = $clampedOperatorRank }
    $reasons.Add("operator:$OperatorMode")
}

if ($null -ne $stateActiveSet) {
    $activeTriggers = @(
        @($policy.triggers) |
            Where-Object { [bool]$_.enabled -and $stateActiveSet.Contains([string]$_.id) } |
            Sort-Object -Property @{Expression='priority';Descending=$true}, @{Expression='id';Descending=$false}
    )
    $reasons.Add('trigger_state:authoritative')
}
else {
    $activeTriggers = @(
        @($policy.triggers) |
            Where-Object { Test-NxbTriggerCondition -Trigger $_ -Signals $signals } |
            Sort-Object -Property @{Expression='priority';Descending=$true}, @{Expression='id';Descending=$false}
    )
}

foreach ($trigger in $activeTriggers) {
    $triggerRank = Get-NxbModeRank -Mode ([string]$trigger.minimum_mode)
    $clampedTriggerRank = [Math]::Min($triggerRank,$maximumRank)
    if ($clampedTriggerRank -gt $effectiveRank) { $effectiveRank = $clampedTriggerRank }
    $reasons.Add("trigger:$($trigger.id)")
}

$effectiveMode = $ModeOrder[$effectiveRank]
$profile = $policy.mode_profiles.PSObject.Properties[$effectiveMode].Value

# Domain candidates intentionally preserve semantic priority: highest-priority active
# triggers first, then the selected mode profile as a fallback. The global domain
# budget is applied only after this stable first-occurrence ordering is built.
$domainCandidates = [Collections.Generic.List[string]]::new()
foreach ($trigger in $activeTriggers) {
    foreach ($domain in @($trigger.domains)) { $domainCandidates.Add([string]$domain) }
}
foreach ($domain in @($profile.domains)) { $domainCandidates.Add([string]$domain) }

$orderedDomains = @(Get-NxbStableUniqueDomain -Domains $domainCandidates.ToArray())
$maxDomains = [int]$policy.budgets.max_concurrent_domains
if ($orderedDomains.Count -gt $maxDomains) {
    $orderedDomains = @($orderedDomains | Select-Object -First $maxDomains)
    $reasons.Add('budget:max_concurrent_domains')
}

$eventRate = [Math]::Min([int]$profile.max_event_rate_per_second,[int]$policy.budgets.max_event_rate_per_second)
$diskBudget = [Math]::Min([int]$profile.max_disk_mb_per_hour,[int]$policy.budgets.max_disk_mb_per_hour)
$detail = [string]$profile.detail
if ($detail -ceq 'payload' -and -not [bool]$policy.privacy.payload_fields) {
    $detail = 'semantic'
    $reasons.Add('privacy:payload_fields_clamped')
}

$pendingClaims = @(
    @($policy.claim_targets) |
        Where-Object { [bool]$_.target_requested -and -not [bool]$_.validated } |
        ForEach-Object { [string]$_.name } |
        Sort-Object
)
$validatedClaims = @(
    @($policy.claim_targets) |
        Where-Object { [bool]$_.validated } |
        ForEach-Object { [string]$_.name } |
        Sort-Object
)

$triggerIds = @($activeTriggers | ForEach-Object { [string]$_.id })
$reasonArray = @($reasons.ToArray())
$material = @(
    'schema=1',
    "policy_id=$($policy.policy_id)",
    "mode=$effectiveMode",
    "detail=$detail",
    "event_rate=$eventRate",
    "disk_mb_per_hour=$diskBudget",
    "session_seconds=$([int]$policy.budgets.max_session_seconds)",
    "pretrigger_seconds=$([int]$policy.budgets.pretrigger_seconds)",
    "posttrigger_seconds=$([int]$policy.budgets.posttrigger_seconds)",
    "domains=$($orderedDomains -join ',')",
    "triggers=$($triggerIds -join ',')",
    "reasons=$($reasonArray -join ',')",
    "privacy_raw_identifiers=$([bool]$policy.privacy.raw_identifiers)",
    "privacy_formatted_messages=$([bool]$policy.privacy.formatted_messages)",
    "privacy_payload_fields=$([bool]$policy.privacy.payload_fields)",
    "privacy_network_payload=$([bool]$policy.privacy.network_payload)",
    "pending_claims=$($pendingClaims -join ',')",
    "validated_claims=$($validatedClaims -join ',')"
) -join "`n"
$planFingerprint = Get-NxbSha256Text -Text $material

$result = [pscustomobject][ordered]@{
    schema_version = 1
    policy_id = [string]$policy.policy_id
    effective_mode = $effectiveMode
    detail = $detail
    active_domains = $orderedDomains
    active_trigger_ids = $triggerIds
    reasons = $reasonArray
    budgets = [pscustomobject][ordered]@{
        max_event_rate_per_second = $eventRate
        max_disk_mb_per_hour = $diskBudget
        max_session_seconds = [int]$policy.budgets.max_session_seconds
        pretrigger_seconds = [int]$policy.budgets.pretrigger_seconds
        posttrigger_seconds = [int]$policy.budgets.posttrigger_seconds
    }
    privacy = [pscustomobject][ordered]@{
        raw_identifiers = [bool]$policy.privacy.raw_identifiers
        formatted_messages = [bool]$policy.privacy.formatted_messages
        payload_fields = [bool]$policy.privacy.payload_fields
        network_payload = [bool]$policy.privacy.network_payload
    }
    claims = [pscustomobject][ordered]@{
        pending = $pendingClaims
        validated = $validatedClaims
    }
    plan_fingerprint_sha256 = $planFingerprint
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $outputFull
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $outputFull,
        (($result | ConvertTo-Json -Depth 20) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 20
