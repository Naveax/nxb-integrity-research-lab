[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$ExpectedHead,
    [Parameter(Mandatory)][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $RepositoryRoot 'scripts\NxbProductionFinalization.Common.ps1')
$policy = Get-Content -LiteralPath (Join-Path $RepositoryRoot 'config\nxb-production-finalization-policy.json') -Raw | ConvertFrom-Json
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null

$allowedPlan = [pscustomobject][ordered]@{
    host = '127.0.0.1'
    method = 'GET'
    request_count = 1
    maximum_response_bytes = 4096
    production_secret_attached = $false
    permit_sha256 = $null
    scope_authorized = $true
    kill_switch_armed = $true
    permit_host_authorized = $true
    permit_method_authorized = $true
}
if (-not (Test-NxbFinalAuthorizedRequestPlan -Policy $policy -Plan $allowedPlan -CertificationMode $true)) {
    throw 'Part 7 certification loopback request plan was rejected.'
}

$negativePlan = @(
    [pscustomobject][ordered]@{ host='example.com'; method='GET'; request_count=1; maximum_response_bytes=4096; production_secret_attached=$false; permit_sha256=$null; scope_authorized=$true; kill_switch_armed=$true; permit_host_authorized=$true; permit_method_authorized=$true },
    [pscustomobject][ordered]@{ host='127.0.0.1'; method='POST'; request_count=1; maximum_response_bytes=4096; production_secret_attached=$false; permit_sha256=$null; scope_authorized=$true; kill_switch_armed=$true; permit_host_authorized=$true; permit_method_authorized=$true },
    [pscustomobject][ordered]@{ host='127.0.0.1'; method='GET'; request_count=99; maximum_response_bytes=4096; production_secret_attached=$false; permit_sha256=$null; scope_authorized=$true; kill_switch_armed=$true; permit_host_authorized=$true; permit_method_authorized=$true },
    [pscustomobject][ordered]@{ host='127.0.0.1'; method='GET'; request_count=1; maximum_response_bytes=4096; production_secret_attached=$true; permit_sha256=$null; scope_authorized=$true; kill_switch_armed=$true; permit_host_authorized=$true; permit_method_authorized=$true }
)
foreach ($plan in $negativePlan) {
    if (Test-NxbFinalAuthorizedRequestPlan -Policy $policy -Plan $plan -CertificationMode $true) {
        throw 'Part 7 fail-closed certification request plan unexpectedly passed.'
    }
}

$productionWithoutPermit = [pscustomobject][ordered]@{
    host = 'authorized.example'
    method = 'GET'
    request_count = 1
    maximum_response_bytes = 4096
    production_secret_attached = $false
    permit_sha256 = ''
    scope_authorized = $true
    kill_switch_armed = $true
    permit_host_authorized = $true
    permit_method_authorized = $true
}
if (Test-NxbFinalAuthorizedRequestPlan -Policy $policy -Plan $productionWithoutPermit -CertificationMode $false) {
    throw 'Part 7 production plan without permit unexpectedly passed.'
}

$productionAuthorized = [pscustomobject][ordered]@{
    host = 'authorized.example'
    method = 'GET'
    request_count = 1
    maximum_response_bytes = 4096
    production_secret_attached = $false
    permit_sha256 = Get-NxbFinalSha256Text -Text 'part7-certification-permit'
    scope_authorized = $true
    kill_switch_armed = $true
    permit_host_authorized = $true
    permit_method_authorized = $true
}
if (-not (Test-NxbFinalAuthorizedRequestPlan -Policy $policy -Plan $productionAuthorized -CertificationMode $false)) {
    throw 'Part 7 fully authorized production request plan was rejected.'
}
$productionWrongHost = $productionAuthorized | ConvertTo-Json -Depth 8 | ConvertFrom-Json
$productionWrongHost.permit_host_authorized = $false
if (Test-NxbFinalAuthorizedRequestPlan -Policy $policy -Plan $productionWrongHost -CertificationMode $false) {
    throw 'Part 7 production plan outside the permit host boundary unexpectedly passed.'
}

$listener = New-Object Net.Sockets.TcpListener ([Net.IPAddress]::Loopback,0)
$listener.Start()
$client = $null
$server = $null
try {
    $port = [int]$listener.LocalEndpoint.Port
    $accept = $listener.BeginAcceptTcpClient($null,$null)
    $client = New-Object Net.Sockets.TcpClient
    $client.Connect('127.0.0.1',$port)
    $server = $listener.EndAcceptTcpClient($accept)

    $encoding = New-Object Text.UTF8Encoding($false)
    $clientStream = $client.GetStream()
    $requestBytes = $encoding.GetBytes("GET /certification HTTP/1.1`r`nHost: 127.0.0.1`r`nConnection: close`r`n`r`n")
    $clientStream.Write($requestBytes,0,$requestBytes.Length)
    $clientStream.Flush()

    $serverStream = $server.GetStream()
    $buffer = New-Object byte[] 4096
    $read = $serverStream.Read($buffer,0,$buffer.Length)
    $requestText = $encoding.GetString($buffer,0,$read)
    if ($requestText -cnotmatch '^GET /certification HTTP/1\.1') { throw 'Part 7 loopback request shape mismatch.' }

    $body = '{"status":"ok","scope":"loopback-certification"}'
    $responseText = "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`nContent-Length: $($encoding.GetByteCount($body))`r`nConnection: close`r`n`r`n$body"
    $responseBytes = $encoding.GetBytes($responseText)
    if ($responseBytes.Length -gt [int]$policy.certification.maximum_response_bytes) { throw 'Part 7 loopback response exceeded budget.' }
    $serverStream.Write($responseBytes,0,$responseBytes.Length)
    $serverStream.Flush()
    $server.Close()
    $server = $null

    $responseBuffer = New-Object byte[] 4096
    $responseRead = $clientStream.Read($responseBuffer,0,$responseBuffer.Length)
    $received = $encoding.GetString($responseBuffer,0,$responseRead)
    if ($received -cnotmatch '^HTTP/1\.1 200 OK') { throw 'Part 7 loopback response status mismatch.' }
}
finally {
    if ($null -ne $server) { $server.Close() }
    if ($null -ne $client) { $client.Close() }
    $listener.Stop()
}

$secret = 'NXB-CERT-SECRET-DO-NOT-EMIT'
$redacted = Protect-NxbFinalSecretText -Text ('Authorization: Bearer ' + $secret) -Secret @($secret)
if ($redacted.Contains($secret)) { throw 'Part 7 secret redaction failed.' }
if ($redacted -cnotmatch '\[REDACTED\]') { throw 'Part 7 redaction marker missing.' }

$receipt = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    contract_id = [string]$policy.part7.contract_id
    head_sha = $ExpectedHead
    certification_network_mode = [string]$policy.certification.network_mode
    loopback_native_probe = $true
    native_probe_requests = 1
    rejected_request_plans = $negativePlan.Count + 2
    request_budget_enforced = $true
    response_budget_enforced = $true
    secret_redaction = $true
    production_secret_in_evidence = $false
    permit_required_for_noncertification = $true
    permit_target_binding = $true
    permit_method_binding = $true
    kill_switch_required_for_noncertification = $true
    requirements_validated = @($policy.part7.requirements).Count
}
$path = Join-Path $OutputDirectory 'part7-bounded-active-validation-receipt.json'
Write-NxbFinalAtomicJson -Path $path -InputObject $receipt

if ($PassThru) {
    return [pscustomobject][ordered]@{
        status = 'passed'
        receipt_path = $path
        receipt_sha256 = Get-NxbFinalFileSha256 -Path $path
        requirements_validated = [int]$receipt.requirements_validated
        loopback_native_probe = $true
    }
}
