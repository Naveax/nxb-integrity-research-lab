# NXB-IRL-004 SUPERBLOCK 2 L4 direct-state semantic control

Status: **IMPLEMENTED — NATIVE VALIDATION NEXT**

Canonical runtime/test candidate:

```text
a37b92e02acfce70b6fdd23a69a8b25dfc013cca
```

## Why L4 exists

L2 and L3 both completed controlled PnP rescans and reversible power-scheme transitions without producing persisted Event Log events inside matched observation windows. L3 expanded discovery to 61 providers / 118 surfaces / 62 usable surfaces and still measured zero events on all replayed surfaces.

L4 therefore changes observation class instead of merely extending Event Log timing.

## PnP direct-state control

For repeats A and B:

1. collect a sanitized `Win32_PnPEntity` inventory;
2. hash each raw PnP identity before evidence construction;
3. build sorted per-device record hashes;
4. compute an aggregate devnode inventory SHA-256;
5. run only `pnputil /scan-devices`;
6. collect the same sanitized inventory again;
7. record whether before/after inventory fingerprints are identical.

Raw PnP identifiers are not emitted into review evidence.

PnP inventory stability is a measured result, not a pass requirement. L4 does not promote device-lifecycle semantics.

## Power direct-state control

For repeats A and B:

1. resolve the original active power scheme;
2. create an owned duplicate;
3. verify the temporary scheme is visible;
4. activate the temporary scheme;
5. directly read the active scheme and require it to equal the temporary scheme;
6. restore the original scheme;
7. directly read the active scheme and require it to equal the original scheme;
8. delete the owned temporary scheme;
9. verify the temporary scheme is no longer visible.

A `finally` path retries restore and owned cleanup.

Review evidence stores SHA-256 bindings of scheme GUIDs rather than raw GUIDs.

If both repeats satisfy the direct-state relation, L4 may promote only:

```text
power_policy_transition_mapping = true
```

It does not promote `power_causality`.

## Independent validation

Python independently:

- recomputes each PnP inventory fingerprint from sorted record hashes;
- verifies two PnP repeats and successful rescan execution;
- verifies two power repeats;
- requires `before == original`;
- requires `during == temporary`;
- requires `restored == original`;
- requires temporary != original;
- requires create/activate/restore/delete success;
- enforces conservative claim boundaries.

## Native acceptance

```text
PS7:                           20/20
PS5.1:                         20/20
PSScriptAnalyzer:              0
Python syntax:                 PASS
canonical L3 bind:             PASS
PnP repeats:                   2/2 successful
PnP inventory stable both:     measured true|false
power repeats:                 2/2 successful
power direct-state mapping:    true
power restore/delete:          2/2
raw PnP identifier exposure:   false
WPR / ETL / Get-WinEvent:      not used
```

## Conservative boundary

Still false/unclaimed:

```text
pnp_lifecycle_semantics
pcie_bdf_semantics
power_causality
firmware_causality
root_cause_validated
continuous_trace_completeness
```
