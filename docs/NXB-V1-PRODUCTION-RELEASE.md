# NXB v1.0.1 Production Release Authority

## Purpose

`Invoke-NxbV1ProductionRelease.ps1` is the fail-closed operator authority that turns one exact, native-certified v1.0.1 successor tree into the immutable public `v1.0.1` release.

It is governed by:

```text
config/nxb-v1-production-release-policy.json
```

Canonical successor tracking: Issue #42.

## Two-SHA release model

The release has two distinct commit identities and they MUST NOT be conflated.

`CertifiedHead` is the final PR head that passed the exact-head hosted and self-hosted Windows native WPT workflow.

`ExpectedHead` is the merge commit on `main` after that certified PR is merged by merge commit.

The production authority requires:

1. `ExpectedHead` is the local and remote `main` head.
2. `release/nxb-v1.0.1-prep` also points to `ExpectedHead`.
3. `ExpectedHead` is a merge commit.
4. `CertifiedHead` is a direct parent of `ExpectedHead`.
5. the Git tree of `ExpectedHead` is byte-identical to the Git tree of `CertifiedHead`.
6. frozen v1.0.0 head `a4f1b242c003333b1f34b1cd54ca37cab33fbf4f` remains an ancestor.

This permits the merge commit to record integration without pretending that the merge SHA itself was the native-certified PR SHA.

## Frozen predecessor

The v1.0.0 production authority is immutable:

```text
head        a4f1b242c003333b1f34b1cd54ca37cab33fbf4f
tree        34779176d9e15cd4d700d46132785c0b25f19604
tag         v1.0.0
release id  370629171
package     c489ba417f1284bfcad4d0666e61fde93ab4ed8fab7fa4e8c0ef1df5c7e9ce78
closure     b3914161cb851a600c2d79a6f1fb877766aa8af453d2a19e03a43884758f1355
signer      1d72e76225854e09af2552639436a508f050042e5e1c635bd7e11cc3feae4373
```

The production authority snapshots the v1.0.0 GitHub Release and its canonical package/final-closure digests before successor publication, repeats that check before tagging, and repeats it after v1.0.1 publication.

The historical Phase-7 pointer remains:

```text
9e7e47561914f5ecbb59d1958aef695ca03a1f30
```

It is never advanced by the v1.0.1 release.

## Required native CI authority

The operator receives one `NativeRunId` and requires the run to be:

- workflow `NXB v1 CI`;
- event `workflow_dispatch`;
- exact `head_sha == CertifiedHead`;
- final conclusion `success`;
- all four jobs successful:
  - `nxb-v1 / signed-release-verify`
  - `nxb-v1 / hosted-contract`
  - `nxb-v1 / native-wpt`
  - `nxb-v1 / release-candidate`.

The native job must expose exactly the NXB runner labels:

```text
self-hosted
Windows
X64
nxb-native
wpt
```

The hosted and native artifact ZIPs are downloaded from GitHub, hashed locally, and compared to GitHub's recorded SHA-256 artifact digests. Their receipts, native calibration binding, replayed hosted receipt, and seven-entry native review ZIP are independently audited before packaging begins.

## Package authority

The runtime package is a bounded recursive literal-dependency closure starting from the public runtime seeds:

```text
scripts/nxb.ps1
scripts/Invoke-NxbV1Installer.ps1
scripts/Invoke-NxbV1Updater.ps1
scripts/Export-NxbV1PackageManifest.ps1
scripts/Invoke-NxbV1ReleaseManifestSigning.ps1
```

The generated `package-manifest.json` must bind:

```text
release_version = 1.0.1
source_head     = ExpectedHead
```

Package files are signed as `package/<relative-path>` artifacts and must match the manifest byte counts and SHA-256 values exactly.

The package ZIP is deterministic: ordinal entry order and a fixed ZIP timestamp are used.

## Production signer boundary

The only permitted production mode is the protected Windows Certificate Store signer.

The authority scans `CurrentUser\My` and `LocalMachine\My` for time-valid RSA private keys of at least 3072 bits whose provider protection contract passes. It then filters those candidates to the exact frozen production public fingerprint:

```text
1d72e76225854e09af2552639436a508f050042e5e1c635bd7e11cc3feae4373
```

Exactly one candidate must remain. A different otherwise-valid certificate is not treated as an implicit signer rotation.

No production private key is generated, exported, uploaded, serialized, or committed.

## Independent signing verification

The production envelope is checked twice:

1. the PowerShell signing authority performs its own signature and file-binding checks;
2. `tools/validate_v1_production_signing.py` independently reconstructs the canonical material and verifies RSA PKCS#1 v1.5 SHA-256 using public modulus/exponent arithmetic in `production-windows-certificate-store` mode.

The independent verifier must bind the expected production public fingerprint and close 12 requirements plus 8 adversarial controls.

## Update release sequence

v1.0.0 is sequence `1`.

v1.0.1 uses:

```text
channel          stable
release_sequence 2
```

The release performs a production-signed `Stage` smoke only. It requires:

```text
auto_apply=false
production_release_updated=false
```

No update Apply occurs during release preparation.

## 18-step production closure

The operator executes these boundaries in order:

1. integrated-head, merge-tree and remote CAS gate;
2. frozen predecessor GitHub Release snapshot;
3. exact-head workflow-dispatch CI/job closure;
4. hosted/native artifact download and independent audit;
5. integrated-head successor and release-integration authorities;
6. signing, installer and update certification authorities;
7. bounded runtime package and v1.0.1 manifest;
8. CLI and portable installer smoke;
9. release notes, update metadata, operational policies and deterministic ZIP;
10. protected production signer/fingerprint gate;
11. production signature and independent production-mode verification;
12. Stage-only production-signed updater smoke;
13. production readiness and public evidence bundle;
14. final pre-tag CAS and frozen-predecessor immutability gate;
15. immutable annotated `v1.0.1` tag;
16. GitHub Release creation and exact asset re-download verification;
17. final release/predecessor closure receipt;
18. final closure receipt upload and exact-byte re-download verification.

No tag or GitHub Release exists before step 15.

## Public release assets

The canonical initial asset set is:

```text
nxb-v1.0.1.zip
package-manifest.json
release-notes.txt
signature-envelope.json
update-descriptor.json
update-trust.json
production-readiness-receipt.json
nxb-v1.0.1-public-evidence.zip
production-key-rotation-policy.txt
production-revocation-policy.txt
```

After all initial assets are re-downloaded and verified, the immutable final closure asset is added:

```text
production-final-closure-receipt.json
```

## Invocation boundary

The production operator requires elevated PowerShell 7 on Windows and an explicit confirmation switch:

```powershell
./scripts/Invoke-NxbV1ProductionRelease.ps1 `
  -CertifiedHead <exact-certified-pr-sha> `
  -ExpectedHead <integrated-main-merge-sha> `
  -NativeRunId <successful-workflow-dispatch-run-id> `
  -ConfirmProductionRelease
```

Optional certificate location/thumbprint arguments only narrow the already fingerprint-matched candidate set. They cannot override the frozen public fingerprint.

## Failure semantics

Every pre-tag failure is safe to abandon: no v1.0.1 public tag or GitHub Release has been created.

After tag creation, the operator never force-rewrites the tag and never uses release-asset clobber semantics. A publication failure must be diagnosed and closed explicitly rather than hidden by rewriting already-published evidence.

The v1.0.0 tag, release assets, final receipt and historical Phase-7 pointer remain immutable throughout the successor closure.
