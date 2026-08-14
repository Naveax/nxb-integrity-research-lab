# NXB v1.0.1 Version Surface Inventory

## Purpose

This inventory separates v1.0.1 mutable release metadata from frozen v1.0.0 authority. It exists to prevent a repository-wide `1.0.0 -> 1.0.1` replacement from rewriting historical evidence or breaking release-integration contracts.

Successor base:

- frozen predecessor head: `a4f1b242c003333b1f34b1cd54ca37cab33fbf4f`
- frozen predecessor tree: `34779176d9e15cd4d700d46132785c0b25f19604`
- successor branch: `release/nxb-v1.0.1-prep`
- target successor version: `1.0.1`

## Direct mutable target-version policies

The v1.0.0 production head exposes `target_version: 1.0.0` in these release-facing policy files:

1. `config/nxb-v1-cli-policy.json`
2. `config/nxb-v1-installer-policy.json`
3. `config/nxb-v1-update-policy.json`
4. `config/nxb-v1-production-signing-policy.json`
5. `config/nxb-v1-ci-policy.json`
6. `config/nxb-v1-release-integration-policy.json`

The first five are straightforward successor-version surfaces in principle, but their validators/tests must advance in the same successor change so policy and enforcement do not drift.

`config/nxb-v1-release-integration-policy.json` is a special case and must not be bumped independently. Its current policy carries:

- `candidate_version: 1.0.0-candidate`
- `target_version: 1.0.0`
- `release_branch: release/nxb-v1.0.0-prep`
- historical certified implementation / ancestor bindings

## Release-integration hard-coded enforcement

`scripts/Test-NxbV1ReleaseIntegration.ps1` currently enforces exact v1.0.0 values in code:

- `candidate_version` must equal `1.0.0-candidate`
- `target_version` must equal `1.0.0`
- `config/nxb-production-finalization-policy.json` Part10 `release_version` must remain `1.0.0-candidate`

That last check is intentionally historical. The Production Final v1.0.0 candidate authority is not a v1.0.1 mutable version field.

Therefore the v1.0.1 implementation must not simply edit `config/nxb-v1-release-integration-policy.json`. Policy, validator, tests, receipt schema assumptions, and predecessor semantics have to be changed as one successor contract.

## Enforcement dependents

Search results show the release-facing target version is also asserted or consumed by these families:

- `tools/validate_v1_cli.py`
- `tools/validate_v1_installer.py`
- `tools/validate_v1_update.py`
- `tools/validate_v1_production_signing.py`
- `tools/validate_v1_ci.py`
- `tools/validate_v1_release_integration.py`
- `scripts/Invoke-NxbV1CliCertification.ps1`
- `scripts/Invoke-NxbV1InstallerCertification.ps1`
- `scripts/Invoke-NxbV1UpdateCertification.ps1`
- `scripts/Invoke-NxbV1ProductionSigningCertification.ps1`
- `scripts/Invoke-NxbV1ReleaseIntegrationCertification.ps1`
- `scripts/Test-NxbV1ReleaseIntegration.ps1`
- `tests/V1Cli.Tests.ps1`
- `tests/V1Installer.Tests.ps1`
- `tests/V1Update.Tests.ps1`
- `tests/V1ProductionSigning.Tests.ps1`
- `tests/V1ReleaseIntegration.Tests.ps1`
- `schemas/nxb-v1-release-integration-receipt.schema.json`

An occurrence in one of these files is not automatically mutable. Tests and validators may intentionally assert v1.0.0 historical behavior, so each occurrence must be classified by semantics before editing.

## Frozen historical version fields

These must remain v1.0.0 records unless a new successor contract explicitly references them as predecessor metadata:

- `config/nxb-production-finalization-policy.json` Part10 `release_version: 1.0.0-candidate`
- v1.0.0 package manifest and signed envelope
- v1.0.0 production readiness/final closure receipts
- v1.0.0 release notes
- v1.0.0 Git tag and GitHub Release
- v1.0.0 production package SHA-256
- v1.0.0 final closure SHA-256
- historical Phase-7 evidence and certified pointer
- predecessor commit/tree hashes

## Successor contract decision

The next code change should introduce successor-aware version semantics rather than weakening existing v1.0.0 checks.

Preferred direction:

1. Keep Production Final v1.0.0 candidate authority frozen.
2. Treat `a4f1b242c003333b1f34b1cd54ca37cab33fbf4f` as the v1.0.1 production predecessor boundary.
3. Add a successor-specific version/predecessor contract for `1.0.1`.
4. Update release-integration validation to distinguish:
   - frozen predecessor candidate/release metadata, and
   - mutable successor candidate/target metadata.
5. Advance CLI/installer/update/signing/CI target versions only together with their validators and tests.
6. Require the successor candidate to remain a descendant of the frozen v1.0.0 head.
7. Preserve no-history-rewrite, no-private-key-in-repo, bounded package signing, explicit update mutation, and receipt-bound promotion gates.

## Next implementation gate

Before the first behavioral v1.0.1 change, the branch should gain a machine-readable successor policy plus validator/tests that prove:

- predecessor version/head/tree are exact,
- target version is `1.0.1`,
- v1.0.0 Production Final candidate remains unchanged,
- v1.0.0 tag/release assets are untouched,
- successor ancestry begins at the exact v1.0.0 production head,
- mutable version surfaces and historical fields are not conflated.

Only after that gate is green should the normal v1.0.1 feature/bugfix work resume.
