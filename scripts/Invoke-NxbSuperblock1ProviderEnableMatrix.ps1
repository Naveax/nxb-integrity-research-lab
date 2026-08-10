[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputPath,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbEnableMatrixAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NxbTextSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Write-NxbProviderProbeProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter()][string[]]$Keywords = @()
    )
    $keywordXml = if (@($Keywords).Count -eq 0) {
        ''
    }
    else {
        $rows = @($Keywords | ForEach-Object { '        <Keyword Value="' + $_ + '" />' })
        "`n      <Keywords>`n" + ($rows -join "`n") + "`n      </Keywords>"
    }
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<WindowsPerformanceRecorder Version="1.0" Author="NXB Integrity Research Lab" Team="Observability" Company="NXB Integrity Research Lab" Comments="Single-provider native enableability probe" Tag="NXB-IRL-004">
  <Profiles>
    <EventCollector Id="ProbeCollector" Name="NXB Provider Enable Probe">
      <BufferSize Value="128" />
      <Buffers Value="16" />
      <MaximumFileSize Value="16" FileMode="Circular" />
    </EventCollector>
    <EventProvider Id="ProbeProvider" Name="$ProviderName" Strict="true">$keywordXml
    </EventProvider>
    <Profile Id="NxbProviderEnableProbe.Verbose.File" Name="NxbProviderEnableProbe" DetailLevel="Verbose" LoggingMode="File" Description="Single-provider native enableability probe">
      <Collectors>
        <EventCollectorId Value="ProbeCollector">
          <EventProviders><EventProviderId Value="ProbeProvider" /></EventProviders>
        </EventCollectorId>
      </Collectors>
    </Profile>
  </Profiles>
</WindowsPerformanceRecorder>
"@
    [IO.File]::WriteAllText($Path,$xml,[Text.UTF8Encoding]::new($false))
}

if ($env:OS -cne 'Windows_NT') { throw 'Provider enable matrix requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Provider enable matrix requires PowerShell 7.' }
if (-not (Test-NxbEnableMatrixAdministrator)) { throw 'Provider enable matrix requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Provider enable matrix requires a clean exact-head worktree.'
}

$outputFull = [IO.Path]::GetFullPath($OutputPath)
if (Test-Path -LiteralPath $outputFull) { throw "OutputPath already exists: $outputFull" }
$outputDirectory = Split-Path -Parent $outputFull
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
$probeRoot = Join-Path $outputDirectory 'provider-enable-probes-local'
[IO.Directory]::CreateDirectory($probeRoot) | Out-Null
$wpr = Get-Command wpr.exe -ErrorAction Stop

$providerSpecs = @(
    [pscustomobject][ordered]@{ domain='gpu'; name='Microsoft-Windows-DxgKrnl'; keywords=@('0x0000000000008000','0x0000000000010000','0x0000000008000000') },
    [pscustomobject][ordered]@{ domain='gpu'; name='Microsoft-Windows-DXGI'; keywords=@('0x0000000000000002') },
    [pscustomobject][ordered]@{ domain='network'; name='Microsoft-Windows-Kernel-Network'; keywords=@() },
    [pscustomobject][ordered]@{ domain='network'; name='Microsoft-Windows-Winsock-AFD'; keywords=@() },
    [pscustomobject][ordered]@{ domain='network'; name='Microsoft-Windows-DNS-Client'; keywords=@() },
    [pscustomobject][ordered]@{ domain='kernel_lifecycle'; name='Microsoft-Windows-Kernel-Process'; keywords=@() },
    [pscustomobject][ordered]@{ domain='kernel_lifecycle'; name='Microsoft-Windows-Kernel-Registry'; keywords=@() },
    [pscustomobject][ordered]@{ domain='kernel_lifecycle'; name='Microsoft-Windows-Kernel-PnP'; keywords=@() }
)

$rows = [Collections.Generic.List[object]]::new()
foreach ($providerSpec in $providerSpecs) {
    $safeName = ([string]$providerSpec.name -replace '[^A-Za-z0-9._-]','_')
    $profilePath = Join-Path $probeRoot ($safeName + '.wprp')
    Write-NxbProviderProbeProfile -Path $profilePath -ProviderName ([string]$providerSpec.name) -Keywords @($providerSpec.keywords)

    & $wpr.Source -profiles $profilePath 2>&1 | Out-Null
    $profileExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($profileExit -ne 0) {
        throw "Native WPR probe profile parse failed for $($providerSpec.name): exit=$profileExit"
    }

    $sessionOwned = $false
    $startOutput = @()
    $startExit = $null
    $cancelExit = $null
    try {
        $profileReference = "$profilePath!NxbProviderEnableProbe.Verbose"
        $startOutput = @(& $wpr.Source -start $profileReference -filemode 2>&1)
        $startExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        if ($startExit -eq 0) {
            $sessionOwned = $true
            Start-Sleep -Milliseconds 100
            $cancelOutput = @(& $wpr.Source -cancel 2>&1)
            $cancelExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
            if ($cancelExit -ne 0) {
                throw "Owned WPR probe session could not be cancelled for $($providerSpec.name): exit=$cancelExit output=$($cancelOutput -join ' ')"
            }
            $sessionOwned = $false
        }
    }
    finally {
        if ($sessionOwned) {
            try {
                & $wpr.Source -cancel 2>&1 | Out-Null
            }
            catch {
                Write-Warning "Owned WPR probe cleanup failed for $($providerSpec.name): $($_.Exception.Message)"
            }
        }
    }

    $startText = @($startOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $errorCodeMatch = [regex]::Match($startText,'(?i)0x[0-9a-f]{8}')
    $rows.Add([pscustomobject][ordered]@{
        domain = [string]$providerSpec.domain
        name = [string]$providerSpec.name
        keyword_count = @($providerSpec.keywords).Count
        native_profile_parse = 'passed'
        status = if ($startExit -eq 0) { 'enabled' } else { 'unavailable' }
        start_exit_code = [int]$startExit
        start_error_code = if ($errorCodeMatch.Success) { $errorCodeMatch.Value.ToLowerInvariant() } else { $null }
        start_output_sha256 = Get-NxbTextSha256 -Text $startText
        start_output_line_count = @($startOutput).Count
        owned_session_cancel_exit_code = $cancelExit
    })
}

$enabledRows = @($rows | Where-Object { $_.status -ceq 'enabled' })
$unavailableRows = @($rows | Where-Object { $_.status -ceq 'unavailable' })
$domainSummary = [ordered]@{}
foreach ($domain in @('gpu','network','kernel_lifecycle')) {
    $domainRows = @($rows | Where-Object { $_.domain -ceq $domain })
    $domainSummary[$domain] = [ordered]@{
        assessed = $domainRows.Count
        enabled = @($domainRows | Where-Object { $_.status -ceq 'enabled' }).Count
        unavailable = @($domainRows | Where-Object { $_.status -ceq 'unavailable' }).Count
    }
}

$result = [pscustomobject][ordered]@{
    schema_version = 1
    status = 'passed'
    head_sha = $currentHead
    collected_utc = [DateTime]::UtcNow.ToString('o')
    provider_count = $rows.Count
    enabled_count = $enabledRows.Count
    unavailable_count = $unavailableRows.Count
    domain_summary = [pscustomobject]$domainSummary
    providers = @($rows)
    claims = [ordered]@{
        native_enableability_measured = $true
        start_failure_implies_provider_absence = $false
        start_failure_implies_semantic_absence = $false
        event_delivery_validated = $false
        event_semantics_validated = $false
        trace_completeness = 'not_claimed'
    }
    policy = [ordered]@{
        probe_provider_strict = $true
        combined_profile_provider_strict = $false
        preexisting_session_auto_cancel = $false
        successful_probe_sessions_cancelled_only_when_owned = $true
        raw_wpr_start_output_in_result = $false
    }
}
[IO.File]::WriteAllText(
    $outputFull,
    (($result | ConvertTo-Json -Depth 16) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)

Write-Information -MessageData "Provider enable matrix written: $outputFull" -InformationAction Continue
foreach ($row in $rows) {
    Write-Information -MessageData ("{0}: {1} (exit={2}, error={3})" -f $row.name,$row.status,$row.start_exit_code,$row.start_error_code) -InformationAction Continue
}
Write-Information -MessageData "Enabled providers: $($enabledRows.Count)/$($rows.Count)" -InformationAction Continue
Write-Information -MessageData 'Provider enable failures do not imply semantic absence.' -InformationAction Continue
if ($PassThru) { return $result }
