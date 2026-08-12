# NXB v1 Signed Staged Update and Rollback Authority

## Purpose

This successor layer sits on top of native-certified installer head:

```text
efdeb275c25a7df1326d7effdddb4af8d83ef81d
```

It adds signed staged updates with a pinned signer trust anchor, monotonic release sequencing, explicit Apply, automatic rollback on failed publication validation, manual Rollback, and independently replayable evidence. It does not mutate the certified installer tree.

## Trust model

The updater never trusts an envelope merely because its embedded public key verifies its own signature. A separate local update-trust document pins the accepted public-key fingerprint and channel.

Production mode accepts only envelopes produced by the production Windows Certificate Store signer contract. Certification mode uses an ephemeral RSA-3072 signer and a temporary trust document pinned to that ephemeral public fingerprint.

The update trust contract contains:

- channel (`stable` or `beta`),
- exact trusted signer fingerprint,
- minimum release sequence,
- `allow_downgrade=false`,
- bounded revoked release-head list.

## Signed update descriptor

The signed descriptor binds:

- channel,
- target release version,
- monotonic `release_sequence`,
- target release head,
- certified implementation head,
- package-manifest SHA-256.

The descriptor bytes are themselves included in the signed release envelope as `update/update-descriptor.json`. Package files are separately represented in the signed artifact set as `package/<relative-path>` rows. Certification reconstructs those artifact rows from the real target-package files, including byte counts and SHA-256 values, instead of merely copying manifest metadata into the signed envelope.

## Release sequence and replay floor

An installer-created baseline is treated as sequence `0`. Signed updates begin at sequence `1`.

The updater rejects:

- a target sequence below the trust minimum,
- a target sequence less than or equal to the persisted highest-seen sequence,
- revoked release heads,
- channel mismatch,
- a signer fingerprint that does not match the local trust anchor.

Authoritative update state keeps both:

- `current_release_sequence`, which identifies the release currently installed,
- `highest_seen_release_sequence`, which is a monotonic anti-replay floor.

A manual Rollback may restore an older current sequence, but it never lowers `highest_seen_release_sequence`. Therefore an already-applied signed update cannot become admissible again merely because the operator rolled back the installed tree. This is protected by `NXB-ERR-039` and independently replayed from final `update-state.json`.

An already-staged update may be replaced only by a strictly higher signed sequence. Equal or older staged sequences are rejected.

## Stage

`Stage` is explicit and never performs Apply automatically.

Before publication it verifies:

1. package-manifest structure,
2. package bytes and SHA-256 values,
3. signed envelope RSA signature,
4. public-key fingerprint,
5. local trust anchor,
6. signed descriptor identity and channel,
7. monotonic release sequence against the highest-seen floor,
8. revocation policy,
9. descriptor hash in the signed artifact map,
10. every package artifact byte count and SHA-256 in the signed artifact map.

The staged package and staged metadata are stored separately. Stage state records their exact roots and metadata hashes.

## Apply

`Apply` requires a previously staged update and revalidates the staged package, descriptor, envelope, trust anchor, and metadata hashes before any install-tree mutation.

Apply then:

1. copies the verified package into a sibling candidate directory,
2. writes managed installer state into the candidate,
3. verifies the complete candidate,
4. computes the current installed-tree digest,
5. moves the current install root to a unique rollback snapshot,
6. moves the candidate into the install root,
7. verifies the published install,
8. publishes authoritative update state with the new current sequence and highest-seen floor,
9. retains the previous tree as a verified rollback snapshot.

If post-publication validation fails, the atomic-swap helper restores the previous install tree. If update-state publication fails after a successful tree swap, the operator restores the previous install tree before surfacing failure.

## Authoritative JSON publication

Update state, stage state, and operation receipts use sibling-temp publication. JSON is serialized into a unique sibling temp file, opened exclusively, written and flushed, then published by same-directory `File.Replace` or `File.Move`. This prevents an existing authoritative state file from being truncated by a failed direct overwrite.

This behavior is protected by release-layer `NXB-ERR-038`.

## Manual Rollback

Rollback requires a recorded rollback snapshot and verifies its canonical tree SHA-256 before use.

The current forward tree is moved aside, the rollback snapshot is restored, and the restored tree hash is verified. Only after successful verification is update state rewritten with `rollback_available=false`. If state publication fails, the forward tree is restored.

Rollback changes the current release identity back to the restored release but preserves the monotonic `highest_seen_release_sequence`. Certification must then prove that replay of the already-seen target sequence is still rejected.

## External data and evidence

Data and evidence roots remain outside the managed install root. Certification carries independent sentinel files for both and requires their SHA-256 values to remain unchanged through Stage, Apply, automatic failed-apply rollback, and manual Rollback.

## Safety boundaries

Certification:

- uses temporary roots only,
- never auto-applies,
- never performs a PerMachine install,
- never updates the actual production release,
- never uses or creates a production private key,
- never merges, tags, pushes, or creates a GitHub Release.

## Native certification target

The update authority targets:

```text
PS7                              24/24
Windows PowerShell 5.1          24/24
independent requirements         16/16
adversarial controls             12/12
base known-error rules           >=23
production extension              9+1+1
release successor rules           1
signing successor rules           2
installer successor rules         4
update successor rules            6
known-error findings              0
PSScriptAnalyzer findings         0
trust anchor                       PASS
Stage                              PASS
Apply                              PASS
failed-apply automatic rollback    PASS
manual Rollback                    PASS
rollback anti-replay floor         PASS
auto apply                         false
machine install                    false
production release update          false
review ZIP                         exactly 28 entries
```

The independent Python validator reconstructs the RSA PKCS#1 v1.5 SHA-256 verification with modular exponentiation, consumes final `update-state.json`, and replays 16 requirements plus 12 adversarial controls.