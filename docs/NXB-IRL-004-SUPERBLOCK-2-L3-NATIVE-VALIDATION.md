# NXB-IRL-004 SUPERBLOCK 2 L3 native validation

Status: **VALIDATED — ZERO-SIGNAL EVENT-LOG MAPPING**

Canonical runtime/test head:

```text
9f418cbb5aee79cb88093a5894ed2f68b165a344
```

## Native authority

The native elevated Windows run completed the exact-head L3 transition-surface-discovery gate.

```text
PS7 contract:                     20/20
PS5.1 contract:                   20/20
PSScriptAnalyzer findings:        0
canonical L2 bind:                PASS
provider metadata errors skipped: 5
provider count:                   61
surface count:                    118
usable surfaces:                  62
PnP usable surfaces:              47
power usable surfaces:            15
discovery A/B fingerprint stable: true
scenario count:                   8
power restore/delete validated:   true
analysis replay identical:        true
```

Discovery fingerprint:

```text
86e239550d09c250086004bd634a990f87dc891b346ea354b3348fd27516974f
```

Five provider metadata enumeration errors were explicitly accounted while readable providers continued through bounded discovery. The errors were not folded into fingerprint material.

Independent validation accepted both discovery snapshots. A/B discovery JSON differed only in `captured_utc`; provider inventory, surface inventory, availability state and fingerprint material were identical.

## Controlled replay result

The discovery-backed replay used:

```text
PnP replay surfaces:   32
power replay surfaces: 15
idle window:           3000 ms
post-stimulus window:  3000 ms
```

All replayed surfaces remained queryable. Both controlled stimulus families completed twice:

```text
PnP rescan A/B:          successful
power transition A/B:   successful
power restore/delete:   2/2 validated
```

No selected Event Log surface produced an event inside any matched idle or stimulus window.

```text
PnP repeated positive shapes:   0
PnP mapping eligible:           false
power repeated positive shapes: 0
power mapping eligible:         false
```

This is a measured zero-signal Event Log result, not a query-unavailable result.

## Evidence

```text
observation SHA-256:
85c2d9fa74d3c548c3618988f947ca7e8b1566b3031594aef0323c988373d848

analysis SHA-256:
0b1a5d31b3a1aa1aceffa541c7a5a14d4fe1f9baeb7496d4f96dbcb06a1c9742

receipt SHA-256:
6f6820c9afde72e5d5cd437542d109e26d6813cafb7173e94786e22c5efe2f21

review ZIP SHA-256:
2a8ef6942285af0df07cb2e124eaa7edda8dac746a5c756b1a0b133d3a5446b4
```

The bounded review ZIP contains only JSON review artifacts. No ETL, EVTX, raw event XML, event messages or raw event payload are part of L3 review evidence.

## Claim boundary

Validated:

```text
provider_name_family_discovery
attached_log_discovery
bounded provider-error accounting
discovery fingerprint stability
controlled PnP rescan execution
controlled temporary power-scheme transition execution
power restore/delete cleanup
measured Event Log zero-signal result
```

Still false or unclaimed:

```text
pcie_bdf_semantics
event_id_semantics
event_task_opcode_semantics
device_lifecycle_semantics
power_eventlog_mapping
power_causality
firmware_causality
root_cause_validated
continuous_trace_completeness
```

## Next gate

L4 should not merely extend Event Log timing windows. L3 already expanded discovery to 61 providers / 118 surfaces and replayed 32 PnP plus 15 power usable surfaces with measured zero events.

The next gate therefore uses direct state binding for controlled transitions:

- PnP rescan: before/after sanitized devnode inventory fingerprint plus successful rescan receipt;
- power: original active scheme -> owned temporary duplicate active -> original restored, with state observed at each phase and owned cleanup validated;
- semantic promotion remains bounded to what those direct state observations prove.
