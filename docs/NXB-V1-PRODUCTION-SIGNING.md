# NXB v1 Production Signing

## Purpose

This successor authority certifies the release-signing pipeline without modifying the frozen predecessor or pretending that a production release has already been signed.

Historical production-signing component predecessor:

```text
9371399bab4fbb921ad94198aa148c597c7b6261
```

Historical Parts 1-10 implementation authority:

```text
a10535b294c4d7ba8a4c3683154609087bf50c4b
```

Current successor target release version:

```text
1.0.1
```

The signing schema deliberately continues to admit historical `1.0.0` envelopes for verification. New production signing through the current policy must emit `1.0.1`.

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

For the v1.0.1 successor, signer discovery is additionally constrained by the frozen v1.0.0 production public fingerprint recorded in `config/nxb-v1-successor-policy.json`. A different valid certificate is not silently accepted as a signer rotation.

## Package identity binding

The signing operator parses the real package manifest before any signature is produced. It requires:

```text
schema_version = 1
contract_id     = nxb-v1-package-manifest-v1
release_version = 1.0.1
source_head     = release_head
```

The manifest must contain at least one file and its `file_count` must equal the actual file-row count.

Every manifest row must also exist in the signed artifact set as:

```text
package/<manifest-relative-path>
```

The signed artifact byte count and SHA-256 must exactly match the package-manifest row. Hashing the manifest file alone is not considered sufficient release identity binding.

## Canonical material

The signature is over explicitly ordered UTF-8 material, not arbitrary JSON serialization.

The current successor contract begins with:

```text
nxb-v1-release-signature-canonical-v1
schema_version=1
release_version=1.0.1
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

## Independent verification v2

`tools/validate_v1_production_signing.py` reconstructs the canonical material independently and verifies RSA-PKCS1-v1.5/SHA-256 with public modulus/exponent arithmetic. It does not trust PowerShell `VerifyData()` as the final independent authority.

The v2 independent authority has two explicit expected modes:

```text
certification-ephemeral
production-windows-certificate-store
```

Certification mode requires an ephemeral key ID and forbids production signer claims or persisted private-key state.

Production mode requires:

- signer mode `production-windows-certificate-store`;
- `production_signer_claimed=true`;
- certificate-store key ID `win-cert:<StoreLocation>/My/<THUMBPRINT>`;
- public-key fingerprint equal to the separately supplied expected production fingerprint.

The production fingerprint is an external trust input. The envelope cannot make itself trusted merely by containing a self-consistent public key.

Eight adversarial controls are mandatory in either expected mode:

1. tampered release head,
2. tampered package-manifest hash,
3. tampered artifact hash,
4. tampered signer fingerprint,
5. malformed signature,
6. weak key metadata,
7. wrong signer key ID,
8. duplicate artifact path.

## Known-error inheritance

The signing authority inherits the native-certified base known-error ledger and the release-layer ERR-036 contract.

A separate signing-successor scanner carries two existing native classes without changing the certified release-integration rule count:

- `NXB-ERR-007`: rejects the old `New-NxbV1CertificationSigner` and `New-NxbV1SignedReleaseEnvelope` helper names that triggered `PSUseShouldProcessForStateChangingFunctions`.
- `NXB-ERR-014`: rejects hard-coded `ps7='18/18'` / `ps51='18/18'` receipt fields that would leave actual Pester result objects assigned but unused.

The repaired helper surface uses `Get-NxbV1CertificationSigner` and `ConvertTo-NxbV1SignedReleaseEnvelope`. PS7 and Windows PowerShell 5.1 summary strings are computed from the real Pester result objects and carried into the certification receipt and result.

## Certification fixture

The certification authority creates a real two-file package root and exports its manifest through `scripts/Export-NxbV1PackageManifest.ps1`. The fixture therefore uses the same `1.0.1` package identity and exact current source head that the operator is expected to sign.

The certification authority then signs those package files through the same operator-facing command used by production mode and independently verifies the envelope in explicit `certification-ephemeral` mode.

Expected certification closure:

```text
PS7                         18/18
Windows PowerShell 5.1     18/18
Independent requirements   12/12
Negative controls           8/8
Base known-error findings   0
Production findings         0
Release findings            0
Signing findings            0
Release known-error rules   1
Signing known-error rules   2
PSScriptAnalyzer            0
RSA key size                >=3072
Production signer claimed   false
Actual production release   false
Pipeline certified          true
```

The bounded review ZIP must contain exactly 11 entries:

```text
base-known-error-scan.json
production-known-error-scan.json
release-known-error-scan.json
signing-known-error-scan.json
v1-production-signing-envelope.json
v1-production-signing-independent-validation.json
v1-production-signing-certification-receipt.json
fixture/package-manifest.json
fixture/release-notes.txt
fixture/package/a-first.bin
fixture/package/z-last.bin
```

## Deliberate non-capabilities

This signing layer does not merge branches, create tags, push refs, create a GitHub Release, install certificates, generate a production private key, export a private key, or mark the candidate as a completed production release.

Production release signing happens only after exact-head hosted/native authority, merge-tree identity, packaging, installer hashes, release notes, and the protected production signer are all available. The end-to-end v1.0.1 closure is tracked by Issue #42 and `docs/NXB-V1-PRODUCTION-RELEASE.md`.
