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