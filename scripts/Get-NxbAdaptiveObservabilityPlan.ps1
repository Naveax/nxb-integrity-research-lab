[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PolicyPath,
    [Parameter()][string]$SignalsPath,
    [Parameter()][string]$ClaimTargetsPath,
    [Parameter()][datetime]$EvaluationUtc = [DateTime]::UtcNow,
    [Parameter()][string]$OutputPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbAdaptiveProperty {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Name,
        [Parameter()][AllowNull()][object]$DefaultValue = $null
    )
    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $DefaultValue }
    return $property.Value
}

function Get-NxbAdaptiveJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "JSON file not found: $fullPath" }
    return (Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json)
}

function Write-NxbAdaptiveJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $fullPath,
        (($InputObject | ConvertTo-Json -Depth 40) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-NxbAdaptiveLevelRank {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][ValidateSet('off','baseline','focused','forensic')][string]$Level
    )
    return [int](Get-NxbAdaptiveProperty -InputObject $Policy.levels.$Level -Name 'rank' -DefaultValue -1)
}

function Get-NxbAdaptiveClampedLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Policy,
        [Parameter(Mandatory)][string]$RequestedLevel,
        [Parameter(Mandatory)][string]$MinimumLevel,
        [Parameter(Mandatory)][string]$MaximumLevel
    )
    $requestedRank = Get-NxbAdaptiveLevelRank -Policy $Policy -Level $RequestedLevel
    $minimumRank = Get-NxbAdaptiveLevelRank -Policy $Policy -Level $MinimumLevel
    $maximumRank = Get-NxbAdaptiveLevelRank -Policy $Policy -Level $MaximumLevel
    $targetRank = [Math]::Max($minimumRank,[Math]::Min($maximumRank,$requestedRank))
    foreach ($candidate in @('off','baseline','focused','forensic')) {
        if ((Get-NxbAdaptiveLevelRank -Policy $Policy -Level $candidate) -eq $targetRank) { return $candidate }
    }
    throw "Unable to resolve adaptive level rank: $targetRank"
}

$policy = Get-NxbAdaptiveJson -Path $PolicyPath
if ([int](Get-NxbAdaptiveProperty $policy 'schema_version' 0) -ne 1) { throw 'Unsupported adaptive observability policy schema_version.' }

$evaluation = $EvaluationUtc.ToUniversalTime()
$signals = @()
if (-not [string]::IsNullOrWhiteSpace($SignalsPath)) {
    $signalDocument = Get-NxbAdaptiveJson -Path $SignalsPath
    if ($signalDocument -is [System.Array]) { $signals = @($signalDocument) }
    else {
        $items = Get-NxbAdaptiveProperty -InputObject $signalDocument -Name 'signals' -DefaultValue @()
        $signals = @($items)
    }
}

$claimDocument = $null
if (-not [string]::IsNullOrWhiteSpace($ClaimTargetsPath)) {
    $claimDocument = Get-NxbAdaptiveJson -Path $ClaimTargetsPath
}

$states = @{}
foreach ($domainProperty in @($policy.domains.PSObject.Properties | Sort-Object Name)) {
    $domainName = [string]$domainProperty.Name
    $domainConfig = $domainProperty.Value
    $enabled = [bool](Get-NxbAdaptiveProperty $domainConfig 'enabled' $false)
    $minimum = [string](Get-NxbAdaptiveProperty $domainConfig 'minimum_level' 'off')
    $maximum = [string](Get-NxbAdaptiveProperty $domainConfig 'maximum_level' 'off')
    $priority = [int](Get-NxbAdaptiveProperty $domainConfig 'priority' 0)
    $initial = if ($enabled) {
        Get-NxbAdaptiveClampedLevel -Policy $policy -RequestedLevel ([string]$policy.default_level) -MinimumLevel $minimum -MaximumLevel $maximum
    }
    else { 'off' }
    $states[$domainName] = [ordered]@{
        name = $domainName
        enabled = $enabled
        minimum_level = $minimum
        maximum_level = $maximum
        priority = $priority
        level = $initial
        requested_level = $initial
        reasons = @()
        expires_utc = $null
        budget_suppressed = $false
    }
}

$activeSignalCount = 0
foreach ($signal in $signals) {
    $signalName = [string](Get-NxbAdaptiveProperty $signal 'signal' '')
    if ([string]::IsNullOrWhiteSpace($signalName)) { continue }
    $capturedText = [string](Get-NxbAdaptiveProperty $signal 'captured_utc' $evaluation.ToString('o'))
    $captured = [DateTime]::Parse($capturedText,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeUniversal).ToUniversalTime()
    $signalDomains = @((Get-NxbAdaptiveProperty $signal 'domains' @()) | ForEach-Object { [string]$_ })

    foreach ($rule in @($policy.rules | Where-Object { [string]$_.signal -ceq $signalName } | Sort-Object @{Expression='priority';Descending=$true},rule_id)) {
        $ttl = [int](Get-NxbAdaptiveProperty $rule 'ttl_seconds' 1)
        $expiry = $captured.AddSeconds($ttl)
        if ($evaluation -gt $expiry) { continue }
        $activeSignalCount++
        foreach ($ruleDomainRaw in @($rule.domains)) {
            $ruleDomain = [string]$ruleDomainRaw
            if (-not $states.ContainsKey($ruleDomain)) { continue }
            if ($signalDomains.Count -gt 0 -and $signalDomains -notcontains $ruleDomain) { continue }
            $state = $states[$ruleDomain]
            if (-not [bool]$state.enabled) { continue }
            $requested = Get-NxbAdaptiveClampedLevel -Policy $policy -RequestedLevel ([string]$rule.level) -MinimumLevel ([string]$state.minimum_level) -MaximumLevel ([string]$state.maximum_level)
            if ((Get-NxbAdaptiveLevelRank -Policy $policy -Level $requested) -gt (Get-NxbAdaptiveLevelRank -Policy $policy -Level ([string]$state.requested_level))) {
                $state.requested_level = $requested
                $state.level = $requested
            }
            $state.reasons = @($state.reasons) + @([pscustomobject][ordered]@{
                rule_id = [string]$rule.rule_id
                signal = $signalName
                requested_level = [string]$rule.level
                effective_level = $requested
                captured_utc = $captured.ToString('o')
                expires_utc = $expiry.ToString('o')
                priority = [int]$rule.priority
            })
            if ($null -eq $state.expires_utc -or $expiry -gt [DateTime]::Parse([string]$state.expires_utc)) {
                $state.expires_utc = $expiry.ToString('o')
            }
        }
    }
}

$focusedRank = Get-NxbAdaptiveLevelRank -Policy $policy -Level 'focused'
$elevated = @(
    $states.Values |
        Where-Object { (Get-NxbAdaptiveLevelRank -Policy $policy -Level ([string]$_.level)) -ge $focusedRank } |
        Sort-Object @{Expression='priority';Descending=$true},@{Expression={ Get-NxbAdaptiveLevelRank -Policy $policy -Level ([string]$_.level) };Descending=$true},name
)
$maxElevated = [int]$policy.budgets.max_concurrent_elevated_domains
if ($elevated.Count -gt $maxElevated) {
    foreach ($state in @($elevated | Select-Object -Skip $maxElevated)) {
        $fallback = Get-NxbAdaptiveClampedLevel -Policy $policy -RequestedLevel 'baseline' -MinimumLevel ([string]$state.minimum_level) -MaximumLevel ([string]$state.maximum_level)
        $state.level = $fallback
        $state.budget_suppressed = $true
    }
}

$domainResults = [ordered]@{}
foreach ($domainName in @($states.Keys | Sort-Object)) {
    $state = $states[$domainName]
    $level = [string]$state.level
    $levelConfig = $policy.levels.$level
    $rawAllowed = [bool](Get-NxbAdaptiveProperty $levelConfig 'raw_payload_allowed' $false)
    if (-not [bool]$policy.retention.raw_payload_default -and $level -cne 'forensic') { $rawAllowed = $false }
    $claimIds = @()
    if ($null -ne $claimDocument) {
        foreach ($claim in @($claimDocument.claims)) {
            if (@($claim.adaptive_domains) -contains $domainName) { $claimIds += [string]$claim.claim_id }
        }
    }
    $domainResults[$domainName] = [pscustomobject][ordered]@{
        enabled = [bool]$state.enabled
        level = $level
        rank = Get-NxbAdaptiveLevelRank -Policy $policy -Level $level
        requested_level = [string]$state.requested_level
        priority = [int]$state.priority
        elevated = ((Get-NxbAdaptiveLevelRank -Policy $policy -Level $level) -ge $focusedRank)
        budget_suppressed = [bool]$state.budget_suppressed
        raw_payload_allowed = $rawAllowed
        expires_utc = $state.expires_utc
        reasons = @($state.reasons)
        claim_targets = @($claimIds | Sort-Object -Unique)
    }
}

$result = [pscustomobject][ordered]@{
    schema_version = 1
    policy_id = [string]$policy.policy_id
    evaluation_utc = $evaluation.ToString('o')
    capture_strategy = 'policy_driven_adaptive'
    active_signal_count = [int]$activeSignalCount
    budgets = [pscustomobject][ordered]@{
        max_concurrent_elevated_domains = [int]$policy.budgets.max_concurrent_elevated_domains
        max_capture_seconds = [int]$policy.budgets.max_capture_seconds
        cooldown_seconds = [int]$policy.budgets.cooldown_seconds
        max_review_bytes = [int64]$policy.budgets.max_review_bytes
    }
    retention = $policy.retention
    domains = [pscustomobject]$domainResults
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) { Write-NxbAdaptiveJson -Path $OutputPath -InputObject $result }
if ($PassThru) { return $result }
if ([string]::IsNullOrWhiteSpace($OutputPath)) { $result | ConvertTo-Json -Depth 40 }
else { Write-Output ([IO.Path]::GetFullPath($OutputPath)) }
