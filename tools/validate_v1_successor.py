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
TARGET_POLICY_PATHS = [
    "config/nxb-v1-cli-policy.json",
    "config/nxb-v1-installer-policy.json",
    "config/nxb-v1-update-policy.json",
    "config/nxb-v1-production-signing-policy.json",
    "config/nxb-v1-ci-policy.json",
    "config/nxb-v1-release-integration-policy.json",
]
REQUIRED_DOCUMENTS = [
    "docs/NXB-V1.0.1-SUCCESSOR-BOOTSTRAP.md",
    "docs/NXB-V1.0.1-VERSION-SURFACE-INVENTORY.md",
]
ALLOWED_BOOTSTRAP_PATHS = [
    "docs/NXB-V1.0.1-",
    "config/nxb-v1-successor-policy.json",
    "tools/validate_v1_successor.py",
    "tests/V1Successor.Tests.ps1",
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
    proc = subprocess.run(
        ["git", *args],
        cwd=str(root),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            "git {} failed ({}): {}".format(" ".join(args), proc.returncode, proc.stderr.strip())
        )
    return proc


def lower_hex(value, length):
    return isinstance(value, str) and len(value) == length and re.fullmatch(r"[0-9a-f]+", value) is not None


def validate_policy(policy):
    predecessor = policy.get("predecessor", {})
    successor = policy.get("successor", {})
    historical = policy.get("historical", {})
    pre_transition = policy.get("pre_transition", {})
    bootstrap = policy.get("bootstrap", {})
    safety = policy.get("safety", {})
    return all(
        [
            policy.get("schema_version") == 1,
            policy.get("contract_id") == "nxb-v1-successor-v1",
            policy.get("phase") == "pre-version-transition",
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
            pre_transition.get("expected_existing_target_version") == "1.0.0",
            pre_transition.get("target_version_policy_paths") == TARGET_POLICY_PATHS,
            bootstrap.get("required_documents") == REQUIRED_DOCUMENTS,
            bootstrap.get("allowed_changed_paths") == ALLOWED_BOOTSTRAP_PATHS,
            safety.get("require_predecessor_ancestor") is True,
            safety.get("allow_history_rewrite") is False,
            safety.get("allow_v1_0_0_tag_mutation") is False,
            safety.get("allow_v1_0_0_release_asset_mutation") is False,
            safety.get("allow_production_private_key_export") is False,
            safety.get("auto_apply_updates") is False,
            safety.get("require_explicit_future_promotion") is True,
        ]
    )


def bootstrap_path_allowed(path):
    normalized = path.replace("\\", "/")
    for allowed in ALLOWED_BOOTSTRAP_PATHS:
        if allowed.endswith("-") or allowed.endswith("/"):
            if normalized.startswith(allowed):
                return True
        elif normalized == allowed:
            return True
    return False


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository-root", required=True)
    parser.add_argument("--expected-head")
    args = parser.parse_args()

    root = pathlib.Path(args.repository_root).resolve()
    policy_path = root / "config" / "nxb-v1-successor-policy.json"
    final_policy_path = root / "config" / "nxb-production-finalization-policy.json"

    failures = []
    checks = {}

    policy = load_json(policy_path)
    checks["policy_contract"] = validate_policy(policy)
    if not checks["policy_contract"]:
        failures.append("policy_contract")

    checks["predecessor_head_format"] = lower_hex(PREDECESSOR_HEAD, 40)
    checks["predecessor_tree_format"] = lower_hex(PREDECESSOR_TREE, 40)
    checks["closure_hash_format"] = lower_hex(FINAL_CLOSURE_SHA256, 64)
    checks["package_hash_format"] = lower_hex(PACKAGE_SHA256, 64)
    checks["signer_fingerprint_format"] = lower_hex(SIGNER_FINGERPRINT, 64)
    for name in (
        "predecessor_head_format",
        "predecessor_tree_format",
        "closure_hash_format",
        "package_hash_format",
        "signer_fingerprint_format",
    ):
        if not checks[name]:
            failures.append(name)

    final_policy = load_json(final_policy_path)
    checks["historical_candidate_preserved"] = (
        final_policy.get("part10", {}).get("release_version") == HISTORICAL_CANDIDATE_VERSION
    )
    if not checks["historical_candidate_preserved"]:
        failures.append("historical_candidate_preserved")

    target_versions = {}
    for relative in TARGET_POLICY_PATHS:
        doc = load_json(root / relative)
        target_versions[relative] = doc.get("target_version")
    checks["pre_transition_target_versions_preserved"] = all(
        value == "1.0.0" for value in target_versions.values()
    )
    if not checks["pre_transition_target_versions_preserved"]:
        failures.append("pre_transition_target_versions_preserved")

    missing_documents = [relative for relative in REQUIRED_DOCUMENTS if not (root / relative).is_file()]
    checks["required_documents_present"] = not missing_documents
    if missing_documents:
        failures.append("required_documents_present")

    head = run_git(root, "rev-parse", "HEAD").stdout.strip().lower()
    checks["head_format"] = lower_hex(head, 40)
    if not checks["head_format"]:
        failures.append("head_format")
    if args.expected_head:
        checks["expected_head"] = head == args.expected_head.lower()
        if not checks["expected_head"]:
            failures.append("expected_head")

    predecessor_tree = run_git(root, "rev-parse", PREDECESSOR_HEAD + "^{tree}").stdout.strip().lower()
    checks["predecessor_tree_exact"] = predecessor_tree == PREDECESSOR_TREE
    if not checks["predecessor_tree_exact"]:
        failures.append("predecessor_tree_exact")

    ancestor = run_git(root, "merge-base", "--is-ancestor", PREDECESSOR_HEAD, head, check=False)
    checks["predecessor_is_ancestor"] = ancestor.returncode == 0
    if not checks["predecessor_is_ancestor"]:
        failures.append("predecessor_is_ancestor")

    diff = run_git(
        root,
        "diff",
        "--name-only",
        "--diff-filter=ACMRTUXB",
        PREDECESSOR_HEAD + "..." + head,
    )
    changed_paths = sorted({line.strip().replace("\\", "/") for line in diff.stdout.splitlines() if line.strip()})
    disallowed_paths = [path for path in changed_paths if not bootstrap_path_allowed(path)]
    checks["bootstrap_paths_allowed"] = not disallowed_paths
    if disallowed_paths:
        failures.append("bootstrap_paths_allowed")

    forbidden_suffixes = tuple(policy.get("bootstrap", {}).get("forbidden_artifact_suffixes", []))
    forbidden_artifacts = [path for path in changed_paths if path.lower().endswith(tuple(s.lower() for s in forbidden_suffixes))]
    checks["generated_artifacts_absent"] = not forbidden_artifacts
    if forbidden_artifacts:
        failures.append("generated_artifacts_absent")

    private_markers = [
        "-----BEGIN " + "PRIVATE KEY-----",
        "-----BEGIN RSA " + "PRIVATE KEY-----",
        "-----BEGIN EC " + "PRIVATE KEY-----",
        "-----BEGIN OPENSSH " + "PRIVATE KEY-----",
    ]
    private_key_hits = []
    for relative in changed_paths:
        path = root / relative
        if not path.is_file():
            continue
        try:
            text = path.read_text(encoding="utf-8-sig")
        except (UnicodeDecodeError, OSError):
            continue
        if any(marker in text for marker in private_markers):
            private_key_hits.append(relative)
    checks["private_key_material_absent"] = not private_key_hits
    if private_key_hits:
        failures.append("private_key_material_absent")

    negatives = []
    mutated = copy.deepcopy(policy)
    mutated["predecessor"]["head"] = "0" * 40
    negatives.append(not validate_policy(mutated))
    mutated = copy.deepcopy(policy)
    mutated["successor"]["target_version"] = "1.1.0"
    negatives.append(not validate_policy(mutated))
    mutated = copy.deepcopy(policy)
    mutated["phase"] = "released"
    negatives.append(not validate_policy(mutated))
    mutated = copy.deepcopy(policy)
    mutated["historical"]["production_final_candidate_version"] = CANDIDATE_VERSION
    negatives.append(not validate_policy(mutated))
    mutated = copy.deepcopy(policy)
    mutated["safety"]["allow_history_rewrite"] = True
    negatives.append(not validate_policy(mutated))
    mutated = copy.deepcopy(policy)
    mutated["pre_transition"]["expected_existing_target_version"] = TARGET_VERSION
    negatives.append(not validate_policy(mutated))
    checks["negative_controls"] = all(negatives) and len(negatives) == 6
    if not checks["negative_controls"]:
        failures.append("negative_controls")

    result = {
        "schema_version": 1,
        "status": "passed" if not failures else "failed",
        "authority": "nxb-v1-successor-independent-v1",
        "phase": policy.get("phase"),
        "predecessor_head": PREDECESSOR_HEAD,
        "predecessor_tree": PREDECESSOR_TREE,
        "head_sha": head,
        "target_version": TARGET_VERSION,
        "candidate_version": CANDIDATE_VERSION,
        "checks": checks,
        "target_versions": target_versions,
        "changed_paths": changed_paths,
        "disallowed_paths": disallowed_paths,
        "forbidden_artifacts": forbidden_artifacts,
        "private_key_hits": private_key_hits,
        "missing_documents": missing_documents,
        "negative_controls_validated": sum(bool(value) for value in negatives),
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
