# NXB IRL-005 Bounded Trigger Capture

## Status

This document defines the post-release runtime contract for Issue #26. It does not rewrite the published `v1.0.1` release authority or its historical CI cardinalities.

The runtime feature is certified only after a fresh exact-head hosted CI PASS and a fresh trusted Windows native WPT PASS. Source presence alone is not certification.

## Capture model

The capture primitive uses the committed `Nxb.MinimalCpuScheduler` WPR profile in its **Memory** logging variant. The profile contract is already repository-owned and validated as:

- 1024 KiB buffer size;
- 64 buffers;
- 64 MiB aggregate in-memory buffer budget;
- bounded buffer reuse rather than unbounded retention;
- the existing CPU/scheduler kernel keyword and stack set.

`Start-NxbBoundedMemoryTrace.ps1` starts the profile without `-filemode`, which selects the committed Memory variant. The script seals the profile SHA-256, profile provenance, exact Git head, policy fingerprint, and bounded capture session ID before the runtime coordinator proceeds.

The Memory WPR session is armed **before** the adaptive trigger activates. This is the pre-trigger ring. When a trigger activates, the coordinator keeps the same bounded Memory session alive for the bounded post-trigger interval, then converts the session to ETL through the existing WPR stop path.

No unbounded `GeneralProfile` fallback is permitted by this runtime authority.

## State machine

`Update-NxbBoundedTriggerCaptureState.ps1` owns the durable JSON state machine:

```text
armed -> post_capture -> finalizing -> completed
  |          |              |
  +----------+--------------+-> failed
```

The state is bound to:

- exact repository head;
- bounded capture session GUID;
- adaptive policy ID;
- canonical policy SHA-256 fingerprint;
- monotonic clock frequency and monotonically increasing ticks.

Requested pre-trigger and post-trigger durations are recorded separately from effective durations. Effective durations are clamped to the policy maximums. A hard session deadline caps all post-trigger extension.

A zero-length post-trigger request moves directly to `finalizing` after the trigger. Negative durations are rejected.

## Trigger binding and overlap

The first accepted trigger is retained as `primary_trigger`. Each trigger record contains:

- trigger ID;
- reason;
- priority;
- UTC timestamp;
- monotonic timestamp;
- adaptive plan fingerprint;
- disposition.

The first plan fingerprint is retained as `primary_plan_fingerprint_sha256`. The current effective plan fingerprint is separately tracked because an overlapping trigger can legitimately change the adaptive plan.

Overlapping triggers are coalesced up to `MaxCoalescedTriggers`. A coalesced trigger may extend the post-trigger deadline, but never beyond the hard session deadline. Higher-priority overlapping triggers may become `selected_trigger` without rewriting the original primary trigger.

After the coalescing budget is exhausted, additional activations are explicitly counted as rejected storm events. Trigger history has its own independent bounded retention cap and a dropped-history counter.

## Budget and emergency termination

The coordinator checks free disk capacity before arming WPR and throughout capture. If free space drops below `MinimumFreeDiskMiB`, the state machine enters bounded finalization with `disk_pressure` as the budget and termination reason.

Other bounded termination paths include:

- hard session timeout before a trigger;
- hard session timeout during post-trigger capture;
- explicit budget exhaustion;
- emergency-stop sentinel;
- normal post-window completion;
- zero post-window completion;
- fail-closed runtime or evidence errors.

WPR cleanup is attempted on exceptional paths. A completed state cannot later be rewritten to failed.

## Domain accounting

The current real primitive is the minimal CPU/scheduler kernel WPR profile. Therefore the runtime receipt does **not** pretend that every adaptive domain requested by a trigger was captured.

Requested domains are reported individually as either:

- `captured`, currently for `cpu` and `kernel`; or
- `not_captured_by_minimal_wpr_primitive`.

Overall domain coverage is reported as `none`, `partial`, or `complete`. A valid capture requires at least one requested domain to be genuinely represented by the primitive; complete multi-domain coverage is not falsely claimed.

This keeps the runtime authority honest while leaving future domain-specific primitives able to extend coverage without weakening the current contract.

## Loss and overwrite accounting

The existing trace-loss pipeline remains authoritative. The bounded capture is stopped through `Stop-PerformanceTraceWithAccounting.ps1`, preserving the existing pre-stop WPR snapshot, ETL statistics, trace-loss accounting, profile-provenance validation, and failure semantics.

The bounded receipt records:

- configured Memory buffer capacity;
- observed buffers written;
- Events Lost;
- Buffers Lost;
- realtime Buffers Lost when available;
- an explicit bounded-buffer reuse estimate:

```text
max(0, observed_buffers_written - configured_buffer_capacity)
```

The estimate is labeled as an estimate. It is not substituted for native loss counters.

## Evidence receipt

`Invoke-NxbBoundedTriggerCapture.ps1` writes a JSON receipt bound to:

- exact Git head;
- session ID;
- policy ID and SHA-256 fingerprint;
- primary and final adaptive plan fingerprints;
- trigger reason/time/priority/history;
- requested, effective, and observed pre/post durations;
- capture modes before and after trigger;
- truncation and termination state;
- memory and disk budgets;
- per-domain accounting;
- buffer/loss/overwrite accounting;
- privacy flags inherited from the adaptive policy;
- ETL SHA-256;
- ETL metadata SHA-256;
- trace-session SHA-256;
- trace-loss-accounting SHA-256;
- post-stop-statistics SHA-256;
- profile and profile-provenance SHA-256 values.

The durable state is completed only after this receipt exists and its SHA-256 is written back into the state authority.

## Negative controls

`tests/BoundedTriggerCapture.Tests.ps1` permanently covers:

1. bounded Memory profile/static parser contract;
2. oversized-window clamping;
3. zero-length post window;
4. trigger/session/policy/plan/domain binding;
5. overlapping triggers with evolving plan fingerprints;
6. bounded storm coalescing and rejection;
7. backwards monotonic time rejection;
8. stale exact-head and session rejection;
9. stale policy fingerprint rejection;
10. hard trigger timeout;
11. emergency stop;
12. budget/disk-pressure termination;
13. bounded trigger-history retention;
14. completion evidence binding and completed-state immutability;
15. coordinator domain, disk, overwrite, and session-evidence contract.

## Native certification evidence

`Invoke-NxbBoundedTriggerNativeSmoke.ps1` is executed by the trusted Windows native CI authority. It:

1. creates a fresh experiment outside the repository worktree;
2. publishes an initially non-triggering signal;
3. arms the real Memory WPR primitive;
4. changes the signal after a delay so a real pre-trigger interval exists;
5. waits for the adaptive trigger and a one-second bounded post-trigger interval;
6. stops WPR through the existing trace-loss accounting path;
7. validates exact-head/session/policy bindings and real observed pre/post durations;
8. writes only a bounded JSON review summary.

The ETL itself is hashed and bound into the evidence but is **not** retained inside the CI review ZIP. The post-release native review set therefore grows from seven to eight entries by adding `bounded-trigger-native-smoke.json`.

The published `v1.0.1` production release policy remains unchanged at its historical seven-entry native review set and historical 899/892 Pester evidence. Runtime growth is a new authority, not a retroactive edit of release history.

## Successor validation after publication

`tools/validate_v1_successor.py` freezes the v1.0.1 release transition at the published release head:

```text
v1.0.1 -> 9a6f5b91d1a9e1d639be4b904851c7d7a1a12c85
```

The release-transition allowlist is evaluated only from the frozen v1.0.0 predecessor to that published release head. Current post-release source development must descend from the published v1.0.1 head, but it does not expand the historical release allowlist.

Post-release changes remain independently fail-closed for forbidden generated artifacts and private-key material.

## Certification gate

Issue #26 is complete only when all of the following are true on one exact candidate head:

- parser clean;
- PSScriptAnalyzer clean;
- permanent known-error scan clean;
- all PowerShell 7 tests pass with no skips/not-run;
- Windows PowerShell 5.1 compatible partition passes with only the existing seven `PS7Only` exclusions;
- independent CI validator passes;
- frozen-release successor validator passes;
- real native Memory-WPR trigger smoke passes;
- native review ZIP contains exactly eight review entries;
- review evidence is JSON/text only and does not retain ETL bytes;
- production signing/release/tag/private-key mutation flags remain false;
- a new exact-head/tree authority is recorded before merge.
