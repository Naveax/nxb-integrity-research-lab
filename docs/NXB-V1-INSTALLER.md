# NXB v1 Installer and Package Authority

## Purpose

This successor layer sits on top of native-certified production signing head:

```text
91be58af59d0703de0159fea9d11935805e16022
```

It introduces deterministic package manifests, bounded host preflight, Portable staging, PerUser/PerMachine install modes, atomic repair, managed uninstall, and a native certification lifecycle without mutating the certified predecessor.

## Package manifest

`Export-NxbV1PackageManifest.ps1` enumerates real package files, rejects reparse points and unsafe relative paths, hashes every file with SHA-256, records byte counts, enforces package budgets, rejects duplicate relative paths, and orders paths with `StringComparer.Ordinal`.

The manifest does not include the installer state file. Installer state is generated only when a package is staged or installed.

## Install-root policy

The installer rejects:

- filesystem roots,
- the Windows directory and descendants,
- the system directory and descendants,
- the repository root and descendants,
- existing reparse-point roots,
- paths whose existing parent chain contains a reparse point,
- receipt paths located inside the install root.

Stage and Install require an absent target root. Repair and Uninstall require an existing managed root.

## Modes

### Portable

Portable packages use `Stage`. They are copied into an absent target root through a sibling staging directory and verified before publication.

### PerUser

PerUser uses `Install`, `Repair`, and `Uninstall` without requiring Administrator when the chosen root is otherwise permitted.

### PerMachine

PerMachine requires Administrator. Certification deliberately does not exercise or claim a machine-wide install.

## Atomic install and repair

Install/Stage copy the package into a sibling staging root, verify all package bytes, write managed state, verify again, and then publish by directory move.

Repair creates a fresh verified sibling repair root, moves the existing managed root to a unique backup, publishes the repaired root, verifies it, and removes the backup only after success. A failure after backup creation attempts an explicit rollback.

## Managed uninstall

Uninstall requires:

- a valid `.nxb-install-state.json`,
- matching install mode,
- matching source head,
- matching package-manifest SHA-256,
- an intact managed package.

If package bytes are damaged, the operator must Repair first. This prevents Uninstall from treating an arbitrary directory as an NXB-managed root.

User data and evidence are outside the install root. Uninstall receipts always report:

```text
data_removed=false
evidence_removed=false
```

## Host preflight

The host preflight requires Windows, PowerShell Core 7 or newer, and Python 3.9 or newer. It records Administrator status and the matched Xperf/WPR capability when available, but WPT availability is not a prerequisite for package installation itself.

## Certification lifecycle

The installer certification authority uses only temporary fixture roots and performs:

```text
Portable Stage
PerUser Install
intentional managed-file corruption
corruption detection
atomic Repair
exact byte/hash restoration
Uninstall
install-root absence check
```

Separate data and evidence sentinel files are hashed before the lifecycle and must remain byte-identical afterward. Their bytes are included in the review ZIP so an external verifier can recompute the preservation claim.

Certification never performs a PerMachine install and never installs the actual production v1.0.0 release.

## Independent validation

`tools/validate_v1_installer.py` independently checks 14 requirements and 10 adversarial controls. It re-hashes the package fixture and every operation receipt, validates the lifecycle evidence, and binds the preserved data/evidence sentinel bytes.

Mandatory negative controls:

1. duplicate manifest path,
2. traversal manifest path,
3. unsorted manifest,
4. tampered file hash,
5. wrong total byte count,
6. stale source head,
7. missing corruption detection,
8. false machine-install claim,
9. uninstall data-removal claim,
10. operation-receipt manifest mismatch.

## Review closure

The native installer authority targets an exact 22-test contract under PowerShell 7 and Windows PowerShell 5.1, inherited scanner closure, four installer-successor known-error rules, PSScriptAnalyzer zero findings, independent 14/14 + 10/10 replay, and an exact 18-entry review ZIP.

No merge, tag, GitHub Release, production signing operation, real production install, service creation, registry autorun, or data deletion is performed by certification.
