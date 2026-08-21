# NXB v1.0.1 Release Integration

## Status

This document describes the v1.0.1 successor release-integration layer built on the frozen v1.0.0 production predecessor.

Frozen production predecessor authority:

```text
a4f1b242c003333b1f34b1cd54ca37cab33fbf4f
```

Frozen predecessor tree:

```text
34779176d9e15cd4d700d46132785c0b25f19604
```

Historical Parts 1-10 implementation authority remains:

```text
a10535b294c4d7ba8a4c3683154609087bf50c4b
```

Certified-main ancestor retained by the release-integration contract:

```text
b55fed4e4c960f8fea73b959f29dd57649c6bd65
```

Release preparation branch:

```text
release/nxb-v1.0.1-prep
```

Target version:

```text
1.0.1
```

The historical Production Final receipt remains `1.0.0-candidate`. It is immutable evidence and MUST NOT be rewritten into a v1.0.1 production-release receipt.

## Successor boundary rule

The release-integration diff boundary is the exact frozen v1.0.0 production head, not the earlier pre-release Parts 1-10 implementation authority. Every v1.0.1 release-layer change must therefore remain a descendant of `a4f1b242c003333b1f34b1cd54ca37cab33fbf4f`.

The live `main` head must also remain an ancestor of the release head before integration is permitted. History rewrite is forbidden.

The v1.0.1 release-preparation authority allows only explicit successor surfaces:

```text
.github/workflows/nxb-v1-*
AGENTS.md
config/nxb-v1-*
docs/NXB-V1-*
docs/NXB-V1.0.1-*
schemas/nxb-v1-*
scripts/Export-NxbV1*
scripts/Invoke-NxbV1*
scripts/NxbV1*
scripts/Test-NxbV1*
scripts/nxb.ps1
tests/V1*
tools/validate_v1_*
```

`docs/NXB-V1.0.1-*` is admitted specifically for the successor bootstrap/version-surface records. `scripts/Export-NxbV1*` is admitted specifically because the v1.0.1 package-manifest exporter is a shipped release identity surface. `scripts/nxb.ps1` is admitted as one exact post-release CLI runtime surface for successor-aware status/version reporting after the immutable v1.0.1 production closure. None of these admissions broadens the boundary to arbitrary documentation or scripts.

`AGENTS.md` is admitted only because the live main branch carries the repository-wide bounded CI execution policy. It is an operational control, not a shipped runtime dependency.

Broad `scripts/` and `config/` prefixes are deliberately not admitted. A change outside the explicit successor surfaces is not release preparation and requires a new implementation authority.

## Preflight requirements

The release integration preflight must fail closed unless all of the following hold:

1. The Git worktree is clean.
2. The frozen v1.0.0 production predecessor is an ancestor of the release head.
3. The current main head is an ancestor of the release head.
4. The recorded certified-main ancestor remains an ancestor of the frozen predecessor boundary.
5. Every path changed after the predecessor belongs to an allowed successor surface.
6. No generated evidence or release artifact such as ETL, ZIP, PFX, P12 or private-key file is added by the successor layer.
7. No private-key PEM marker exists in the tracked repository.
8. The production signer is explicitly separate from the certification signer.
9. The historical `1.0.0-candidate` Production Final authority remains unchanged.
10. The preflight receipt contains zero failures.

## Signing boundary

The certification-only ephemeral RSA authorities are not production release signers.

The v1.0.1 production release requires:

- protected Windows Certificate Store private-key custody;
- RSA key size of at least 3072 bits;
- signer key ID and public fingerprint binding;
- rotation policy;
- revocation policy;
- signed release manifest/envelope;
- tamper and wrong-key rejection;
- the production signer to remain separate from certification-only ephemeral signing.

No production private key may be generated, exported, uploaded, or stored in this repository.

## Integration boundary

This preflight does not merge, tag, push, create a GitHub Release, or mutate `main`.

Those actions require the later production-release authority after exact-head CI/native closure and integration. The final merge SHA is recorded separately from both the historical Parts 1-10 implementation SHA and the frozen v1.0.0 predecessor SHA.

The historical Phase-7 pointer remains immutable and is not advanced by v1.0.1 release integration.

## Current successor work

The v1.0.1 production closure tracked by Issue #42 is complete. Immutable tag `v1.0.1` resolves to integrated head `9a6f5b91d1a9e1d639be4b904851c7d7a1a12c85`, whose tree is `26f0c29bd8da284e0553902e18f22f759e3c907f`.

Post-release CLI authority cleanup is tracked by Issue #43. That work may report the published v1.0.1 authority while preserving the historical `1.0.0-candidate` Production Final policy byte-for-byte. It does not rewrite tag `v1.0.1`, its GitHub Release, its final closure receipt, or the frozen v1.0.0 predecessor.

Bounded pre-trigger/post-trigger capture primitives remain separate runtime-feature work because they are implementation changes rather than release packaging work.
