# NXB-IRL-002 Validation Record

## Scope

This record closes the deterministic experiment lifecycle block.

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
- [x] PowerShell 5.1 and PowerShell 7 workflow jobs.
- [x] Manual `workflow_dispatch` trigger.
- [x] UTF-8 BOM enforcement for non-ASCII PowerShell sources.

## Repository Actions configuration

Repository owner confirmed on 2026-08-04 that:

- Actions are enabled,
- all actions and reusable workflows are allowed,
- full-length SHA pinning is not required,
- the default workflow token is read-only for repository contents and packages,
- GitHub Actions cannot create or approve pull requests.

## Failure analysis and repair history

### Validate run #84

Run ID: `30921066820`

Initial results:

- `Static analysis and smoke validation`: failed before repository smoke validation.
- `Lifecycle - PowerShell 7`: 12 passed, 14 failed.
- `Lifecycle - Windows PowerShell 5.1`: 12 passed, 14 failed.
- Public repository content guard passed with 44 candidate files.
- Reparse-point/junction adversarial tests passed.

Confirmed root causes:

1. `Invoke-ScriptAnalyzer -Path` received an object array although the parameter accepts one string path per invocation.
2. `Test-EvidenceIntegrity.ps1` used ambiguous `$lineNumber:` interpolation.
3. The synthetic WPR fixture was unavailable during Pester 5 run-phase execution.
4. `jsonschema` was installed only in the static-analysis job.

Repairs:

- analyzer invocation split per source root,
- evidence interpolation and issue collection repaired,
- evidence paths rooted at the experiment directory,
- synthetic WPR fixture moved into `BeforeAll`,
- Python 3.13 and `jsonschema` installed in both lifecycle jobs.

Repair commits:

- `932b56cf903276e60ae798ec66b59d95aa417cf9`
- `ab3dfb653a82bd4c619ab362d7ef8474c012b104`
- `6a970b09dfdc56527269ea31ec54767439ed22e6`

### Encoding closeout

PSScriptAnalyzer then reported `PSUseBOMForUnicodeEncodedFile` for non-ASCII PowerShell sources. A bounded one-time workflow normalized only `.ps1` and `.psm1` files under `scripts/` and `tests/`, verified the UTF-8 BOM bytes, committed the result, and was removed from `main` after use.

Normalization commit:

- `878710229ad11c5c1b95247e304986ca4e5eda47`

This also eliminated the Windows PowerShell 5.1 mojibake that caused two message-matching tests to fail.

## Final execution gates

- [x] GitHub Actions run visible.
- [x] PowerShell parser clean for all scripts and tests.
- [x] PSScriptAnalyzer clean at Error and Warning severity.
- [x] Repository smoke validation succeeds.
- [x] PowerShell 7 Pester suite succeeds.
- [x] Windows PowerShell 5.1 Pester suite succeeds.
- [x] Failure logs inspected and repaired.
- [x] Final three-job run confirmed green by repository owner.

The GitHub connector did not expose the final manual `workflow_dispatch` run as a commit status. The final green state is therefore recorded from the repository owner's direct Actions view, while the implementation head and all preceding failure logs were independently inspected through repository data.

## Validated lifecycle assertions

The final Windows validation demonstrates that:

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

## Merge record

- Pull request: `#3 — NXB-IRL-002: close deterministic lifecycle validation gaps`
- Validated head: `878710229ad11c5c1b95247e304986ca4e5eda47`
- Squash merge commit: `e3b3ab79ab72cafa92f2afa97895258cec912d86`

## Current result

Status: `COMPLETE`

NXB-IRL-002 is closed. The next required block is `NXB-IRL-003 — Evidence integrity store`.
