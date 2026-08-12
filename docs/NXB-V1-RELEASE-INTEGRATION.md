# NXB v1.0 Release Integration

## Status

This document describes the successor release layer built on the native-certified Parts 1-10 exact tree.

Certified implementation authority:

```text
a10535b294c4d7ba8a4c3683154609087bf50c4b
```

Certified main ancestor:

```text
b55fed4e4c960f8fea73b959f29dd57649c6bd65
```

Release preparation branch:

```text
release/nxb-v1.0.0-prep
```

The native-certified receipt remains `1.0.0-candidate`. It is historical evidence and MUST NOT be rewritten into a production-release receipt.

## Release-layer rule

All post-certification changes must be additive successor work. The certified implementation head must remain an ancestor of the release head, and the live main head must remain an ancestor of the release head before integration is permitted.

The first release-preparation authority therefore allows only explicit successor paths:

```text
.github/workflows/nxb-v1-*
config/nxb-v1-*
docs/NXB-V1-*
schemas/nxb-v1-*
scripts/Invoke-NxbV1*
scripts/Test-NxbV1*
tests/V1*
tools/validate_v1_*
```

A change to the certified runtime outside those surfaces is not release preparation. It is a new implementation change and requires a new implementation authority.

## Preflight requirements

The release integration preflight must fail closed unless all of the following hold:

1. The Git worktree is clean.
2. The certified implementation SHA is an ancestor of the release head.
3. The current main head is an ancestor of the release head.
4. The recorded certified-main ancestor is an ancestor of the certified implementation SHA.
5. Every path changed after certification belongs to an allowed successor surface.
6. No generated evidence or release artifact such as ETL, ZIP, PFX, P12 or private-key file is added by the successor layer.
7. No private-key PEM marker exists in the tracked repository.
8. The production signer is explicitly separate from the certification signer.
9. The certified `1.0.0-candidate` version remains unchanged.
10. The preflight receipt contains zero failures.

## Signing boundary

The certification-only ephemeral RSA authorities are not production release signers.

A real v1.0 release requires a separate production-signing policy with:

- protected private-key storage;
- signer key ID and fingerprint;
- rotation policy;
- revocation policy;
- signed release manifest;
- tamper and wrong-key rejection.

No production private key may be stored in this repository.

## Integration boundary

This preflight does not merge, tag, push, create a GitHub Release, or mutate `main`.

Those actions require a later explicit release decision after the release-layer authority passes. The integration or merge SHA must be recorded separately from the certified implementation SHA.

## Successor work

Tracked by Issue #27:

1. final integration hygiene;
2. production signing;
3. installer/setup;
4. signed staged update and rollback;
5. CLI release commands;
6. CI and self-hosted Windows authority;
7. compatibility and soak testing;
8. release documentation;
9. final `v1.0.0` release closure.

Bounded pre-trigger/post-trigger capture primitives are tracked separately by Issue #26 because they are a new runtime feature and therefore require their own successor implementation authority.
