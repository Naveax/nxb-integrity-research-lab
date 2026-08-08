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

function Test-NxbSuperblockAdministrator {
    [CmdletBinding()]
    param()
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-NxbSuperblockPesterRun {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$Executable,
        [Parameter(Mandatory)]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
        [string]$TestPath,
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Label,
        [Parameter(Mandatory)]
        [int]$ExpectedCount
    )
    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("nxb-superblock-pester-$([guid]::NewGuid().ToString('N'))")
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
            & $Executable -NoLogo -NoProfile -ExecutionPolicy Bypass -File $childPath -TestPath $TestPath -ResultPath $resultPath -ExpectedCount $ExpectedCount 2>&1
        )
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
        foreach ($line in $childOutput) {
            Write-Information -MessageData ([string]$line) -InformationAction Continue
        }
        if ($exitCode -ne 0) { throw "$Label Pester run failed with exit code $exitCode." }
        $summary = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        return [pscustomobject][ordered]@{
            label = $Label
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

function Write-NxbSuperblockJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$InputObject
    )
    [IO.File]::WriteAllText(
        $Path,
        (($InputObject | ConvertTo-Json -Depth 32) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($env:OS -cne 'Windows_NT') { throw 'SUPERBLOCK multi-domain certification requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'SUPERBLOCK multi-domain certification requires PowerShell 7.' }
if (-not (Test-NxbSuperblockAdministrator)) { throw 'SUPERBLOCK multi-domain certification requires elevated PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = Get-Command git.exe -ErrorAction Stop
$currentHead = (& $git.Source -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head mismatch. Expected: $ExpectedHead; actual: $currentHead"
}
$dirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) {
    throw 'SUPERBLOCK multi-domain certification requires a clean exact-head worktree.'
}

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$repositoryPrefix = [IO.Path]::GetFullPath($repositoryRoot).TrimEnd('\') + '\'
if ($outputFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'SUPERBLOCK certification output must remain outside the repository worktree.'
}
if (Test-Path -LiteralPath $outputFull) { throw "OutputDirectory already exists: $outputFull" }

$rawRoot = Join-Path $outputFull 'raw-local'
$reviewRoot = Join-Path $outputFull 'review'
$captureRoot = Join-Path $rawRoot 'multi-domain-capture'
$tracesRoot = Join-Path $captureRoot 'traces'
$analysisRoot = Join-Path $captureRoot 'analysis'
[IO.Directory]::CreateDirectory($rawRoot) | Out-Null
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
[IO.Directory]::CreateDirectory($tracesRoot) | Out-Null
[IO.Directory]::CreateDirectory($analysisRoot) | Out-Null

$adapterCertification = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1CaptureAdapterCertification.ps1'
$profileValidation = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1MultiDomainProfileLocalValidation.ps1'
$profileContractPath = Join-Path $PSScriptRoot 'Test-NxbSuperblock1MultiDomainWprProfile.ps1'
$workloadPath = Join-Path $PSScriptRoot 'Invoke-NxbSuperblock1BoundedWorkload.ps1'
$inventoryPath = Join-Path $PSScriptRoot 'Get-NxbSuperblock1XperfHeaderInventory.ps1'
$statisticsPath = Join-Path $PSScriptRoot 'Get-NxbEtlTraceStatistics.ps1'
$captureTestPath = Join-Path $repositoryRoot 'tests\Superblock1MultiDomainCapture.Tests.ps1'
foreach ($requiredPath in @(
    $adapterCertification,$profileValidation,$profileContractPath,$workloadPath,
    $inventoryPath,$statisticsPath,$captureTestPath,$PSCommandPath
)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required SUPERBLOCK certification component missing: $requiredPath"
    }
}

Write-Information -MessageData '=== SUPERBLOCK 1 ONE-SHOT MULTI-DOMAIN CERTIFICATION ===' -InformationAction Continue
Write-Information -MessageData '[1/7] Selected-provider metadata + capability-adapter certification' -InformationAction Continue
$adapterGateDirectory = Join-Path $rawRoot 'capture-adapter-gate'
$adapterGate = & $adapterCertification -ExpectedHead $ExpectedHead -OutputDirectory $adapterGateDirectory -PassThru
if ([string]$adapterGate.status -cne 'passed' -or [bool]$adapterGate.real_etl_capture_executed) {
    throw 'Existing SUPERBLOCK capture/adapter gate did not pass conservatively.'
}

Write-Information -MessageData '[2/7] Multi-domain WPR profile dual-runtime + native parse gate' -InformationAction Continue
$profileGate = & $profileValidation -ExpectedHead $ExpectedHead -PassThru
if ([string]$profileGate.status -cne 'passed' -or
    [int]$profileGate.powershell7.passed -ne 10 -or
    [int]$profileGate.windows_powershell_51.passed -ne 10 -or
    [int]$profileGate.analyzer_findings -ne 0 -or
    [string]$profileGate.native_wpr_profile_parse -cne 'passed') {
    throw 'SUPERBLOCK multi-domain profile gate did not pass cleanly.'
}

Write-Information -MessageData '[3/7] Capture-layer parser/analyzer + dual-runtime contract gate' -InformationAction Continue
$captureScripts = @($workloadPath,$inventoryPath,$PSCommandPath)
foreach ($scriptPath in $captureScripts) {
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($scriptPath,[ref]$tokens,[ref]$errors)
    if (@($errors).Count -gt 0) {
        throw "PowerShell parser failed: $scriptPath"
    }
}
Import-Module PSScriptAnalyzer -ErrorAction Stop
$findings = @(
    foreach ($scriptPath in @($captureScripts + $captureTestPath)) {
        Invoke-ScriptAnalyzer -Path $scriptPath -Severity Warning,Error
    }
)
if ($findings.Count -gt 0) {
    throw (
        "SUPERBLOCK capture-layer PSScriptAnalyzer findings: $($findings.Count)`n" +
        (@($findings | ForEach-Object { '{0}:{1} {2} {3}' -f $_.ScriptName,$_.Line,$_.RuleName,$_.Message }) -join "`n")
    )
}
$pwsh = Get-Command pwsh.exe -ErrorAction Stop
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
    throw "Windows PowerShell 5.1 executable missing: $windowsPowerShell"
}
$capturePs7 = Invoke-NxbSuperblockPesterRun -Executable $pwsh.Source -TestPath $captureTestPath -Label 'PowerShell 7 SUPERBLOCK capture contract' -ExpectedCount 8
$capturePs51 = Invoke-NxbSuperblockPesterRun -Executable $windowsPowerShell -TestPath $captureTestPath -Label 'Windows PowerShell 5.1 SUPERBLOCK capture contract' -ExpectedCount 8

$wpr = Get-Command wpr.exe -ErrorAction Stop
$xperf = Get-Command xperf.exe -ErrorAction Stop
$profileContract = & $profileContractPath -PassThru
$profileReference = "$($profileContract.path)!NxbSuperblock1MultiDomain.Verbose"
$etlPath = Join-Path $tracesRoot 'performance.etl'
$dumperPath = Join-Path $rawRoot 'superblock1-xperf-dumper.txt'
$headerInventoryPath = Join-Path $rawRoot 'superblock1-xperf-header-inventory.json'
$workloadReceiptPath = Join-Path $rawRoot 'superblock1-bounded-workload.json'
$statusPath = Join-Path $rawRoot 'wpr-status-pre-stop.txt'
$traceQualityReviewPath = Join-Path $reviewRoot 'superblock1-trace-quality.json'
$receiptPath = Join-Path $reviewRoot 'superblock1-multi-domain-certification-receipt.json'
$reviewZipPath = Join-Path $outputFull 'superblock1-multi-domain-certification-review.zip'
$stagingEtl = Join-Path ([IO.Path]::GetTempPath()) ("nxb-superblock1-$([guid]::NewGuid().ToString('N')).etl")
$sessionOwned = $false
$targetProcessId = $null
$targetImageSha256 = $null
$traceStartedUtc = $null
$traceStoppedUtc = $null

try {
    Write-Information -MessageData '[4/7] Real bounded WPR capture + controlled host workload' -InformationAction Continue
    Write-Information -MessageData 'Existing WPR sessions are never auto-cancelled.' -InformationAction Continue
    $traceStartedUtc = [DateTime]::UtcNow
    $startOutput = @(& $wpr.Source -start $profileReference -filemode 2>&1)
    $startExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($startExit -ne 0) {
        throw (
            'WPR start failed; no existing session was cancelled. ' +
            "exit=$startExit output=$($startOutput -join ' ')"
        )
    }
    $sessionOwned = $true
    Start-Sleep -Milliseconds 250

    $workloadArguments = @(
        '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$workloadPath,
        '-OutputPath',$workloadReceiptPath,'-LoopbackBytes','65536'
    )
    $targetProcess = Start-Process -FilePath $pwsh.Source -ArgumentList $workloadArguments -PassThru -WindowStyle Hidden
    try {
        $targetProcessId = [int]$targetProcess.Id
        $targetImageSha256 = (Get-FileHash -LiteralPath $pwsh.Source -Algorithm SHA256).Hash.ToLowerInvariant()
        if (-not $targetProcess.WaitForExit(20000)) {
            try { $targetProcess.Kill() } catch { Write-Warning "Bounded workload kill failed: $($_.Exception.Message)" }
            throw 'SUPERBLOCK bounded workload exceeded the 20 second safety timeout.'
        }
        if ($targetProcess.ExitCode -ne 0) {
            throw "SUPERBLOCK bounded workload failed: exit=$($targetProcess.ExitCode)"
        }
    }
    finally {
        $targetProcess.Dispose()
    }
    $workload = Get-Content -LiteralPath $workloadReceiptPath -Raw | ConvertFrom-Json
    if ([string]$workload.status -cne 'passed' -or [bool]$workload.loopback.external_network_used) {
        throw 'SUPERBLOCK bounded workload receipt failed its local-only contract.'
    }

    $statusOutput = @(& $wpr.Source -status collectors -details 2>&1)
    [IO.File]::WriteAllLines($statusPath,@($statusOutput | ForEach-Object { [string]$_ }),[Text.UTF8Encoding]::new($false))

    $stopOutput = @(& $wpr.Source -stop $stagingEtl 2>&1)
    $stopExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($stopExit -ne 0) {
        throw "WPR stop failed: exit=$stopExit output=$($stopOutput -join ' ')"
    }
    $sessionOwned = $false
    $traceStoppedUtc = [DateTime]::UtcNow
    if (-not (Test-Path -LiteralPath $stagingEtl -PathType Leaf)) {
        throw 'WPR stop succeeded but no ETL was produced.'
    }
    Move-Item -LiteralPath $stagingEtl -Destination $etlPath -Force

    Write-Information -MessageData '[5/7] Native trace-loss accounting + full local xperf dumper' -InformationAction Continue
    $statistics = & $statisticsPath -ExperimentPath $captureRoot -XperfExecutablePath $xperf.Source -PassThru
    foreach ($counterName in @('events_lost','buffers_lost','buffers_written')) {
        if ([string]$statistics.$counterName.status -cne 'measured') {
            throw "Native trace counter is not measured: $counterName"
        }
    }
    if ([uint64]$statistics.events_lost.value -ne 0 -or [uint64]$statistics.buffers_lost.value -ne 0) {
        throw "Native trace loss detected: events=$($statistics.events_lost.value) buffers=$($statistics.buffers_lost.value)"
    }
    if ([uint64]$statistics.buffers_written.value -eq 0) {
        throw 'Native ETL reports zero buffers written.'
    }

    $dumperOutput = @(& $xperf.Source -i $etlPath -o $dumperPath -a dumper 2>&1)
    $dumperExit = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    if ($dumperExit -ne 0 -or -not (Test-Path -LiteralPath $dumperPath -PathType Leaf)) {
        throw "xperf dumper failed: exit=$dumperExit output=$($dumperOutput -join ' ')"
    }

    Write-Information -MessageData '[6/7] Header-only GPU/network/kernel discovery inventory' -InformationAction Continue
    $inventory = & $inventoryPath -InputPath $dumperPath -OutputPath $headerInventoryPath -PassThru
    if ([string]$inventory.status -cne 'passed' -or [int]$inventory.header_count -le 0) {
        throw 'SUPERBLOCK xperf header inventory is empty.'
    }

    $etlItem = Get-Item -LiteralPath $etlPath
    $etlSha = (Get-FileHash -LiteralPath $etlPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $dumperSha = (Get-FileHash -LiteralPath $dumperPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $inventorySha = (Get-FileHash -LiteralPath $headerInventoryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $traceQuality = [pscustomobject][ordered]@{
        schema_version = 1
        status = 'passed'
        etl_sha256 = $etlSha
        etl_length = [int64]$etlItem.Length
        counter_source = [string]$statistics.counter_source
        events_lost = [uint64]$statistics.events_lost.value
        buffers_lost = [uint64]$statistics.buffers_lost.value
        buffers_written = [uint64]$statistics.buffers_written.value
        etl_header = $statistics.etl_header
        circular_overwrite = 'unknown'
        trace_completeness = 'not_claimed'
    }
    Write-NxbSuperblockJson -Path $traceQualityReviewPath -InputObject $traceQuality

    Write-Information -MessageData '[7/7] Bounded receipt + review ZIP evidence-policy gate' -InformationAction Continue
    $adapterReceiptSha = (Get-FileHash -LiteralPath ([string]$adapterGate.receipt_path) -Algorithm SHA256).Hash.ToLowerInvariant()
    $adapterReviewSha = (Get-FileHash -LiteralPath ([string]$adapterGate.review_zip_path) -Algorithm SHA256).Hash.ToLowerInvariant()
    $receipt = [pscustomobject][ordered]@{
        schema_version = 1
        status = 'passed'
        head_sha = $currentHead
        certified_utc = [DateTime]::UtcNow.ToString('o')
        adapter_gate = [ordered]@{
            receipt_sha256 = $adapterReceiptSha
            review_zip_sha256 = $adapterReviewSha
            selected_provider_count = @($adapterGate.selected_provider_metadata).Count
            capability_collection_error_count = [int]$adapterGate.capability_collection_error_count
        }
        profile_gate = [ordered]@{
            powershell7 = "$($profileGate.powershell7.passed)/$($profileGate.powershell7.total)"
            windows_powershell_51 = "$($profileGate.windows_powershell_51.passed)/$($profileGate.windows_powershell_51.total)"
            analyzer_findings = 0
            native_wpr_profile_parse = 'passed'
            profile_sha256 = [string]$profileContract.sha256
            file_system_collector_max_mib = 128
            file_event_collector_max_mib = 128
        }
        capture_contract = [ordered]@{
            powershell7 = "$($capturePs7.passed)/$($capturePs7.total)"
            windows_powershell_51 = "$($capturePs51.passed)/$($capturePs51.total)"
            analyzer_findings = 0
        }
        capture = [ordered]@{
            trace_started_utc = $traceStartedUtc.ToString('o')
            trace_stopped_utc = $traceStoppedUtc.ToString('o')
            target_process_id = $targetProcessId
            target_image_sha256 = $targetImageSha256
            etl_sha256 = $etlSha
            etl_length = [int64]$etlItem.Length
            dumper_sha256 = $dumperSha
            header_inventory_sha256 = $inventorySha
            header_count = [int]$inventory.header_count
            candidate_counts = $inventory.candidate_counts
        }
        workload = [ordered]@{
            loopback_byte_count = [int]$workload.loopback.byte_count
            loopback_payload_sha256 = [string]$workload.loopback.payload_sha256
            external_network_used = [bool]$workload.loopback.external_network_used
            registry_read_completed = [bool]$workload.registry.bounded_read_completed
            child_exit_code = [int]$workload.process_lifecycle.child_exit_code
            controlled_gpu_workload_executed = [bool]$workload.gpu.controlled_gpu_workload_executed
        }
        trace_quality = [ordered]@{
            events_lost = [uint64]$statistics.events_lost.value
            buffers_lost = [uint64]$statistics.buffers_lost.value
            buffers_written = [uint64]$statistics.buffers_written.value
            circular_overwrite = 'unknown'
            trace_completeness = 'not_claimed'
        }
        review_policy = [ordered]@{
            raw_etl_in_review_zip = $false
            full_xperf_dumper_in_review_zip = $false
            raw_provider_metadata_in_review_zip = $false
            raw_capability_snapshot_in_review_zip = $false
            event_rows_in_review_zip = $false
        }
        claims = [ordered]@{
            keyword_semantics_validated = $false
            event_ids_validated = $false
            present_semantics = $false
            gpu_queue_semantics = $false
            network_connection_semantics = $false
            network_latency_semantics = $false
            kernel_lifecycle_semantics = $false
            device_lifecycle_semantics = $false
            power_thermal_representative = $false
            firmware_security_effect_semantics = $false
            trace_completeness = 'not_claimed'
        }
    }
    Write-NxbSuperblockJson -Path $receiptPath -InputObject $receipt
    Copy-Item -LiteralPath $headerInventoryPath -Destination (Join-Path $reviewRoot 'superblock1-xperf-header-inventory.json') -Force
    Compress-Archive -Path (Join-Path $reviewRoot '*') -DestinationPath $reviewZipPath -Force

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead($reviewZipPath)
    try {
        foreach ($entry in $archive.Entries) {
            $lower = $entry.FullName.ToLowerInvariant()
            if ($lower.EndsWith('.etl') -or $lower.Contains('xperf-dumper') -or $lower.Contains('selected-provider-metadata') -or $lower.Contains('system-capabilities')) {
                throw "Forbidden raw evidence entered SUPERBLOCK review ZIP: $($entry.FullName)"
            }
        }
    }
    finally {
        $archive.Dispose()
    }

    $postDirty = @(& $git.Source -C $repositoryRoot status --porcelain=v1 --untracked-files=all)
    if ($LASTEXITCODE -ne 0 -or $postDirty.Count -gt 0) {
        throw 'SUPERBLOCK multi-domain certification dirtied the exact-head worktree.'
    }
    $result = [pscustomobject][ordered]@{
        status = 'passed'
        head_sha = $currentHead
        output_directory = $outputFull
        receipt_path = $receiptPath
        review_zip_path = $reviewZipPath
        receipt_sha256 = (Get-FileHash -LiteralPath $receiptPath -Algorithm SHA256).Hash.ToLowerInvariant()
        review_zip_sha256 = (Get-FileHash -LiteralPath $reviewZipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        etl_path_local = $etlPath
        dumper_path_local = $dumperPath
        header_inventory_path_local = $headerInventoryPath
        events_lost = [uint64]$statistics.events_lost.value
        buffers_lost = [uint64]$statistics.buffers_lost.value
        buffers_written = [uint64]$statistics.buffers_written.value
        header_count = [int]$inventory.header_count
        candidate_counts = $inventory.candidate_counts
        real_etl_capture_executed = $true
        semantic_claims_enabled = $false
        trace_completeness = 'not_claimed'
    }
    Write-Information -MessageData "SUPERBLOCK one-shot multi-domain certification passed: $currentHead" -InformationAction Continue
    Write-Information -MessageData "Native trace loss: events=$($result.events_lost), buffers=$($result.buffers_lost)" -InformationAction Continue
    Write-Information -MessageData "Header inventory count: $($result.header_count)" -InformationAction Continue
    Write-Information -MessageData "Review receipt SHA256: $($result.receipt_sha256)" -InformationAction Continue
    Write-Information -MessageData "Review ZIP SHA256: $($result.review_zip_sha256)" -InformationAction Continue
    Write-Information -MessageData 'Raw ETL and full xperf dumper remain local.' -InformationAction Continue
    Write-Information -MessageData 'Semantic claims enabled: False' -InformationAction Continue
    if ($PassThru) { return $result }
}
catch {
    if ($sessionOwned) {
        try {
            & $wpr.Source -cancel 2>&1 | Out-Null
        }
        catch {
            Write-Warning "Owned WPR cleanup cancel failed: $($_.Exception.Message)"
        }
        $sessionOwned = $false
    }
    throw
}
finally {
    if (Test-Path -LiteralPath $stagingEtl -PathType Leaf) {
        Remove-Item -LiteralPath $stagingEtl -Force
    }
}
