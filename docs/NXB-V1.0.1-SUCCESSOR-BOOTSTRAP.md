# NXB v1.0.1 Successor Bootstrap

## Frozen predecessor

NXB v1.0.1 development starts from the immutable v1.0.0 production authority.

- predecessor version: `1.0.0`
- predecessor head: `a4f1b242c003333b1f34b1cd54ca37cab33fbf4f`
- predecessor tree: `34779176d9e15cd4d700d46132785c0b25f19604`
- predecessor tag: `v1.0.0`
- predecessor GitHub Release ID: `370629171`
- predecessor package SHA-256: `c489ba417f1284bfcad4d0666e61fde93ab4ed8fab7fa4e8c0ef1df5c7e9ce78`
- predecessor final-closure SHA-256: `b3914161cb851a600c2d79a6f1fb877766aa8af453d2a19e03a43884758f1355`
- predecessor production signer fingerprint: `1d72e76225854e09af2552639436a508f050042e5e1c635bd7e11cc3feae4373`
- historical Phase-7 certified pointer remains `9e7e47561914f5ecbb59d1958aef695ca03a1f30`

The `v1.0.0` tag, GitHub Release assets, production receipts, package manifest, signed envelope, and historical certification evidence are not successor workspaces and must not be rewritten.

## Successor authority

- target version: `1.0.1`
- bootstrap branch: `release/nxb-v1.0.1-prep`
- bootstrap parent: exact predecessor head `a4f1b242c003333b1f34b1cd54ca37cab33fbf4f`
- release class: patch successor unless an explicitly approved breaking or feature scope requires a later minor-version line

## Required invariants

1. No history rewrite of the v1.0.0 ancestry.
2. No movement or replacement of `v1.0.0`.
3. No mutation of v1.0.0 GitHub Release assets or final closure receipts.
4. No production private-key export, repository persistence, PFX/PEM path, or raw private-key handling.
5. The historical `release/nxb-v1.0.0-ci` pointer remains historical unless a separately authorized migration is defined.
6. Every v1.0.1 release candidate must remain an exact descendant of `a4f1b242c003333b1f34b1cd54ca37cab33fbf4f`.
7. Version changes must distinguish mutable next-release fields from historical `1.0.0-candidate` / v1.0.0 evidence fields.
8. Runtime-package signing remains bounded by the production signing policy; do not increase limits merely to accommodate repository-wide packaging.
9. Update remains explicit Stage/Apply/Rollback with `auto_apply=false` by default.
10. Final promotion/tag/release transitions remain fail-closed and receipt-bound.

## Mutable next-release version surface

The initial v1.0.1 bootstrap should review and, where semantically appropriate, advance the next-release fields in:

- `config/nxb-v1-cli-policy.json`
- `config/nxb-v1-installer-policy.json`
- `config/nxb-v1-update-policy.json`
- `config/nxb-v1-production-signing-policy.json`
- `config/nxb-v1-ci-policy.json`
- `config/nxb-v1-release-integration-policy.json`

The current v1.0.0 tree exposes `target_version: 1.0.0` in these release-facing policies. Tests, validators, schemas, and documentation that enforce those policies must be updated only when their contract semantics require it.

## Historical fields that must not be blindly bumped

Do not globally replace `1.0.0` with `1.0.1`. In particular, historical authority fields such as the Production Final Part10 `release_version: 1.0.0-candidate`, predecessor hashes, release receipts, old tags, prior release documentation, and evidence hashes remain records of v1.0.0.

## Bootstrap sequence

1. Inventory all exact `1.0.0` / `1.0.0-candidate` occurrences and classify each as mutable-next-release or historical.
2. Define the v1.0.1 predecessor contract using the frozen v1.0.0 head and closure receipt.
3. Advance only mutable target-version fields.
4. Update validators/tests for the successor contract without weakening v1.0.0 checks.
5. Run hosted + local certification for the successor head.
6. Keep installer/update/signing tests on bounded runtime package surfaces.
7. Build release candidates on successor branches; do not reuse or rewrite v1.0.0 release refs.
8. Require explicit promotion authority for future main/tag/GitHub Release transitions.

## Initial state

At bootstrap creation, this branch intentionally contains no v1.0.1 behavioral change. Its first job is to establish an exact, non-destructive successor boundary from the frozen v1.0.0 authority before implementation resumes.
