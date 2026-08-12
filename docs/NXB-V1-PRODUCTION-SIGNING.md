# NXB v1 Production Signing

## Purpose

This successor authority certifies the release-signing pipeline without modifying the native-certified Parts 1-10 tree or pretending that a production release has already been signed.

Predecessor release-integration authority:

```text
9371399bab4fbb921ad94198aa148c597c7b6261
```

Certified implementation authority:

```text
a10535b294c4d7ba8a4c3683154609087bf50c4b
```

Target release version:

```text
1.0.0
```

## Two signer modes

### CertificationEphemeral

Used only by the production-signing certification authority.

- RSA is at least 3072 bits.
- The private key exists only in the certification process.
- The private key is not written to the repository or review artifacts.
- `private_key_persisted=false`.
- `production_signer_claimed=false`.
- It proves signing, canonicalization, verification, and tamper rejection, not production key custody.

### ProductionWindowsCertificateStore

The only production signing mode.

- The caller supplies `StoreLocation`, `StoreName=My`, and an exact certificate thumbprint.
- The certificate must exist exactly once.
- It must be time-valid and have an RSA private key of at least 3072 bits.
- The private key must be non-exportable according to the supported Windows RSA provider inspection.
- Raw private-key bytes, PEM paths, and PFX paths are not accepted by the signing command.
- The repository never receives production private-key material.

A production signer can be backed by a Windows software key container or hardware-backed provider as long as the private-key protection contract is satisfied. Key custody, enrollment, rotation, and revocation remain separate release-operational responsibilities.

## Canonical material

The signature is over explicitly ordered UTF-8 material, not arbitrary JSON serialization.

The contract begins with:

```text
nxb-v1-release-signature-canonical-v1
schema_version=1
release_version=1.0.0
release_head=...
certified_implementation_head=...
package_manifest_sha256=...
release_notes_sha256=...
artifact_count=...
signer_mode=...
signer_key_id=...
signing_algorithm=RSA-PKCS1-SHA256
key_size_bits=...
public_modulus_b64=...
public_exponent_b64=...
public_fingerprint=...
created_utc=...
```

Artifact rows follow in ordinal path order:

```text
artifact=<relative-path>|<byte-count>|<sha256>
```

Artifact paths must be safe forward-slash relative paths, ASCII-only, unique, non-rooted, without traversal, control characters, backslashes, or the `|` delimiter.

## Real-file binding

`scripts/Invoke-NxbV1ReleaseManifestSigning.ps1` hashes the actual:

- package manifest,
- release notes,
- release artifacts.

It rejects reparse-point files and an ArtifactRoot that is itself a reparse point. After signing, it re-hashes package metadata and every artifact before writing the final signature envelope. A mid-signing mutation therefore fails instead of producing a misleading release envelope.

## Independent verification

`tools/validate_v1_production_signing.py` reconstructs the canonical material independently and verifies RSA-PKCS1-v1.5/SHA-256 with public modulus/exponent arithmetic. It does not trust PowerShell `VerifyData()` as the final independent authority.

Eight adversarial controls are mandatory:

1. tampered release head,
2. tampered package-manifest hash,
3. tampered artifact hash,
4. tampered signer fingerprint,
5. malformed signature,
6. weak key metadata,
7. wrong signer key ID,
8. duplicate artifact path.

## Certification fixture

The certification authority signs a bounded synthetic release fixture through the same operator-facing signing command used by production mode. The review ZIP includes the fixture package manifest, release notes, and both fixture artifacts so their signed hashes can be independently recalculated.

Expected certification closure:

```text
PS7                         18/18
Windows PowerShell 5.1     18/18
Independent requirements   12/12
Negative controls           8/8
Base known-error findings   0
Production findings         0
Release findings            0
PSScriptAnalyzer            0
RSA key size                >=3072
Production signer claimed   false
Actual production release   false
Pipeline certified          true
```

## Deliberate non-capabilities

This signing layer does not merge branches, create tags, push refs, create a GitHub Release, install certificates, generate a production private key, export a private key, or mark the candidate as a completed production release.

Production release signing happens only after integration, packaging, installer hashes, release notes, and the protected production signer are all available.
