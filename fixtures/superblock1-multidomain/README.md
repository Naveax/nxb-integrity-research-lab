# SUPERBLOCK 1 controlled same-PID multi-domain fixture

This fixture exists only to create a bounded, owned Windows process with deliberate activity in the three structural observability domains already supported by IRL-004.

## Stimulus

One native x64 process performs, in order:

- hardware-only D3D11 device + DXGI swap-chain creation;
- 128 bounded `Present(0, 0)` calls on a 64x64 render target;
- `localhost` DNS resolution;
- a 64 KiB TCP echo exchange bound to IPv4 loopback only;
- read-only access to the current-user registry root;
- a 64 KiB temporary-file write/read/delete round trip;
- bounded worker-thread activity.

Socket waits are bounded. There is no WARP fallback, public address, external hostname, registry write, persistent fixture file, or unbounded loop.

## Receipt boundary

The executable writes a small JSON receipt containing its PID and stimulus counters. The receipt describes what the fixture itself attempted and completed. It does **not** claim that any particular ETW event maps to a particular API call.

The following remain false until separately validated:

- ETW event mapping semantics;
- Present semantics or Present success semantics;
- network connection/lifecycle semantics;
- kernel lifecycle semantics;
- causal relationship or root cause.

## Certification use

`scripts/Invoke-NxbSuperblock1SemanticEligibilityCertification.ps1` builds the fixture from an exact clean repository head, captures it under the existing resilient multi-domain WPR profile, normalizes the resulting xperf dumper twice, correlates the normalized rows twice, and requires the owned fixture PID to have nonzero GPU, network, and kernel-lifecycle row counts.

Raw ETL, full xperf dumper, normalized JSONL, native executable, build log, WPR status, and correlation pair records remain local. The bounded review ZIP contains only receipts, aggregate coverage/correlation summaries, trace-quality counters, and header inventory.
