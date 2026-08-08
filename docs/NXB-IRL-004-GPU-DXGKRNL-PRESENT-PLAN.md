# NXB-IRL-004 — GPU / DXGKRNL / Present Plan

## Status

`IN PROGRESS — PROVIDER DISCOVERY / PROFILE CONTRACT NEXT`

- Tracking issue: `#2`
- Base: `main`
- Branch: `nxb-irl-004-gpu-dxgkrnl-present`
- Parent storage block: merged PR `#10`, merge `b9e570f3581927e35c4c42251ffb6d7ddfd3c6e7`
- GitHub Actions: intentionally disabled repository-wide
- Authority: native exact-head validation on real Windows

## Objective

Build a bounded, evidence-first GPU observability path that can correlate CPU submission activity with DXGKRNL scheduling, GPU-engine execution evidence and presentation without promoting undocumented or unverified event fields into semantic claims.

Target chain:

```text
application graphics API
 -> user-mode display driver
 -> DXGKRNL
 -> context / queue / submission scheduling
 -> GPU engine execution
 -> present
 -> normalized GPU evidence
```

GPUView/WPT is a downstream analysis surface for ETL evidence; it is not the source of truth for claims that are absent from the captured events.

## Evidence policy

Every GPU event or metric must use an explicit evidence state:

```text
measured
unsupported
unavailable
failed
not_assessed
```

Missing or unobserved GPU activity is never synthesized as zero.

Raw ETL, provider dumps, path-heavy exports and third-party target data remain local-only. Review artifacts must be bounded and sanitized.

## Initial conservative claim boundary

Until independently proven by real Windows traces and replay:

```text
present_semantics:                false
submission_semantics:             false
queue_context_semantics:          false
queue_wait_semantics:             false
gpu_execution_duration_semantics: false
engine_utilization_representative:false
resource_residency_semantics:     false
frame_pacing_representative:      false
trace_completeness:               not_claimed
```

## Slice 1 — provider and capability discovery

- [ ] Inventory installed graphics adapters, driver versions and WDDM-related capability metadata available through supported Windows interfaces.
- [ ] Enumerate ETW providers whose names indicate DXGKRNL / graphics-kernel / presentation relevance.
- [ ] Query provider metadata on the exact Windows host rather than hard-coding provider GUIDs or keyword masks from memory.
- [ ] Record available Windows Performance Toolkit binaries (`wpr.exe`, `wpa.exe`, `xperf.exe`, GPUView when installed).
- [ ] Record OS build, boot identity and machine identity binding.
- [ ] Produce a sanitized provider-inventory JSON that contains provider names/IDs/capability metadata but no raw event payloads.
- [ ] Add PS7 + Windows PowerShell 5.1 parser/contract tests and PSScriptAnalyzer gate.

### Slice 1 completion gate

A specific DXGKRNL capture profile is not authored until the real target host has demonstrated which provider names/IDs and capture surfaces are actually available.

## Slice 2 — bounded GPU WPR profile foundation

After Slice 1 evidence:

- [ ] Add `NxbGpuDxgkrnlPresent` WPR profile.
- [ ] Provide minimal and diagnostic variants where supported.
- [ ] Keep capture file bounded and use circular file mode unless a validated reason requires a different mode.
- [ ] Include process/thread/image correlation needed to bind graphics activity to a process/thread.
- [ ] Enable only provider keywords/events that were observed and validated on the target Windows build.
- [ ] Do not infer queue-depth, queue-wait, execution-duration or residency semantics from event names alone.
- [ ] Pass native `wpr.exe -profiles` parsing on real Windows.
- [ ] Record exact profile SHA-256.

## Slice 3 — real ETL header inventory and normalized GPU event contract

- [ ] Capture a short bounded owned graphics scenario.
- [ ] Enumerate real ETL event/header names before writing a parser.
- [ ] Define normalized GPU event schema with experiment/machine/boot/process/thread identity.
- [ ] Map only observed fields.
- [ ] Preserve raw timestamp units when the unit contract is unresolved.
- [ ] Separate event evidence from higher-level presentation/queue/performance metrics.
- [ ] Treat unobserved event classes as `not_assessed`, never zero.

Candidate normalized event families are provisional until observed:

```text
gpu_submission
gpu_context_schedule
gpu_queue_activity
gpu_present
gpu_preemption
gpu_wait
gpu_resource_lifecycle
gpu_memory_residency
```

## Slice 4 — bounded owned GPU fixture and canonical capture

- [ ] Use an owned deterministic D3D11 or D3D12 fixture; do not depend on a protected third-party target for validation.
- [ ] Bound frame count/runtime, resource count and output size.
- [ ] Record fixture result/provenance independently from GPU instrumentation.
- [ ] Capture minimal GPU trace on the same machine/boot/power state.
- [ ] Produce sanitized downstream summary and review ZIP while keeping raw ETL local.

## Slice 5 — deterministic replay and presentation/scheduling semantics investigation

- [ ] Replay the same local raw export to byte-identical normalized output.
- [ ] Preserve experiment/machine/boot identity across replay.
- [ ] Measure native ETL `EventsLost` / `BuffersLost` where the existing ETL accounting contract applies.
- [ ] Classify circular-capacity risk without claiming overwrite absence.
- [ ] Investigate CPU submit -> DXGKRNL -> GPU engine -> present correlation using explicit IDs/timestamps exposed by the observed trace.
- [ ] Promote present/submission/queue/execution semantics only when the field mapping is independently established.
- [ ] Keep unresolved timestamp units raw.

## Slice 6 — paired overhead calibration and closeout

- [ ] Run warmup plus multiple alternating control/instrumented pairs on the owned GPU fixture.
- [ ] Measure fixture wall time and safe process/system overhead indicators.
- [ ] Require each instrumented pair to remain loss-free under native ETL accounting.
- [ ] Keep production overhead threshold `not_declared` unless representative evidence supports one.
- [ ] Run final exact-head repository Pester/PSScriptAnalyzer/native-profile validation.
- [ ] Audit duplicate/obsolete GPU profile, parser and validation paths.
- [ ] Write canonical GPU closeout document.
- [ ] Mark Issue #2 GPU item complete only after every mandatory gate passes.
- [ ] Mark the GPU PR ready and merge only after final exact-head evidence exists.

## Cross-domain target

The GPU block must eventually support this bounded correlation chain:

```text
experiment
 -> machine / boot
 -> process / thread
 -> CPU submission evidence
 -> DXGKRNL scheduling evidence
 -> GPU engine evidence
 -> present evidence
 -> normalized common timeline
```

A visually plausible GPUView timeline by itself is not sufficient to claim semantic correctness; repository evidence must retain the event identities and provenance used to produce the conclusion.

## Immediate next gate

Run **Slice 1 provider/capability discovery on the real Windows host**. The resulting provider inventory determines the first `NxbGpuDxgkrnlPresent` WPR profile contract. No GUID, keyword mask, event ID or timing unit should be hard-coded before that discovery is recorded.
