[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunRoot,
    [Parameter()][ValidateSet('continue','crash_after_receipt','graceful','emergency')][string]$Mode = 'continue',
    [Parameter()][ValidateRange(0,256)][int]$StopAfterCommitted = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'NxbPart4Runner.Common.ps1')

function Write-NxbPart4WorkerEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][object]$InputObject)
    $line = $InputObject | ConvertTo-Json -Depth 16 -Compress
    Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Get-NxbPart4ReceiptCount {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReceiptRoot)
    if (-not (Test-Path -LiteralPath $ReceiptRoot -PathType Container)) { return 0 }
    return @(Get-ChildItem -LiteralPath $ReceiptRoot -Filter '*.json' -File).Count
}

function Sync-NxbPart4ReceiptCheckpoint {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Checkpoint,[Parameter(Mandatory)][string]$ReceiptRoot)
    $completed = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($taskId in @($Checkpoint.completed_task_ids)) { [void]$completed.Add([string]$taskId) }
    foreach ($receiptFile in @(Get-ChildItem -LiteralPath $ReceiptRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $receipt = Read-NxbPart4Json -Path $receiptFile.FullName
        if ([string]$receipt.run_id -cne [string]$Checkpoint.run_id) { throw ('Receipt run binding mismatch: {0}' -f $receiptFile.Name) }
        [void]$completed.Add([string]$receipt.task_id)
    }
    $Checkpoint.completed_task_ids = @($completed | ForEach-Object { [string]$_ } | Sort-Object)
    $Checkpoint.budget_consumed = @($Checkpoint.completed_task_ids).Count
}

$root = [IO.Path]::GetFullPath($RunRoot)
$manifestPath = Join-Path $root 'run-manifest.json'
$policyPath = Join-Path $root 'policy.json'
$checkpointPath = Join-Path $root 'checkpoint.json'
$receiptRoot = Join-Path $root 'receipts'
$eventPath = Join-Path $root 'execution-events.jsonl'
foreach ($path in @($manifestPath,$policyPath,$checkpointPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('Worker input missing: {0}' -f $path) }
}
[IO.Directory]::CreateDirectory($receiptRoot) | Out-Null

$manifest = Read-NxbPart4Json -Path $manifestPath
$policy = Read-NxbPart4Json -Path $policyPath
$checkpoint = Read-NxbPart4Json -Path $checkpointPath
[void](Test-NxbPart4CheckpointBinding -Checkpoint $checkpoint -Manifest $manifest)
if ((Get-NxbPart4FileSha256 -Path $policyPath) -cne [string]$manifest.config_sha256) { throw 'Worker policy hash mismatch.' }

$checkpointCountBeforeReconcile = @($checkpoint.completed_task_ids).Count
Sync-NxbPart4ReceiptCheckpoint -Checkpoint $checkpoint -ReceiptRoot $receiptRoot
$checkpointCountAfterReconcile = @($checkpoint.completed_task_ids).Count
if ($checkpointCountAfterReconcile -gt $checkpointCountBeforeReconcile) {
    Write-NxbPart4WorkerEvent -Path $eventPath -InputObject ([pscustomobject][ordered]@{
        kind='receipt_reconciled'; run_id=[string]$manifest.run_id;
        recovered_count=($checkpointCountAfterReconcile - $checkpointCountBeforeReconcile);
        completed_before=$checkpointCountBeforeReconcile; completed_after=$checkpointCountAfterReconcile; tick=[int]$checkpoint.tick
    })
}
$checkpoint.stop_mode = 'none'
$checkpoint.checkpoint_sequence = [int]$checkpoint.checkpoint_sequence + 1
Write-NxbPart4Checkpoint -Path $checkpointPath -Checkpoint $checkpoint

$domainTarget = @{}
$domainCompleted = @{}
foreach ($domain in @($policy.domains)) {
    $domainName = [string]$domain
    $domainTarget[$domainName] = @($manifest.tasks | Where-Object { [string]$_.domain -ceq $domainName }).Count
    $domainCompleted[$domainName] = @($manifest.tasks | Where-Object { [string]$_.domain -ceq $domainName -and @($checkpoint.completed_task_ids) -contains [string]$_.task_id }).Count
}

while (@($checkpoint.completed_task_ids).Count -lt @($manifest.tasks).Count) {
    if ([int]$checkpoint.tick -ge [int]$policy.budget.maximum_ticks) { throw 'Runner maximum tick budget exceeded.' }
    if ([int]$checkpoint.budget_consumed -gt [int]$policy.budget.maximum_committed_tasks) { throw 'Runner committed-task budget exceeded.' }

    $completedSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($doneId in @($checkpoint.completed_task_ids)) { [void]$completedSet.Add([string]$doneId) }
    $ready = [Collections.Generic.List[object]]::new()
    foreach ($task in @($manifest.tasks)) {
        $taskId = [string]$task.task_id
        if ($completedSet.Contains($taskId)) { continue }
        $notBefore = [int]$checkpoint.not_before_tick.PSObject.Properties[$taskId].Value
        if ($notBefore -gt [int]$checkpoint.tick) { continue }
        $score = Get-NxbPart4SchedulerScore -Task $task -Checkpoint $checkpoint -Policy $policy -DomainTarget $domainTarget -DomainCompleted $domainCompleted
        $ready.Add([pscustomobject][ordered]@{ task=$task; score=[int]$score })
    }

    if ($ready.Count -gt [int]$policy.budget.maximum_ready_queue_depth) { throw 'Runner ready queue exceeded configured maximum.' }
    if ($ready.Count -eq 0) {
        $checkpoint.tick = [int]$checkpoint.tick + 1
        $checkpoint.checkpoint_sequence = [int]$checkpoint.checkpoint_sequence + 1
        Write-NxbPart4Checkpoint -Path $checkpointPath -Checkpoint $checkpoint
        continue
    }

    $selected = @($ready.ToArray() | Sort-Object @{Expression='score';Descending=$true}, @{Expression={ [string]$_.task.task_id };Descending=$false})[0]
    $task = $selected.task
    $taskId = [string]$task.task_id
    $domain = [string]$task.domain
    $attemptProperty = $checkpoint.attempts.PSObject.Properties[$taskId]
    $attempt = [int]$attemptProperty.Value + 1
    $attemptProperty.Value = $attempt
    if ($attempt -gt [int]$policy.budget.maximum_attempts_per_task) { throw ('Task attempt budget exceeded: {0}' -f $taskId) }

    Write-NxbPart4WorkerEvent -Path $eventPath -InputObject ([pscustomobject][ordered]@{
        kind='attempt_started'; run_id=[string]$manifest.run_id; task_id=$taskId; domain=$domain; shard=[int]$task.shard;
        tick=[int]$checkpoint.tick; attempt=$attempt; scheduler_score=[int]$selected.score; ready_queue_depth=[int]$ready.Count
    })

    $failOnce = @($policy.fault_injection.fail_once_task_ids) -contains $taskId
    if ($failOnce -and $attempt -eq 1) {
        $notBeforeTick = Get-NxbPart4BackoffTick -CurrentTick ([int]$checkpoint.tick) -Attempt $attempt -Policy $policy
        $checkpoint.not_before_tick.PSObject.Properties[$taskId].Value = $notBeforeTick
        Write-NxbPart4WorkerEvent -Path $eventPath -InputObject ([pscustomobject][ordered]@{
            kind='attempt_failed'; run_id=[string]$manifest.run_id; task_id=$taskId; tick=[int]$checkpoint.tick;
            attempt=$attempt; not_before_tick=$notBeforeTick; failure_class='synthetic_fail_once'
        })
        $checkpoint.tick = [int]$checkpoint.tick + 1
        $checkpoint.checkpoint_sequence = [int]$checkpoint.checkpoint_sequence + 1
        Write-NxbPart4Checkpoint -Path $checkpointPath -Checkpoint $checkpoint
        continue
    }

    $receiptPath = Join-Path $receiptRoot ($taskId + '.json')
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) { throw ('Duplicate task execution attempted despite existing receipt: {0}' -f $taskId) }
    $receipt = [pscustomobject][ordered]@{
        schema_version=1; status='succeeded'; run_id=[string]$manifest.run_id; exact_head=[string]$manifest.exact_head;
        config_sha256=[string]$manifest.config_sha256; scope_sha256=[string]$manifest.scope_sha256; task_id=$taskId;
        domain=$domain; shard=[int]$task.shard; attempt=$attempt; committed_tick=[int]$checkpoint.tick;
        synthetic_payload_sha256=[string]$task.synthetic_payload_sha256
    }
    Write-NxbPart4AtomicJson -Path $receiptPath -InputObject $receipt
    Write-NxbPart4WorkerEvent -Path $eventPath -InputObject ([pscustomobject][ordered]@{
        kind='receipt_committed'; run_id=[string]$manifest.run_id; task_id=$taskId; domain=$domain; shard=[int]$task.shard;
        tick=[int]$checkpoint.tick; attempt=$attempt; receipt_sha256=(Get-NxbPart4FileSha256 -Path $receiptPath)
    })

    $receiptCount = Get-NxbPart4ReceiptCount -ReceiptRoot $receiptRoot
    if ($Mode -ceq 'crash_after_receipt' -and $StopAfterCommitted -gt 0 -and $receiptCount -eq $StopAfterCommitted) {
        Write-NxbPart4WorkerEvent -Path $eventPath -InputObject ([pscustomobject][ordered]@{
            kind='fault_injected_process_crash'; run_id=[string]$manifest.run_id; task_id=$taskId; tick=[int]$checkpoint.tick;
            receipt_count=$receiptCount; checkpoint_completed_count=@($checkpoint.completed_task_ids).Count
        })
        Stop-Process -Id $PID -Force
    }

    $checkpoint.completed_task_ids = @(@($checkpoint.completed_task_ids) + $taskId | Sort-Object -Unique)
    $checkpoint.budget_consumed = @($checkpoint.completed_task_ids).Count
    $checkpoint.domain_last_served_tick.PSObject.Properties[$domain].Value = [int]$checkpoint.tick
    $domainCompleted[$domain] = [int]$domainCompleted[$domain] + 1
    $checkpoint.tick = [int]$checkpoint.tick + 1
    $checkpoint.checkpoint_sequence = [int]$checkpoint.checkpoint_sequence + 1
    Write-NxbPart4Checkpoint -Path $checkpointPath -Checkpoint $checkpoint

    if ($Mode -ceq 'graceful' -and $StopAfterCommitted -gt 0 -and [int]$checkpoint.budget_consumed -ge $StopAfterCommitted) {
        $checkpoint.stop_mode = 'graceful'
        $checkpoint.checkpoint_sequence = [int]$checkpoint.checkpoint_sequence + 1
        Write-NxbPart4Checkpoint -Path $checkpointPath -Checkpoint $checkpoint
        Write-NxbPart4WorkerEvent -Path $eventPath -InputObject ([pscustomobject][ordered]@{ kind='graceful_stop'; run_id=[string]$manifest.run_id; tick=[int]$checkpoint.tick; completed=[int]$checkpoint.budget_consumed })
        exit 20
    }
    if ($Mode -ceq 'emergency' -and $StopAfterCommitted -gt 0 -and [int]$checkpoint.budget_consumed -ge $StopAfterCommitted) {
        $checkpoint.stop_mode = 'emergency'
        $checkpoint.checkpoint_sequence = [int]$checkpoint.checkpoint_sequence + 1
        Write-NxbPart4Checkpoint -Path $checkpointPath -Checkpoint $checkpoint
        Write-NxbPart4WorkerEvent -Path $eventPath -InputObject ([pscustomobject][ordered]@{ kind='emergency_stop'; run_id=[string]$manifest.run_id; tick=[int]$checkpoint.tick; completed=[int]$checkpoint.budget_consumed })
        exit 30
    }
}

$checkpoint.stop_mode = 'completed'
$checkpoint.checkpoint_sequence = [int]$checkpoint.checkpoint_sequence + 1
Write-NxbPart4Checkpoint -Path $checkpointPath -Checkpoint $checkpoint
Write-NxbPart4WorkerEvent -Path $eventPath -InputObject ([pscustomobject][ordered]@{ kind='run_completed'; run_id=[string]$manifest.run_id; tick=[int]$checkpoint.tick; completed=@($checkpoint.completed_task_ids).Count })
exit 0
