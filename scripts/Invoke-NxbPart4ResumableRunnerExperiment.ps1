[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedHead,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$OutputDirectory,
    [Parameter()][switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NxbPart4Runner.Common.ps1')

function Invoke-NxbPart4WorkerProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PwshPath,
        [Parameter(Mandatory)][string]$WorkerPath,
        [Parameter(Mandatory)][string]$RunRoot,
        [Parameter(Mandatory)][string]$Mode,
        [Parameter()][int]$StopAfterCommitted = 0
    )
    $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$WorkerPath,'-RunRoot',$RunRoot,'-Mode',$Mode)
    if ($StopAfterCommitted -gt 0) { $arguments += @('-StopAfterCommitted',[string]$StopAfterCommitted) }
    $previous = $ErrorActionPreference
    $nativePreferenceVariable = Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue
    $nativeAvailable = ($null -ne $nativePreferenceVariable)
    $oldNative = if ($nativeAvailable) { [bool]$nativePreferenceVariable.Value } else { $null }
    try {
        $ErrorActionPreference = 'Continue'
        if ($nativeAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $false -Scope Local }
        $output = @(& $PwshPath @arguments 2>&1)
        $exitCode = if ($null -eq $LASTEXITCODE) { 1 } else { [int]$LASTEXITCODE }
    }
    finally {
        $ErrorActionPreference = $previous
        if ($nativeAvailable) { Set-Variable -Name PSNativeCommandUseErrorActionPreference -Value $oldNative -Scope Local }
    }
    return [pscustomobject][ordered]@{ exit_code=$exitCode; output=(@($output | ForEach-Object { [string]$_ }) -join "`n") }
}

function Get-NxbPart4EventDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    $items = [Collections.Generic.List[object]]::new()
    foreach ($line in @(Get-Content -LiteralPath $Path)) {
        if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
        $items.Add(([string]$line | ConvertFrom-Json))
    }
    return $items.ToArray()
}

if ($env:OS -cne 'Windows_NT') { throw 'Part 4 runner experiment requires Windows.' }
if ($PSVersionTable.PSEdition -cne 'Core') { throw 'Part 4 runner experiment requires PowerShell 7.' }

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$git = (Get-Command git.exe -ErrorAction Stop).Source
$currentHead = (& $git -C $repositoryRoot rev-parse HEAD).Trim().ToLowerInvariant()
if ($LASTEXITCODE -ne 0 -or $currentHead -cne $ExpectedHead.ToLowerInvariant()) { throw 'Part 4 runner experiment exact-head mismatch.' }

$outputFull = [IO.Path]::GetFullPath($OutputDirectory)
$runRoot = Join-Path $outputFull 'run'
$reviewRoot = Join-Path $outputFull 'review'
if (Test-Path -LiteralPath $outputFull) { throw ('Part 4 experiment output already exists: {0}' -f $outputFull) }
[IO.Directory]::CreateDirectory($runRoot) | Out-Null
[IO.Directory]::CreateDirectory($reviewRoot) | Out-Null
[IO.Directory]::CreateDirectory((Join-Path $runRoot 'receipts')) | Out-Null

$sourcePolicyPath = Join-Path $repositoryRoot 'config\nxb-part4-runner-policy.json'
$policyPath = Join-Path $runRoot 'policy.json'
[IO.File]::Copy($sourcePolicyPath,$policyPath,$false)
$policy = Read-NxbPart4Json -Path $policyPath
$configSha = Get-NxbPart4FileSha256 -Path $policyPath

$taskList = [Collections.Generic.List[object]]::new()
$domains = @($policy.domains | ForEach-Object { [string]$_ })
for ($index = 1; $index -le [int]$policy.task_count; $index++) {
    $taskId = 'task-{0:D3}' -f $index
    $domain = $domains[($index - 1) % $domains.Count]
    $basePriority = (($index - 1) % 5) + 1
    $payloadHash = Get-NxbPart4Sha256Text -Text ('synthetic-payload-v1|{0}|{1}' -f $taskId,$domain)
    $taskList.Add([pscustomobject][ordered]@{
        task_id=$taskId; domain=$domain; base_priority=$basePriority;
        shard=(Get-NxbPart4Shard -TaskId $taskId -ShardCount ([int]$policy.shard_count));
        synthetic_payload_sha256=$payloadHash
    })
}
if ($taskList.Count -ne [int]$policy.task_count) { throw 'Part 4 deterministic task construction count mismatch.' }

$scopeMaterial = @($taskList.ToArray() | Sort-Object task_id | ForEach-Object { '{0}|{1}|{2}|{3}' -f $_.task_id,$_.domain,$_.base_priority,$_.shard }) -join "`n"
$scopeSha = Get-NxbPart4Sha256Text -Text $scopeMaterial
$runId = Get-NxbPart4RunId -Repository 'Naveax/nxb-integrity-research-lab' -ExactHead $currentHead -ConfigSha256 $configSha -ScopeSha256 $scopeSha -ContractId ([string]$policy.contract_id)
$manifest = [pscustomobject][ordered]@{
    schema_version=1; contract_id=[string]$policy.contract_id; repository='Naveax/nxb-integrity-research-lab';
    exact_head=$currentHead; config_sha256=$configSha; scope_sha256=$scopeSha; run_id=$runId;
    shard_count=[int]$policy.shard_count; tasks=$taskList.ToArray()
}
$manifestPath = Join-Path $runRoot 'run-manifest.json'
Write-NxbPart4AtomicJson -Path $manifestPath -InputObject $manifest

$attempts = [ordered]@{}
$notBefore = [ordered]@{}
foreach ($task in @($taskList.ToArray())) { $attempts[[string]$task.task_id]=0; $notBefore[[string]$task.task_id]=0 }
$domainLast = [ordered]@{}
foreach ($domain in $domains) { $domainLast[$domain]=0 }
$checkpoint = [pscustomobject][ordered]@{
    schema_version=1; run_id=$runId; exact_head=$currentHead; config_sha256=$configSha; scope_sha256=$scopeSha;
    checkpoint_sequence=1; tick=0; budget_consumed=0; stop_mode='none'; completed_task_ids=@();
    attempts=[pscustomobject]$attempts; not_before_tick=[pscustomobject]$notBefore; domain_last_served_tick=[pscustomobject]$domainLast;
    checkpoint_fingerprint_sha256=''
}
$checkpointPath = Join-Path $runRoot 'checkpoint.json'
Write-NxbPart4Checkpoint -Path $checkpointPath -Checkpoint $checkpoint

$workerPath = Join-Path $PSScriptRoot 'Invoke-NxbPart4RunnerWorker.ps1'
$pwshPath = (Get-Command pwsh.exe -ErrorAction Stop).Source
$eventPath = Join-Path $runRoot 'execution-events.jsonl'
$receiptRoot = Join-Path $runRoot 'receipts'
$phaseResult = [Collections.Generic.List[object]]::new()

$crash = Invoke-NxbPart4WorkerProcess -PwshPath $pwshPath -WorkerPath $workerPath -RunRoot $runRoot -Mode crash_after_receipt -StopAfterCommitted ([int]$policy.fault_injection.crash_after_committed_tasks)
if ($crash.exit_code -eq 0) { throw 'Part 4 crash phase unexpectedly exited cleanly.' }
$afterCrashCheckpoint = Read-NxbPart4Json -Path $checkpointPath
$afterCrashReceiptCount = @(Get-ChildItem -LiteralPath $receiptRoot -Filter '*.json' -File).Count
if ($afterCrashReceiptCount -ne [int]$policy.fault_injection.crash_after_committed_tasks) { throw 'Part 4 crash phase receipt count mismatch.' }
if (@($afterCrashCheckpoint.completed_task_ids).Count -ge $afterCrashReceiptCount) { throw 'Part 4 crash did not create the required stale-checkpoint window.' }
$phaseResult.Add([pscustomobject][ordered]@{ phase='crash_after_receipt'; exit_code=$crash.exit_code; receipts=$afterCrashReceiptCount; checkpoint_completed=@($afterCrashCheckpoint.completed_task_ids).Count; checkpoint_sequence=[int]$afterCrashCheckpoint.checkpoint_sequence })

$graceful = Invoke-NxbPart4WorkerProcess -PwshPath $pwshPath -WorkerPath $workerPath -RunRoot $runRoot -Mode graceful -StopAfterCommitted ([int]$policy.fault_injection.graceful_stop_after_committed_tasks)
if ($graceful.exit_code -ne 20) { throw ('Part 4 graceful stop exit mismatch: {0}' -f $graceful.exit_code) }
$afterGraceful = Read-NxbPart4Json -Path $checkpointPath
if ([string]$afterGraceful.stop_mode -cne 'graceful' -or [int]$afterGraceful.budget_consumed -lt [int]$policy.fault_injection.graceful_stop_after_committed_tasks) { throw 'Part 4 graceful stop state mismatch.' }
$phaseResult.Add([pscustomobject][ordered]@{ phase='graceful'; exit_code=$graceful.exit_code; receipts=@(Get-ChildItem -LiteralPath $receiptRoot -Filter '*.json' -File).Count; checkpoint_completed=@($afterGraceful.completed_task_ids).Count; checkpoint_sequence=[int]$afterGraceful.checkpoint_sequence })

$emergency = Invoke-NxbPart4WorkerProcess -PwshPath $pwshPath -WorkerPath $workerPath -RunRoot $runRoot -Mode emergency -StopAfterCommitted ([int]$policy.fault_injection.emergency_stop_after_committed_tasks)
if ($emergency.exit_code -ne 30) { throw ('Part 4 emergency stop exit mismatch: {0}' -f $emergency.exit_code) }
$afterEmergency = Read-NxbPart4Json -Path $checkpointPath
if ([string]$afterEmergency.stop_mode -cne 'emergency' -or [int]$afterEmergency.budget_consumed -lt [int]$policy.fault_injection.emergency_stop_after_committed_tasks) { throw 'Part 4 emergency stop state mismatch.' }
$phaseResult.Add([pscustomobject][ordered]@{ phase='emergency'; exit_code=$emergency.exit_code; receipts=@(Get-ChildItem -LiteralPath $receiptRoot -Filter '*.json' -File).Count; checkpoint_completed=@($afterEmergency.completed_task_ids).Count; checkpoint_sequence=[int]$afterEmergency.checkpoint_sequence })

$complete = Invoke-NxbPart4WorkerProcess -PwshPath $pwshPath -WorkerPath $workerPath -RunRoot $runRoot -Mode continue
if ($complete.exit_code -ne 0) { throw ('Part 4 completion phase failed: exit={0} output={1}' -f $complete.exit_code,$complete.output) }
$finalCheckpoint = Read-NxbPart4Json -Path $checkpointPath
[void](Test-NxbPart4CheckpointBinding -Checkpoint $finalCheckpoint -Manifest $manifest)
$receiptFiles = @(Get-ChildItem -LiteralPath $receiptRoot -Filter '*.json' -File | Sort-Object Name)
if ($receiptFiles.Count -ne [int]$policy.task_count -or @($finalCheckpoint.completed_task_ids).Count -ne [int]$policy.task_count) { throw 'Part 4 final completion count mismatch.' }
if ([string]$finalCheckpoint.stop_mode -cne 'completed') { throw 'Part 4 final checkpoint is not completed.' }
$phaseResult.Add([pscustomobject][ordered]@{ phase='complete'; exit_code=$complete.exit_code; receipts=$receiptFiles.Count; checkpoint_completed=@($finalCheckpoint.completed_task_ids).Count; checkpoint_sequence=[int]$finalCheckpoint.checkpoint_sequence })

$events = @(Get-NxbPart4EventDocument -Path $eventPath)
$receiptDocuments = @($receiptFiles | ForEach-Object { Read-NxbPart4Json -Path $_.FullName })
$duplicateReceiptIds = @($receiptDocuments | Group-Object task_id | Where-Object Count -ne 1)
$attemptStarted = @($events | Where-Object { [string]$_.kind -ceq 'attempt_started' })
$receiptCommitted = @($events | Where-Object { [string]$_.kind -ceq 'receipt_committed' })
$failureEvents = @($events | Where-Object { [string]$_.kind -ceq 'attempt_failed' })

$result = [pscustomobject][ordered]@{
    schema_version=1; status='passed'; contract_id=[string]$policy.contract_id; scope=[string]$policy.scope;
    repository='Naveax/nxb-integrity-research-lab'; exact_head=$currentHead; config_sha256=$configSha; scope_sha256=$scopeSha; run_id=$runId;
    manifest_sha256=(Get-NxbPart4FileSha256 -Path $manifestPath); final_checkpoint_sha256=(Get-NxbPart4FileSha256 -Path $checkpointPath);
    task_count=[int]$policy.task_count; shard_count=[int]$policy.shard_count; phases=$phaseResult.ToArray();
    crash_resume=[pscustomobject][ordered]@{
        crash_observed=$true; stale_checkpoint_observed=(@($afterCrashCheckpoint.completed_task_ids).Count -lt $afterCrashReceiptCount);
        receipt_count_after_crash=$afterCrashReceiptCount; checkpoint_completed_after_crash=@($afterCrashCheckpoint.completed_task_ids).Count;
        final_receipts=$receiptFiles.Count; final_completed=@($finalCheckpoint.completed_task_ids).Count
    };
    scheduler=[pscustomobject][ordered]@{
        attempt_started_count=$attemptStarted.Count; fail_once_event_count=$failureEvents.Count; final_tick=[int]$finalCheckpoint.tick;
        maximum_ticks=[int]$policy.budget.maximum_ticks; maximum_attempts_per_task=[int]$policy.budget.maximum_attempts_per_task;
        maximum_ready_queue_depth=[int]$policy.budget.maximum_ready_queue_depth; maximum_starvation_gap_ticks=[int]$policy.scheduler.maximum_starvation_gap_ticks
    };
    duplicate_prevention=[pscustomobject][ordered]@{
        unique_receipt_count=@($receiptDocuments | ForEach-Object { [string]$_.task_id } | Sort-Object -Unique).Count;
        duplicate_receipt_group_count=$duplicateReceiptIds.Count; receipt_commit_event_count=$receiptCommitted.Count
    };
    review_boundary=[pscustomobject][ordered]@{ synthetic_only=$true; raw_payload_reviewable=$false; task_receipt_body_reviewable=$false };
    local_evidence=[pscustomobject][ordered]@{ manifest_path=$manifestPath; checkpoint_path=$checkpointPath; events_path=$eventPath; receipt_directory=$receiptRoot }
}
$reviewPath = Join-Path $reviewRoot 'part4-runner-experiment.json'
Write-NxbPart4AtomicJson -Path $reviewPath -InputObject $result
Write-Information -InformationAction Continue -MessageData ('NXB Part 4 runner experiment passed: run={0} tasks={1} crash_stale={2} phases=4' -f $runId,$receiptFiles.Count,$result.crash_resume.stale_checkpoint_observed)
if ($PassThru) { return $result }
Write-Output $reviewPath
