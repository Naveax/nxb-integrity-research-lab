[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$ExpectedHead,

    [Parameter()]
    [string]$ResultsRoot,

    [Parameter()]
    [ValidateRange(1, 1000000)]
    [int]$Iterations = 5000,

    [Parameter()]
    [ValidateRange(1, 255)]
    [int]$Seed = 73,

    [Parameter()]
    [switch]$BootstrapDependencies,

    [Parameter()]
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-NxbValidationExecutable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Candidate
    )

    foreach ($name in $Candidate) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return [string]$command.Source
        }
    }
    return $null
}

function Test-NxbValidationAdministrator {
    [CmdletBinding()]
    param()

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

function Write-NxbValidationJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$InputObject
    )

    $json = $InputObject | ConvertTo-Json -Depth 32
    [IO.File]::WriteAllText(
        $Path,
        $json,
        [Text.UTF8Encoding]::new($false)
    )
}

function Add-NxbTraceLossGate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [Collections.Generic.List[object]]$GateList,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('passed', 'failed', 'skipped')]
        [string]$Status,

        [Parameter()]
        [string]$Reason,

        [Parameter()]
        [string]$LogPath
    )

    $GateList.Add([pscustomobject][ordered]@{
        name = $Name
        status = $Status
        reason = $Reason
        log_path = $LogPath
    })
}

if ($env:OS -cne 'Windows_NT') {
    throw 'Trace-loss validation yalnız gerçek Windows üzerinde çalışır.'
}
if ($PSVersionTable.PSEdition -cne 'Core') {
    throw 'Trace-loss validation PowerShell 7 içinde çalıştırılmalıdır.'
}
if (-not (Test-NxbValidationAdministrator)) {
    throw 'Native WPR/xperf validation için yönetici PowerShell 7 gereklidir.'
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitPath = Resolve-NxbValidationExecutable -Candidate @('git.exe', 'git')
$wprPath = Resolve-NxbValidationExecutable -Candidate @('wpr.exe', 'wpr')
$xperfPath = Resolve-NxbValidationExecutable -Candidate @('xperf.exe', 'xperf')
foreach ($required in [ordered]@{
    git = $gitPath
    wpr = $wprPath
    xperf = $xperfPath
}.GetEnumerator()) {
    if ([string]::IsNullOrWhiteSpace([string]$required.Value) -or
        -not (Test-Path -LiteralPath $required.Value -PathType Leaf)) {
        throw "Gerekli executable bulunamadı: $($required.Key)"
    }
}

$currentHead = (& $gitPath -C $repositoryRoot rev-parse HEAD 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $currentHead -notmatch '^[0-9a-fA-F]{40}$') {
    throw "Git HEAD çözümlenemedi: $currentHead"
}
$currentHead = $currentHead.ToLowerInvariant()
if ($currentHead -cne $ExpectedHead.ToLowerInvariant()) {
    throw "Exact-head uyuşmazlığı. Beklenen: $ExpectedHead; mevcut: $currentHead"
}

$workingTree = @(
    & $gitPath `
        -C $repositoryRoot `
        status `
        --porcelain=v1 `
        --untracked-files=all 2>&1
)
if ($LASTEXITCODE -ne 0) {
    throw 'Git çalışma ağacı durumu okunamadı.'
}
if ($workingTree.Count -gt 0) {
    throw (
        "Exact-head validation için çalışma ağacı temiz olmalıdır:`n" +
        ($workingTree -join [Environment]::NewLine)
    )
}

if ([string]::IsNullOrWhiteSpace($ResultsRoot)) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $ResultsRoot = Join-Path `
        ([IO.Path]::GetTempPath()) `
        "nxb-trace-loss-validation-$($currentHead.Substring(0, 12))-$stamp"
}
$resultsFull = [IO.Path]::GetFullPath($ResultsRoot)
$repositoryPrefix = $repositoryRoot.TrimEnd(
    [IO.Path]::DirectorySeparatorChar,
    [IO.Path]::AltDirectorySeparatorChar
) + [IO.Path]::DirectorySeparatorChar
if ($resultsFull.StartsWith($repositoryPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Validation sonuç dizini repository içinde olamaz.'
}
if (Test-Path -LiteralPath $resultsFull) {
    throw "Validation sonuç dizini zaten var: $resultsFull"
}
[IO.Directory]::CreateDirectory($resultsFull) | Out-Null
$logsRoot = Join-Path $resultsFull 'logs'
[IO.Directory]::CreateDirectory($logsRoot) | Out-Null
$summaryPath = Join-Path $resultsFull 'trace-loss-validation-summary.json'
$reviewZip = Join-Path $HOME (
    'Downloads\' +
    (Split-Path -Leaf $resultsFull) +
    '-review.zip'
)
$gates = [Collections.Generic.List[object]]::new()
$startedUtc = [DateTime]::UtcNow
$failure = $null
$baseResults = Join-Path $resultsFull 'base-validation'
$nativeLabRoot = Join-Path $resultsFull 'native-trace-loss-lab'
$nativeExperimentPath = $null
$nativeAccountingPath = $null
$nativeSnapshotPath = $null
$nativeStatisticsPath = $null
$nativeSafeSummaryPath = Join-Path $resultsFull 'native-trace-loss-summary.json'

try {
    $baseLog = Join-Path $logsRoot 'base-validation.log'
    $baseOutput = [Collections.Generic.List[string]]::new()
    try {
        $baseParameters = @{
            ExpectedHead = $currentHead
            ResultsRoot = $baseResults
            RepetitionCount = 1
            WarmupCount = 0
            Ordering = 'alternating_control_first'
            Iterations = 1000
            Seed = $Seed
            Confirm = $false
        }
        if ($BootstrapDependencies) {
            $baseParameters.BootstrapDependencies = $true
        }
        foreach ($line in @(
            & (Join-Path $PSScriptRoot 'Invoke-NxbLocalValidation.ps1') `
                @baseParameters *>&1
        )) {
            $baseOutput.Add([string]$line)
        }
    }
    catch {
        $baseOutput.Add(($_ | Out-String))
    }
    [IO.File]::WriteAllLines(
        $baseLog,
        @($baseOutput),
        [Text.UTF8Encoding]::new($false)
    )

    $baseSummaryPath = Join-Path $baseResults 'validation-summary.json'
    $basePassed = $false
    if (Test-Path -LiteralPath $baseSummaryPath -PathType Leaf) {
        $baseSummary = Get-Content -LiteralPath $baseSummaryPath -Raw |
            ConvertFrom-Json
        $basePassed = [string]$baseSummary.status -ceq 'passed'
    }
    Add-NxbTraceLossGate `
        -GateList $gates `
        -Name 'base-exact-head-validation' `
        -Status $(if ($basePassed) { 'passed' } else { 'failed' }) `
        -Reason $(if ($basePassed) { $null } else { 'Base exact-head validation başarısız.' }) `
        -LogPath $baseLog

    if (-not $basePassed) {
        throw 'Base exact-head validation geçmeden native trace-loss gate çalıştırılamaz.'
    }

    $nativeLog = Join-Path $logsRoot 'native-trace-loss.log'
    $nativeOutput = [Collections.Generic.List[string]]::new()
    try {
        if (-not $PSCmdlet.ShouldProcess(
            $nativeLabRoot,
            'Run real WPR and xperf trace-loss accounting validation'
        )) {
            Add-NxbTraceLossGate `
                -GateList $gates `
                -Name 'native-trace-loss-accounting' `
                -Status 'skipped' `
                -Reason 'Operator declined native validation.' `
                -LogPath $nativeLog
            throw 'Native trace-loss validation atlanamaz.'
        }

        & (Join-Path $PSScriptRoot 'Initialize-Lab.ps1') `
            -Root $nativeLabRoot `
            -Role Target | Out-Null
        $nativeExperimentPath = & (Join-Path $PSScriptRoot 'New-Experiment.ps1') `
            -Root $nativeLabRoot `
            -Name 'Native-Trace-Loss-Validation' `
            -Hypothesis 'Native WPR and xperf loss accounting is explicit and provenance-bound'

        [void](& (Join-Path $PSScriptRoot 'Get-SystemCapabilities.ps1') `
            -ExperimentPath $nativeExperimentPath)
        [void](& (Join-Path $PSScriptRoot 'Get-ObservationIdentity.ps1') `
            -ExperimentPath $nativeExperimentPath)

        & (Join-Path $PSScriptRoot 'Start-PerformanceTrace.ps1') `
            -ExperimentPath $nativeExperimentPath `
            -CaptureProfile NxbMinimalCpuScheduler `
            -CancelExistingSession `
            -WprExecutablePath $wprPath

        [void](& (Join-Path $PSScriptRoot 'Invoke-NxbMeasuredWorkload.ps1') `
            -ExperimentPath $nativeExperimentPath `
            -Iterations $Iterations `
            -Seed $Seed `
            -TimeoutSeconds 120 `
            -SampleIntervalMilliseconds 25)

        $stopResult = & (Join-Path $PSScriptRoot 'Stop-PerformanceTraceWithAccounting.ps1') `
            -ExperimentPath $nativeExperimentPath `
            -WprExecutablePath $wprPath `
            -XperfExecutablePath $xperfPath `
            -PassThru `
            -Confirm:$false

        $nativeAccountingPath = [string]$stopResult.AccountingPath
        $nativeSnapshotPath = [string]$stopResult.StatusSnapshotPath
        $nativeStatisticsPath = [string]$stopResult.PostStopStatisticsPath
        & (Join-Path $PSScriptRoot 'Test-TraceLossAccounting.ps1') `
            -Path $nativeAccountingPath

        $accounting = Get-Content -LiteralPath $nativeAccountingPath -Raw |
            ConvertFrom-Json
        $preStop = Get-Content -LiteralPath $nativeSnapshotPath -Raw |
            ConvertFrom-Json
        $postStop = Get-Content -LiteralPath $nativeStatisticsPath -Raw |
            ConvertFrom-Json
        $manifest = Get-Content `
            -LiteralPath (Join-Path $nativeExperimentPath 'manifest.json') `
            -Raw | ConvertFrom-Json
        $session = Get-Content `
            -LiteralPath (Join-Path $nativeExperimentPath 'trace-session.json') `
            -Raw | ConvertFrom-Json

        if ([string]$manifest.status -cne 'stopped' -or
            [string]$session.status -cne 'stopped') {
            throw 'Native experiment/session stopped durumunda değil.'
        }
        if ([string]$accounting.capture.etl.status -cne 'measured') {
            throw 'Native accounting ETL evidence measured değil.'
        }
        if ([string]$preStop.events_lost.status -cne 'measured') {
            throw 'Pre-stop WPR Events Lost counter measured değil.'
        }
        if ([string]$postStop.events_lost.status -cne 'measured' -or
            [string]$postStop.buffers_lost.status -cne 'measured' -or
            [string]$postStop.buffers_written.status -cne 'measured') {
            throw 'Post-stop xperf trace-header sayaçları tam ölçülemedi.'
        }
        if ([string]$accounting.summary.evidence_completeness -in @('failed', 'unavailable')) {
            throw 'Native accounting evidence completeness kabul edilemez.'
        }
        if ([bool]$accounting.claims.trace_loss_absence -or
            [bool]$accounting.claims.circular_overwrite_absence -or
            [string]$accounting.claims.capture_completeness -cne 'not_claimed') {
            throw 'Native accounting yasaklanmış completeness/absence iddiası üretti.'
        }

        & (Join-Path $PSScriptRoot 'Finalize-Experiment.ps1') `
            -ExperimentPath $nativeExperimentPath
        $integrity = & (Join-Path $PSScriptRoot 'Test-EvidenceIntegrity.ps1') `
            -ExperimentPath $nativeExperimentPath `
            -PassThru
        if (-not $integrity.IsValid) {
            throw 'Native trace-loss experiment evidence integrity başarısız.'
        }

        $safeNativeSummary = [ordered]@{
            status = 'passed'
            trace_loss_classification = [string]$accounting.trace_loss.classification
            measured_counter_count = [int]$accounting.trace_loss.measured_counter_count
            total_reported_loss = $accounting.trace_loss.total_reported_loss
            circular_overwrite_classification = [string]$accounting.circular_overwrite.classification
            circular_utilization_ratio = $accounting.circular_overwrite.utilization_ratio
            evidence_completeness = [string]$accounting.summary.evidence_completeness
            pre_stop_events_lost_status = [string]$preStop.events_lost.status
            post_stop_events_lost_status = [string]$postStop.events_lost.status
            post_stop_buffers_lost_status = [string]$postStop.buffers_lost.status
            post_stop_buffers_written_status = [string]$postStop.buffers_written.status
            etl_sha256 = [string]$accounting.capture.etl.sha256
            etl_length = [int64]$accounting.capture.etl.length
            profile_provenance_sha256 = [string]$accounting.capture.profile.provenance_sha256
        }
        Write-NxbValidationJson `
            -Path $nativeSafeSummaryPath `
            -InputObject $safeNativeSummary
        $nativeOutput.Add('Native trace-loss accounting validation passed.')
        $nativeOutput.Add(($safeNativeSummary | ConvertTo-Json -Depth 8))
        Add-NxbTraceLossGate `
            -GateList $gates `
            -Name 'native-trace-loss-accounting' `
            -Status 'passed' `
            -LogPath $nativeLog
    }
    catch {
        $nativeOutput.Add(($_ | Out-String))
        if (@($gates | Where-Object name -eq 'native-trace-loss-accounting').Count -eq 0) {
            Add-NxbTraceLossGate `
                -GateList $gates `
                -Name 'native-trace-loss-accounting' `
                -Status 'failed' `
                -Reason $_.Exception.Message `
                -LogPath $nativeLog
        }
        throw
    }
    finally {
        [IO.File]::WriteAllLines(
            $nativeLog,
            @($nativeOutput),
            [Text.UTF8Encoding]::new($false)
        )
    }
}
catch {
    $failure = $_
}
finally {
    try {
        & $wprPath -cancel 2>&1 | Out-Null
    }
    catch {
        Write-Warning "WPR cleanup başarısız: $($_.Exception.Message)"
    }

    $stoppedUtc = [DateTime]::UtcNow
    $failedGates = @($gates | Where-Object status -ne 'passed')
    $summary = [ordered]@{
        schema_version = 1
        status = if ($failedGates.Count -eq 0 -and $null -eq $failure) {
            'passed'
        }
        else {
            'failed'
        }
        exact_head = $currentHead
        started_utc = $startedUtc.ToString('o')
        stopped_utc = $stoppedUtc.ToString('o')
        duration_seconds = [Math]::Round(
            ($stoppedUtc - $startedUtc).TotalSeconds,
            6
        )
        results_root = $resultsFull
        gates = @($gates)
        failure = if ($null -eq $failure) {
            $null
        }
        else {
            $failure.Exception.Message
        }
    }
    Write-NxbValidationJson -Path $summaryPath -InputObject $summary

    $reviewRoot = Join-Path $resultsFull 'review'
    [IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
    Copy-Item -LiteralPath $summaryPath -Destination $reviewRoot -Force
    Copy-Item -LiteralPath $logsRoot -Destination $reviewRoot -Recurse -Force
    if (Test-Path -LiteralPath $nativeSafeSummaryPath -PathType Leaf) {
        Copy-Item -LiteralPath $nativeSafeSummaryPath -Destination $reviewRoot -Force
    }
    foreach ($baseArtifact in @(
        'validation-summary.json',
        'pester-pwsh.xml',
        'pester-ps51.xml'
    )) {
        $source = Join-Path $baseResults $baseArtifact
        if (Test-Path -LiteralPath $source -PathType Leaf) {
            Copy-Item -LiteralPath $source -Destination $reviewRoot -Force
        }
    }
    $baseLogs = Join-Path $baseResults 'logs'
    if (Test-Path -LiteralPath $baseLogs -PathType Container) {
        Copy-Item `
            -LiteralPath $baseLogs `
            -Destination (Join-Path $reviewRoot 'base-logs') `
            -Recurse `
            -Force
    }

    if (Test-Path -LiteralPath $reviewZip) {
        Remove-Item -LiteralPath $reviewZip -Force
    }
    Compress-Archive `
        -Path (Join-Path $reviewRoot '*') `
        -DestinationPath $reviewZip `
        -Force

    Write-Host "Trace-loss validation summary: $summaryPath"
    Write-Host "Review ZIP: $reviewZip"
}

if ($null -ne $failure) {
    throw $failure
}

$finalSummary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
if ([string]$finalSummary.status -cne 'passed') {
    throw 'Trace-loss validation required gates did not pass.'
}

if ($PassThru) {
    return $finalSummary
}
Write-Output $summaryPath
