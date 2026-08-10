[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$PolicyPath,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SignalsPath,
    [Parameter()][ValidateSet('127.0.0.1','localhost')][string]$BindAddress = '127.0.0.1',
    [Parameter()][ValidateRange(1024,65535)][int]$Port = 43128,
    [Parameter()][ValidateNotNullOrEmpty()][string]$StateDirectory,
    [Parameter()][switch]$OpenBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbPanelJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        (($InputObject | ConvertTo-Json -Depth 30) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-NxbPanelRequestBody {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Net.HttpListenerRequest]$Request)
    $reader = [IO.StreamReader]::new($Request.InputStream,$Request.ContentEncoding)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

function Write-NxbPanelResponse {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Net.HttpListenerResponse]$Response,
        [Parameter(Mandatory)][int]$StatusCode,
        [Parameter(Mandatory)][string]$ContentType,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Body
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = $ContentType
    $Response.ContentEncoding = [Text.Encoding]::UTF8
    $Response.ContentLength64 = $bytes.Length
    try { $Response.OutputStream.Write($bytes,0,$bytes.Length) }
    finally { $Response.OutputStream.Close() }
}

function Get-NxbPanelModeRank {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Mode)
    $modes = @('off','minimal','normal','deep','forensic')
    $rank = [Array]::IndexOf($modes,$Mode)
    if ($rank -lt 0) { throw "Unsupported mode: $Mode" }
    return $rank
}

$policyFull = [IO.Path]::GetFullPath($PolicyPath)
$signalsFull = [IO.Path]::GetFullPath($SignalsPath)
if (-not (Test-Path -LiteralPath $policyFull -PathType Leaf)) { throw "Policy missing: $policyFull" }

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot
$resolverPath = Join-Path $scriptRoot 'Resolve-NxbAdaptiveObservabilityPlan.ps1'
$panelHtmlPath = Join-Path $repoRoot 'ui\adaptive-observability-panel.html'
if (-not (Test-Path -LiteralPath $resolverPath -PathType Leaf)) { throw "Resolver missing: $resolverPath" }
if (-not (Test-Path -LiteralPath $panelHtmlPath -PathType Leaf)) { throw "Panel HTML missing: $panelHtmlPath" }

$policy = Get-Content -LiteralPath $policyFull -Raw | ConvertFrom-Json
if (-not [bool]$policy.panel.local_only) { throw 'Adaptive panel policy must remain local_only.' }
if ([string]$policy.panel.bind_address -notin @('127.0.0.1','localhost')) { throw 'Adaptive panel policy requested a non-local bind address.' }
if ($BindAddress -notin @('127.0.0.1','localhost')) { throw 'Panel bind address must remain local.' }

if ([string]::IsNullOrWhiteSpace($StateDirectory)) {
    $StateDirectory = Join-Path $env:LOCALAPPDATA 'NXB\AdaptiveObservability'
}
$stateFull = [IO.Path]::GetFullPath($StateDirectory)
[IO.Directory]::CreateDirectory($stateFull) | Out-Null
$overridePath = Join-Path $stateFull 'override.json'
$planPath = Join-Path $stateFull 'current-plan.json'

if (-not (Test-Path -LiteralPath $signalsFull -PathType Leaf)) {
    $signalsParent = Split-Path -Parent $signalsFull
    if (-not [string]::IsNullOrWhiteSpace($signalsParent)) { [IO.Directory]::CreateDirectory($signalsParent) | Out-Null }
    [IO.File]::WriteAllText($signalsFull,"{}`n",[Text.UTF8Encoding]::new($false))
}

function Get-NxbPanelOverride {
    [CmdletBinding()]
    param()
    if (-not (Test-Path -LiteralPath $overridePath -PathType Leaf)) { return $null }
    try {
        $value = Get-Content -LiteralPath $overridePath -Raw | ConvertFrom-Json
        $expires = [DateTime]::Parse([string]$value.expires_utc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind)
        if ($expires -le [DateTime]::UtcNow) {
            Remove-Item -LiteralPath $overridePath -Force -ErrorAction SilentlyContinue
            return $null
        }
        return $value
    }
    catch {
        Remove-Item -LiteralPath $overridePath -Force -ErrorAction SilentlyContinue
        return $null
    }
}

function Get-NxbPanelStatus {
    [CmdletBinding()]
    param()
    $currentPolicy = Get-Content -LiteralPath $policyFull -Raw | ConvertFrom-Json
    $override = Get-NxbPanelOverride
    $operatorMode = $null
    if ($null -ne $override) { $operatorMode = [string]$override.mode }

    if ([string]::IsNullOrWhiteSpace($operatorMode)) {
        $plan = & $resolverPath -PolicyPath $policyFull -SignalsPath $signalsFull -OutputPath $planPath -PassThru
    }
    else {
        $plan = & $resolverPath -PolicyPath $policyFull -SignalsPath $signalsFull -OperatorMode $operatorMode -OutputPath $planPath -PassThru
    }

    $overrideStatus = [pscustomobject][ordered]@{ active = $false; mode = $null; expires_utc = $null }
    if ($null -ne $override) {
        $overrideStatus = [pscustomobject][ordered]@{
            active = $true
            mode = [string]$override.mode
            expires_utc = [string]$override.expires_utc
        }
    }

    return [pscustomobject][ordered]@{
        schema_version = 1
        utc = [DateTime]::UtcNow.ToString('o')
        policy_id = [string]$currentPolicy.policy_id
        plan = $plan
        override = $overrideStatus
        claim_targets = @($currentPolicy.claim_targets)
        state_directory = $stateFull
    }
}

$prefix = 'http://{0}:{1}/' -f $BindAddress,$Port
$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Information -InformationAction Continue -MessageData ("NXB adaptive observability panel listening at {0}" -f $prefix)
if ($OpenBrowser) { Start-Process $prefix }

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        try {
            $request = $context.Request
            $response = $context.Response
            $path = $request.Url.AbsolutePath

            if ($request.HttpMethod -ceq 'GET' -and $path -ceq '/') {
                $html = Get-Content -LiteralPath $panelHtmlPath -Raw
                Write-NxbPanelResponse -Response $response -StatusCode 200 -ContentType 'text/html; charset=utf-8' -Body $html
                continue
            }

            if ($request.HttpMethod -ceq 'GET' -and $path -ceq '/health') {
                Write-NxbPanelResponse -Response $response -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body '{"status":"ok","local_only":true}'
                continue
            }

            if ($request.HttpMethod -ceq 'GET' -and $path -ceq '/api/status') {
                $status = Get-NxbPanelStatus
                Write-NxbPanelResponse -Response $response -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ($status | ConvertTo-Json -Depth 40)
                continue
            }

            if ($request.HttpMethod -ceq 'POST' -and $path -ceq '/api/override') {
                $body = Get-NxbPanelRequestBody -Request $request
                $payload = $body | ConvertFrom-Json
                $mode = [string]$payload.mode
                $seconds = [int]$payload.seconds
                $requestedRank = Get-NxbPanelModeRank -Mode $mode
                $maximumRank = Get-NxbPanelModeRank -Mode ([string]$policy.maximum_mode)
                if ($requestedRank -gt $maximumRank) { throw 'Requested override exceeds policy maximum_mode.' }
                if ($seconds -lt 1 -or $seconds -gt [int]$policy.panel.manual_override_max_seconds) { throw 'Override duration is outside the policy boundary.' }
                $override = [pscustomobject][ordered]@{
                    mode = $mode
                    created_utc = [DateTime]::UtcNow.ToString('o')
                    expires_utc = [DateTime]::UtcNow.AddSeconds($seconds).ToString('o')
                }
                Write-NxbPanelJsonFile -Path $overridePath -InputObject $override
                Write-NxbPanelResponse -Response $response -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body ($override | ConvertTo-Json -Depth 10)
                continue
            }

            if ($request.HttpMethod -ceq 'POST' -and $path -ceq '/api/clear') {
                Remove-Item -LiteralPath $overridePath -Force -ErrorAction SilentlyContinue
                Write-NxbPanelResponse -Response $response -StatusCode 200 -ContentType 'application/json; charset=utf-8' -Body '{"cleared":true}'
                continue
            }

            Write-NxbPanelResponse -Response $response -StatusCode 404 -ContentType 'application/json; charset=utf-8' -Body '{"error":"not_found"}'
        }
        catch {
            try {
                Write-NxbPanelResponse -Response $context.Response -StatusCode 400 -ContentType 'application/json; charset=utf-8' -Body (([pscustomobject]@{ error = $_.Exception.Message }) | ConvertTo-Json)
            }
            catch { Write-Verbose -Message 'Panel response could not be written.' }
        }
    }
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
    $listener.Close()
}
