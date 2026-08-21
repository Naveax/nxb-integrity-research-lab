[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$WorkRoot,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputPath,
    [Parameter()][string]$WprExecutablePath,
    [Parameter()][string]$XperfExecutablePath,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-NxbBoundedNativeJsonNew {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Value
    )
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    if (Test-Path -LiteralPath $Path) { throw ('Bounded native smoke output already exists: {0}' -f $Path) }
    [IO.File]::WriteAllText(
        $Path,
        (($Value | ConvertTo-Json -Depth 32) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )
}

if ($env:OS -cne 'Windows_NT') { throw 'Bounded trigger native smoke requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core' -or [int]$PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Bounded trigger native smoke requires PowerShell 7.'
}

$repositoryRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$workFull = [IO.Path]::GetFullPath($WorkRoot)
$outputFull = [IO.Path]::GetFullPath($OutputPath)
$repositoryPrefix = $repositoryRoot.TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if ($workFull.StartsWith($repositoryPrefix,[StringComparison]::OrdinalIgnoreCase)) {
    throw 'Bounded trigger native smoke work root must remain outside the repository.'
}
if (Test-Path -LiteralPath $workFull) { throw ('Bounded trigger native smoke work root already exists: {0}' -f $workFull) }

$gitCommand = Get-Command git.exe -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) { $gitCommand = Get-Command git -ErrorAction Stop }
$git = [string]$gitCommand.Source
$expected = $ExpectedHead.ToLowerInvariant()
$currentHead = (@(& $git -C $repositoryRoot rev-parse HEAD 2>&1) -join [Environment]::NewLine).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $expected) {
    throw ('Bounded trigger native smoke exact-head mismatch: expected={0} actual={1}' -f $expected,$currentHead)
}
$dirty = @(& $git -C $repositoryRoot status --porcelain=v1 --untracked-files=all 2>&1)
if ($LASTEXITCODE -ne 0 -or $dirty.Count -gt 0) { throw 'Bounded trigger native smoke requires a clean exact-head repository.' }

[IO.Directory]::CreateDirectory($workFull) | Out-Null
$signalJob = $null
try {
    $labRoot = Join-Path $workFull 'lab'
    & (Join-Path $PSScriptRoot 'Initialize-Lab.ps1') -Root $labRoot -Role Target | Out-Null
    $experiment = & (Join-Path $PSScriptRoot 'New-Experiment.ps1') `
        -Root $labRoot `
        -Name ('NXB-Bounded-Native-' + $expected.Substring(0,12)) `
        -Hypothesis 'A real Memory WPR ring preserves bounded evidence before and after an adaptive trigger'

    $signalsPath = Join-Path $workFull 'signals.json'
    [IO.File]::WriteAllText(
        $signalsPath,
        ((@{ frame_time_ms = 10 } | ConvertTo-Json -Compress) + [Environment]::NewLine),
        [Text.UTF8Encoding]::new($false)
    )

    $signalJob = Start-Job -ScriptBlock {
        param([string]$Path)
        Start-Sleep -Milliseconds 1500
        [IO.File]::WriteAllText(
            $Path,
            ((@{ frame_time_ms = 40 } | ConvertTo-Json -Compress) + [Environment]::NewLine),
            [Text.UTF8Encoding]::new($false)
        )
    } -ArgumentList $signalsPath

    $capture = & (Join-Path $PSScriptRoot 'Invoke-NxbBoundedTriggerCapture.ps1') `
        -ExperimentPath ([string]$experiment) `
        -SignalsPath $signalsPath `
        -TriggerId 'frame-spike' `
        -ExpectedHead $expected `
        -RequestedPreTriggerSeconds 3 `
        -RequestedPostTriggerSeconds 1 `
        -PollMilliseconds 100 `
        -MinimumFreeDiskMiB 64 `
        -WprExecutablePath $WprExecutablePath `
        -XperfExecutablePath $XperfExecutablePath `
        -PassThru

    Wait-Job -Job $signalJob -ErrorAction Stop | Out-Null
    [void](Receive-Job -Job $signalJob -ErrorAction Stop)

    $receipt = Get-Content -LiteralPath $capture.receipt_path -Raw | ConvertFrom-Json
    $statePath = Join-Path ([string]$experiment) 'analysis\bounded-trigger-capture-state.json'
    $accountingPath = Join-Path ([string]$experiment) 'analysis\trace-loss-accounting.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw 'Bounded native smoke state evidence missing.' }
    if (-not (Test-Path -LiteralPath $accountingPath -PathType Leaf)) { throw 'Bounded native smoke trace-loss accounting missing.' }

    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ([string]$capture.status -cne 'passed' -or [string]$receipt.status -cne 'passed') { throw 'Bounded native smoke capture did not return PASS.' }
    if ([string]$receipt.head_sha -cne $expected) { throw 'Bounded native smoke receipt exact-head mismatch.' }
    if (-not [bool]$receipt.session_binding_valid) { throw 'Bounded native smoke session binding is invalid.' }
    if ([int]$receipt.budgets.memory_buffer_budget_mib -ne 64) { throw 'Bounded native smoke memory budget drift.' }
    if ([double]$receipt.observed_pretrigger_seconds -le 0) { throw 'Bounded native smoke did not observe a real pre-trigger window.' }
    if ([double]$receipt.observed_posttrigger_seconds -le 0) { throw 'Bounded native smoke did not observe a real post-trigger window.' }
    if ([uint64]$receipt.sample_accounting.observed_buffers_written -lt 1) { throw 'Bounded native smoke observed no ETW buffers.' }
    if ([string]$state.state -cne 'completed') { throw 'Bounded native smoke state did not complete.' }
    if ([string]$receipt.capture_mode_before_trigger -cne 'Memory' -or [string]$receipt.capture_mode_after_trigger -cne 'Memory') {
        throw 'Bounded native smoke capture mode drifted.'
    }

    $summary = [pscustomobject][ordered]@{
        schema_version = 1
        status = 'passed'
        authority = 'nxb-bounded-trigger-native-smoke-v1'
        head_sha = $expected
        session_id = [string]$receipt.session_id
        policy_fingerprint_sha256 = [string]$receipt.policy_fingerprint_sha256
        primary_plan_fingerprint_sha256 = [string]$receipt.primary_plan_fingerprint_sha256
        final_plan_fingerprint_sha256 = [string]$receipt.plan_fingerprint_sha256
        capture_mode_before_trigger = [string]$receipt.capture_mode_before_trigger
        capture_mode_after_trigger = [string]$receipt.capture_mode_after_trigger
        requested_pretrigger_seconds = [int]$receipt.requested_pretrigger_seconds
        requested_posttrigger_seconds = [int]$receipt.requested_posttrigger_seconds
        observed_pretrigger_seconds = [double]$receipt.observed_pretrigger_seconds
        observed_posttrigger_seconds = [double]$receipt.observed_posttrigger_seconds
        memory_buffer_budget_mib = [int]$receipt.budgets.memory_buffer_budget_mib
        configured_buffer_capacity = [int]$receipt.sample_accounting.configured_buffer_capacity
        observed_buffers_written = [uint64]$receipt.sample_accounting.observed_buffers_written
        dropped_event_count = $receipt.sample_accounting.dropped_event_count
        dropped_buffer_count = $receipt.sample_accounting.dropped_buffer_count
        estimated_overwritten_buffer_count = $receipt.sample_accounting.estimated_overwritten_buffer_count
        domain_coverage = [string]$receipt.domain_coverage
        captured_domain_count = [int]$receipt.captured_domain_count
        uncaptured_domain_count = [int]$receipt.uncaptured_domain_count
        truncation = [bool]$receipt.truncation
        budget_state = [string]$receipt.budgets.state_budget
        disk_state = [string]$receipt.budgets.disk_state
        receipt_sha256 = (Get-FileHash -LiteralPath $capture.receipt_path -Algorithm SHA256).Hash.ToLowerInvariant()
        state_sha256 = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToLowerInvariant()
        trace_loss_accounting_sha256 = (Get-FileHash -LiteralPath $accountingPath -Algorithm SHA256).Hash.ToLowerInvariant()
        etl_sha256 = [string]$receipt.evidence.etl_sha256
        etl_retained_in_review_artifact = $false
    }
    Write-NxbBoundedNativeJsonNew -Path $outputFull -Value $summary

    if ($PassThru) { return $summary }
    $summary | ConvertTo-Json -Depth 16
}
finally {
    if ($null -ne $signalJob) {
        try { Stop-Job -Job $signalJob -ErrorAction SilentlyContinue | Out-Null } catch {}
        try { Remove-Job -Job $signalJob -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
    }
    if (Test-Path -LiteralPath $workFull -PathType Container) {
        Remove-Item -LiteralPath $workFull -Recurse -Force
    }
}
