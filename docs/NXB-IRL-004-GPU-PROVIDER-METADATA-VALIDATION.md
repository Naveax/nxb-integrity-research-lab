# NXB-IRL-004 GPU provider metadata validation

## Status

Validated on native Windows at exact head:

```text
f29e227c61ce9c6b4600ba814605f61c9159510c
```

Validation ref used for the run:

```text
validation/gpu-provider-metadata-f29e227
```

## Static gate

```text
PowerShell 7 Pester:       8/8
Windows PowerShell 5.1:   8/8
PSScriptAnalyzer:         0 findings
```

The real metadata probe executed only after those gates passed.

## Real provider metadata result

```text
Microsoft-Windows-DxgKrnl
GUID observed:              true
keyword parser:             section-v1
keyword section detected:   true
keyword contamination:      false
keyword rows:               38
publisher metadata:         measured

Microsoft-Windows-DXGI
GUID observed:              true
keyword parser:             section-v1
keyword section detected:   true
keyword contamination:      false
keyword rows:               5
publisher metadata:         measured
```

Observed provider GUID bindings:

```text
Microsoft-Windows-DxgKrnl
{802ec45a-1e99-4b83-9920-87c98277ba9d}

Microsoft-Windows-DXGI
{ca11c036-0102-4a2d-a6ad-f03cfed5d3c9}
```

## Observed DxgKrnl keyword metadata

```text
0x0000000000000001 Base
0x0000000000000002 Profiler
0x0000000000000004 References
0x0000000000000008 ForceVsync
0x0000000000000010 Patch
0x0000000000000020 Cdd
0x0000000000000040 Resource
0x0000000000000080 Memory
0x0000000000000100 Dxgkrnl_StatusChangeNotify
0x0000000000000200 DxgKrnl_Power
0x0000000000000400 DriverEvents
0x0000000000000800 LongHaul
0x0000000000001000 StablePower
0x0000000000002000 DefaultOverride
0x0000000000004000 HistoryBuffer
0x0000000000008000 GPUScheduler
0x0000000000010000 DxgKrnl
0x0000000000020000 DxgKrnl_WDI
0x0000000000040000 Miracast
0x0000000000080000 IndirectSwapChain
0x0000000000100000 GPUVA
0x0000000000200000 VidMmWorkerThread
0x0000000000400000 Diagnostics
0x0000000000800000 VirtualGpu
0x0000000001000000 AdapterLock
0x0000000002000000 MixedReality
0x0000000004000000 HardwareSchedulingLog
0x0000000008000000 Present
0x0000000010000000 DxgKrnl_Int
0x0000000020000000 PerfData
0x0000000040000000 AzureTriageLogging
0x0001000000000000 win:ResponseTime
0x8000000000000000 Microsoft-Windows-DxgKrnl/Diagnostic
0x4000000000000000 Microsoft-Windows-DxgKrnl/Performance
0x2000000000000000 Microsoft-Windows-DxgKrnl/Power
0x1000000000000000 Microsoft-Windows-DxgKrnl/Contention
0x0800000000000000 Microsoft-Windows-DxgKrnl-Admin
0x0400000000000000 Microsoft-Windows-DxgKrnl-Operational
```

## Observed DXGI keyword metadata

```text
0x0000000000000001 Objects
0x0000000000000002 Events
0x0000000000000004 JournalEntries
0x8000000000000000 Microsoft-Windows-DXGI/Analytic
0x4000000000000000 Microsoft-Windows-DXGI/Logging
```

## Evidence-quality correction history

An earlier global hexadecimal-row parser was rejected because it also classified later DXGI process/PID rows as keyword metadata. The promoted run uses the repaired `section-v1` parser, which:

- enters only the `Value ... Keyword ...` section;
- tolerates native blank lines;
- stops when that section ends;
- rejects executable/path contamination fail-closed;
- recorded `contamination=false` for both providers.

## Conservative claim boundary

This validation proves provider identity and host-observed keyword metadata only. It does not prove event payload or timing semantics.

```text
keyword_semantics_validated:        false
event_ids_validated:                false
event_payload_contract_validated:   false
present_semantics:                  false
submission_semantics:               false
queue_context_semantics:            false
queue_wait_semantics:               false
gpu_execution_duration_semantics:  false
trace_completeness:                 not_claimed
```

The observed names/masks are input evidence for the next bounded profile-design step; they are not, by themselves, authorization to promote higher-level GPU claims.
