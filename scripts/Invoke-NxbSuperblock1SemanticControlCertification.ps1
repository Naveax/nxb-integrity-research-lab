[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbSemanticControlAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-NxbSemanticControlJson {
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

function Get-NxbSemanticControlProperty {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter()][AllowNull()][object]$DefaultValue = $null
    )
    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $DefaultValue }
        if ($current -is [System.Collections.IDictionary]) {
            if ($current.Contains($segment)) {
                $current = $current[$segment]
                continue
            }
            return $DefaultValue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $DefaultValue }
        $current = $property.Value
    }
    if ($null -eq $current) { return $DefaultValue }
    return $current
}

function ConvertTo-NxbSemanticControlBoolean {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$Value,
        [Parameter()][bool]$DefaultValue = $false
    )
    if ($null -eq $Value) { return $DefaultValue }
    if ($Value -is [bool]) { return [bool]$Value }
    if ($Value -is [string]) {
        $parsed = $false
        if ([bool]::TryParse([string]$Value,[ref]$parsed)) { return $parsed }
        return $DefaultValue
    }
    try { return [Convert]::ToBoolean($Value,[Globalization.CultureInfo]::InvariantCulture) }
    catch { return $DefaultValue }
}

function Invoke-NxbSemanticControlPester {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$Executable,
        [Parameter(Mandatory)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$TestPath,
        [Parameter(Mandatory)][ValidateRange(1,1000)][int]$ExpectedCount,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Label
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-semantic-controls-pester-$([guid]::NewGuid().ToString('N'))")
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
        $childOutput = @(& $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath -ExpectedCount $ExpectedCount 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $childOutput) { Write-Information -MessageData ([string]$line) -InformationAction Continue }
        if ($exitCode -ne 0) { throw "$Label Pester run failed: exit=$exitCode" }
        $summary = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        return [pscustomobject][ordered]@{
            passed = [int]$summary.passed
            failed = [int]$summary.failed
            skipped = [int]$summary.skipped
            total = [int]$summary.total
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
    }
}

if ($env:OS -cne 'Windows_NT') { throw 'Semantic control certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Semantic control certification requires PowerShell 7.' }
if (-not (Test-NxbSemanticControlAdministrator)) { throw 'Semantic control certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Semantic control exact-head mismatch. Expected=$ExpectedHead actual=$currentHead"
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Semantic control certification requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) { throw 'Output must remain outside the repository.' }
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }

$rawRoot = Join-Path $outputFull 'raw-local'
$reviewRoot = Join-Path $outputFull 'review'
$fixtureReviewRoot = Join-Path $reviewRoot 'fixture-receipts'
$captureRoot = Join-Path $rawRoot 'control-capture'
$tracesRoot = Join-Path $captureRoot 'traces'
$analysisRoot = Join-Path $captureRoot 'analysis'
$buildRoot = Join-Path $rawRoot 'fixture-build'
[IO.Directory]::CreateDirectory($rawRoot) | Out-Null
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
[IO.Directory]::CreateDirectory($fixtureReviewRoot) | Out-Null
[IO.Directory]::CreateDirectory($tracesRoot) | Out-Null
[IO.Directory]::CreateDirectory($analysisRoot) | Out-Null

$buildScript = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1SemanticControlFixtureBuild.ps1'
$testPath = Join-Path $repositoryRoot 'tests\Superblock1SemanticControls.Tests.ps1'
$profileTest = Join-Path $PSScriptRoot 'Test-NxbSuperblock1MultiDomainWprProfile.ps1'
$statisticsScript = Join-Path $PSScriptRoot 'Get-NxbEtlTraceStatistics.ps1'
$inventoryScript = Join-Path $PSScriptRoot 'Get-NxbSuperblock1XperfHeaderInventory.ps1'
$normalizerScript = Join-Path $PSScriptRoot 'ConvertFrom-NxbSuperblock1XperfDumper.ps1'
$analysisScript = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1SemanticControlAnalysis.ps1'
$analysisTool = Join-Path $repositoryRoot 'tools\analyze_superblock1_semantic_controls.py'
$fixtureSource = Join-Path $repositoryRoot 'fixtures\superblock1-semantic-controls\main.cpp'
$requiredPaths = @($buildScript,$testPath,$profileTest,$statisticsScript,$inventoryScript,$normalizerScript,$analysisScript,$analysisTool,$fixtureSource,$PSCommandPath)
foreach ($path in $requiredPaths) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Semantic control component is missing: $path" }
}

Write-Information -MessageData '=== SUPERBLOCK 1 REPEATED ON/OFF SEMANTIC CONTROL CERTIFICATION ===' -InformationAction Continue
Write-Information -MessageData '[1/8] Parser/analyzer + PS7/PS5.1 control contract' -InformationAction Continue
foreach ($scriptPath in @($buildScript,$testPath,$profileTest,$statisticsScript,$inventoryScript,$normalizerScript,$analysisScript,$PSCommandPath)) {
    $tokens = $null
    $parseErrors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$parseErrors)
    if (@($parseErrors).Count -gt 0) { throw "PowerShell parser failed: $scriptPath" }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($scriptPath in @($buildScript,$testPath,$profileTest,$statisticsScript,$inventoryScript,$normalizerScript,$analysisScript,$PSCommandPath)) {
        Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error
    }
)
if ($findings.Count -gt 0) {
    throw ("Semantic control PSScriptAnalyzer findings: $($findings.Count)`n" + (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n"))
}
$python = Get-Command python.exe -ErrorAction SilentlyContinue
if ($null -eq $python) { $python = Get-Command python -ErrorAction Stop }
& $python.Source -m py_compile $analysisTool
if ($LASTEXITCODE -ne 0) { throw 'Semantic control Python syntax check failed.' }
$pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw 'Windows PowerShell 5.1 is unavailable.' }
$ps7 = Invoke-NxbSemanticControlPester -Executable $pwsh -TestPath $testPath -ExpectedCount 18 -Label 'PowerShell 7 semantic controls'
$ps51 = Invoke-NxbSemanticControlPester -Executable $windowsPowerShell -TestPath $testPath -ExpectedCount 18 -Label 'Windows PowerShell 5.1 semantic controls'

Write-Information -MessageData '[2/8] Exact-head semantic control fixture build' -InformationAction Continue
$build = & $buildScript -ExpectedHead $ExpectedHead -OutputDirectory $buildRoot -PassThru
if ([string](Get-NxbSemanticControlProperty -InputObject $build -Path 'status') -cne 'passed') { throw 'Semantic control fixture build did not pass.' }
$fixtureExecutable = [string](Get-NxbSemanticControlProperty -InputObject $build -Path 'executable_path')
if ([string]::IsNullOrWhiteSpace($fixtureExecutable) -or -not (Test-Path -LiteralPath $fixtureExecutable -PathType Leaf)) { throw 'Control fixture executable is missing.' }

$wpr = (Get-Command wpr.exe -ErrorAction Stop).Source
$xperf = (Get-Command xperf.exe -ErrorAction Stop).Source
$profileContract = & $profileTest -PassThru
$profilePath = [string](Get-NxbSemanticControlProperty -InputObject $profileContract -Path 'path')
if ([string]::IsNullOrWhiteSpace($profilePath) -or -not (Test-Path -LiteralPath $profilePath -PathType Leaf)) { throw 'WPR profile path was not resolved.' }
$profileReference = "$profilePath!NxbSuperblock1MultiDomain.Verbose"

$scenarioDefinitions = @(
    [pscustomobject][ordered]@{ id='all_on_a'; mode='all_on'; repeat='A' },
    [pscustomobject][ordered]@{ id='gpu_off_a'; mode='gpu_off'; repeat='A' },
    [pscustomobject][ordered]@{ id='network_off_a'; mode='network_off'; repeat='A' },
    [pscustomobject][ordered]@{ id='kernel_off_a'; mode='kernel_off'; repeat='A' },
    [pscustomobject][ordered]@{ id='minimal_a'; mode='minimal'; repeat='A' },
    [pscustomobject][ordered]@{ id='minimal_b'; mode='minimal'; repeat='B' },
    [pscustomobject][ordered]@{ id='kernel_off_b'; mode='kernel_off'; repeat='B' },
    [pscustomobject][ordered]@{ id='network_off_b'; mode='network_off'; repeat='B' },
    [pscustomobject][ordered]@{ id='gpu_off_b'; mode='gpu_off'; repeat='B' },
    [pscustomobject][ordered]@{ id='all_on_b'; mode='all_on'; repeat='B' }
)

$etlPath = Join-Path $tracesRoot 'performance.etl'
$stagingEtl = Join-Path ([IO.Path]::GetTempPath()) ("nxb-semantic-controls-$([guid]::NewGuid().ToString('N')).etl")
$dumperPath = Join-Path $rawRoot 'superblock1-semantic-controls-xperf-dumper.txt'
$inventoryPath = Join-Path $reviewRoot 'superblock1-semantic-controls-header-inventory.json'
$traceQualityPath = Join-Path $reviewRoot 'superblock1-semantic-controls-trace-quality.json'
$eventsOnePath = Join-Path $rawRoot 'semantic-controls-normalized-events.jsonl'
$coverageOnePath = Join-Path $reviewRoot 'superblock1-semantic-controls-coverage.json'
$eventsTwoPath = Join-Path $rawRoot 'semantic-controls-normalized-events-replay.jsonl'
$coverageTwoPath = Join-Path $rawRoot 'semantic-controls-coverage-replay.json'
$manifestPath = Join-Path $rawRoot 'semantic-controls-manifest.json'
$summaryOnePath = Join-Path $reviewRoot 'superblock1-semantic-controls-summary.json'
$summaryTwoPath = Join-Path $rawRoot 'superblock1-semantic-controls-summary-replay.json'
$receiptPath = Join-Path $reviewRoot 'superblock1-semantic-controls-certification-receipt.json'
$reviewZipPath = Join-Path $outputFull 'superblock1-semantic-controls-review.zip'
$experimentId = "superblock1-semantic-controls-$($currentHead.Substring(0,12))"

$sessionOwned = $false
$scenarioManifest = @()
$fixtureProcesses = @()
try {
    Write-Information -MessageData '[3/8] One fresh WPR session + ten alternating owned control fixtures' -InformationAction Continue
    Write-Information -MessageData 'Pre-existing WPR sessions are never auto-cancelled.' -InformationAction Continue
    $startOutput = @(& $wpr -start $profileReference -filemode 2>&1)
    $startExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($startExit -ne 0) { throw "WPR start failed; existing session untouched. exit=$startExit output=$($startOutput -join ' ')" }
    $sessionOwned = $true
    Start-Sleep -Milliseconds 250

    foreach ($scenario in $scenarioDefinitions) {
        $fixtureReceiptPath = Join-Path $fixtureReviewRoot ("$($scenario.id).json")
        $fixtureReceiptArgument = '"' + $fixtureReceiptPath + '"'
        $process = Start-Process -FilePath $fixtureExecutable -ArgumentList @($fixtureReceiptArgument,[string]$scenario.mode) -PassThru
        $fixtureProcesses += $process
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch { Write-Warning "Fixture kill failed: $($_.Exception.Message)" }
            throw "Semantic control fixture exceeded 30 seconds: $($scenario.id)"
        }
        if ($process.ExitCode -ne 0) { throw "Semantic control fixture failed: scenario=$($scenario.id) exit=$($process.ExitCode)" }
        if (-not (Test-Path -LiteralPath $fixtureReceiptPath -PathType Leaf)) { throw "Fixture receipt missing: $($scenario.id)" }
        $fixtureReceipt = Get-Content -LiteralPath $fixtureReceiptPath -Raw | ConvertFrom-Json
        if ([string](Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'status') -cne 'passed') { throw "Fixture receipt not passed: $($scenario.id)" }
        if ([string](Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'mode') -cne [string]$scenario.mode) { throw "Fixture mode mismatch: $($scenario.id)" }
        if ([int](Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'pid' -DefaultValue 0) -ne [int]$process.Id) { throw "Fixture PID mismatch: $($scenario.id)" }

        $gpuEnabled = [string]$scenario.mode -in @('all_on','network_off','kernel_off')
        $networkEnabled = [string]$scenario.mode -in @('all_on','gpu_off','kernel_off')
        $kernelEnabled = [string]$scenario.mode -in @('all_on','gpu_off','network_off')
        $reportedGpuEnabled = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'stimulus_enabled.gpu')
        $reportedNetworkEnabled = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'stimulus_enabled.network')
        $reportedKernelEnabled = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'stimulus_enabled.explicit_kernel')
        if ($reportedGpuEnabled -ne $gpuEnabled -or $reportedNetworkEnabled -ne $networkEnabled -or $reportedKernelEnabled -ne $kernelEnabled) { throw "Fixture stimulus flags mismatch: $($scenario.id)" }

        $presentAttempted = [int](Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'gpu.present_calls_attempted' -DefaultValue 0)
        $presentSucceeded = [int](Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'gpu.present_calls_succeeded' -DefaultValue 0)
        $hardwareDevice = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'gpu.hardware_device_created')
        if ($gpuEnabled) {
            if (-not $hardwareDevice -or $presentAttempted -ne 128 -or $presentSucceeded -ne 128) { throw "GPU positive-control fixture contract failed: $($scenario.id)" }
        }
        elseif ($hardwareDevice -or $presentAttempted -ne 0 -or $presentSucceeded -ne 0) { throw "GPU negative-control fixture contract failed: $($scenario.id)" }

        $dns = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'network.dns_lookup_executed')
        $loopback = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'network.loopback_completed')
        $external = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'network.external_network_used' -DefaultValue $true) -DefaultValue $true
        $sent = [int64](Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'network.bytes_sent' -DefaultValue -1)
        $received = [int64](Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'network.bytes_received' -DefaultValue -1)
        if ($networkEnabled) {
            if (-not $dns -or -not $loopback -or $external -or $sent -ne 65536 -or $received -ne 65536) { throw "Network positive-control fixture contract failed: $($scenario.id)" }
        }
        elseif ($dns -or $loopback -or $external -or $sent -ne 0 -or $received -ne 0) { throw "Network negative-control fixture contract failed: $($scenario.id)" }

        $registryRead = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'kernel_stimulus.registry_read_executed')
        $registryWrite = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'kernel_stimulus.registry_write_executed' -DefaultValue $true) -DefaultValue $true
        $fileRoundtrip = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'kernel_stimulus.temp_file_roundtrip')
        $workerCreated = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'kernel_stimulus.worker_thread_created')
        $workerJoined = ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path 'kernel_stimulus.worker_thread_joined')
        if ($kernelEnabled) {
            if (-not $registryRead -or $registryWrite -or -not $fileRoundtrip -or -not $workerCreated -or -not $workerJoined) { throw "Kernel positive-control fixture contract failed: $($scenario.id)" }
        }
        elseif ($registryRead -or $registryWrite -or $fileRoundtrip -or $workerCreated -or $workerJoined) { throw "Kernel negative-control fixture contract failed: $($scenario.id)" }

        foreach ($claimPath in @('claims.etw_event_mapping_validated','claims.present_semantics_validated','claims.network_semantics_validated','claims.kernel_semantics_validated','claims.causal_relationship_validated')) {
            if (ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $fixtureReceipt -Path $claimPath -DefaultValue $true) -DefaultValue $true) {
                throw "Fixture unexpectedly promoted claim: scenario=$($scenario.id) claim=$claimPath"
            }
        }
        $scenarioManifest += [pscustomobject][ordered]@{
            id = [string]$scenario.id
            mode = [string]$scenario.mode
            repeat = [string]$scenario.repeat
            fixture_receipt_path = [IO.Path]::GetFullPath($fixtureReceiptPath)
            pid = [int]$process.Id
        }
        Start-Sleep -Milliseconds 100
    }

    $stopOutput = @(& $wpr -stop $stagingEtl 2>&1)
    $stopExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($stopExit -ne 0) { throw "WPR stop failed: exit=$stopExit output=$($stopOutput -join ' ')" }
    $sessionOwned = $false
    if (-not (Test-Path -LiteralPath $stagingEtl -PathType Leaf)) { throw 'WPR stop produced no ETL.' }
    Move-Item -LiteralPath $stagingEtl -Destination $etlPath -Force

    Write-Information -MessageData '[4/8] Trace quality + xperf inventory' -InformationAction Continue
    $statistics = & $statisticsScript -ExperimentPath $captureRoot -XperfExecutablePath $xperf -PassThru
    $eventsLost = [uint64](Get-NxbSemanticControlProperty -InputObject $statistics -Path 'events_lost.value' -DefaultValue ([uint64]::MaxValue))
    $buffersLost = [uint64](Get-NxbSemanticControlProperty -InputObject $statistics -Path 'buffers_lost.value' -DefaultValue ([uint64]::MaxValue))
    $buffersWritten = [uint64](Get-NxbSemanticControlProperty -InputObject $statistics -Path 'buffers_written.value' -DefaultValue 0)
    foreach ($counterName in @('events_lost','buffers_lost','buffers_written')) {
        if ([string](Get-NxbSemanticControlProperty -InputObject (Get-NxbSemanticControlProperty -InputObject $statistics -Path $counterName) -Path 'status') -cne 'measured') { throw "Trace counter not measured: $counterName" }
    }
    if ($eventsLost -ne 0 -or $buffersLost -ne 0 -or $buffersWritten -eq 0) { throw "Trace quality failed: EventsLost=$eventsLost BuffersLost=$buffersLost BuffersWritten=$buffersWritten" }
    $traceQuality = [pscustomobject][ordered]@{ schema_version=1; status='passed'; events_lost=$eventsLost; buffers_lost=$buffersLost; buffers_written=$buffersWritten; circular_overwrite='unknown'; trace_completeness='not_claimed' }
    Write-NxbSemanticControlJson -Path $traceQualityPath -InputObject $traceQuality
    $dumperOutput = @(& $xperf -i $etlPath -o $dumperPath -a dumper 2>&1)
    $dumperExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($dumperExit -ne 0 -or -not (Test-Path -LiteralPath $dumperPath -PathType Leaf)) { throw "xperf dumper failed: exit=$dumperExit output=$($dumperOutput -join ' ')" }
    $inventory = & $inventoryScript -InputPath $dumperPath -OutputPath $inventoryPath -PassThru
    if ([string](Get-NxbSemanticControlProperty -InputObject $inventory -Path 'status') -cne 'passed') { throw 'Header inventory did not pass.' }

    Write-Information -MessageData '[5/8] Normalize twice + byte-identical replay' -InformationAction Continue
    $manifest = [pscustomobject][ordered]@{ schema_version=1; experiment_id=$experimentId; source_head=$currentHead; scenarios=@($scenarioManifest) }
    Write-NxbSemanticControlJson -Path $manifestPath -InputObject $manifest
    $targetPid = [int]$scenarioManifest[0].pid
    $normalOne = & $normalizerScript -InputPath $dumperPath -EventsOutputPath $eventsOnePath -CoverageOutputPath $coverageOnePath -SourceHead $ExpectedHead -ExperimentId $experimentId -TargetProcessId $targetPid -PassThru
    $normalTwo = & $normalizerScript -InputPath $dumperPath -EventsOutputPath $eventsTwoPath -CoverageOutputPath $coverageTwoPath -SourceHead $ExpectedHead -ExperimentId $experimentId -TargetProcessId $targetPid -PassThru
    if ([string](Get-NxbSemanticControlProperty -InputObject $normalOne -Path 'status') -cne 'passed' -or [string](Get-NxbSemanticControlProperty -InputObject $normalTwo -Path 'status') -cne 'passed') { throw 'Semantic control normalization did not pass twice.' }
    $coverage = Get-Content -LiteralPath $coverageOnePath -Raw | ConvertFrom-Json
    $recognizedCandidates = [int64](Get-NxbSemanticControlProperty -InputObject $coverage -Path 'rows.recognized_candidate_rows' -DefaultValue -1)
    $normalizedRows = [int64](Get-NxbSemanticControlProperty -InputObject $coverage -Path 'rows.normalized_rows' -DefaultValue -2)
    $unresolvedRows = [int64](Get-NxbSemanticControlProperty -InputObject $coverage -Path 'rows.unresolved_schema_rows' -DefaultValue -1)
    $recognizedMalformed = [int64](Get-NxbSemanticControlProperty -InputObject $coverage -Path 'rows.recognized_malformed_rows' -DefaultValue -1)
    if ($recognizedCandidates -le 0 -or $normalizedRows -ne $recognizedCandidates -or $unresolvedRows -ne 0 -or $recognizedMalformed -ne 0) { throw "Normalization contract failed: candidates=$recognizedCandidates normalized=$normalizedRows unresolved=$unresolvedRows malformed=$recognizedMalformed" }
    $eventsOneSha = (Get-FileHash -LiteralPath $eventsOnePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $eventsTwoSha = (Get-FileHash -LiteralPath $eventsTwoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $coverageOneSha = (Get-FileHash -LiteralPath $coverageOnePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $coverageTwoSha = (Get-FileHash -LiteralPath $coverageTwoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($eventsOneSha -cne $eventsTwoSha -or $coverageOneSha -cne $coverageTwoSha) { throw 'Semantic control normalization replay is not byte-identical.' }

    Write-Information -MessageData '[6/8] Repeated ON/OFF differential analysis + replay' -InformationAction Continue
    $analysisOne = & $analysisScript -InputPath $eventsOnePath -ManifestPath $manifestPath -OutputPath $summaryOnePath -SourceHead $ExpectedHead -ExperimentId $experimentId -PassThru
    $analysisTwo = & $analysisScript -InputPath $eventsOnePath -ManifestPath $manifestPath -OutputPath $summaryTwoPath -SourceHead $ExpectedHead -ExperimentId $experimentId -PassThru
    if ([string](Get-NxbSemanticControlProperty -InputObject $analysisOne -Path 'status') -cne 'passed' -or [string](Get-NxbSemanticControlProperty -InputObject $analysisTwo -Path 'status') -cne 'passed') { throw 'Semantic control analysis did not pass twice.' }
    $summaryOneSha = (Get-FileHash -LiteralPath $summaryOnePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $summaryTwoSha = (Get-FileHash -LiteralPath $summaryTwoPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($summaryOneSha -cne $summaryTwoSha) { throw 'Semantic control analysis replay is not byte-identical.' }
    $controlSummary = Get-Content -LiteralPath $summaryOnePath -Raw | ConvertFrom-Json
    if (-not (ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $controlSummary -Path 'claims.controlled_present_count_mapping_validated'))) { throw 'Controlled Present count mapping did not validate.' }
    if (-not (ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $controlSummary -Path 'claims.controlled_network_activity_mapping_validated'))) { throw 'Controlled network activity mapping did not validate.' }
    foreach ($claimPath in @('claims.present_event_mapping_generalized','claims.present_pairing_semantics','claims.present_success_semantics','claims.tcp_connection_lifecycle_validated','claims.network_latency_semantics','claims.kernel_lifecycle_semantics','claims.registry_operation_semantics','claims.timestamp_unit_resolved','claims.causal_relationship_validated','claims.root_cause_validated')) {
        if (ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $controlSummary -Path $claimPath -DefaultValue $true) -DefaultValue $true) { throw "Semantic control unexpectedly promoted claim: $claimPath" }
    }

    Write-Information -MessageData '[7/8] Conservative Round-2 certification receipt' -InformationAction Continue
    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        status = 'passed'
        head_sha = $currentHead
        experiment_id = $experimentId
        fixture_build = [ordered]@{ executable_sha256=[string](Get-NxbSemanticControlProperty -InputObject $build -Path 'executable_sha256'); source_sha256=[string](Get-NxbSemanticControlProperty -InputObject $build -Path 'source_sha256') }
        scenario_count = $scenarioManifest.Count
        scenarios = @($scenarioManifest | ForEach-Object { [ordered]@{ id=$_.id; mode=$_.mode; repeat=$_.repeat; pid=$_.pid } })
        trace_quality = [ordered]@{ events_lost=$eventsLost; buffers_lost=$buffersLost; buffers_written=$buffersWritten; circular_overwrite='unknown'; trace_completeness='not_claimed' }
        normalization = [ordered]@{ recognized_candidate_rows=$recognizedCandidates; normalized_rows=$normalizedRows; unresolved_schema_rows=$unresolvedRows; recognized_malformed_rows=$recognizedMalformed; events_sha256=$eventsOneSha; replay_events_sha256=$eventsTwoSha; coverage_sha256=$coverageOneSha; replay_coverage_sha256=$coverageTwoSha; byte_identical=$true }
        semantic_controls = [ordered]@{
            summary_sha256=$summaryOneSha
            replay_summary_sha256=$summaryTwoSha
            byte_identical=$true
            controlled_present_count_mapping_validated=$true
            controlled_network_activity_mapping_validated=$true
            present_field_shape_asymmetry_reproduced=ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $controlSummary -Path 'differential.present_pairing_eligibility.field_shape_asymmetry_reproduced')
            exact_named_present_pairing_eligible=ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $controlSummary -Path 'differential.present_pairing_eligibility.exact_named_identifier_pairing_eligible')
        }
        claims = [ordered]@{
            controlled_present_count_mapping_validated=$true
            controlled_network_activity_mapping_validated=$true
            present_event_mapping_generalized=$false
            present_pairing_semantics=$false
            present_success_semantics=$false
            tcp_connection_lifecycle_validated=$false
            network_latency_semantics=$false
            kernel_lifecycle_semantics=$false
            registry_operation_semantics=$false
            timestamp_unit_resolved=$false
            causal_relationship_validated=$false
            root_cause_validated=$false
            trace_completeness='not_claimed'
        }
    }
    Write-NxbSemanticControlJson -Path $receiptPath -InputObject $receipt

    Write-Information -MessageData '[8/8] Bounded review ZIP + raw evidence boundary audit' -InformationAction Continue
    Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZipPath -Force
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $lower = $entry.FullName.ToLowerInvariant()
            if ($lower.EndsWith('.etl') -or $lower.EndsWith('.exe') -or $lower.EndsWith('.obj') -or $lower.Contains('xperf-dumper') -or $lower.Contains('normalized-events') -or $lower.Contains('manifest') -or $lower.Contains('wpr-status') -or $lower.EndsWith('.wprp')) { throw "Forbidden raw/local artifact entered review ZIP: $($entry.FullName)" }
        }
    }
    finally { $archive.Dispose() }
    $postDirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) { throw 'Semantic control certification dirtied the exact-head worktree.' }

    $result = [pscustomobject][ordered]@{
        status='passed'
        head_sha=$currentHead
        fixture_contract=[ordered]@{ powershell7="$($ps7.passed)/$($ps7.total)"; windows_powershell_51="$($ps51.passed)/$($ps51.total)"; analyzer_findings=0 }
        scenario_count=$scenarioManifest.Count
        events_lost=$eventsLost
        buffers_lost=$buffersLost
        buffers_written=$buffersWritten
        normalized_rows=$normalizedRows
        unresolved_schema_rows=$unresolvedRows
        recognized_malformed_rows=$recognizedMalformed
        normalization_replay_byte_identical=$true
        semantic_control_replay_byte_identical=$true
        controlled_present_count_mapping_validated=$true
        controlled_network_activity_mapping_validated=$true
        present_field_shape_asymmetry_reproduced=ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $controlSummary -Path 'differential.present_pairing_eligibility.field_shape_asymmetry_reproduced')
        exact_named_present_pairing_eligible=ConvertTo-NxbSemanticControlBoolean (Get-NxbSemanticControlProperty -InputObject $controlSummary -Path 'differential.present_pairing_eligibility.exact_named_identifier_pairing_eligible')
        review_zip_path=$reviewZipPath
        review_zip_sha256=(Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        summary_path=$summaryOnePath
        summary_sha256=$summaryOneSha
        trace_completeness='not_claimed'
    }
    Write-Information -MessageData "SUPERBLOCK semantic controls passed: scenarios=$($result.scenario_count) present_mapping=$($result.controlled_present_count_mapping_validated) network_mapping=$($result.controlled_network_activity_mapping_validated)" -InformationAction Continue
    if ($PassThru) { return $result }
}
finally {
    foreach ($process in $fixtureProcesses) { try { $process.Dispose() } catch { Write-Verbose "Fixture process dispose failed: $($_.Exception.Message)" } }
    if ($sessionOwned) {
        Write-Warning 'Cancelling only the WPR session started and owned by this semantic control run.'
        try { & $wpr -cancel 2>&1 | Out-Null } catch { Write-Warning "Owned WPR cancel failed: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $stagingEtl -PathType Leaf) { Remove-Item -LiteralPath $stagingEtl -Force -ErrorAction SilentlyContinue }
}
