# NXB-IRL-004 — GPU Provider Discovery Validation

## Status

`VALIDATED — SLICE 1 CLOSED`

- Tracking issue: `#2`
- PR: `#11`
- Branch: `nxb-irl-004-gpu-dxgkrnl-present`
- Exact validated head: `5c38ee49eb2e465a9627ecb87dec49e7fceb16ec`
- Authority: native Windows exact-head validation

## Static gate

```text
PowerShell 7 Pester:       8/8
Windows PowerShell 5.1:    8/8
PSScriptAnalyzer:          0
```

## Real host discovery

```text
display adapters:          3
provider candidates:       15
graphics event channels:   18
wpr.exe:                    available
wpa.exe:                    available
xperf.exe:                  available
GPUView.exe:                available
```

Observed display adapters:

```text
NVIDIA GeForce RTX 3080
Parsec Virtual Display Adapter
USB Mobile Monitor Virtual Display
```

The presence of virtual display adapters is recorded as host provenance only. It is not treated as physical-GPU evidence.

## Provider evidence

The real host exposed the following provider identities relevant to the initial GPU/present path:

```text
Microsoft-Windows-DxgKrnl
{802ec45a-1e99-4b83-9920-87c98277ba9d}

Microsoft-Windows-DXGI
{ca11c036-0102-4a2d-a6ad-f03cfed5d3c9}
```

Additional observed graphics candidates included DWM providers, `Microsoft-Windows-DxgKrnl-SysMm`, runtime graphics and graphics-capture providers.

Observed DxgKrnl channels included:

```text
Microsoft-Windows-DxgKrnl-Admin
Microsoft-Windows-DxgKrnl-Operational
Microsoft-Windows-DxgKrnl/Contention
Microsoft-Windows-DxgKrnl/Diagnostic
Microsoft-Windows-DxgKrnl/Performance
Microsoft-Windows-DxgKrnl/Power
```

DXGI channels included:

```text
Microsoft-Windows-DXGI/Analytic
Microsoft-Windows-DXGI/Logging
```

## Claim boundary

Provider discovery validates provider/channel existence only. It does not validate provider keyword masks, event IDs, payload contracts or timing semantics.

```text
provider_semantics_validated:       false
keyword_masks_validated:            false
event_ids_validated:                false
present_semantics:                  false
submission_semantics:               false
queue_context_semantics:            false
queue_wait_semantics:               false
gpu_execution_duration_semantics:   false
engine_utilization_representative:  false
resource_residency_semantics:       false
frame_pacing_representative:        false
trace_completeness:                 not_claimed
```

## Next gate

Before authoring the minimal GPU WPR profile, query the real-host metadata for the two primary providers above. Record keyword values and publisher metadata without starting an ETW session. Only observed metadata may be promoted into the first bounded `NxbGpuDxgkrnlPresent` profile.
