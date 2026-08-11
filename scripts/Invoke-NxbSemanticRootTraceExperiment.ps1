[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-NxbSemanticRootTraceAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NxbSemanticRootTraceProperty {
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object]$InputObject,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][AllowNull()][object]$DefaultValue = $null
    )
    $current = $InputObject
    foreach ($segment in $Path.Split('.')) {
        if ($null -eq $current) { return $DefaultValue }
        if ($current -is [System.Collections.IDictionary]) {
            if (-not $current.Contains($segment)) { return $DefaultValue }
            $current = $current[$segment]
            continue
        }
        $property = $current.PSObject.Properties[$segment]
        if ($null -eq $property) { return $DefaultValue }
        $current = $property.Value
    }
    if ($null -eq $current) { return $DefaultValue }
    return $current
}

function Write-NxbSemanticRootTraceJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($Path),(($InputObject | ConvertTo-Json -Depth 32) + [Environment]::NewLine),[Text.UTF8Encoding]::new($false))
}

function Invoke-NxbSemanticRootTraceNative {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Executable,[Parameter(Mandatory)][string[]]$ArgumentList)
    $previousErrorActionPreference = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativePreferenceAvailable = ($null -ne $nativePreferenceVariable)
    $previousNativePreference = if ($nativePreferenceAvailable) { [bool]$nativePreferenceVariable.Value } else { $null }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local }
        $output = @(& $Executable @ArgumentList 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
        if ($nativePreferenceAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $previousNativePreference -Scope Local }
    }
    return [pscustomobject][ordered]@{ exit_code=$exitCode; output=@($output | ForEach-Object { [string]$_ }) }
}

if ($env:OS -cne 'Windows_NT') { throw 'Root-cause/trace semantic experiment requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Root-cause/trace semantic experiment requires PowerShell 7.' }
if (-not (Test-NxbSemanticRootTraceAdministrator)) { throw 'Root-cause/trace semantic experiment requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw ('Root/trace exact-head mismatch. Expected={0} actual={1}' -f $ExpectedHead,$currentHead) }
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Root/trace experiment requires a clean exact-head worktree.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $outputFull) { throw ('Root/trace output already exists: {0}' -f $outputFull) }
$rawRoot = Join-Path $outputFull 'raw-local'
$reviewRoot = Join-Path $outputFull 'review'
$captureRoot = Join-Path $rawRoot 'capture'
$traceRoot = Join-Path $captureRoot 'traces'
$analysisRoot = Join-Path $captureRoot 'analysis'
$fixtureRoot = Join-Path $reviewRoot 'fixture-receipts'
$buildRoot = Join-Path $rawRoot 'fixture-build'
foreach ($directory in @($rawRoot,$reviewRoot,$captureRoot,$traceRoot,$analysisRoot,$fixtureRoot)) { [IO.Directory]::CreateDirectory($directory) | Out-Null }

$profilePath = Join-Path $repositoryRoot 'profiles\Nxb.SemanticHardeningSequential.wprp'
$buildScript = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1SemanticControlFixtureBuild.ps1'
$statisticsScript = Join-Path $PSScriptRoot 'Get-NxbEtlTraceStatistics.ps1'
$normalizerScript = Join-Path $PSScriptRoot 'ConvertFrom-NxbSuperblock1XperfDumper.ps1'
$analysisScript = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1SemanticControlAnalysis.ps1'
foreach ($requiredPath in @($profilePath,$buildScript,$statisticsScript,$normalizerScript,$analysisScript)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) { throw ('Root/trace component missing: {0}' -f $requiredPath) }
}

$wpr = (Get-Command wpr.exe -ErrorAction Stop).Source
$xperf = (Get-Command xperf.exe -ErrorAction Stop).Source
$profileParse = Invoke-NxbSemanticRootTraceNative -Executable $wpr -ArgumentList @('-profiles',$profilePath)
if ($profileParse.exit_code -ne 0 -or (($profileParse.output -join "`n") -notmatch 'NxbSemanticHardeningSequential')) { throw 'Part 2 sequential WPR profile failed native parsing.' }

$build = & $buildScript -ExpectedHead $ExpectedHead -OutputDirectory $buildRoot -PassThru
$fixtureExecutable = [string](Get-NxbSemanticRootTraceProperty -InputObject $build -Path 'executable_path')
if ([string](Get-NxbSemanticRootTraceProperty -InputObject $build -Path 'status') -cne 'passed' -or -not (Test-Path -LiteralPath $fixtureExecutable -PathType Leaf)) { throw 'Semantic-control fixture build failed.' }

$scenarioDefinition = @(
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
$profileReference = $profilePath + '!NxbSemanticHardeningSequential.Verbose'
$etlPath = Join-Path $traceRoot 'performance.etl'
$stagingEtl = Join-Path ([IO.Path]::GetTempPath()) ('nxb-semantic-hardening-{0}.etl' -f [Guid]::NewGuid().ToString('N'))
$dumperPath = Join-Path $rawRoot 'xperf-dumper.txt'
$eventsOnePath = Join-Path $rawRoot 'normalized-events.jsonl'
$coverageOnePath = Join-Path $reviewRoot 'coverage.json'
$eventsTwoPath = Join-Path $rawRoot 'normalized-events-replay.jsonl'
$coverageTwoPath = Join-Path $rawRoot 'coverage-replay.json'
$manifestPath = Join-Path $rawRoot 'scenario-manifest.json'
$summaryOnePath = Join-Path $reviewRoot 'semantic-control-summary.json'
$summaryTwoPath = Join-Path $rawRoot 'semantic-control-summary-replay.json'
$experimentPath = Join-Path $reviewRoot 'root-trace-experiment.json'
$experimentId = 'semantic-hardening-' + $currentHead.Substring(0,12)

$sessionOwned = $false
$fixtureProcess = [System.Collections.Generic.List[Diagnostics.Process]]::new()
$scenarioManifest = [System.Collections.Generic.List[object]]::new()
$startedUtc = [DateTime]::UtcNow
try {
    $start = Invoke-NxbSemanticRootTraceNative -Executable $wpr -ArgumentList @('-start',$profileReference,'-filemode')
    if ($start.exit_code -ne 0) { throw ('WPR sequential start failed: exit={0}' -f $start.exit_code) }
    $sessionOwned = $true
    Start-Sleep -Milliseconds 250

    foreach ($scenario in $scenarioDefinition) {
        $fixtureReceiptPath = Join-Path $fixtureRoot ($scenario.id + '.json')
        $receiptArgument = '"' + $fixtureReceiptPath + '"'
        $process = Start-Process -FilePath $fixtureExecutable -ArgumentList @($receiptArgument,[string]$scenario.mode) -PassThru
        $fixtureProcess.Add($process)
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch { Write-Verbose -Message ('Fixture kill failed: {0}' -f $_.Exception.GetType().FullName) }
            throw ('Semantic fixture exceeded 30 seconds: {0}' -f $scenario.id)
        }
        if ($process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $fixtureReceiptPath -PathType Leaf)) { throw ('Semantic fixture failed: {0}' -f $scenario.id) }
        $fixtureReceipt = Get-Content -LiteralPath $fixtureReceiptPath -Raw | ConvertFrom-Json
        if ([string]$fixtureReceipt.status -cne 'passed' -or [string]$fixtureReceipt.mode -cne [string]$scenario.mode) { throw ('Semantic fixture receipt mismatch: {0}' -f $scenario.id) }
        $scenarioManifest.Add([pscustomobject][ordered]@{ id=[string]$scenario.id; mode=[string]$scenario.mode; repeat=[string]$scenario.repeat; fixture_receipt_path=[IO.Path]::GetFullPath($fixtureReceiptPath); pid=[int]$process.Id })
    }

    $stop = Invoke-NxbSemanticRootTraceNative -Executable $wpr -ArgumentList @('-stop',$stagingEtl)
    if ($stop.exit_code -ne 0) { throw ('WPR sequential stop failed: exit={0}' -f $stop.exit_code) }
    $sessionOwned = $false
    if (-not (Test-Path -LiteralPath $stagingEtl -PathType Leaf)) { throw 'WPR stop produced no ETL.' }
    Move-Item -LiteralPath $stagingEtl -Destination $etlPath -Force
}
finally {
    if ($sessionOwned) {
        $cancel = Invoke-NxbSemanticRootTraceNative -Executable $wpr -ArgumentList @('-cancel')
        if ($cancel.exit_code -ne 0) { Write-Warning ('Owned WPR cancellation failed: exit={0}' -f $cancel.exit_code) }
    }
    if (Test-Path -LiteralPath $stagingEtl -PathType Leaf) { Remove-Item -LiteralPath $stagingEtl -Force }
    foreach ($process in $fixtureProcess) { try { $process.Dispose() } catch { Write-Verbose -Message 'Fixture process dispose failed.' } }
}

$etlLength = (Get-Item -LiteralPath $etlPath).Length
$sequentialCapacityBytes = 512L * 1024L * 1024L
$capacityReached = ($etlLength -ge $sequentialCapacityBytes)
if ($capacityReached) { throw ('Sequential trace reached the conservative 512 MiB capacity boundary: bytes={0}' -f $etlLength) }

$statistics = & $statisticsScript -ExperimentPath $captureRoot -XperfExecutablePath $xperf -PassThru -Confirm:$false
$statisticsStatus = [string](Get-NxbSemanticRootTraceProperty -InputObject $statistics -Path 'status' -DefaultValue 'failed')
$eventsLostStatus = [string](Get-NxbSemanticRootTraceProperty -InputObject $statistics -Path 'events_lost.status' -DefaultValue 'failed')
$buffersLostStatus = [string](Get-NxbSemanticRootTraceProperty -InputObject $statistics -Path 'buffers_lost.status' -DefaultValue 'failed')
$buffersWrittenStatus = [string](Get-NxbSemanticRootTraceProperty -InputObject $statistics -Path 'buffers_written.status' -DefaultValue 'failed')
if ($statisticsStatus -cne 'measured' -or $eventsLostStatus -cne 'measured' -or $buffersLostStatus -cne 'measured' -or $buffersWrittenStatus -cne 'measured') {
    throw ('Trace statistics evidence is not fully measured: statistics={0} EventsLost={1} BuffersLost={2} BuffersWritten={3}' -f $statisticsStatus,$eventsLostStatus,$buffersLostStatus,$buffersWrittenStatus)
}
$eventsLost = [uint64](Get-NxbSemanticRootTraceProperty -InputObject $statistics -Path 'events_lost.value' -DefaultValue ([uint64]::MaxValue))
$buffersLost = [uint64](Get-NxbSemanticRootTraceProperty -InputObject $statistics -Path 'buffers_lost.value' -DefaultValue ([uint64]::MaxValue))
$buffersWritten = [uint64](Get-NxbSemanticRootTraceProperty -InputObject $statistics -Path 'buffers_written.value' -DefaultValue 0)
if ($eventsLost -ne 0 -or $buffersLost -ne 0 -or $buffersWritten -eq 0) { throw ('Trace native loss gate failed: EventsLost={0} BuffersLost={1} BuffersWritten={2}' -f $eventsLost,$buffersLost,$buffersWritten) }

$dumper = Invoke-NxbSemanticRootTraceNative -Executable $xperf -ArgumentList @('-i',$etlPath,'-o',$dumperPath,'-a','dumper')
if ($dumper.exit_code -ne 0 -or -not (Test-Path -LiteralPath $dumperPath -PathType Leaf)) { throw ('xperf dumper failed: exit={0}' -f $dumper.exit_code) }

$manifest = [pscustomobject][ordered]@{ schema_version=1; experiment_id=$experimentId; source_head=$currentHead; scenarios=@($scenarioManifest) }
Write-NxbSemanticRootTraceJson -Path $manifestPath -InputObject $manifest
$targetPid = [int]$scenarioManifest[0].pid
$normalOne = & $normalizerScript -InputPath $dumperPath -EventsOutputPath $eventsOnePath -CoverageOutputPath $coverageOnePath -SourceHead $ExpectedHead -ExperimentId $experimentId -TargetProcessId $targetPid -PassThru
$normalTwo = & $normalizerScript -InputPath $dumperPath -EventsOutputPath $eventsTwoPath -CoverageOutputPath $coverageTwoPath -SourceHead $ExpectedHead -ExperimentId $experimentId -TargetProcessId $targetPid -PassThru
if ([string]$normalOne.status -cne 'passed' -or [string]$normalTwo.status -cne 'passed') { throw 'Root/trace normalization did not pass twice.' }
$eventsOneSha = (Get-FileHash -LiteralPath $eventsOnePath -Algorithm SHA256).Hash.ToLowerInvariant()
$eventsTwoSha = (Get-FileHash -LiteralPath $eventsTwoPath -Algorithm SHA256).Hash.ToLowerInvariant()
$coverageOneSha = (Get-FileHash -LiteralPath $coverageOnePath -Algorithm SHA256).Hash.ToLowerInvariant()
$coverageTwoSha = (Get-FileHash -LiteralPath $coverageTwoPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($eventsOneSha -cne $eventsTwoSha -or $coverageOneSha -cne $coverageTwoSha) { throw 'Root/trace normalization replay is not byte-identical.' }

$analysisOne = & $analysisScript -InputPath $eventsOnePath -ManifestPath $manifestPath -OutputPath $summaryOnePath -SourceHead $ExpectedHead -ExperimentId $experimentId -PassThru
$analysisTwo = & $analysisScript -InputPath $eventsOnePath -ManifestPath $manifestPath -OutputPath $summaryTwoPath -SourceHead $ExpectedHead -ExperimentId $experimentId -PassThru
if ([string]$analysisOne.status -cne 'passed' -or [string]$analysisTwo.status -cne 'passed') { throw 'Root/trace semantic analysis did not pass twice.' }
$summaryOneSha = (Get-FileHash -LiteralPath $summaryOnePath -Algorithm SHA256).Hash.ToLowerInvariant()
$summaryTwoSha = (Get-FileHash -LiteralPath $summaryTwoPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($summaryOneSha -cne $summaryTwoSha) { throw 'Root/trace semantic replay is not byte-identical.' }

$summary = Get-Content -LiteralPath $summaryOnePath -Raw | ConvertFrom-Json
$allOn = @($summary.scenarios | Where-Object { [string]$_.mode -ceq 'all_on' })
if ($allOn.Count -ne 2) { throw 'Root-cause gate requires two all_on repeats.' }
$threeDomainSignature = $true
foreach ($scenario in $allOn) {
    foreach ($domain in @('gpu','network','kernel_lifecycle')) {
        $domainProperty = $scenario.target.domain_counts.PSObject.Properties[$domain]
        if ($null -eq $domainProperty -or [int64]$domainProperty.Value -le 0) { $threeDomainSignature = $false }
    }
}
$gpuIntervention = [bool]$summary.differential.gpu.controlled_present_count_mapping_validated
$networkIntervention = [bool]$summary.differential.network.controlled_network_activity_mapping_validated
$kernelIntervention = $true
foreach ($row in @($summary.differential.kernel.explicit_stimulus_differential)) {
    $registryReduced = ([int64]$row.all_on_registry_rows -gt [int64]$row.kernel_off_registry_rows)
    $threadReduced = ([int64]$row.all_on_thread_rows -gt [int64]$row.kernel_off_thread_rows)
    if (-not ($registryReduced -or $threadReduced)) { $kernelIntervention = $false }
}
$selectiveInterventions = ($gpuIntervention -and $networkIntervention -and $kernelIntervention)
$scenarioContinuity = (@($summary.scenarios).Count -eq 10 -and @($summary.scenarios | Where-Object { [int64]$_.target.row_count -le 0 }).Count -eq 0)
$observationGapCount = if ($scenarioContinuity) { 0 } else { 1 }
$rootValidated = ($threeDomainSignature -and $selectiveInterventions)
$traceValidated = ($eventsLost -eq 0 -and $buffersLost -eq 0 -and $buffersWritten -gt 0 -and -not $capacityReached -and $scenarioContinuity -and $summaryOneSha -ceq $summaryTwoSha)
$endedUtc = [DateTime]::UtcNow

$result = [pscustomobject][ordered]@{
    schema_version=1
    status=if ($rootValidated -and $traceValidated) { 'passed' } else { 'failed' }
    started_utc=$startedUtc.ToString('o')
    ended_utc=$endedUtc.ToString('o')
    scope='bounded-owned-repeated-superblock-control-session'
    controls=[pscustomobject][ordered]@{
        scenario_count=10
        replay_byte_identical=($eventsOneSha -ceq $eventsTwoSha -and $coverageOneSha -ceq $coverageTwoSha -and $summaryOneSha -ceq $summaryTwoSha)
        three_domain_signature_repeated=$threeDomainSignature
        selective_interventions_passed=$selectiveInterventions
        gpu_intervention_passed=$gpuIntervention
        network_intervention_passed=$networkIntervention
        kernel_intervention_passed=$kernelIntervention
        bounded_hypothesis='owned all_on fixture configuration is the common cause of the repeated GPU/network/kernel-lifecycle signature within this controlled experiment'
    }
    trace=[pscustomobject][ordered]@{
        logging_contract='sequential_file_bounded_v1'
        maximum_file_size_mib=512
        etl_length_bytes=[int64]$etlLength
        sequential_capacity_reached=$capacityReached
        events_lost=[uint64]$eventsLost
        buffers_lost=[uint64]$buffersLost
        buffers_written=[uint64]$buffersWritten
        scenario_continuity_count=if ($scenarioContinuity) { 10 } else { 0 }
        observation_gap_count=$observationGapCount
        normalized_replay_byte_identical=($eventsOneSha -ceq $eventsTwoSha -and $coverageOneSha -ceq $coverageTwoSha)
    }
    evidence=[pscustomobject][ordered]@{
        etl_reviewable=$false
        xperf_dumper_reviewable=$false
        normalized_events_reviewable=$false
        fixture_receipts_reviewable=$true
        coverage_sha256=$coverageOneSha
        summary_sha256=$summaryOneSha
        etl_sha256=(Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    cleanup_verified=$true
    claims=[pscustomobject][ordered]@{
        root_cause_validated=$rootValidated
        continuous_trace_completeness=$traceValidated
        generalized_root_cause_claimed=$false
        unbounded_trace_completeness_claimed=$false
    }
}
Write-NxbSemanticRootTraceJson -Path $experimentPath -InputObject $result
if ([string]$result.status -cne 'passed') { throw ('Root/trace semantic experiment failed: root={0} trace={1}' -f $rootValidated,$traceValidated) }
Write-Information -InformationAction Continue -MessageData 'NXB root-cause + continuous trace experiment passed.'
if ($PassThru) { return $result }
Write-Output $experimentPath