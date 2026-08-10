[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DomainMapPath,
    [Parameter()][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$planFull = [IO.Path]::GetFullPath($PlanPath)
$mapFull = [IO.Path]::GetFullPath($DomainMapPath)
if (-not (Test-Path -LiteralPath $planFull -PathType Leaf)) { throw ('Plan missing: {0}' -f $planFull) }
if (-not (Test-Path -LiteralPath $mapFull -PathType Leaf)) { throw ('Domain map missing: {0}' -f $mapFull) }

$plan = Get-Content -LiteralPath $planFull -Raw | ConvertFrom-Json
$domainMap = Get-Content -LiteralPath $mapFull -Raw | ConvertFrom-Json
if ([int]$domainMap.schema_version -ne 1) { throw 'Unsupported adaptive domain-map schema.' }

$repoRoot = Split-Path -Parent (Split-Path -Parent $mapFull)
$detail = [string]$plan.detail
$includeDeepAssets = ($detail -ceq 'semantic' -or $detail -ceq 'payload')
$entries = [Collections.Generic.List[object]]::new()

foreach ($domainName in @($plan.active_domains)) {
    $matches = @($domainMap.domains | Where-Object { [string]$_.name -ceq [string]$domainName })
    if ($matches.Count -ne 1) { throw ('Domain map must contain exactly one entry for {0}; found {1}' -f $domainName,$matches.Count) }
    $mapping = $matches[0]
    $assets = [Collections.Generic.List[string]]::new()
    foreach ($asset in @($mapping.base_assets)) { $assets.Add([string]$asset) }
    if ($includeDeepAssets) {
        foreach ($asset in @($mapping.deep_assets)) {
            if (-not $assets.Contains([string]$asset)) { $assets.Add([string]$asset) }
        }
    }

    $assetStates = [Collections.Generic.List[object]]::new()
    $missingCount = 0
    foreach ($relative in $assets) {
        $full = Join-Path $repoRoot ($relative -replace '/','\')
        $exists = Test-Path -LiteralPath $full -PathType Leaf
        if (-not $exists) { $missingCount++ }
        $assetStates.Add([pscustomobject][ordered]@{
            path = $relative
            repo_owned = $exists
        })
    }

    $availability = 'ready'
    $reason = 'repo_assets_present'
    if ([string]$mapping.adapter_kind -ceq 'pending_semantic_adapter') {
        $availability = 'pending'
        $reason = 'semantic_adapter_not_yet_certified'
    }
    elseif ($missingCount -gt 0) {
        $availability = 'unavailable'
        $reason = 'repo_asset_missing'
    }

    $entries.Add([pscustomobject][ordered]@{
        domain = [string]$domainName
        requested_detail = $detail
        adapter_kind = [string]$mapping.adapter_kind
        runtime_surface = [string]$mapping.runtime_surface
        availability = $availability
        reason = $reason
        assets = @($assetStates.ToArray())
    })
}

$readyCount = @($entries | Where-Object { [string]$_.availability -ceq 'ready' }).Count
$pendingCount = @($entries | Where-Object { [string]$_.availability -ceq 'pending' }).Count
$unavailableCount = @($entries | Where-Object { [string]$_.availability -ceq 'unavailable' }).Count

$result = [pscustomobject][ordered]@{
    schema_version = 1
    policy_id = [string]$plan.policy_id
    plan_fingerprint_sha256 = [string]$plan.plan_fingerprint_sha256
    effective_mode = [string]$plan.effective_mode
    detail = $detail
    budgets = $plan.budgets
    capture = [pscustomobject][ordered]@{
        domain_count = [int]$entries.Count
        ready_count = $readyCount
        pending_count = $pendingCount
        unavailable_count = $unavailableCount
        domains = @($entries.ToArray())
    }
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outputFull = [IO.Path]::GetFullPath($OutputPath)
    $parent = Split-Path -Parent $outputFull
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        $outputFull,
        (($result | ConvertTo-Json -Depth 30) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($PassThru) { return $result }
$result | ConvertTo-Json -Depth 30
