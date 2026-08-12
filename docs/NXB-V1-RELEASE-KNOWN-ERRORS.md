# NXB v1 Release-Layer Known Errors

This ledger applies only to post-certification NXB v1 successor layers. It does not mutate the native-certified Parts 1-10 known-error authority.

## NXB-ERR-036 — bare typed member expression in command argument mode

**Class:** PowerShell command argument parsing / release review packaging.

**Native discovery:** Release Integration Portable V1 at exact head `b735fca79c32de9a1044255040abe75002194c80`.

The run passed exact-head clone, external release-boundary gates, parser/analyzer/scanner gates, PS7 + Windows PowerShell 5.1 release contracts, fail-closed preflight, and independent Python `10/10 + 6/6` replay. It failed only while copying the five JSON review members.

The failing form was conceptually:

```powershell
Join-Path $reviewRoot [string]$entry.Key
```

In command argument mode the bare cast/member expression was not treated as the intended expression, producing a malformed path containing the cast/enumerator representation.

### Repair contract

- Convert enumerator key/value into explicit local scalar variables before command invocation.
- Pass the already-normalized scalar name to `Join-Path`.
- Keep the five-member JSON-only review closure unchanged.
- Add a release-layer machine signature that rejects the recurring `Join-Path <root> [type]$object.Member` shape.
- Keep the existing 16-test release integration contract count unchanged while adding ERR-036 regression coverage.

### Safety boundary

This failure occurred after all security/integration validation gates. No merge, tag, push, `main` update, production signer claim, or certified runtime mutation occurred.

## Production Signing Portable V1 — existing ERR-007 and ERR-014 reused

**Native discovery:** Production Signing Portable V1 at exact head `d1469719e2cc399fa1ac02ff4984534c4d2cb784` on Windows 10.0.19045 / PowerShell 7.6.3.

The run passed exact-head clone and the external signing fast gates (`18` source tests, ERR-036, private-key boundary, Python syntax). It stopped in the first repo-owned production-signing authority stage because PSScriptAnalyzer reported exactly four findings:

- `PSUseDeclaredVarsMoreThanAssignments` for `$ps7Contract`.
- `PSUseDeclaredVarsMoreThanAssignments` for `$ps51Contract`.
- `PSUseShouldProcessForStateChangingFunctions` for `New-NxbV1CertificationSigner`.
- `PSUseShouldProcessForStateChangingFunctions` for `New-NxbV1SignedReleaseEnvelope`.

No new error ID is allocated. The two classes are already defined by the native-certified base ledger:

- **NXB-ERR-007:** `New-*` helper without ShouldProcess. For these in-memory construction helpers the repair is to use approved non-mutating verbs instead of pretending that an external system mutation occurs.
- **NXB-ERR-014:** assigned-but-unused analyzer state. The dual-runtime Pester result objects must be consumed in the receipt/result rather than replaced by hard-coded `18/18` strings.

### Signing successor repair contract

- `Get-NxbV1CertificationSigner` replaces the old `New-*` signer helper.
- `ConvertTo-NxbV1SignedReleaseEnvelope` replaces the old `New-*` envelope helper.
- PS7 and PS5.1 summaries are calculated from the actual Pester result objects and bound into certification evidence.
- A signing-successor machine signature set carries ERR-007 and ERR-014 without changing the certified release-integration ERR-036 rule count.
- The production-signing Pester contract remains exactly 18 tests.
- The review closure includes a dedicated `signing-known-error-scan.json` receipt.

The V1 failure occurred before dual-runtime signing tests, real-file fixture signing, RSA replay, adversarial controls, or review packaging executed. Therefore none of those later production-signing layers are considered native-certified by this run.

## NXB-ERR-037 — assignment to readonly PowerShell platform automatic variable

**Class:** PSScriptAnalyzer / PowerShell 6+ readonly automatic platform state.

**Native discovery:** Installer Portable V1 at exact head `24e445f4bcdbdccd8a92c23605913d5c6aa93a67` on Windows 10.0.19045 / PowerShell 7.6.3.

The run passed exact-head clone and all external installer fast gates (`22` source tests, four installer successor rules, ERR-004/007/018/036, path-boundary checks, sentinel binding, and Python syntax). It stopped in the first repo-owned installer authority stage because PSScriptAnalyzer reported exactly one finding in `Test-NxbV1InstallerHost.ps1`: assignment to `$isWindows`, which resolves case-insensitively to the readonly `$IsWindows` automatic variable in PowerShell 6 and newer.

### Repair contract

- Use a semantic local such as `$windowsHost`; never assign `$IsWindows`, `$IsLinux`, `$IsMacOS`, or `$IsCoreCLR`.
- Carry an installer-successor machine signature that rejects assignments to those readonly platform automatic variables across the active installer PowerShell surface.
- Extend the existing release ERR-036 scanner across installer files instead of duplicating ERR-036 inside the installer-successor rule set.
- Keep the installer-successor scanner at four rules: ERR-004, ERR-007, ERR-018, and ERR-037.
- Keep the installer Pester contract exactly 22 tests while adding ERR-037 behavioral/source regression coverage.
- In the same repair sweep, precompute the host receipt status string before object construction so the host surface also remains inside existing ERR-018 PS5.1 compatibility discipline.

### Native scope of the failed run

Installer Portable V1 failed before dual-runtime installer Pester execution, host lifecycle execution, package manifest generation, Stage/Install/Corrupt/Repair/Uninstall, independent Python replay, or review ZIP packaging. None of those later installer layers are considered native-certified by this V1 run.

## Signed staged update pre-native sweep — existing ERR-014 and ERR-029 reused

Before publishing Update Portable V1, the successor source sweep found two existing classes:

- **NXB-ERR-014:** the certification fixture assigned `$nativeRelative` inside the signed-artifact loop without consuming it. The repair uses that native relative path to resolve the real package artifact and recompute its byte count and SHA-256 before adding it to the signed envelope, eliminating the analyzer warning while strengthening byte authority.
- **NXB-ERR-029:** the 24-test source contract still expected stale prose (`An update is already staged.`), while the implementation intentionally rejects equal/older staged sequences and permits explicit supersession by a newer signed sequence. The test is rebound to those stable behaviors instead of weakening the implementation.

The cleanup `finally` around the certification signer was also reviewed. It is entered only after the signer assignment succeeds, so no new cleanup/StrictMode error class is allocated. No Update Portable V1 had been issued at the time of this sweep.

## NXB-ERR-038 — non-atomic authoritative update JSON publication

**Class:** caught-preflight / persistent update-state durability.

**Pre-native discovery:** signed staged update successor review before Update Portable V1.

`Write-NxbV1UpdateJson` originally wrote stage state, update state, and operation receipts directly to the authoritative destination with `File.WriteAllText`. During an Apply state-publication failure, the install tree could be restored while an existing `update-state.json` had already been truncated or partially replaced, weakening the rollback authority for later runs.

### Repair contract

- Serialize authoritative JSON to a unique sibling temporary file in the same directory.
- Open the temporary file exclusively, write all bytes, and flush them before publication.
- If the destination already exists, replace it atomically with `File.Replace`; otherwise publish with same-directory `File.Move`.
- Always remove an orphaned temporary file in cleanup.
- Carry an update-successor machine signature that rejects the old direct `File.WriteAllText($full, ...)` publication shape.
- Keep the existing 24-test update contract count unchanged while binding the atomic publication tokens into the persistent-state contract.

This class was caught before any native Update Portable V1 was issued. Update successor known-error rule count advanced from four to five at this step.

## NXB-ERR-039 — rollback lowers the anti-replay sequence floor

**Class:** caught-preflight / signed update replay prevention across manual rollback.

**Pre-native discovery:** final signed staged update behavior audit before Update Portable V1.

The initial update-state design used only `current_release_sequence` as the replay floor. A successful Apply moved the fixture from sequence `0` to sequence `1`; a manual Rollback restored the old release and wrote `current_release_sequence=0`. Because later Stage/Apply validation compared a signed descriptor only against that current sequence, the already-seen sequence `1` bundle could become admissible again after rollback even though `allow_sequence_replay=false`.

### Repair contract

- Persist a monotonic `highest_seen_release_sequence` in authoritative update state.
- Require `highest_seen_release_sequence >= current_release_sequence` whenever state is read.
- Use `highest_seen_release_sequence`, not the currently installed rollback sequence, as the admission floor for future signed updates.
- Successful Apply advances the highest-seen floor to the target sequence.
- Manual Rollback may lower `current_release_sequence` to the restored release but must preserve the previous highest-seen floor.
- Native certification must prove `current=0`, `highest_seen=1`, `rollback_available=false` after rollback and must reject replay of the already-seen signed sequence `1` bundle.
- Independent Python replay must consume the final `update-state.json` and enforce the same persisted floor.
- Carry an update-successor machine signature that rejects the old getter shape returning `current_release_sequence` as the anti-replay admission floor.
- Keep the update Pester contract exactly 24 tests; update successor machine-rule count advances from five to six.

This class was caught before any native Update Portable V1 was issued.

## Signed staged update Portable V2 — existing ERR-029 reused for test-cardinality drift

**Native/preflight discovery:** Update Portable V2 at exact head `58cc857e2a4ee99a09610ccd646f992c767352dd`.

The run passed exact-head clone and the repaired shape-safe update-policy boundary, then stopped in the external source-contract gate with `expected=24 actual=25`. The repo-owned authority had not yet started.

The 25th `It` block did not represent a missing security behavior. The Apply contract already asserted `Invoke-NxbV1UpdateAtomicSwap`, while a separate standalone `uses a rollback-on-failed-validation atomic swap helper` test repeated the same helper surface. This drift contradicted the certification schema and authority, both of which intentionally bind the dual-runtime contract to `24/24`.

No new error ID is allocated. This is another **NXB-ERR-029** source/contract drift instance.

### Repair contract

- Preserve every atomic-swap/failure-rollback source assertion.
- Merge the standalone helper assertions into the existing Apply/candidate/rollback test.
- Remove only the redundant `It` wrapper, not its assertions.
- Restore the Pester contract to exactly 24 tests.
- Keep certification schema `ps7=24/24`, PS5.1 target `24/24`, update successor rule count `6`, independent Python `16/16 + 12/12`, and 28-entry review closure unchanged.

The failed V2 run did not execute the repo-owned update certification authority, Stage, Apply, rollback, Python replay, or review packaging, so none of those layers are certified by that run.

## Signed staged update Portable V3 — existing ERR-014 reused for analyzer-unused declarations

**Native discovery:** Update Portable V3 at exact head `08e4aa48bb4c6f3645373a357b5c99c32130cff3` on PowerShell 7.6.4.

The run passed exact-head clone and the complete external source/policy/error-ledger contract gate up to PSScriptAnalyzer, then stopped with exactly two findings:

- `PSUseDeclaredVarsMoreThanAssignments` for `$updateRepositoryRoot` in `NxbV1Update.Common.ps1`.
- `PSReviewUnusedParameter` for callback parameter `$root` in the forced failed-publish validation scriptblock inside `Invoke-NxbV1UpdateCertification.ps1`.

No new error ID is allocated. Both are the same update-successor application of **NXB-ERR-014**: authority declarations must be consumed by evidence or runtime behavior rather than left as dead analyzer state.

### Repair contract

- Remove `$updateRepositoryRoot`; sibling authority files already resolve from `$PSScriptRoot` and the variable has no semantic role.
- Keep the failed-publish validation callback parameter, rename it to a semantic `$publishedRoot`, and actually validate that the published root exists before intentionally returning `false` to exercise rollback.
- Do not suppress `PSUseDeclaredVarsMoreThanAssignments` or `PSReviewUnusedParameter`.
- Keep update successor machine-rule count at `6`; PSScriptAnalyzer remains the general guard for unused declarations.
- Keep the dual-runtime Pester contract at exactly `24` tests, independent Python at `16/16 + 12/12`, and the review ZIP at exactly `28` entries.

The V3 run stopped before the repo-owned dual-runtime Pester contract, Stage, Apply, failure rollback, manual rollback, Python replay, or review packaging. None of those later update layers are certified by this run.

## NXB-ERR-040 — valid empty scalar rejected by mandatory string binder

**Class:** observed-native / PowerShell mandatory scalar binding at signing-fixture construction.

**Native discovery:** Update Portable V4 at exact head `89ed9c1ee46d7f6e84154e917733f09a0c46ca74` on PowerShell 7.6.4.

The run passed exact-head clone, all external parser/analyzer/policy/error-ledger/source-contract gates, the repo-owned parser/analyzer/schema/known-error gate, and the dual-runtime `24/24` update contract. It entered the real fixture stage, exported both two-file manifests, installed the bounded PerUser initial fixture, then failed while building the signing fixture with:

```text
Cannot bind argument to parameter 'Text' because it is an empty string.
```

The failing call intentionally attempted to hash empty release-notes content through `Get-NxbV1SigningSha256Text -Text ''`. The inherited production-signing helper declares `Text` as a mandatory string and therefore PowerShell rejects the empty scalar before the helper body executes.

### Repair contract

- Do not mutate the native-certified production-signing predecessor helper merely to satisfy the update fixture.
- Materialize the intentional empty release notes as a real zero-byte `release-notes.md` fixture file.
- Compute `release_notes_sha256` from those actual file bytes through the update file-hash authority.
- Carry an update-successor machine signature that rejects the old empty-string call shape.
- Keep the update Pester contract exactly `24` tests while binding the real zero-byte release-notes fixture/hash behavior into an existing signing-fixture test.
- Advance update successor machine-rule count from `6` to `7` and bind the certification receipt schema to that exact count.
- Preserve independent Python `16/16 + 12/12`, 28-entry review closure, and all Stage/Apply/Rollback safety boundaries.

### Native scope of the failed run

V4 stopped during fixture construction before signed trust-anchor validation, Stage, Apply, forced failure rollback, manual rollback, independent Python replay, or review packaging. None of those later update layers are certified by the V4 run.

## NXB-ERR-041 — persisted signed timestamp coerced out of canonical string form

**Class:** observed-native / JSON round-trip canonical-signature drift.

**Native discovery:** Update Portable V5 at exact head `48b54b6df5a4e2ea9e182c5121b14fbe6e03405e` on PowerShell 7.6.4.

The run passed exact-head clone, all external fast gates, the repo-owned parser/analyzer/schema/known-error gate, the dual-runtime `24/24` contract, real bounded fixture construction, in-memory signed trust-anchor validation, and all trust/revocation/sequence/tamper negative controls. It failed only when the real Stage operator reloaded the persisted signed envelope from JSON and revalidated the same bundle.

PowerShell 7.6 `ConvertFrom-Json` defaults timestamp-shaped JSON strings to DateTime objects. The release-signature canonical material signs `created_utc` as a string. Therefore the in-memory envelope verified, while the persisted/reloaded envelope could present `created_utc` as DateTime and reconstruct different canonical material before RSA verification.

### Repair contract

- Keep the native-certified production-signing predecessor unchanged.
- Normalize a persisted envelope `created_utc` value back to invariant UTC round-trip (`o`) string form only when JSON parsing has materialized it as `[datetime]`.
- Centralize this behavior inside update bundle verification so Stage, Apply, and future update callers share one canonicalization boundary.
- Verify RSA against the normalized `$verificationEnvelope`, not directly against the possibly coerced `$Envelope` object.
- Keep update successor machine-rule count at `7`; ERR-041 is tracked in this release-layer ledger and regression-locked inside the existing `24`-test update contract instead of perturbing scanner cardinality again.
- Preserve independent Python `16/16 + 12/12`, exact 28-entry review closure, anti-replay floor, rollback, and no-auto-apply boundaries.

### Native scope of the failed run

V5 reached the real Stage action but failed before Stage publication completed. Apply, automatic failed-publish rollback, manual Rollback, independent Python replay, and review packaging were not certified by V5.
