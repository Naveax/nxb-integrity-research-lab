#!/usr/bin/env python3
import argparse
import copy
import hashlib
import json
import pathlib
import re
import subprocess
import sys

PREDECESSOR_HEAD = "a4f1b242c003333b1f34b1cd54ca37cab33fbf4f"
PREDECESSOR_TREE = "34779176d9e15cd4d700d46132785c0b25f19604"
TARGET_VERSION = "1.0.1"
CANDIDATE_VERSION = "1.0.1-candidate"
HISTORICAL_CANDIDATE_VERSION = "1.0.0-candidate"
HISTORICAL_CERTIFIED_POINTER = "9e7e47561914f5ecbb59d1958aef695ca03a1f30"
FINAL_CLOSURE_SHA256 = "b3914161cb851a600c2d79a6f1fb877766aa8af453d2a19e03a43884758f1355"
PACKAGE_SHA256 = "c489ba417f1284bfcad4d0666e61fde93ab4ed8fab7fa4e8c0ef1df5c7e9ce78"
SIGNER_FINGERPRINT = "1d72e76225854e09af2552639436a508f050042e5e1c635bd7e11cc3feae4373"

COMPONENTS = {
    "cli": ("config/nxb-v1-cli-policy.json", "migrated", "1.0.1"),
    "installer": ("config/nxb-v1-installer-policy.json", "migrated", "1.0.1"),
    "update": ("config/nxb-v1-update-policy.json", "migrated", "1.0.1"),
    "production_signing": ("config/nxb-v1-production-signing-policy.json", "migrated", "1.0.1"),
    "ci": ("config/nxb-v1-ci-policy.json", "pending", "1.0.0"),
    "release_integration": ("config/nxb-v1-release-integration-policy.json", "pending", "1.0.0"),
}
COMPONENT_ORDER = list(COMPONENTS)
REQUIRED_DOCUMENTS = [
    "docs/NXB-V1.0.1-SUCCESSOR-BOOTSTRAP.md",
    "docs/NXB-V1.0.1-VERSION-SURFACE-INVENTORY.md",
]
ALLOWED_PATHS = {
    "docs/NXB-V1.0.1-SUCCESSOR-BOOTSTRAP.md",
    "docs/NXB-V1.0.1-VERSION-SURFACE-INVENTORY.md",
    "config/nxb-v1-successor-policy.json",
    "tools/validate_v1_successor.py",
    "tests/V1Successor.Tests.ps1",
    "config/nxb-v1-cli-policy.json",
    "tools/validate_v1_cli.py",
    "tests/V1Cli.Tests.ps1",
    "config/nxb-v1-installer-policy.json",
    "tools/validate_v1_installer.py",
    "tests/V1Installer.Tests.ps1",
    "config/nxb-v1-update-policy.json",
    "tools/validate_v1_update.py",
    "tests/V1Update.Tests.ps1",
    "config/nxb-v1-production-signing-policy.json",
    "schemas/nxb-v1-release-signature-envelope.schema.json",
    "scripts/NxbV1ProductionSigning.Common.ps1",
    "scripts/Invoke-NxbV1ReleaseManifestSigning.ps1",
    "tools/validate_v1_production_signing.py",
    "tests/V1ProductionSigning.Tests.ps1",
}
FORBIDDEN_SUFFIXES = (".etl", ".etl.tmp", ".pfx", ".p12", ".pem", ".key", ".zip")
PRIVATE_MARKERS = [
    "-----BEGIN " + "PRIVATE KEY-----",
    "-----BEGIN RSA " + "PRIVATE KEY-----",
    "-----BEGIN EC " + "PRIVATE KEY-----",
    "-----BEGIN OPENSSH " + "PRIVATE KEY-----",
]


def load_json(path):
    return json.loads(pathlib.Path(path).read_text(encoding="utf-8-sig"))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def run_git(root, *args, check=True):
    p = subprocess.run(
        ["git", *args],
        cwd=str(root),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and p.returncode != 0:
        raise RuntimeError("git {} failed ({}): {}".format(" ".join(args), p.returncode, p.stderr.strip()))
    return p


def lower_hex(value, length):
    return isinstance(value, str) and len(value) == length and re.fullmatch(r"[0-9a-f]+", value) is not None


def component_map(policy):
    vt = policy.get("version_transition", {})
    rows = vt.get("components", {}) if isinstance(vt, dict) else {}
    result = {}
    for name in COMPONENT_ORDER:
        row = rows.get(name, {}) if isinstance(rows, dict) else {}
        result[name] = (row.get("policy_path"), row.get("status"), row.get("expected_target_version"))
    return result


def validate_policy(policy):
    predecessor = policy.get("predecessor", {})
    successor = policy.get("successor", {})
    historical = policy.get("historical", {})
    vt = policy.get("version_transition", {})
    safety = policy.get("safety", {})
    return all(
        [
            policy.get("schema_version") == 1,
            policy.get("contract_id") == "nxb-v1-successor-v1",
            policy.get("phase") == "version-transition",
            predecessor.get("version") == "1.0.0",
            predecessor.get("head") == PREDECESSOR_HEAD,
            predecessor.get("tree") == PREDECESSOR_TREE,
            predecessor.get("tag") == "v1.0.0",
            predecessor.get("github_release_id") == 370629171,
            predecessor.get("package_sha256") == PACKAGE_SHA256,
            predecessor.get("final_closure_sha256") == FINAL_CLOSURE_SHA256,
            predecessor.get("production_signer_fingerprint") == SIGNER_FINGERPRINT,
            predecessor.get("historical_certified_pointer") == HISTORICAL_CERTIFIED_POINTER,
            successor.get("target_version") == TARGET_VERSION,
            successor.get("candidate_version") == CANDIDATE_VERSION,
            successor.get("branch") == "release/nxb-v1.0.1-prep",
            successor.get("release_class") == "patch",
            historical.get("production_final_policy") == "config/nxb-production-finalization-policy.json",
            historical.get("production_final_candidate_version") == HISTORICAL_CANDIDATE_VERSION,
            historical.get("preserve_v1_0_0_tag") is True,
            historical.get("preserve_v1_0_0_release_assets") is True,
            historical.get("preserve_v1_0_0_receipts") is True,
            historical.get("preserve_historical_certified_pointer") is True,
            vt.get("component_order") == COMPONENT_ORDER,
            component_map(policy) == COMPONENTS,
            safety.get("require_predecessor_ancestor") is True,
            safety.get("allow_history_rewrite") is False,
            safety.get("allow_v1_0_0_tag_mutation") is False,
            safety.get("allow_v1_0_0_release_asset_mutation") is False,
            safety.get("allow_production_private_key_export") is False,
            safety.get("auto_apply_updates") is False,
            safety.get("require_explicit_future_promotion") is True,
        ]
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repository-root", required=True)
    ap.add_argument("--expected-head")
    a = ap.parse_args()
    root = pathlib.Path(a.repository_root).resolve()
    policy_path = root / "config" / "nxb-v1-successor-policy.json"
    final_policy_path = root / "config" / "nxb-production-finalization-policy.json"
    policy = load_json(policy_path)
    failures = []
    checks = {}

    checks["policy_contract"] = validate_policy(policy)
    if not checks["policy_contract"]:
        failures.append("policy_contract")

    for name, value, length in [
        ("predecessor_head_format", PREDECESSOR_HEAD, 40),
        ("predecessor_tree_format", PREDECESSOR_TREE, 40),
        ("closure_hash_format", FINAL_CLOSURE_SHA256, 64),
        ("package_hash_format", PACKAGE_SHA256, 64),
        ("signer_fingerprint_format", SIGNER_FINGERPRINT, 64),
    ]:
        checks[name] = lower_hex(value, length)
        if not checks[name]:
            failures.append(name)

    final_policy = load_json(final_policy_path)
    checks["historical_candidate_preserved"] = final_policy.get("part10", {}).get("release_version") == HISTORICAL_CANDIDATE_VERSION
    if not checks["historical_candidate_preserved"]:
        failures.append("historical_candidate_preserved")

    target_versions = {}
    for name, (relative, status, expected) in COMPONENTS.items():
        actual = load_json(root / relative).get("target_version")
        target_versions[name] = actual
        checks["component_" + name] = actual == expected
        if not checks["component_" + name]:
            failures.append("component_" + name)

    checks["cli_installer_update_signing_migrated"] = (
        target_versions.get("cli") == "1.0.1"
        and target_versions.get("installer") == "1.0.1"
        and target_versions.get("update") == "1.0.1"
        and target_versions.get("production_signing") == "1.0.1"
        and all(target_versions[n] == "1.0.0" for n in COMPONENT_ORDER if n not in {"cli", "installer", "update", "production_signing"})
    )
    if not checks["cli_installer_update_signing_migrated"]:
        failures.append("cli_installer_update_signing_migrated")

    missing = [x for x in REQUIRED_DOCUMENTS if not (root / x).is_file()]
    checks["required_documents_present"] = not missing
    if missing:
        failures.append("required_documents_present")

    head = run_git(root, "rev-parse", "HEAD").stdout.strip().lower()
    checks["head_format"] = lower_hex(head, 40)
    if not checks["head_format"]:
        failures.append("head_format")
    if a.expected_head:
        checks["expected_head"] = head == a.expected_head.lower()
        if not checks["expected_head"]:
            failures.append("expected_head")

    tree = run_git(root, "rev-parse", PREDECESSOR_HEAD + "^{tree}").stdout.strip().lower()
    checks["predecessor_tree_exact"] = tree == PREDECESSOR_TREE
    if not checks["predecessor_tree_exact"]:
        failures.append("predecessor_tree_exact")

    anc = run_git(root, "merge-base", "--is-ancestor", PREDECESSOR_HEAD, head, check=False)
    checks["predecessor_is_ancestor"] = anc.returncode == 0
    if not checks["predecessor_is_ancestor"]:
        failures.append("predecessor_is_ancestor")

    diff = run_git(root, "diff", "--name-only", "--diff-filter=ACMRTUXB", PREDECESSOR_HEAD + "..." + head)
    changed = sorted({line.strip().replace("\\", "/") for line in diff.stdout.splitlines() if line.strip()})
    disallowed = [x for x in changed if x not in ALLOWED_PATHS]
    checks["transition_paths_allowed"] = not disallowed
    if disallowed:
        failures.append("transition_paths_allowed")

    forbidden = [x for x in changed if x.lower().endswith(FORBIDDEN_SUFFIXES)]
    checks["generated_artifacts_absent"] = not forbidden
    if forbidden:
        failures.append("generated_artifacts_absent")

    private_hits = []
    for relative in changed:
        path = root / relative
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8-sig")
        except (UnicodeDecodeError, OSError):
            continue
        if any(marker in text for marker in PRIVATE_MARKERS):
            private_hits.append(relative)
    checks["private_key_material_absent"] = not private_hits
    if private_hits:
        failures.append("private_key_material_absent")

    negatives = []
    m = copy.deepcopy(policy); m["predecessor"]["head"] = "0" * 40; negatives.append(not validate_policy(m))
    m = copy.deepcopy(policy); m["phase"] = "released"; negatives.append(not validate_policy(m))
    m = copy.deepcopy(policy); m["version_transition"]["components"]["production_signing"]["status"] = "pending"; negatives.append(not validate_policy(m))
    m = copy.deepcopy(policy); m["version_transition"]["components"]["ci"]["expected_target_version"] = "1.0.1"; negatives.append(not validate_policy(m))
    m = copy.deepcopy(policy); m["historical"]["production_final_candidate_version"] = CANDIDATE_VERSION; negatives.append(not validate_policy(m))
    m = copy.deepcopy(policy); m["safety"]["allow_history_rewrite"] = True; negatives.append(not validate_policy(m))
    checks["negative_controls"] = all(negatives) and len(negatives) == 6
    if not checks["negative_controls"]:
        failures.append("negative_controls")

    result = {
        "schema_version": 1,
        "status": "passed" if not failures else "failed",
        "authority": "nxb-v1-successor-independent-v5",
        "phase": policy.get("phase"),
        "predecessor_head": PREDECESSOR_HEAD,
        "predecessor_tree": PREDECESSOR_TREE,
        "head_sha": head,
        "target_version": TARGET_VERSION,
        "candidate_version": CANDIDATE_VERSION,
        "components": {
            name: {
                "policy_path": COMPONENTS[name][0],
                "status": COMPONENTS[name][1],
                "expected_target_version": COMPONENTS[name][2],
                "actual_target_version": target_versions.get(name),
            }
            for name in COMPONENT_ORDER
        },
        "checks": checks,
        "changed_paths": changed,
        "disallowed_paths": disallowed,
        "forbidden_artifacts": forbidden,
        "private_key_hits": private_hits,
        "missing_documents": missing,
        "negative_controls_validated": sum(bool(x) for x in negatives),
        "negative_control_count": 6,
        "failures": sorted(set(failures)),
        "source_sha256": {
            "policy": sha256_file(policy_path),
            "validator": sha256_file(pathlib.Path(__file__).resolve()),
            "production_final_policy": sha256_file(final_policy_path),
        },
    }
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
