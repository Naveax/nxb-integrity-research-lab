# NXB Known-Error Ledger

This ledger is a mandatory pre-final checklist for NXB validation authorities.

## Mandatory workflow

Before publishing a new portable validator, declaring a native authority frozen, marking a gate certified, or giving a final completion result:

1. Run `scripts/Invoke-NxbKnownErrorScan.ps1` against the exact candidate tree.
2. The scan must report zero active findings.
3. Run the ledger contract tests on PowerShell 7 and Windows PowerShell 5.1.
4. If review of a native transcript, static scan, analyzer, parser, Pester, Python validator, evidence audit, or GitHub integration step reveals a new recurring error class, add it to this ledger **and** to `config/nxb-known-error-signatures.json` when it is statically detectable.
5. Fix the complete same-class surface before issuing the next authority. Do not fix only the first visible occurrence.
6. Never weaken an independent validator or evidence boundary merely to make a gate pass.

Statuses:

- `observed-native`: appeared in a user/native validation transcript.
- `caught-preflight`: found during self-review before native execution.
- `workflow`: repository/publication/integration failure rather than target runtime behavior.

## Error classes

| ID | Status | Class | Failure mode | Required prevention |
|---|---|---|---|---|
| NXB-ERR-001 | observed-native | PowerShell variable-colon interpolation | A double-quoted string such as `$Repeat: ...` is parsed as a scoped-variable reference and fails parsing. | Delimit as `${Repeat}:` or use `-f`; scan double-quoted source for ambiguous `$name:` forms. |
| NXB-ERR-002 | observed-native | Global provider enumeration abort | `Get-WinEvent -ListProvider * -ErrorAction Stop` lets one malformed provider abort otherwise-readable provider discovery. | Use bounded partial enumeration with `-ErrorAction SilentlyContinue -ErrorVariable`, explicit error accounting, and fail closed only when no readable metadata remains. |
| NXB-ERR-003 | caught-preflight | Array cardinality / `-NoEnumerate` nesting | Returning an array with `Write-Output -NoEnumerate` can create a nested array at a caller using `@(...)`, breaking membership/count logic. | Preserve intended cardinality explicitly; test scalar/1/many cases. |
| NXB-ERR-004 | observed-native | Cross-runtime ordering drift | Culture/default sort differences can change fingerprints between PS7/PS5.1 or PowerShell/Python. | Use ordinal ordering and an explicit canonical material format (`ordinal_tsv_v1` or equivalent); independently recompute fingerprints. |
| NXB-ERR-005 | caught-preflight | Empty catch / analyzer suppression | Empty `catch {}` blocks hide bounded failures and trigger analyzer concerns. | Record bounded status/reason or rethrow; never leave an empty catch in authority code. |
| NXB-ERR-006 | observed-native | Assignment to automatic `$Matches` | `$matches` is case-insensitively the PowerShell automatic `$Matches` variable. | Never assign to `$matches`; use a semantic name such as `$domainMappings`. |
| NXB-ERR-007 | observed-native | `New-*` test helper without ShouldProcess | PSScriptAnalyzer treats custom `New-*` functions as state-changing and requires `ShouldProcess`. | Test helpers that only compute/write bounded fixtures should use an approved non-state-changing verb when appropriate, or implement ShouldProcess when genuinely mutating. |
| NXB-ERR-008 | observed-native | Plural noun in custom function | Names such as `Write-...Signals` / `Get-...Domains` trigger `PSUseSingularNouns`. | Use approved singular nouns and scan all active authority functions, not only the first reported file. |
| NXB-ERR-009 | observed-native | Regression assertion self-match | A test reads its own full source and asserts a forbidden literal is absent, but the assertion string itself contains that literal. | For function-name regressions, inspect AST `FunctionDefinitionAst` nodes instead of raw self-source text. |
| NXB-ERR-010 | observed-native | JSON DateTime timezone round-trip loss | PS7.5+ can materialize ISO JSON values as `DateTime`; casting to culture-formatted string before reparsing can lose Kind/offset and expire hold/cooldown early. | Handle `DateTimeOffset` and `DateTime` directly in UTC; use invariant `RoundtripKind` only for string inputs; test persisted-state round trips. |
| NXB-ERR-011 | caught-preflight | Existing state fail-open | An unreadable existing trigger-state file silently reset to empty state, allowing hold/cooldown authority to be bypassed. | Existing authoritative state must fail closed when unreadable; only a truly absent state starts empty. |
| NXB-ERR-012 | observed-native | Same-path publication copy | Portable wrapper attempted `Copy-Item` from a review ZIP to the identical destination path and failed after the repo-owned gate had passed. | Compare normalized source/destination paths before copying; support resume/finalize from existing exact-head PASS evidence. |
| NXB-ERR-013 | caught-preflight | Static test-count drift | Certification expected 20 tests while a draft contract contained 21. | Count contract tests before freezing authority; certification and test suite counts must be derived/locked consistently. |
| NXB-ERR-014 | caught-preflight | Assigned-but-unused analyzer finding | Pester result objects were assigned but a receipt hardcoded `20/20`, risking `PSUseDeclaredVarsMoreThanAssignments`. | Derive receipt counts from actual result objects; do not hardcode values while leaving assigned results unused. |
| NXB-ERR-015 | observed-native | Double-quoted expected-source interpolation in test | A regex/source assertion such as `[regex]::Escape("... $stateFull ...")` expands the test-scope variable instead of matching literal source text. | Expected source-code literals containing `$` must be single-quoted, escaped, or validated through AST. Scanner rejects double-quoted `regex::Escape` arguments containing `$variable`. |
| NXB-ERR-016 | workflow | Stale GitHub contents blob SHA | Sequential `update_file` with an old blob SHA returns HTTP 409. | Fetch current blob before sequential mutation and use the returned `content_sha` for the next update. Never interpret 409 as content state. |
| NXB-ERR-017 | caught-preflight | Locale-dependent diagnostic material in fingerprint | Raw provider/error text can vary by OS locale and destabilize evidence fingerprints. | Keep localized error text out of canonical material; include bounded counts/status codes instead. |
| NXB-ERR-018 | caught-preflight | Inline parser-risk expressions in compatibility authority | Dense inline expressions in hashtable/string contexts can create PS5.1 parser/analyzer risk. | Precompute nontrivial values into named variables when cross-runtime compatibility is required. |
| NXB-ERR-019 | observed-native | Unqualified PowerShell engine enum type | The scanner used `[WildcardOptions]::IgnoreCase`; `WildcardOptions` is not a PowerShell type accelerator, so runtime resolution failed with `Unable to find type [WildcardOptions]`. | Fully qualify non-accelerated engine types. This surface must use `System.Management.Automation.WildcardPattern` and `System.Management.Automation.WildcardOptions`; scan the scanner for the bare `[WildcardOptions]::` form. |

## Current IRL-005 application

The IRL-005 adaptive observability branch must run the known-error scanner before its V4 child certification. A scanner PASS does not replace parser, PSScriptAnalyzer, Pester, Python replay, evidence-boundary audit, or native validation; it is an additional mandatory gate.

When a new error class is discovered, append it here before issuing the next portable authority.
