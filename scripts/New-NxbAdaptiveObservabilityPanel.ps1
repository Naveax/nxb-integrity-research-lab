[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PlanPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ClaimTargetsPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][switch]$Open
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-NxbPanelJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Panel input missing: $full" }
    return (Get-Content -LiteralPath $full -Raw | ConvertFrom-Json)
}

function Get-NxbPanelHtml {
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [Net.WebUtility]::HtmlEncode([string]$Value)
}

$plan = Get-NxbPanelJson -Path $PlanPath
$claims = Get-NxbPanelJson -Path $ClaimTargetsPath

$domainCards = [Text.StringBuilder]::new()
foreach ($property in @($plan.domains.PSObject.Properties | Sort-Object Name)) {
    $name = [string]$property.Name
    $domain = $property.Value
    $level = [string]$domain.level
    $reasonText = if (@($domain.reasons).Count -eq 0) { 'baseline policy' } else { (@($domain.reasons | ForEach-Object { [string]$_.signal }) -join ', ') }
    $expiry = if ($null -eq $domain.expires_utc) { '—' } else { [string]$domain.expires_utc }
    $claimsText = if (@($domain.claim_targets).Count -eq 0) { '—' } else { @($domain.claim_targets) -join ', ' }
    [void]$domainCards.AppendLine(@"
<article class="card level-$level">
  <header><h3>$(Get-NxbPanelHtml $name)</h3><span class="badge">$(Get-NxbPanelHtml $level)</span></header>
  <dl>
    <dt>Requested</dt><dd>$(Get-NxbPanelHtml $domain.requested_level)</dd>
    <dt>Priority</dt><dd>$(Get-NxbPanelHtml $domain.priority)</dd>
    <dt>Elevated</dt><dd>$(Get-NxbPanelHtml $domain.elevated)</dd>
    <dt>Budget suppressed</dt><dd>$(Get-NxbPanelHtml $domain.budget_suppressed)</dd>
    <dt>Raw payload</dt><dd>$(Get-NxbPanelHtml $domain.raw_payload_allowed)</dd>
    <dt>Expires</dt><dd>$(Get-NxbPanelHtml $expiry)</dd>
    <dt>Reason</dt><dd>$(Get-NxbPanelHtml $reasonText)</dd>
    <dt>Claim targets</dt><dd>$(Get-NxbPanelHtml $claimsText)</dd>
  </dl>
</article>
"@)
}

$claimRows = [Text.StringBuilder]::new()
foreach ($claim in @($claims.claims | Sort-Object claim_id)) {
    $required = @($claim.required_evidence) -join '; '
    [void]$claimRows.AppendLine(@"
<tr>
  <td><code>$(Get-NxbPanelHtml $claim.claim_id)</code></td>
  <td>$(Get-NxbPanelHtml $claim.current_state)</td>
  <td>$(Get-NxbPanelHtml $claim.desired_state)</td>
  <td>$(Get-NxbPanelHtml $claim.scope)</td>
  <td>$(Get-NxbPanelHtml $claim.risk_class)</td>
  <td>$(Get-NxbPanelHtml $required)</td>
</tr>
"@)
}

$alwaysKeep = @($plan.retention.always_keep) -join ', '
$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>NXB Adaptive Observability</title>
<style>
:root { color-scheme: dark; font-family: Inter, Segoe UI, system-ui, sans-serif; }
body { margin:0; background:#0b0d10; color:#e7ebf0; }
main { max-width:1500px; margin:auto; padding:28px; }
h1,h2,h3 { margin:0 0 12px; }
.summary { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:12px; margin:18px 0 26px; }
.metric,.card { background:#141820; border:1px solid #2a303b; border-radius:12px; padding:16px; }
.metric b { display:block; font-size:1.35rem; margin-top:4px; }
.grid { display:grid; grid-template-columns:repeat(auto-fit,minmax(310px,1fr)); gap:14px; }
.card header { display:flex; justify-content:space-between; gap:12px; align-items:center; }
.badge { border:1px solid #4d5667; border-radius:999px; padding:4px 10px; text-transform:uppercase; font-size:.78rem; }
.level-forensic { border-color:#8f5bff; }
.level-focused { border-color:#d59a2b; }
.level-baseline { border-color:#3e7c67; }
.level-off { opacity:.65; }
dl { display:grid; grid-template-columns:130px 1fr; gap:7px 10px; margin:12px 0 0; font-size:.9rem; }
dt { color:#99a4b4; }
dd { margin:0; overflow-wrap:anywhere; }
table { width:100%; border-collapse:collapse; margin-top:12px; font-size:.88rem; }
th,td { border-bottom:1px solid #2a303b; padding:10px; text-align:left; vertical-align:top; }
th { color:#aeb8c7; position:sticky; top:0; background:#0f1319; }
section { margin-top:30px; }
.note { color:#9fa8b5; line-height:1.55; }
code { color:#d4bcff; }
</style>
</head>
<body>
<main>
<h1>NXB Adaptive Observability Control Plane</h1>
<p class="note">Policy-driven capture: keep normal telemetry light, elevate only relevant domains for bounded windows, then fall back automatically. The panel is read-only; policy JSON remains the authority.</p>
<div class="summary">
  <div class="metric">Policy<b>$(Get-NxbPanelHtml $plan.policy_id)</b></div>
  <div class="metric">Evaluation UTC<b>$(Get-NxbPanelHtml $plan.evaluation_utc)</b></div>
  <div class="metric">Active signals<b>$(Get-NxbPanelHtml $plan.active_signal_count)</b></div>
  <div class="metric">Max elevated domains<b>$(Get-NxbPanelHtml $plan.budgets.max_concurrent_elevated_domains)</b></div>
  <div class="metric">Max capture seconds<b>$(Get-NxbPanelHtml $plan.budgets.max_capture_seconds)</b></div>
  <div class="metric">Review budget bytes<b>$(Get-NxbPanelHtml $plan.budgets.max_review_bytes)</b></div>
</div>
<section>
<h2>Domain capture plan</h2>
<div class="grid">$($domainCards.ToString())</div>
</section>
<section>
<h2>High-value retention</h2>
<p class="note">Always retained: $(Get-NxbPanelHtml $alwaysKeep). Raw identifiers are hash-bound and messages are redacted by default.</p>
</section>
<section>
<h2>Semantic claim hardening</h2>
<p class="note">Desired state can be true while current state remains false. Promotion occurs only after every required evidence gate for the declared scope passes.</p>
<div style="overflow:auto">
<table>
<thead><tr><th>Claim</th><th>Current</th><th>Desired</th><th>Scope</th><th>Risk</th><th>Promotion gates</th></tr></thead>
<tbody>$($claimRows.ToString())</tbody>
</table>
</div>
</section>
</main>
</body>
</html>
"@

$fullOutput = [IO.Path]::GetFullPath($OutputPath)
$parent = Split-Path -Parent $fullOutput
if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
[IO.File]::WriteAllText($fullOutput,$html,[Text.UTF8Encoding]::new($false))
Write-Information -MessageData ("NXB adaptive observability panel written: {0}" -f $fullOutput) -InformationAction Continue
if ($Open) { Start-Process -FilePath $fullOutput | Out-Null }
Write-Output $fullOutput
