# NXB IRL-004 — SUPERBLOCK 1 repeated semantic-control gate

## Status

`ROUND 2 — NATIVE VALIDATION NEXT`

Round 1 is canonically validated at exact head `2230864433890c2992b59088fe1af3db0c635808` with one controlled fixture PID observed in GPU, network and kernel-lifecycle domains, zero ETL loss, and byte-identical normalization/correlation replay.

## Objective

Round 2 tests controlled stimulus-specific observability with repeated positive and negative controls. It does not infer semantics from provider/event names alone.

One fresh WPR session contains ten sequential owned fixture processes:

```text
all_on A
  -> gpu_off A
  -> network_off A
  -> kernel_off A
  -> minimal A
  -> minimal B
  -> kernel_off B
  -> network_off B
  -> gpu_off B
  -> all_on B
```

Every process has a distinct receipt and must have a unique positive PID. The analyzer refuses a manifest with fewer than ten unique PIDs.

## Modes

```text
all_on:      GPU + localhost network + explicit kernel stimulus
gpu_off:     localhost network + explicit kernel stimulus
network_off: GPU + explicit kernel stimulus
kernel_off:  GPU + localhost network; no explicit registry/file/extra-worker stimulus
minimal:     no deliberate GPU/network/explicit-kernel stimulus
```

`kernel_off` and `minimal` are not kernel-event absence controls. Process startup, image loading, receipt writing and normal runtime activity necessarily create kernel-lifecycle evidence. Kernel and registry operation semantics therefore remain unpromoted.

## GPU controlled mapping gate

For each repeated GPU-positive fixture used by the analyzer:

```text
hardware D3D11 device created:              true
Present attempted/succeeded:                128 / 128
fixture-PID DXGI Present Start rows:         128
fixture-PID DXGI Present Stop rows:          128
```

For repeated GPU-negative fixtures:

```text
Present attempted/succeeded:                0 / 0
fixture-PID DXGI Present Start rows:         0
fixture-PID DXGI Present Stop rows:          0
```

A PASS may establish only the bounded claim:

```text
controlled_present_count_mapping_validated = true
```

It does not generalize this mapping to arbitrary applications, profiles, Windows builds, providers, swap effects or Present semantics.

## Network controlled mapping gate

Positive network modes must independently report the owned localhost DNS + 64 KiB loopback exchange and expose fixture-PID normalized DNS/TCP rows. `network_off` and `minimal` must expose zero fixture-PID DNS/TCP rows.

A PASS may establish only:

```text
controlled_network_activity_mapping_validated = true
```

TCP connection lifecycle semantics, payload semantics and latency semantics remain false.

## Present field-shape eligibility

The analyzer records field names, never raw field values, for fixture-PID Present Start/Stop rows. It measures:

- Start/Stop shape signatures;
- rows exposing named Present identifier candidates (`swapchain`, `presentid`, `hwnd` name tokens);
- shared named identifier field names;
- whether exact named-identifier pairing is structurally eligible;
- whether only a PID/sequence candidate remains.

Even a structural pairing candidate does not establish pairing semantics. `sequence_delta` is not time while timestamp units remain unresolved.

## Capture and replay

The ten fixtures run inside one owned WPR session. A pre-existing WPR session is never cancelled automatically. The resulting ETL must satisfy:

```text
EventsLost = 0
BuffersLost = 0
BuffersWritten > 0
```

The xperf dump is normalized twice. Both normalized events and coverage must be byte-identical. The repeated-control analyzer then runs twice over the same normalized stream and its summary must also be byte-identical.

## Evidence boundary

Reviewable:

- ten bounded fixture receipts;
- trace-quality JSON;
- header inventory;
- normalized aggregate coverage;
- repeated-control aggregate summary with field names only;
- Round-2 certification receipt.

Local-only:

- ETL;
- full xperf dumper;
- normalized event JSONL/replay;
- local manifest containing receipt paths;
- executable/object/build log;
- any WPR raw status;
- raw event field values.

## Claims that must remain false/unclaimed

```text
present_event_mapping_generalized
present_pairing_semantics
present_success_semantics
tcp_connection_lifecycle_validated
network_latency_semantics
kernel_lifecycle_semantics
registry_operation_semantics
timestamp_unit_resolved
causal_relationship_validated
root_cause_validated
trace_completeness = not_claimed
circular_overwrite = unknown
```

## Next after PASS

Round 3 performs paired overhead calibration plus the final IRL-004 claim/evidence audit. A fourth native round is reserved only for combined residual repair if Round 2 or Round 3 exposes a Windows-specific gap.
