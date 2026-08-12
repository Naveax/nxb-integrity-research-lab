# NXB Known-Error Ledger

This ledger is a mandatory pre-final checklist for NXB validation authorities.

## Mandatory workflow

Before publishing a portable validator, freezing a native authority, or declaring a gate complete:

1. Run `scripts/Invoke-NxbKnownErrorScan.ps1` against the exact candidate tree.
2. Require zero active findings.
3. Run the ledger contract under PowerShell 7 and Windows PowerShell 5.1.
4. Classify every new recurring native/static/workflow failure before repair.
5. Add a human-ledger entry and a machine signature when the class is statically detectable.
6. Sweep the complete same-class and near-class surface before issuing the next authority.
7. Never weaken an independent validator or evidence boundary merely to obtain PASS.

Statuses: `observed-native`, `caught-preflight`, and `workflow`.

## Error classes

| ID | Status | Class | Required prevention |
|---|---|---|---|
| NXB-ERR-001 | observed-native | PowerShell variable-colon interpolation | Delimit `${name}:` or use `-f`; reject ambiguous `$name:` inside double-quoted source. |
| NXB-ERR-002 | observed-native | Global provider enumeration abort | Use bounded partial provider discovery and explicit error accounting; do not let one malformed provider abort the set. |
| NXB-ERR-003 | caught-preflight | Array cardinality / nested enumeration | Preserve intended scalar/array cardinality explicitly and test 0/1/many cases. |
| NXB-ERR-004 | observed-native | Cross-runtime ordering drift | Use ordinal ordering and explicit canonical material; independently recompute fingerprints. |
| NXB-ERR-005 | caught-preflight | Empty catch / analyzer suppression | Record bounded failure state or rethrow; never leave empty catches. |
| NXB-ERR-006 | observed-native | Assignment to automatic `$Matches` | Use semantic variable names; scanner rejects assignment to `$matches`. |
| NXB-ERR-007 | observed-native | `New-*` helper without ShouldProcess | Use an approved non-mutating verb or implement ShouldProcess when mutation is real. |
| NXB-ERR-008 | observed-native | Plural noun helper | Use singular approved nouns and scan the entire active authority surface. |
| NXB-ERR-009 | observed-native | Regression assertion self-match | Avoid raw full-source forbidden-literal assertions that contain their own forbidden fixture; use AST or constructed fixtures. |
| NXB-ERR-010 | observed-native | JSON DateTime timezone round-trip loss | Preserve `DateTimeOffset`/UTC semantics and use invariant round-trip parsing for strings. |
| NXB-ERR-011 | caught-preflight | Existing state fail-open | Existing unreadable authoritative state must fail closed; only absent state may initialize empty. |
| NXB-ERR-012 | observed-native | Same-path publication copy | Normalize source/destination paths before copy and support finalize from existing PASS evidence. |
| NXB-ERR-013 | caught-preflight | Static test-count drift | Lock source test counts before freeze and keep certifier expectations synchronized. |
| NXB-ERR-014 | observed-native | Assigned-but-unused analyzer / Pester cross-scope state | Return context objects and consume values inside each `It`; avoid loose shared path assignments. |
| NXB-ERR-015 | observed-native | Double-quoted expected-source interpolation | Source-code literals containing `$` must be single-quoted, escaped, constructed, or validated through AST. |
| NXB-ERR-016 | workflow | Stale GitHub contents blob SHA | Fetch the current blob or use the latest returned content SHA for sequential updates. |
| NXB-ERR-017 | caught-preflight | Locale-dependent fingerprint material | Keep localized diagnostic text out of canonical fingerprints; use stable counts/codes. |
| NXB-ERR-018 | caught-preflight | PS5.1 parser-risk inline expressions | Precompute nontrivial compatibility values into named variables. |
| NXB-ERR-019 | observed-native | Unqualified engine enum type | Fully qualify non-accelerated PowerShell engine types such as `System.Management.Automation.WildcardOptions`. |
| NXB-ERR-020 | workflow | Opaque scanner failure | Emit finding ID, path, line, and preview before generic scanner assertions. |
| NXB-ERR-021 | observed-native | Assignment to automatic `$PROFILE` | Never assign `$profile`; use a semantic variable such as `$modeProfile`. |
| NXB-ERR-022 | observed-native | Native stderr merge under inherited Stop preference | Scope `Continue` around expected native stderr capture, snapshot/restore preferences, and capture `$LASTEXITCODE` immediately. |
| NXB-ERR-023 | caught-preflight | Generated portable regex quantifier escaping | Avoid nested brace formatting; validate hex by length plus fixed regex and assert the emitted wrapper. |
| NXB-ERR-024 | observed-native | JSON array projected through `PSObject.Properties` | Enumerate `@($policy.claim_targets)` directly and inspect element fields; scanner rejects the incorrect projection. |
| NXB-ERR-025 | observed-native | Shallow native capability preflight | Execute the exact bounded create/present/remove/absent lifecycle before PASS; use CfgMgr32 presence authority and bounded SetupAPI fallback. |
| NXB-ERR-026 | observed-native | BOM-less non-ASCII PowerShell authority/test source | Keep active IRL-006 `.ps1` authority/test source ASCII-only on the GitHub text publication path; generate Unicode fixtures at runtime. |
| NXB-ERR-027 | observed-native | Optional Windows EventLog used as mandatory PnP authority | Use repo-owned EventSource metadata after native lifecycle confirmation; optional diagnostic channels are not claim authority. |
| NXB-ERR-028 | observed-native | Cross-runtime ASCII text-regex false positive | Prove ASCII cleanliness from raw bytes and fail on any byte above `0x7F`; do not use Unicode-range `Should -Not -Match` encoding assertions. |
| NXB-ERR-029 | observed-native | Brittle ledger prose assertion drift | Ledger contracts must bind stable error IDs, machine rules, and behavioral regression fixtures, not exact explanatory sentences that may be edited without changing semantics. |
| NXB-ERR-030 | observed-native | Mandatory collection rejects valid empty evidence set | When zero records are a valid negative-control result, collection parameters must explicitly permit empty input with `AllowEmptyCollection()` and handle zero cardinality without invoking scalar-only logic. Scanner rejects the old mandatory `object[] Record` signature on the active PnP shaper. |
| NXB-ERR-031 | observed-native | Hyper-V VMFirmware Secure Boot readback property-name drift | Treat `Set-VMFirmware -EnableSecureBoot` as the write contract but never assume the returned `VMFirmware` object exposes `.EnableSecureBoot`. Read through a bounded adapter that accepts only a present `SecureBoot` or `EnableSecureBoot` property and normalizes only `On`/`Off` or boolean values. Scanner rejects direct `.EnableSecureBoot` readback from `Get-VMFirmware`. |
| NXB-ERR-032 | observed-native | Nested ordered-dictionary evidence traversal falls through to sentinel defaults | Generic dotted-path readers must traverse `IDictionary` keys before falling back to `PSObject.Properties`. For trace counters, require `status=measured` before consuming numeric values; never reinterpret a missing nested key as `UInt64::MaxValue` loss evidence. Scanner rejects the old PSObject-only walker in the active root/trace authority. |
| NXB-ERR-033 | observed-native | Valid empty transport transcript rejected by mandatory collection binding | A mutable transcript intentionally starts empty before the first authenticated request. Mark that collection with `AllowEmptyCollection()` while keeping non-empty spool-record contracts strict. Scanner rejects the old mandatory `Generic.List[object] Transcript` signature. |
| NXB-ERR-034 | observed-native | WPR stop/merge RPC mode failure under split or unbound WPT lifecycle | Root/trace must bind WPR to the sibling of the selected Xperf executable, require explicit `-instancename` ownership for start/stop/cancel, and place file-mode temporary ETLs under an owned `-recordtempto` root. If WPR stop returns `RPC_E_CHANGED_MODE (0x80010106)`, recovery is allowed only after the owned instance is proven inactive and only by merging the owned raw ETLs with the matched Xperf toolchain; all native loss, continuity, and replay gates remain mandatory. Scanner rejects independent `Get-Command wpr.exe` selection and the old unbound start shape. |
| NXB-ERR-035 | observed-native | Production scanner/config schema drift dereferences a missing required guard field under StrictMode | Production extension config must carry an explicit schema contract for every required guard field. Guard contracts require `id`, repo-relative `path`, and non-empty `required_tokens`; the scanner must use shape-safe property access and emit an `NXB-ERR-035` finding before any missing property is dereferenced. Raw StrictMode `PropertyNotFound` exceptions are never an acceptable scanner result. |

## Current IRL-005 application

IRL-005 must run the exact-tree known-error scanner before its V4/V5 authority chain. A scanner PASS is additive; it never replaces parser, PSScriptAnalyzer, Pester, independent Python replay, evidence-boundary audit, or native validation.

## IRL-006 inheritance

NXB-IRL-006 inherits `NXB-ERR-001` through `NXB-ERR-035`. Active Part 1/2/3/4/5/6/7/8/9/10 authorities must carry the applicable machine signatures forward. `NXB-ERR-023` remains human-ledger-only because it occurs while generating an external portable. ERR-035 is machine-enforced by the production scanner schema contract rather than the inherited base regex set. The ledger contract remains exactly 12 tests per PowerShell runtime.

Native history relevant to the current stack:

- Part 3 Portable V1 exposed ERR-025.
- Part 3 Portable V2 proved ERR-025 and exposed ERR-026.
- Part 3 Portable V3 proved ERR-025/026 and exposed ERR-027.
- Combined Part 2+3+4 Portable V1 exposed ERR-028 in the PS5.1 ASCII assertion.
- Combined Part 2+3+4 Portable V2 proved the 17-rule fast gate and then exposed ERR-029 because the ledger test expected stale prose for ERR-024 even though the rule semantics and machine signature were intact.
- Combined Part 2+3+4+5 Portable V1 proved ERR-029, the 18-rule fast gate, Part 1 and inherited IRL-005 V5, then exposed ERR-030 when the expected empty idle EventSource evidence set was rejected by the mandatory `Record` collection parameter before shaping logic could run.
- Combined Part 2+3+4+5 Portable V2 proved ERR-030, the 19-rule fast gate, PnP/EventSource semantics and PCIe BDF semantics, then exposed ERR-031 when the host `VMFirmware` readback object did not expose the hard-coded `.EnableSecureBoot` property.
- Combined Part 2+3+4+5 Portable V3 proved ERR-031, the 20-rule fast gate, PnP, PCIe and power/firmware semantics, then exposed ERR-032 when root/trace dotted-path traversal treated nested ordered dictionaries as PSObject-only objects and substituted sentinel fallback values for valid trace-statistic keys.
- Combined Part 2+3+4+5 Portable V4 proved ERR-032, the 21-rule fast gate, complete Part 2 semantic hardening `8/8`, deep root/trace replay, then exposed ERR-033 when the deliberately empty initial Part 3 transport transcript was rejected by mandatory collection binding before the first loopback request could be recorded.
- Part 6-10 Production Final Portable V1 proved the exact candidate clone and fast gates (`22` base rules, production extension `9+1`, zero findings), then re-certified Part 1 and inherited IRL-005 V5 and passed Part 2 PnP/PCIe/power/firmware native experiments. It exposed ERR-034 before Part 2 root/trace completed and therefore before Part 6-10 feature authorities executed: on Windows 10.0.19045, `wpr -stop` returned `0x80010106 / RPC_E_CHANGED_MODE`; the subsequent cancellation returned `0xc5583000`, consistent with the WPR session already being stopped without a final ETL.
- Part 6-10 Production Final Portable V2 proved the new exact-head clone and base known-error scan, then exposed ERR-035 in the production extension fast gate before the ERR-034 host/runtime path executed. The sole guard contract omitted its required `path` field while the scanner dereferenced `$guard.path` under StrictMode, producing `PropertyNotFound` instead of a controlled finding.
- Part 6-10 Production Final Portable V3 proved ERR-035 with the malformed-guard negative fixture and canonical production extension scan (`23` base rules, `9` extension rules, `1` schema contract, `1` guard contract, zero findings), and proved the matched WPT host preflight for ERR-034. It then stopped in the inherited Part 5 PS7 source contract at `15/16`: the test still expected literal rule floors of `22` after the V2 authority had correctly advanced to `23`. This is classified under existing ERR-013/ERR-029 contract-drift discipline; no new ERR ID is allocated. The real ERR-034 WPR recovery path was not yet exercised in this run.
- Part 6-10 Production Final Portable V4 proved the dynamic Part 5 rule-floor repair (`16` tests, `23` machine rules, no stale `22`), ERR-035 malformed-guard handling, matched ERR-034 WPT pairing, production extension zero findings, the dual-runtime 20-test Parts 6-10 contract, and Part 5 V2 preflight. It then stopped in the inherited Part 2 PS7 source contract at `11/12`: `SemanticHardening.Tests.ps1` expected the C# parent-device literal with single backslashes while `NxbSemanticPnpFixture.cs` correctly stores the C# source literal as `HTREE\\ROOT\\0`. The historical native-certified Part 5 head already carried the correct doubled-backslash source assertion, so this is classified as existing ERR-029 source-contract drift; no new ERR ID is allocated. ERR-034's real WPR recovery path was still not reached in this run.

When a genuinely new recurring class is discovered, append it here before issuing the next portable authority.
