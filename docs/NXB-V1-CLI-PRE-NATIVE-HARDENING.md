# NXB v1 CLI pre-native hardening

Phase 6 successor branch: `release/nxb-v1.0.0-cli`

Certified predecessor:

```text
certified/nxb-v1-update
27507531154099ab28a05cfe8e4e900d72f22e7b
```

No CLI Portable native authority had been issued when the findings below were discovered. No new error IDs are allocated; existing classes are reused.

## ERR-009 — scanner self-match avoided

The initial CLI successor ERR-004 rule included `tests/V1Cli.Tests.ps1`. That test intentionally contains the forbidden `Sort-Object ... path` regex literal in a `Should -Not -Match` assertion. Scanning that test with the same forbidden-literal regex can make the scanner match its own regression guard rather than an implementation defect.

Repair:

- retain ERR-004 scanning over active CLI implementation/certification PowerShell;
- remove the CLI test file from the ERR-004 machine-signature include list;
- keep the Pester source assertion that rejects culture-dependent path ordering in `scripts/nxb.ps1`;
- CLI successor rule count remains four.

## ERR-014 — unused authority declarations identified before native publication

Static review identified declarations that would otherwise be candidates for PSScriptAnalyzer unused-state findings:

- the top-level CLI `NonInteractive` switch must affect explicit CLI behavior rather than remain decorative;
- PS7/PS5.1 Pester summaries and native config-validation result objects in the certification authority must be consumed by closure assertions rather than assigned and ignored.

Repair contract:

- consume `NonInteractive` in the CLI process behavior/output contract;
- validate both Pester summaries as exactly `24/24`;
- validate both PS7 and PS5.1 config command results before certification continues;
- do not suppress analyzer rules.

## ERR-029 — source-test token drift identified before native publication

The initial CLI Pester contract searched for `$parameters['Confirm']`, while the implementation expressed the same updater delegation with `Confirm=$false` in the splatted hashtable. The test must bind to the actual stable no-prompt behavior instead of an incidental syntax form.

Repair contract:

- assert explicit `Confirm=$false` delegation or an equivalent stable semantic token;
- keep exact Pester cardinality at 24;
- do not weaken the explicit `ConfirmMutation`/`DryRun` operator boundary.

## Native boundary

These findings are pre-native only. They do not certify the CLI. The CLI remains uncertified until the exact successor head passes parser/analyzer/scanner gates, PS7 and Windows PowerShell 5.1 `24/24`, independent validation, native JSON/exit-code checks, bounded dry-run checks, exact review closure, and an external Portable audit.
