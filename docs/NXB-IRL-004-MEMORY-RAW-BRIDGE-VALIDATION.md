# NXB-IRL-004 Memory Raw ETL/xperf Bridge Validation

## Status

`PASSED`

Validated implementation head:

```text
c9ec8cf498d8bebb992be865f2c76fd496d4b8c1
```

Validation ran on real elevated Windows 10 build 19045 with PowerShell 7.6.3 and Windows PowerShell 5.1. GitHub Actions were not used.

## Exact-head result

The exact-head raw-bridge summary reported:

```text
schema_version: 1
status: passed
head_sha: c9ec8cf498d8bebb992be865f2c76fd496d4b8c1
expected_head_sha: c9ec8cf498d8bebb992be865f2c76fd496d4b8c1
```

All raw-bridge gates passed:

- `memory-etl-adapter-v3`
- `memory-raw-bridge-python-parse`
- `memory-raw-bridge-powershell-parser`
- `memory-raw-bridge-psscriptanalyzer`
- `memory-raw-bridge-contract`
- `pester-memory-raw-bridge-pwsh`
- `pester-memory-raw-bridge-ps51`

The nested validated chain also passed at the same exact head:

```text
profile:
  PowerShell 7:             10/10
  Windows PowerShell 5.1:  10/10

snapshot contract:
  PowerShell 7:              9/9
  Windows PowerShell 5.1:    9/9

native collector:
  PowerShell 7:              7/7
  Windows PowerShell 5.1:    7/7

normalized ETL adapter:
  PowerShell 7:             18/18
  Windows PowerShell 5.1:   18/18

raw xperf-dumper bridge:
  PowerShell 7:              9/9
  Windows PowerShell 5.1:    9/9
```

No failed, skipped, inconclusive or not-run raw-bridge tests were present.

## Canonical bridge evidence

The validated fixture bridge produced eight normalized event classes and deliberately kept hard-fault evidence outside the v1 normalized coverage because the observed hard-fault dumper header did not expose a trustworthy byte field.

Observed canonical coverage:

```text
copy_on_write_fault
demand_zero_fault
guard_page_fault
mapped_section_create
mapped_section_delete
transition_fault
virtual_allocation
virtual_free
```

The canonical manifest recorded:

```text
normalized_event_count: 8
process_attribution: partial
hard_fault unmapped count: 1
hard_fault_bytes_semantics: not_available_from_observed_header
missing_event_type_means_zero: false
parser_completeness: not_claimed
```

The downstream ETL summary remained deliberately partial. Hard-fault status was `not_assessed`; soft-fault total was derived only from complete soft-component coverage. No absence or trace-completeness claim was introduced.

## Review archive

Successful review archive:

```text
nxb-memory-raw-bridge-c9ec8cf498d8-20260807T094431Z-review.zip
sha256: 86dfea0e86bfaad43791a1fa14b03086115c7e842eaad8f940113308ce71de0b
```

The archive contains the final raw-bridge JSON summary, both raw-bridge NUnit XML files, the canonical bridge manifest/CSV, the canonical downstream ETL summary and the nested ETL/collector/foundation/profile evidence chain.

## Portable wrapper note

After the repository runner wrote the successful summary and review ZIP, the external portable wrapper reported:

```text
The property 'status' cannot be found on this object.
```

This was not a validation-gate failure. The repository runner had already completed successfully and emitted a `status: passed` summary. The wrapper failure was caused by child PowerShell output sharing the success pipeline with the final `-PassThru` object. Later orchestration work must consume the JSON summary explicitly or otherwise enforce a single-object PassThru contract.

## Boundary

This validation proves the deterministic xperf-dumper text normalization and downstream contract on real Windows. It does not yet prove that a real WPR-generated memory ETL exposes every synthetic fixture header or that all desired event classes can be attributed to a target process. The next mandatory step is a bounded real WPR capture followed by xperf dumper header inspection.
