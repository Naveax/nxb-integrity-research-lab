# NXB IRL-004 — SUPERBLOCK 1 controlled semantic-eligibility gate

## Why this gate exists

Canonical structural correlation passed at implementation head `8bb94d10b4a74629668ddee2ad2fe378f8928999`, but the measured target PID had:

```text
gpu:              0
network:         11
kernel_lifecycle:6384
```

The global structural capture contained multi-domain PIDs but no observed three-domain PID. Existing capture evidence therefore cannot be promoted into same-PID GPU+network+kernel semantics.

## Gate objective

Create one owned, bounded native fixture process that deliberately performs GPU, loopback-network, registry/file, and thread work under a fresh resilient WPR capture, then require structural observability of all three domains on that exact fixture PID.

Acceptance:

```text
fixture build:                 PASS
PowerShell 7 fixture contract: 12/12
PowerShell 5.1 contract:       12/12
PSScriptAnalyzer:              0
hardware D3D11 created:        true
Present calls attempted:       128
Present calls succeeded:       >0
external network used:         false
loopback bytes sent/received:  65536/65536
registry write executed:       false
EventsLost:                    0
BuffersLost:                   0
BuffersWritten:                >0
recognized candidate rows:     >0
normalized rows:               recognized candidate rows
unresolved schema rows:        0
recognized malformed rows:     0
fixture PID GPU rows:          >0
fixture PID network rows:      >0
fixture PID kernel rows:       >0
normalization replay:          byte-identical
correlation replay:            byte-identical
```

## WPR ownership

A pre-existing WPR session is never cancelled automatically. The certification marks the session owned only after its own `wpr -start` succeeds. Failure cleanup may call `wpr -cancel` only while that ownership flag remains true.

## Evidence boundary

Reviewable bounded evidence:

- controlled fixture receipt;
- trace-quality counters;
- header inventory;
- normalized coverage counts/schema diagnostics;
- aggregate structural correlation summary;
- semantic-eligibility certification receipt.

Local-only evidence:

- native executable/object/build log;
- WPR status output;
- raw ETL;
- full xperf dumper;
- normalized event JSONL and replay;
- structural pair-record JSONL and replay.

## Claims after a PASS

A PASS may establish only:

```text
controlled_fixture_executed = true
exact_fixture_pid_attribution = true
same_pid_three_domain_observability = true
semantic_eligibility_established = true
```

It does not validate:

```text
timestamp_unit_resolved
Present event mapping
Present pairing semantics
Present success semantics
GPU queue semantics
TCP lifecycle semantics
network latency semantics
kernel lifecycle semantics
registry operation semantics
causal relationship
root cause
trace completeness
```

`trace_completeness` remains `not_claimed` and `circular_overwrite` remains `unknown`.

## Compressed native-round strategy

The workstream is intentionally batched into a small number of native Windows rounds:

1. **Round 1 — same-PID three-domain eligibility**: build, fresh capture, normalize, correlate, deterministic replay in one run.
2. **Round 2 — controlled ON/OFF semantics experiments**: GPU/network/kernel controls and Present field-shape/pairing eligibility, using Round 1 results to target only measured gaps.
3. **Round 3 — overhead + final IRL-004 certification**: paired control/instrumented overhead and final claim/evidence audit.
4. **Round 4 — contingency only**: combined repair/final rerun if Windows-native behavior exposes a remaining gap.

PR #12 remains draft/open until the native evidence is complete. No merge is implied by this gate.
