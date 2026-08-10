[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDirectory,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbSemanticAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-NxbSemanticJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        $Path,
        (($InputObject | ConvertTo-Json -Depth 32) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

function Get-NxbSemanticProperty {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()][AllowNull()][object]$DefaultValue = $null
    )
    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) {
            return $DefaultValue
        }
        if ($current -is [System.Collections.IDictionary]) {
            try {
                if ($current.Contains($segment)) {
                    $current = $current[$segment]
                    continue
                }
            }
            catch {
                return $DefaultValue
            }
            return $DefaultValue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) {
            return $DefaultValue
        }
        $current = $property.Value
    }
    if ($null -eq $current) {
        return $DefaultValue
    }
    return $current
}

function ConvertTo-NxbSemanticBoolean {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$Value,
        [Parameter()][bool]$DefaultValue = $false
    )
    if ($null -eq $Value) {
        return $DefaultValue
    }
    if ($Value -is [bool]) {
        return [bool]$Value
    }
    if ($Value -is [string]) {
        $parsedValue = $false
        if ([bool]::TryParse([string]$Value,[ref]$parsedValue)) {
            return $parsedValue
        }
        return $DefaultValue
    }
    try {
        return [Convert]::ToBoolean($Value,[Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return $DefaultValue
    }
}

function Invoke-NxbSemanticPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Executable,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TestPath,
        [Parameter(Mandatory)][ValidateRange(1,1000)][int]$ExpectedCount,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label
    )

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-semantic-v2-pester-$([guid]::NewGuid().ToString('N'))")
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $childPath = Join-Path $tempRoot 'invoke-pester.ps1'
    $resultPath = Join-Path $tempRoot 'result.json'
    @'
param([string]$TestPath,[string]$ResultPath,[int]$ExpectedCount)
$ErrorActionPreference = 'Stop'
Import-Module Pester -ErrorAction Stop
$result = Invoke-Pester -Path $TestPath -PassThru
$summary = [pscustomobject]@{
    passed = [int]$result.PassedCount
    failed = [int]$result.FailedCount
    skipped = [int]$result.SkippedCount
    total = [int]$result.TotalCount
}
$summary | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
if ($summary.passed -ne $ExpectedCount -or $summary.total -ne $ExpectedCount -or $summary.failed -ne 0 -or $summary.skipped -ne 0) { exit 1 }
'@ | Set-Content -LiteralPath $childPath -Encoding UTF8

    try {
        $childOutput = @(
            & $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath `
                -TestPath $TestPath -ResultPath $resultPath -ExpectedCount $ExpectedCount 2>&1
        )
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $childOutput) {
            Write-Information -MessageData ([string]$line) -InformationAction Continue
        }
        if ($exitCode -ne 0) {
            throw "$Label Pester run failed: exit=$exitCode"
        }
        if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            throw "$Label Pester run did not produce its result receipt."
        }
        $summary = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        return [pscustomobject][ordered]@{
            passed = [int]$summary.passed
            failed = [int]$summary.failed
            skipped = [int]$summary.skipped
            total = [int]$summary.total
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force
        }
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Semantic eligibility V2 certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Semantic eligibility V2 certification requires PowerShell 7.' }
if (-not (Test-NxbSemanticAdministrator)) { throw 'Semantic eligibility V2 certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'Semantic eligibility V2 requires a clean exact-head worktree.'
}

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Semantic eligibility V2 output must remain outside the repository worktree.'
}
if (Test-Path -LiteralPath $outputFull) {
    throw "OutputDirectory already exists: $outputFull"
}

$rawRoot = Join-Path $outputFull 'raw-local'
$reviewRoot = Join-Path $outputFull 'review'
$captureRoot = Join-Path $rawRoot 'semantic-capture'
$tracesRoot = Join-Path $captureRoot 'traces'
$analysisRoot = Join-Path $captureRoot 'analysis'
$buildRoot = Join-Path $rawRoot 'fixture-build'
[IO.Directory]::CreateDirectory($rawRoot) | Out-Null
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
[IO.Directory]::CreateDirectory($tracesRoot) | Out-Null
[IO.Directory]::CreateDirectory($analysisRoot) | Out-Null

$fixtureBuild = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1SemanticFixtureBuild.ps1'
$fixtureTest = Join-Path $repositoryRoot 'tests\Superblock1SemanticFixtureV2.Tests.ps1'
$profileTest = Join-Path $PSScriptRoot 'Test-NxbSuperblock1MultiDomainWprProfile.ps1'
$statisticsScript = Join-Path $PSScriptRoot 'Get-NxbEtlTraceStatistics.ps1'
$inventoryScript = Join-Path $PSScriptRoot 'Get-NxbSuperblock1XperfHeaderInventory.ps1'
$normalizerScript = Join-Path $PSScriptRoot 'ConvertFrom-NxbSuperblock1XperfDumper.ps1'
$correlationScript = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1CorrelationAnalysis.ps1'

$requiredPaths = @(
    $fixtureBuild,$fixtureTest,$profileTest,$statisticsScript,$inventoryScript,
    $normalizerScript,$correlationScript,$PSCommandPath
)
foreach ($requiredPath in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required semantic eligibility V2 component is missing: $requiredPath"
    }
}

Write-Information -MessageData '=== SUPERBLOCK 1 CONTROLLED SAME-PID SEMANTIC ELIGIBILITY V2 ===' -InformationAction Continue
Write-Information -MessageData '[1/9] Full PowerShell parser/analyzer + dual-runtime fixture contract' -InformationAction Continue
foreach ($scriptPath in $requiredPaths) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) {
        throw "PowerShell parser failed: $scriptPath"
    }
}

Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($scriptPath in $requiredPaths) {
        Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error
    }
)
if ($findings.Count -gt 0) {
    throw (
        "Semantic eligibility V2 PSScriptAnalyzer findings: $($findings.Count)`n" +
        (@($findings | ForEach-Object {
            '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message
        }) -join "`n")
    )
}

$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw 'Windows PowerShell 5.1 is unavailable.'
}
$fixturePs7 = Invoke-NxbSemanticPester -Executable $pwsh -TestPath $fixtureTest -ExpectedCount 15 -Label 'PowerShell 7 semantic fixture V2'
$fixturePs51 = Invoke-NxbSemanticPester -Executable $windowsPowerShell -TestPath $fixtureTest -ExpectedCount 15 -Label 'Windows PowerShell 5.1 semantic fixture V2'

Write-Information -MessageData '[2/9] Exact-head native fixture build' -InformationAction Continue
$build = & $fixtureBuild -ExpectedHead $ExpectedHead -OutputDirectory $buildRoot -PassThru
if ([string](Get-NxbSemanticProperty -InputObject $build -Path 'status') -cne 'passed') {
    throw 'Semantic fixture build gate did not pass.'
}
$fixtureExecutable = [string](Get-NxbSemanticProperty -InputObject $build -Path 'executable_path')
if ([string]::IsNullOrWhiteSpace($fixtureExecutable) -or -not (Test-Path -LiteralPath $fixtureExecutable -PathType Leaf)) {
    throw 'Semantic fixture build did not return a usable executable path.'
}

$wpr = (Get-Command wpr.exe -ErrorAction Stop).Source
$xperf = (Get-Command xperf.exe -ErrorAction Stop).Source
$profileContract = & $profileTest -PassThru
$profilePath = [string](Get-NxbSemanticProperty -InputObject $profileContract -Path 'path')
if ([string]::IsNullOrWhiteSpace($profilePath) -or -not (Test-Path -LiteralPath $profilePath -PathType Leaf)) {
    throw 'Semantic eligibility V2 did not resolve the WPR profile path.'
}
$profileReference = "$profilePath!NxbSuperblock1MultiDomain.Verbose"

$etlPath = Join-Path $tracesRoot 'performance.etl'
$stagingEtl = Join-Path ([IO.Path]::GetTempPath()) ("nxb-semantic-v2-$([guid]::NewGuid().ToString('N')).etl")
$dumperPath = Join-Path $rawRoot 'superblock1-semantic-xperf-dumper.txt'
$inventoryPath = Join-Path $reviewRoot 'superblock1-semantic-header-inventory.json'
$fixtureReceiptPath = Join-Path $reviewRoot 'superblock1-semantic-fixture-receipt.json'
$fixtureReceiptArgument = '"' + $fixtureReceiptPath.Replace('"','\"') + '"'
$statusPath = Join-Path $rawRoot 'wpr-status-pre-stop.txt'
$eventsOnePath = Join-Path $rawRoot 'semantic-normalized-events.jsonl'
$coverageOnePath = Join-Path $reviewRoot 'superblock1-semantic-coverage.json'
$eventsTwoPath = Join-Path $rawRoot 'semantic-normalized-events-replay.jsonl'
$coverageTwoPath = Join-Path $rawRoot 'semantic-coverage-replay.json'
$correlationRecordsOne = Join-Path $rawRoot 'semantic-correlation-records.jsonl'
$correlationSummaryOne = Join-Path $reviewRoot 'superblock1-semantic-correlation-summary.json'
$correlationRecordsTwo = Join-Path $rawRoot 'semantic-correlation-records-replay.jsonl'
$correlationSummaryTwo = Join-Path $rawRoot 'semantic-correlation-summary-replay.json'
$traceQualityPath = Join-Path $reviewRoot 'superblock1-semantic-trace-quality.json'
$receiptPath = Join-Path $reviewRoot 'superblock1-semantic-eligibility-certification-receipt.json'
$reviewZipPath = Join-Path $outputFull 'superblock1-semantic-eligibility-review.zip'
$experimentId = "superblock1-semantic-v2-$($currentHead.Substring(0,12))"

$sessionOwned = $false
$fixtureProcess = $null
$fixtureProcessId = $null
$fixtureImageSha = $null
try {
    Write-Information -MessageData '[3/9] Fresh resilient WPR capture + owned native fixture' -InformationAction Continue
    Write-Information -MessageData 'Pre-existing WPR sessions are never auto-cancelled.' -InformationAction Continue
    $startOutput = @(& $wpr -start $profileReference -filemode 2>&1)
    $startExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($startExit -ne 0) {
        throw "WPR start failed; no existing session was cancelled. exit=$startExit output=$($startOutput -join ' ')"
    }
    $sessionOwned = $true
    Start-Sleep -Milliseconds 250

    $fixtureProcess = Start-Process -FilePath $fixtureExecutable -ArgumentList @($fixtureReceiptArgument) -PassThru
    $fixtureProcessId = [int]$fixtureProcess.Id
    $fixtureImageSha = (Get-FileHash -LiteralPath $fixtureExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $fixtureProcess.WaitForExit(30000)) {
        try { $fixtureProcess.Kill() } catch { Write-Warning "Fixture kill failed: $($_.Exception.Message)" }
        throw 'Semantic fixture exceeded its 30 second bounded runtime.'
    }
    if ($fixtureProcess.ExitCode -ne 0) {
        throw "Semantic fixture failed: exit=$($fixtureProcess.ExitCode)"
    }
    if (-not (Test-Path -LiteralPath $fixtureReceiptPath -PathType Leaf)) {
        throw 'Semantic fixture receipt is missing.'
    }

    $fixtureReceipt = Get-Content -LiteralPath $fixtureReceiptPath -Raw | ConvertFrom-Json
    if ([string](Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'status') -cne 'passed') {
        throw 'Semantic fixture receipt is not passed.'
    }
    if ([int](Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'pid' -DefaultValue 0) -ne $fixtureProcessId) {
        throw 'Semantic fixture receipt PID does not match the owned process.'
    }

    $hardwareDeviceCreated = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'gpu.hardware_device_created')
    $warpFallbackUsed = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'gpu.warp_fallback_used' -DefaultValue $true) -DefaultValue $true
    $presentAttempted = [int](Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'gpu.present_calls_attempted' -DefaultValue 0)
    $presentSucceeded = [int](Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'gpu.present_calls_succeeded' -DefaultValue 0)
    if (-not $hardwareDeviceCreated -or $presentAttempted -ne 128 -or $presentSucceeded -le 0 -or $warpFallbackUsed) {
        throw 'Semantic fixture did not establish the bounded hardware D3D11 stimulus.'
    }

    $dnsLookupExecuted = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'network.dns_lookup_executed')
    $loopbackCompleted = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'network.loopback_completed')
    $externalNetworkUsed = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'network.external_network_used' -DefaultValue $true) -DefaultValue $true
    $bytesSent = [int64](Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'network.bytes_sent' -DefaultValue -1)
    $bytesReceived = [int64](Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'network.bytes_received' -DefaultValue -1)
    if (-not $dnsLookupExecuted -or -not $loopbackCompleted -or $externalNetworkUsed -or $bytesSent -ne 65536 -or $bytesReceived -ne 65536) {
        throw 'Semantic fixture loopback/DNS stimulus violated its bounded local-only contract.'
    }

    $registryRead = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'kernel_stimulus.registry_read_executed')
    $registryWrite = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'kernel_stimulus.registry_write_executed' -DefaultValue $true) -DefaultValue $true
    $fileRoundtrip = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'kernel_stimulus.temp_file_roundtrip')
    $workerCreated = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'kernel_stimulus.worker_thread_created')
    $workerJoined = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path 'kernel_stimulus.worker_thread_joined')
    if (-not $registryRead -or $registryWrite -or -not $fileRoundtrip -or -not $workerCreated -or -not $workerJoined) {
        throw 'Semantic fixture kernel stimulus contract failed.'
    }

    foreach ($claimPath in @(
        'claims.etw_event_mapping_validated',
        'claims.present_semantics_validated',
        'claims.network_semantics_validated',
        'claims.kernel_semantics_validated',
        'claims.causal_relationship_validated'
    )) {
        $claimValue = ConvertTo-NxbSemanticBoolean (Get-NxbSemanticProperty -InputObject $fixtureReceipt -Path $claimPath -DefaultValue $true) -DefaultValue $true
        if ($claimValue) {
            throw "Semantic fixture unexpectedly promoted a claim: $claimPath"
        }
    }

    $statusOutput = @(& $wpr -status collectors -details 2>&1)
    [IO.File]::WriteAllLines(
        $statusPath,
        @($statusOutput | ForEach-Object { [string]$_ }),
        [Text.UTF8Encoding]::new($false)
    )

    $stopOutput = @(& $wpr -stop $stagingEtl 2>&1)
    $stopExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($stopExit -ne 0) {
        throw "WPR stop failed: exit=$stopExit output=$($stopOutput -join ' ')"
    }
    $sessionOwned = $false
    if (-not (Test-Path -LiteralPath $stagingEtl -PathType Leaf)) {
        throw 'WPR stop produced no ETL.'
    }
    Move-Item -LiteralPath $stagingEtl -Destination $etlPath -Force

    Write-Information -MessageData '[4/9] Native trace-loss accounting + full local xperf dump' -InformationAction Continue
    $statistics = & $statisticsScript -ExperimentPath $captureRoot -XperfExecutablePath $xperf -PassThru
    foreach ($counterName in @('events_lost','buffers_lost','buffers_written')) {
        $counter = Get-NxbSemanticProperty -InputObject $statistics -Path $counterName
        if ([string](Get-NxbSemanticProperty -InputObject $counter -Path 'status') -cne 'measured') {
            throw "Trace counter is not measured: $counterName"
        }
    }
    $eventsLost = [uint64](Get-NxbSemanticProperty -InputObject $statistics -Path 'events_lost.value' -DefaultValue ([uint64]::MaxValue))
    $buffersLost = [uint64](Get-NxbSemanticProperty -InputObject $statistics -Path 'buffers_lost.value' -DefaultValue ([uint64]::MaxValue))
    $buffersWritten = [uint64](Get-NxbSemanticProperty -InputObject $statistics -Path 'buffers_written.value' -DefaultValue 0)
    if ($eventsLost -ne 0 -or $buffersLost -ne 0 -or $buffersWritten -eq 0) {
        throw "Trace quality failed: EventsLost=$eventsLost BuffersLost=$buffersLost BuffersWritten=$buffersWritten"
    }
    $traceQuality = [pscustomobject][ordered]@{
        schema_version = 2
        status = 'passed'
        events_lost = $eventsLost
        buffers_lost = $buffersLost
        buffers_written = $buffersWritten
        circular_overwrite = 'unknown'
        trace_completeness = 'not_claimed'
    }
    Write-NxbSemanticJson -Path $traceQualityPath -InputObject $traceQuality

    $dumperOutput = @(& $xperf -i $etlPath -o $dumperPath -a dumper 2>&1)
    $dumperExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($dumperExit -ne 0 -or -not (Test-Path -LiteralPath $dumperPath -PathType Leaf)) {
        throw "xperf dumper failed: exit=$dumperExit output=$($dumperOutput -join ' ')"
    }
    $inventory = & $inventoryScript -InputPath $dumperPath -OutputPath $inventoryPath -PassThru
    if ([string](Get-NxbSemanticProperty -InputObject $inventory -Path 'status') -cne 'passed' -or
        [int](Get-NxbSemanticProperty -InputObject $inventory -Path 'header_count' -DefaultValue 0) -le 0) {
        throw 'Semantic header inventory did not pass.'
    }

    Write-Information -MessageData '[5/9] Fresh normalization + same-PID attribution' -InformationAction Continue
    $normalOne = & $normalizerScript -InputPath $dumperPath -EventsOutputPath $eventsOnePath -CoverageOutputPath $coverageOnePath -SourceHead $ExpectedHead -ExperimentId $experimentId -TargetProcessId $fixtureProcessId -PassThru
    if ([string](Get-NxbSemanticProperty -InputObject $normalOne -Path 'status') -cne 'passed') {
        throw 'First semantic normalization did not pass.'
    }
    $coverageOne = Get-Content -LiteralPath $coverageOnePath -Raw | ConvertFrom-Json
    $recognizedCandidates = [int64](Get-NxbSemanticProperty -InputObject $coverageOne -Path 'rows.recognized_candidate_rows' -DefaultValue -1)
    $normalizedRows = [int64](Get-NxbSemanticProperty -InputObject $coverageOne -Path 'rows.normalized_rows' -DefaultValue -2)
    $unresolvedRows = [int64](Get-NxbSemanticProperty -InputObject $coverageOne -Path 'rows.unresolved_schema_rows' -DefaultValue -1)
    $recognizedMalformed = [int64](Get-NxbSemanticProperty -InputObject $coverageOne -Path 'rows.recognized_malformed_rows' -DefaultValue -1)
    if ($recognizedCandidates -le 0 -or $normalizedRows -ne $recognizedCandidates -or $unresolvedRows -ne 0 -or $recognizedMalformed -ne 0) {
        throw "Semantic normalization contract failed: candidates=$recognizedCandidates normalized=$normalizedRows unresolved=$unresolvedRows recognized_malformed=$recognizedMalformed"
    }

    Write-Information -MessageData '[6/9] Deterministic normalization replay' -InformationAction Continue
    $normalTwo = & $normalizerScript -InputPath $dumperPath -EventsOutputPath $eventsTwoPath -CoverageOutputPath $coverageTwoPath -SourceHead $ExpectedHead -ExperimentId $experimentId -TargetProcessId $fixtureProcessId -PassThru
    if ([string](Get-NxbSemanticProperty -InputObject $normalTwo -Path 'status') -cne 'passed') {
        throw 'Second semantic normalization did not pass.'
    }
    $eventsOneSha = (Get-FileHash -LiteralPath $eventsOnePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $eventsTwoSha = (Get-FileHash -LiteralPath $eventsTwoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $coverageOneSha = (Get-FileHash -LiteralPath $coverageOnePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $coverageTwoSha = (Get-FileHash -LiteralPath $coverageTwoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($eventsOneSha -cne $eventsTwoSha -or $coverageOneSha -cne $coverageTwoSha) {
        throw 'Semantic normalization replay is not byte-identical.'
    }

    Write-Information -MessageData '[7/9] Fresh structural correlation + controlled three-domain acceptance' -InformationAction Continue
    $correlationOne = & $correlationScript -InputPath $eventsOnePath -RecordsOutputPath $correlationRecordsOne -SummaryOutputPath $correlationSummaryOne -SourceHead $ExpectedHead -NormalizerHead $ExpectedHead -ExperimentId $experimentId -TargetProcessId $fixtureProcessId -PassThru
    if ([string](Get-NxbSemanticProperty -InputObject $correlationOne -Path 'status') -cne 'passed') {
        throw 'First semantic correlation did not pass.'
    }
    $summaryOne = Get-Content -LiteralPath $correlationSummaryOne -Raw | ConvertFrom-Json
    $targetRows = [int64](Get-NxbSemanticProperty -InputObject $summaryOne -Path 'target_pid.row_count' -DefaultValue 0)
    $targetGpu = [int64](Get-NxbSemanticProperty -InputObject $summaryOne -Path 'target_pid.domain_counts.gpu' -DefaultValue 0)
    $targetNetwork = [int64](Get-NxbSemanticProperty -InputObject $summaryOne -Path 'target_pid.domain_counts.network' -DefaultValue 0)
    $targetKernel = [int64](Get-NxbSemanticProperty -InputObject $summaryOne -Path 'target_pid.domain_counts.kernel_lifecycle' -DefaultValue 0)
    if ($targetRows -le 0 -or $targetGpu -le 0 -or $targetNetwork -le 0 -or $targetKernel -le 0) {
        throw "Controlled same-PID three-domain observability failed: rows=$targetRows gpu=$targetGpu network=$targetNetwork kernel=$targetKernel"
    }

    Write-Information -MessageData '[8/9] Deterministic correlation replay' -InformationAction Continue
    $correlationTwo = & $correlationScript -InputPath $eventsOnePath -RecordsOutputPath $correlationRecordsTwo -SummaryOutputPath $correlationSummaryTwo -SourceHead $ExpectedHead -NormalizerHead $ExpectedHead -ExperimentId $experimentId -TargetProcessId $fixtureProcessId -PassThru
    if ([string](Get-NxbSemanticProperty -InputObject $correlationTwo -Path 'status') -cne 'passed') {
        throw 'Second semantic correlation did not pass.'
    }
    $recordsOneSha = (Get-FileHash -LiteralPath $correlationRecordsOne -Algorithm SHA256).Hash.ToLowerInvariant()
    $recordsTwoSha = (Get-FileHash -LiteralPath $correlationRecordsTwo -Algorithm SHA256).Hash.ToLowerInvariant()
    $summaryOneSha = (Get-FileHash -LiteralPath $correlationSummaryOne -Algorithm SHA256).Hash.ToLowerInvariant()
    $summaryTwoSha = (Get-FileHash -LiteralPath $correlationSummaryTwo -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($recordsOneSha -cne $recordsTwoSha -or $summaryOneSha -cne $summaryTwoSha) {
        throw 'Semantic correlation replay is not byte-identical.'
    }

    Write-Information -MessageData '[9/9] Conservative eligibility receipt + bounded review ZIP' -InformationAction Continue
    $eligibilityReceipt = [pscustomobject][ordered]@{
        schema_version = 2
        status = 'passed'
        head_sha = $currentHead
        experiment_id = $experimentId
        fixture = [ordered]@{
            process_id = $fixtureProcessId
            image_sha256 = $fixtureImageSha
            build_source_sha256 = [string](Get-NxbSemanticProperty -InputObject $build -Path 'source_sha256')
            present_calls_attempted = $presentAttempted
            present_calls_succeeded = $presentSucceeded
            external_network_used = $false
        }
        trace_quality = [ordered]@{
            events_lost = $eventsLost
            buffers_lost = $buffersLost
            buffers_written = $buffersWritten
            circular_overwrite = 'unknown'
            trace_completeness = 'not_claimed'
        }
        normalization = [ordered]@{
            recognized_candidate_rows = $recognizedCandidates
            normalized_rows = $normalizedRows
            unresolved_schema_rows = $unresolvedRows
            recognized_malformed_rows = $recognizedMalformed
            fixture_pid_rows = [int64](Get-NxbSemanticProperty -InputObject $coverageOne -Path 'rows.target_pid_rows' -DefaultValue 0)
            events_sha256 = $eventsOneSha
            replay_events_sha256 = $eventsTwoSha
            coverage_sha256 = $coverageOneSha
            replay_coverage_sha256 = $coverageTwoSha
            byte_identical = $true
        }
        correlation = [ordered]@{
            target_pid_rows = $targetRows
            target_pid_domain_counts = [ordered]@{
                gpu = $targetGpu
                network = $targetNetwork
                kernel_lifecycle = $targetKernel
            }
            pair_record_count = [int64](Get-NxbSemanticProperty -InputObject $summaryOne -Path 'local_pair_record_count' -DefaultValue 0)
            records_sha256 = $recordsOneSha
            replay_records_sha256 = $recordsTwoSha
            summary_sha256 = $summaryOneSha
            replay_summary_sha256 = $summaryTwoSha
            byte_identical = $true
        }
        claims = [ordered]@{
            controlled_fixture_executed = $true
            exact_fixture_pid_attribution = $true
            same_pid_three_domain_observability = $true
            semantic_eligibility_established = $true
            timestamp_unit_resolved = $false
            present_event_mapping_validated = $false
            present_pairing_semantics = $false
            present_success_semantics = $false
            gpu_queue_semantics = $false
            tcp_connection_lifecycle_validated = $false
            network_connection_semantics = $false
            network_latency_semantics = $false
            kernel_lifecycle_semantics = $false
            registry_operation_semantics = $false
            causal_relationship_validated = $false
            root_cause_validated = $false
            trace_completeness = 'not_claimed'
        }
    }
    Write-NxbSemanticJson -Path $receiptPath -InputObject $eligibilityReceipt

    Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZipPath -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $lower = $entry.FullName.ToLowerInvariant()
            if ($lower.EndsWith('.etl') -or
                $lower.EndsWith('.exe') -or
                $lower.EndsWith('.obj') -or
                $lower.Contains('xperf-dumper') -or
                $lower.Contains('normalized-events') -or
                $lower.Contains('correlation-records') -or
                $lower.Contains('wpr-status') -or
                $lower.EndsWith('.wprp')) {
                throw "Forbidden raw/local artifact entered semantic review ZIP: $($entry.FullName)"
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    $postDirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
        throw 'Semantic eligibility V2 dirtied the exact-head worktree.'
    }

    $result = [pscustomobject][ordered]@{
        status = 'passed'
        head_sha = $currentHead
        fixture_contract = [ordered]@{
            powershell7 = "$($fixturePs7.passed)/$($fixturePs7.total)"
            windows_powershell_51 = "$($fixturePs51.passed)/$($fixturePs51.total)"
            analyzer_findings = 0
        }
        fixture_pid = $fixtureProcessId
        fixture_image_sha256 = $fixtureImageSha
        present_calls_attempted = $presentAttempted
        present_calls_succeeded = $presentSucceeded
        events_lost = $eventsLost
        buffers_lost = $buffersLost
        buffers_written = $buffersWritten
        normalized_rows = $normalizedRows
        unresolved_schema_rows = $unresolvedRows
        recognized_malformed_rows = $recognizedMalformed
        target_pid_rows = $targetRows
        target_pid_domain_counts = [pscustomobject][ordered]@{
            gpu = $targetGpu
            network = $targetNetwork
            kernel_lifecycle = $targetKernel
        }
        normalization_replay_byte_identical = $true
        correlation_replay_byte_identical = $true
        review_zip_path = $reviewZipPath
        review_zip_sha256 = (Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        receipt_path = $receiptPath
        receipt_sha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        etl_path_local = $etlPath
        dumper_path_local = $dumperPath
        normalized_events_path_local = $eventsOnePath
        correlation_records_path_local = $correlationRecordsOne
        semantic_claims_enabled = $false
        trace_completeness = 'not_claimed'
    }
    Write-Information -MessageData "SUPERBLOCK semantic eligibility V2 passed: pid=$fixtureProcessId gpu=$targetGpu network=$targetNetwork kernel=$targetKernel" -InformationAction Continue
    if ($PassThru) {
        return $result
    }
}
finally {
    if ($null -ne $fixtureProcess) {
        try { $fixtureProcess.Dispose() } catch { Write-Verbose "Fixture process dispose failed: $($_.Exception.Message)" }
    }
    if ($sessionOwned) {
        Write-Warning 'Cancelling only the WPR session started and owned by this semantic certification run.'
        try { & $wpr -cancel 2>&1 | Out-Null } catch { Write-Warning "Owned WPR cancel failed: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $stagingEtl -PathType Leaf) {
        Remove-Item -LiteralPath $stagingEtl -Force -ErrorAction SilentlyContinue
    }
}
