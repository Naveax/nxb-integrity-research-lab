# NXB-IRL-002 Validation Record

## Scope

This record tracks the closeout validation for the deterministic experiment lifecycle block.

## Implemented validation coverage

- [x] WPR executable-unavailable test.
- [x] Existing-session cancellation failure test.
- [x] WPR start nonzero-exit test.
- [x] WPR stop nonzero-exit test.
- [x] Successful stop without ETL fail-closed test.
- [x] Synthetic successful WPR lifecycle test.
- [x] Untracked synthetic blocked-artifact test.
- [x] Reparse-point/junction adversarial test.
- [x] Canonical evidence ordering test.
- [x] Finalization idempotency test.
- [x] One-byte evidence modification test.
- [x] Interrupted recording recovery test.
- [x] Manifest Draft 2020-12 validation.
- [x] PowerShell 5.1 and PowerShell 7 workflow matrix.
- [x] Manual `workflow_dispatch` trigger definition.

## Repository Actions configuration

Repository owner confirmed on 2026-08-04 that:

- Actions are enabled,
- all actions and reusable workflows are allowed,
- full-length SHA pinning is not required,
- the default workflow token is read-only for repository contents and packages,
- GitHub Actions cannot create or approve pull requests.

## Validate run #84

Run ID: `30921066820`

Observed results:

- `Static analysis and smoke validation`: failed before repository smoke validation.
- `Lifecycle - PowerShell 7`: 12 passed, 14 failed.
- `Lifecycle - Windows PowerShell 5.1`: 12 passed, 14 failed.
- Public repository content guard passed with 44 candidate files.
- Reparse-point/junction adversarial tests passed.

Root causes confirmed from job logs:

1. `Invoke-ScriptAnalyzer -Path` was passed an object array although that parameter accepts one string path per invocation.
2. `Test-EvidenceIntegrity.ps1` used an ambiguous interpolation form: `$lineNumber:`.
3. `New-NxbFakeWprCommand` was declared outside Pester 5 run-phase setup and was unavailable to the tests.
4. The `jsonschema` Python package was installed only in the static-analysis job, not in either lifecycle job.

Repairs applied on `nxb-irl-002-closeout`:

- static analyzer now invokes `Invoke-ScriptAnalyzer` once per source root,
- evidence line interpolation now uses `${lineNumber}:`,
- evidence issue collection no longer leaks `List.Add()` indices,
- evidence path validation is rooted at the experiment directory,
- the synthetic WPR fixture is defined inside `BeforeAll`,
- Python 3.13 and `jsonschema` are installed in both lifecycle jobs.

Repair commits:

- `932b56cf903276e60ae798ec66b59d95aa417cf9`
- `ab3dfb653a82bd4c619ab362d7ef8474c012b104`
- `6a970b09dfdc56527269ea31ec54767439ed22e6`

## Required execution gates

- [x] GitHub Actions run is visible.
- [ ] PowerShell parser is clean for all scripts and tests.
- [ ] PSScriptAnalyzer is clean at Error and Warning severity.
- [ ] Repository smoke validation succeeds.
- [ ] PowerShell 7 Pester suite succeeds.
- [ ] Windows PowerShell 5.1 Pester suite succeeds.
- [x] Failed run #84 job logs were inspected.
- [ ] Repaired workflow is re-run and every new job log is inspected.

## Expected lifecycle assertions

The Windows test run must demonstrate that:

- missing WPR leaves the experiment `prepared`,
- failed existing-session cancellation starts no new trace,
- failed WPR start leaves the experiment `prepared`,
- failed WPR stop preserves `recording` for recovery,
- successful stop without ETL marks manifest and session `failed`,
- successful synthetic capture reaches `stopped`,
- untracked blocked artifacts are rejected,
- reparse points are rejected before traversal descends,
- second finalization changes no bytes,
- a one-byte evidence change is detected.

## Pull request

Draft PR `#3` contains the closeout implementation. It must remain draft until every required execution gate is backed by inspected Windows Actions results.

## Current result

Status: `REPAIRED — PENDING RE-RUN`

Do not mark NXB-IRL-002 complete, merge PR #3, or close issue #1 until the repaired workflow passes and every job log is inspected.
