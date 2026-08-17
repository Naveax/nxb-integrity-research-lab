#!/usr/bin/env python3
import argparse
import copy
import json
import re
from pathlib import Path
from typing import Any, Dict, List, Tuple

HEX40 = re.compile(r"^[0-9a-f]{40}$")
AUTHORITY = "nxb-v1-release-integration-preflight-v1"
CONTRACT = "nxb-v1-release-integration-v1"


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def allowed_path(path: str, prefixes: List[str]) -> bool:
    return bool(path) and "\\" not in path and not path.startswith("/") and ".." not in path.split("/") and any(
        path.startswith(prefix) for prefix in prefixes if prefix
    )


def validate(policy: Dict[str, Any], receipt: Dict[str, Any], expected_certified: str, expected_release: str) -> Tuple[List[str], Dict[str, bool]]:
    failures: List[str] = []
    checks: Dict[str, bool] = {}

    checks["policy_contract"] = policy.get("schema_version") == 1 and policy.get("contract_id") == CONTRACT
    checks["certified_head_binding"] = policy.get("certified_implementation_head") == expected_certified and receipt.get("certified_implementation_head") == expected_certified
    checks["release_head_binding"] = bool(HEX40.fullmatch(expected_release)) and receipt.get("release_head") == expected_release
    checks["version_boundary"] = policy.get("candidate_version") == "1.0.1-candidate" and policy.get("target_version") == "1.0.1" and receipt.get("candidate_version") == "1.0.1-candidate" and receipt.get("target_version") == "1.0.1"

    receipt_checks = receipt.get("checks") if isinstance(receipt.get("checks"), dict) else {}
    required_receipt_checks = [
        "clean_worktree",
        "certified_head_ancestor",
        "main_head_ancestor",
        "certified_runtime_unchanged",
        "successor_paths_allowed",
        "generated_artifacts_absent",
        "private_key_material_absent",
        "production_signer_separated",
        "candidate_version_preserved",
    ]
    checks["preflight_checks"] = receipt.get("status") == "passed" and receipt.get("authority") == AUTHORITY and all(receipt_checks.get(name) is True for name in required_receipt_checks)

    integration = policy.get("integration") if isinstance(policy.get("integration"), dict) else {}
    prefixes = [str(item) for item in integration.get("allowed_successor_paths", [])]
    suffixes = [str(item).lower() for item in integration.get("forbidden_artifact_suffixes", [])]
    changed = receipt.get("changed_paths") if isinstance(receipt.get("changed_paths"), list) else []
    checks["successor_path_boundary"] = bool(prefixes) and len(changed) == len(set(changed)) and all(allowed_path(str(path), prefixes) for path in changed)
    checks["artifact_boundary"] = all(not str(path).lower().endswith(tuple(suffixes)) for path in changed) if suffixes else False

    signing = policy.get("signing") if isinstance(policy.get("signing"), dict) else {}
    checks["production_signer_boundary"] = (
        signing.get("production_signer_required_for_release") is True
        and signing.get("certification_signer_reuse_allowed") is False
        and signing.get("private_key_in_repository_allowed") is False
        and signing.get("key_rotation_policy_required") is True
        and signing.get("revocation_policy_required") is True
    )

    release = policy.get("release") if isinstance(policy.get("release"), dict) else {}
    checks["release_requirements"] = all(
        release.get(name) is True
        for name in [
            "production_merge_required_before_v1_tag",
            "signed_release_manifest_required",
            "installer_or_package_hashes_required",
            "post_integration_smoke_required",
            "release_receipt_required",
        ]
    )

    failures_value = receipt.get("failures") if isinstance(receipt.get("failures"), list) else ["invalid"]
    checks["zero_failure_receipt"] = receipt.get("failure_count") == 0 and failures_value == []

    for name, passed in checks.items():
        if not passed:
            failures.append(name)
    return failures, checks


def negative_controls(policy: Dict[str, Any], receipt: Dict[str, Any], expected_certified: str, expected_release: str) -> Dict[str, bool]:
    results: Dict[str, bool] = {}

    mutated = copy.deepcopy(receipt)
    mutated["certified_implementation_head"] = "0" * 40
    errors, _ = validate(policy, mutated, expected_certified, expected_release)
    results["tampered_certified_head"] = "certified_head_binding" in errors

    mutated = copy.deepcopy(receipt)
    mutated.setdefault("changed_paths", []).append("scripts/nxb.ps1")
    errors, _ = validate(policy, mutated, expected_certified, expected_release)
    results["certified_runtime_change"] = "successor_path_boundary" in errors

    mutated = copy.deepcopy(receipt)
    mutated.setdefault("changed_paths", []).append("docs/NXB-V1-evidence.zip")
    errors, _ = validate(policy, mutated, expected_certified, expected_release)
    results["generated_zip_artifact"] = "artifact_boundary" in errors

    mutated_policy = copy.deepcopy(policy)
    mutated_policy.setdefault("signing", {})["certification_signer_reuse_allowed"] = True
    errors, _ = validate(mutated_policy, receipt, expected_certified, expected_release)
    results["certification_signer_reuse"] = "production_signer_boundary" in errors

    mutated = copy.deepcopy(receipt)
    mutated.setdefault("checks", {})["private_key_material_absent"] = False
    mutated["status"] = "failed"
    mutated["failure_count"] = 1
    mutated["failures"] = ["private_key_material"]
    errors, _ = validate(policy, mutated, expected_certified, expected_release)
    results["private_key_material"] = "preflight_checks" in errors and "zero_failure_receipt" in errors

    mutated = copy.deepcopy(receipt)
    mutated["target_version"] = "1.0.0"
    errors, _ = validate(policy, mutated, expected_certified, expected_release)
    results["version_drift"] = "version_boundary" in errors

    return results


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--receipt", required=True)
    parser.add_argument("--expected-certified-head", required=True)
    parser.add_argument("--expected-release-head", required=True)
    parser.add_argument("--output")
    args = parser.parse_args()

    expected_certified = args.expected_certified_head.lower()
    expected_release = args.expected_release_head.lower()
    if not HEX40.fullmatch(expected_certified) or not HEX40.fullmatch(expected_release):
        raise SystemExit("expected heads must be 40 lowercase hex characters")

    policy = load_json(Path(args.policy))
    receipt = load_json(Path(args.receipt))
    failures, requirements = validate(policy, receipt, expected_certified, expected_release)
    negatives = negative_controls(policy, receipt, expected_certified, expected_release)

    requirement_count = sum(1 for value in requirements.values() if value)
    negative_count = sum(1 for value in negatives.values() if value)
    status = "passed" if not failures and requirement_count == 10 and negative_count == 6 else "failed"

    document = {
        "schema_version": 1,
        "status": status,
        "authority": "independent-python-v1-release-integration-v1",
        "certified_implementation_head": expected_certified,
        "release_head": expected_release,
        "requirements": requirements,
        "requirements_validated": requirement_count,
        "negative_controls": negatives,
        "negative_controls_validated": negative_count,
        "failures": sorted(set(failures)),
    }

    text = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    print(json.dumps(document, sort_keys=True))
    return 0 if status == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
