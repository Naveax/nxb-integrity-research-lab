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

## NXB-ERR-038 — late-bound cleanup variable can mask an earlier authority failure under StrictMode

**Class:** caught-preflight / PowerShell cleanup and failure-preservation discipline.

**Pre-native discovery:** signed staged update successor source review before publishing Update Portable V1. The update certification authority referenced `$signer` from its final cleanup block, but the first assignment to `$signer` occurred only after parser, analyzer, scanner, Pester, fixture-install, and manifest steps. With `Set-StrictMode -Version Latest`, any earlier exception could reach cleanup before that variable existed and replace the original failure with an uninitialized-variable error.

### Repair contract

- Initialize disposable cleanup-owned variables, including `$signer`, to `$null` before the main authority `try` begins.
- Assign the live disposable only later when its creation step is reached.
- Cleanup must remain null-safe and dispose only an actually-created signer.
- Keep the update Pester contract exactly 24 tests and enforce initialization-before-main-try with a source-order regression assertion rather than a brittle prose assertion.
- This class is context-sensitive and is therefore enforced by the update source contract rather than added as a line-regex successor signature. Update successor signature count remains four.

### Same sweep

The same pre-native update sweep also found two existing classes and repaired them without allocating new IDs:

- **NXB-ERR-014:** an unused `$nativeRelative` assignment in the signing-artifact fixture loop is removed before PSScriptAnalyzer can reject the authority.
- **NXB-ERR-029:** the update Pester contract expected stale prose (`An update is already staged.`) even though the implementation intentionally supports rejecting equal/older staged sequences and explicitly superseding an older stage with a newer signed sequence. The regression is rebound to those stable behaviors instead of restoring obsolete runtime behavior.

No Update Portable V1 had been issued when these defects were found, so no native update claim is affected.