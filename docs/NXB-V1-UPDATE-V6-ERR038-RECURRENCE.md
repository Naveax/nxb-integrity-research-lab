# NXB v1 Update Portable V6 — ERR-038 native recurrence

**Native discovery:** Update Portable V6 at exact head `282dcc94145911b9fa6b844b841fea3e2aa07e68` on PowerShell 7.6.4.

The run passed exact-head clone, external parser/analyzer/policy/error-ledger/source-contract gates, repo-owned parser/analyzer/schema/known-error gates, the dual-runtime `24/24` update contract, fixture construction, trust/revocation/sequence/tamper negatives, signed Stage, and signed Apply. Stage and Apply both succeeded and a rollback snapshot was created.

The run then entered the automatic-failure/manual-rollback phase and failed while replacing the already-existing authoritative `update-state.json` during manual Rollback:

```text
Exception calling "Replace" with "3" argument(s): "The path is empty. (Parameter 'path')"
```

The failing state writer called:

```powershell
[IO.File]::Replace($tempPath,$full,$null)
```

Although the .NET API accepts a null backup filename, the native PowerShell static-method invocation bound the third argument in a way that produced an empty-path runtime failure. This is not a new class. It is a native recurrence of **NXB-ERR-038**, whose contract is durable atomic authoritative update-state publication.

## Repair contract

- Keep the same-directory write-through temporary-file publication model.
- When the authoritative destination already exists, provide `File.Replace` a real unique sibling backup path rather than PowerShell `$null`.
- Always clean the temporary and backup paths best-effort after publication without turning post-commit cleanup into a false state-publication failure.
- Extend the existing ERR-038 machine signature so the old direct authoritative overwrite and the native `$null`-backup `File.Replace` call shape are both rejected.
- Keep update successor rule count at `7` and the dual-runtime Pester contract at exactly `24` tests.
- Require the Pester contract to contain the real sibling backup path and forbid `File.Replace($tempPath,$full,$null)`.
- Preserve ERR-039 anti-replay floor behavior, ERR-041 persisted timestamp normalization, independent Python `16/16 + 12/12`, and the exact 28-entry review closure.

## Native scope of the failed run

V6 proved signed Stage and signed Apply on Windows and reached the rollback phase. It did **not** complete manual Rollback, final persisted anti-replay replay rejection, independent Python replay, certification receipt generation, or the 28-entry review ZIP. Those later layers remain uncertified by V6.
