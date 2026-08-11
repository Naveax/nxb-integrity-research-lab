# NXB IRL-006 Part 4 - Resumable Runner, Scheduler, Deterministic Sharding

## Scope

Part 4 certifies a bounded local synthetic runner. It does not perform network discovery, target mutation, device mutation, or destructive validation. The authority is stacked on Part 3 and therefore re-certifies Part 2 and Part 3 on the same exact Git head before Part 4 can pass.

## Exact run authority

Every run binds:

- repository identity
- exact 40-hex Git head
- runner policy SHA-256
- deterministic scope SHA-256
- contract identifier

The run id is the first 32 hex characters of SHA-256 over those newline-delimited values, prefixed with `run-`. Checkpoints and success receipts repeat the binding. A mismatched head, config hash, scope hash, run id, or checkpoint fingerprint fails closed.

## Deterministic sharding

Each task shard is:

`UInt32(SHA256(task_id)[0:8], hex) mod shard_count`

The independent Python validator recomputes the shard for every task.

## Scheduler

The scheduler score is deterministic and combines:

- base priority
- domain coverage deficit
- fairness credit from ticks since the domain was last served
- saturation penalty from already completed work in that domain
- retry penalty from prior attempts

Ties are resolved by ordinal task id. Ready-queue depth, total ticks, committed tasks, and per-task attempts are bounded by policy. Failed synthetic `fail_once` tasks receive exponential backoff capped by policy.

## Durable idempotency and crash resume

A success receipt is the idempotency authority. On successful work the worker writes the task receipt atomically before advancing the checkpoint.

The crash phase deliberately terminates the child PowerShell process after the seventh success receipt is durable but before that task is added to the checkpoint. This creates a real receipt-ahead-of-checkpoint recovery window. The next process reconciles durable receipts into the stale checkpoint before it schedules any work, preventing duplicate execution.

The experiment then exercises:

1. forced crash after receipt
2. resumed execution to a graceful stop
3. resumed execution to an emergency stop
4. final resume to full completion

Checkpoint sequence numbers must increase across phases.

## Stop modes

`graceful` stops after the current committed task and persists a graceful checkpoint.

`emergency` stops before any next task can be scheduled after the configured committed-task boundary and persists an emergency checkpoint.

A later `continue` run clears the transient stop mode after validating bindings and reconciling receipts.

## Independent validation

`tools/validate_part4_runner.py` independently recomputes:

- exact run binding
- manifest scope hash and run id
- task shards
- checkpoint fingerprint
- receipt uniqueness and bindings
- scheduler score and ordinal tie-break at every attempt
- exponential retry backoff
- domain coverage and starvation bound
- queue, tick and attempt budgets
- crash/stale-checkpoint evidence
- graceful, emergency and final completion phases

Ten fail-closed mutations are required:

1. stale exact head
2. config hash mismatch
3. scope hash mismatch
4. run id mismatch
5. duplicate receipt
6. checkpoint sequence rollback
7. shard mismatch
8. budget exceeded
9. backoff violation
10. fairness violation

## Combined authority

The repo-owned top gate is:

`scripts/Invoke-NxbPart4ResumableRunnerCertification.ps1`

Its order is:

```text
exact clean Part 4 head
-> Part 4 parser/PSScriptAnalyzer/Python/known-error gate
-> Part 4 PS7 + PS5.1 16-test source contract
-> Part 3 certification on the same exact head
   -> Part 2 semantic hardening on the same exact head
-> real child-process crash/resume runner experiment
-> independent Part 4 10/10 requirements
-> independent Part 4 10/10 negative controls
-> JSON-only Part 4 review ZIP
-> final exact-tree zero-error scan
```

Part 4 is not native certified until the combined Windows authority passes on the frozen exact head.
