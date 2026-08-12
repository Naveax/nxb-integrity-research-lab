#!/usr/bin/env python3
import argparse
import copy
import hashlib
import json
from pathlib import Path


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def load_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def is_lower_hex(text, length):
    return isinstance(text, str) and len(text) == length and all(ch in "0123456789abcdef" for ch in text)


def safe_relative(path):
    if not isinstance(path, str) or not path or path.startswith("/") or "\\" in path or "|" in path or "\r" in path or "\n" in path:
        return False
    if len(path) >= 2 and path[1] == ":" and path[0].isalpha():
        return False
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    return all(32 <= ord(ch) <= 126 for ch in path)


def validate_manifest(manifest, expected_head, max_files, max_bytes):
    failures = []
    if manifest.get("schema_version") != 1 or manifest.get("contract_id") != "nxb-v1-package-manifest-v1" or manifest.get("release_version") != "1.0.0":
        failures.append("manifest_identity")
    if manifest.get("source_head") != expected_head or not is_lower_hex(manifest.get("source_head"), 40):
        failures.append("manifest_head")
    files = manifest.get("files")
    if not isinstance(files, list) or not (1 <= len(files) <= max_files) or manifest.get("file_count") != len(files):
        failures.append("manifest_count")
        return failures
    seen = set()
    total = 0
    previous = None
    for row in files:
        path = row.get("path") if isinstance(row, dict) else None
        if not safe_relative(path) or path in seen:
            failures.append("manifest_path")
            break
        if previous is not None and not (previous < path):
            failures.append("manifest_order")
            break
        if not isinstance(row.get("bytes"), int) or row["bytes"] < 0 or not is_lower_hex(row.get("sha256"), 64):
            failures.append("manifest_row")
            break
        seen.add(path)
        previous = path
        total += row["bytes"]
        if total > max_bytes:
            failures.append("manifest_budget")
            break
    if manifest.get("total_bytes") != total:
        failures.append("manifest_total")
    return failures


def validate_package(package_root: Path, manifest):
    expected = {row["path"]: (row["bytes"], row["sha256"]) for row in manifest["files"]}
    actual = {}
    for path in sorted([p for p in package_root.rglob("*") if p.is_file()]):
        relative = path.relative_to(package_root).as_posix()
        actual[relative] = (path.stat().st_size, sha256_file(path))
    return actual == expected


def validate_receipt(receipt, action, mode, expected_head, manifest_sha):
    return (
        receipt.get("schema_version") == 1
        and receipt.get("status") == "passed"
        and receipt.get("authority") == "nxb-v1-installer-operation-v1"
        and receipt.get("action") == action
        and receipt.get("install_mode") == mode
        and receipt.get("release_version") == "1.0.0"
        and receipt.get("source_head") == expected_head
        and receipt.get("package_manifest_sha256") == manifest_sha
        and isinstance(receipt.get("files_verified"), int)
        and receipt.get("files_verified") >= 0
        and isinstance(receipt.get("bytes_verified"), int)
        and receipt.get("bytes_verified") >= 0
        and receipt.get("data_removed") is False
        and receipt.get("evidence_removed") is False
        and isinstance(receipt.get("rollback_used"), bool)
    )


def evaluate(policy, manifest, package_root, host, lifecycle, receipts, receipt_paths, expected_head):
    failures = []
    max_files = int(policy.get("maximum_files", 0))
    max_bytes = int(policy.get("maximum_package_bytes", 0))
    manifest_sha = sha256_file(receipt_paths["manifest"])

    checks = []
    checks.append(
        policy.get("schema_version") == 1
        and policy.get("contract_id") == "nxb-v1-installer-v1"
        and policy.get("predecessor_production_signing_head") == "91be58af59d0703de0159fea9d11935805e16022"
        and policy.get("certified_implementation_head") == "a10535b294c4d7ba8a4c3683154609087bf50c4b"
        and policy.get("target_version") == "1.0.0"
    )
    checks.append(
        policy.get("data_policy", {}).get("data_root_is_separate") is True
        and policy.get("data_policy", {}).get("uninstall_removes_data_by_default") is False
        and policy.get("data_policy", {}).get("uninstall_removes_evidence_by_default") is False
        and policy.get("operation_policy", {}).get("repair_atomic_replace_with_rollback") is True
        and policy.get("operation_policy", {}).get("post_copy_hash_verification") is True
    )
    checks.append(len(validate_manifest(manifest, expected_head, max_files, max_bytes)) == 0)
    checks.append([row["path"] for row in manifest["files"]] == sorted([row["path"] for row in manifest["files"]]))
    checks.append(validate_package(package_root, manifest))
    checks.append(
        host.get("status") == "passed"
        and host.get("windows") is True
        and host.get("powershell_core") is True
        and host.get("python_available") is True
    )
    checks.append(validate_receipt(receipts["stage"], "Stage", "Portable", expected_head, manifest_sha))
    checks.append(validate_receipt(receipts["install"], "Install", "PerUser", expected_head, manifest_sha))
    checks.append(lifecycle.get("corruption_detected") is True)
    checks.append(validate_receipt(receipts["repair"], "Repair", "PerUser", expected_head, manifest_sha) and lifecycle.get("repair_restored_bytes") is True)
    checks.append(validate_receipt(receipts["uninstall"], "Uninstall", "PerUser", expected_head, manifest_sha) and lifecycle.get("install_root_absent_after_uninstall") is True)
    checks.append(
        lifecycle.get("receipt_hashes", {}).get("stage") == sha256_file(receipt_paths["stage"])
        and lifecycle.get("receipt_hashes", {}).get("install") == sha256_file(receipt_paths["install"])
        and lifecycle.get("receipt_hashes", {}).get("repair") == sha256_file(receipt_paths["repair"])
        and lifecycle.get("receipt_hashes", {}).get("uninstall") == sha256_file(receipt_paths["uninstall"])
    )
    checks.append(
        lifecycle.get("data_preserved") is True
        and lifecycle.get("evidence_preserved") is True
        and lifecycle.get("machine_install_performed") is False
        and lifecycle.get("production_release_installed") is False
    )
    checks.append(
        lifecycle.get("schema_version") == 1
        and lifecycle.get("authority") == "nxb-v1-installer-lifecycle-v1"
        and lifecycle.get("source_head") == expected_head
        and lifecycle.get("package_manifest_sha256") == manifest_sha
        and lifecycle.get("host_preflight_passed") is True
        and lifecycle.get("portable_stage_passed") is True
        and lifecycle.get("per_user_install_passed") is True
        and lifecycle.get("repair_passed") is True
        and lifecycle.get("uninstall_passed") is True
    )
    for index, passed in enumerate(checks, start=1):
        if not passed:
            failures.append(f"requirement_{index}")
    return failures


def negative_controls(policy, manifest, package_root, host, lifecycle, receipts, receipt_paths, expected_head):
    controls = {}

    def rejected(mut_manifest=None, mut_lifecycle=None, mut_receipts=None):
        m = mut_manifest if mut_manifest is not None else manifest
        l = mut_lifecycle if mut_lifecycle is not None else lifecycle
        r = mut_receipts if mut_receipts is not None else receipts
        return len(evaluate(policy, m, package_root, host, l, r, receipt_paths, expected_head)) > 0

    duplicate = copy.deepcopy(manifest)
    duplicate["files"].append(copy.deepcopy(duplicate["files"][0]))
    duplicate["file_count"] = len(duplicate["files"])
    duplicate["total_bytes"] += duplicate["files"][-1]["bytes"]
    controls["duplicate_manifest_path"] = rejected(mut_manifest=duplicate)

    traversal = copy.deepcopy(manifest)
    traversal["files"][0]["path"] = "../escape.bin"
    controls["traversal_manifest_path"] = rejected(mut_manifest=traversal)

    unsorted = copy.deepcopy(manifest)
    if len(unsorted["files"]) >= 2:
        unsorted["files"][0], unsorted["files"][1] = unsorted["files"][1], unsorted["files"][0]
    controls["unsorted_manifest"] = rejected(mut_manifest=unsorted)

    bad_hash = copy.deepcopy(manifest)
    bad_hash["files"][0]["sha256"] = "0" * 64
    controls["tampered_file_hash"] = rejected(mut_manifest=bad_hash)

    bad_total = copy.deepcopy(manifest)
    bad_total["total_bytes"] += 1
    controls["wrong_total_bytes"] = rejected(mut_manifest=bad_total)

    stale_head = copy.deepcopy(manifest)
    stale_head["source_head"] = "0" * 40
    controls["stale_source_head"] = rejected(mut_manifest=stale_head)

    no_corruption = copy.deepcopy(lifecycle)
    no_corruption["corruption_detected"] = False
    controls["missing_corruption_detection"] = rejected(mut_lifecycle=no_corruption)

    machine_install = copy.deepcopy(lifecycle)
    machine_install["machine_install_performed"] = True
    controls["machine_install_claim"] = rejected(mut_lifecycle=machine_install)

    data_removed = copy.deepcopy(receipts)
    data_removed["uninstall"] = copy.deepcopy(data_removed["uninstall"])
    data_removed["uninstall"]["data_removed"] = True
    controls["uninstall_data_removal"] = rejected(mut_receipts=data_removed)

    wrong_manifest = copy.deepcopy(receipts)
    wrong_manifest["repair"] = copy.deepcopy(wrong_manifest["repair"])
    wrong_manifest["repair"]["package_manifest_sha256"] = "0" * 64
    controls["receipt_manifest_mismatch"] = rejected(mut_receipts=wrong_manifest)
    return controls


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--package-root", required=True)
    parser.add_argument("--host", required=True)
    parser.add_argument("--lifecycle", required=True)
    parser.add_argument("--stage-receipt", required=True)
    parser.add_argument("--install-receipt", required=True)
    parser.add_argument("--repair-receipt", required=True)
    parser.add_argument("--uninstall-receipt", required=True)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    paths = {
        "manifest": Path(args.manifest),
        "stage": Path(args.stage_receipt),
        "install": Path(args.install_receipt),
        "repair": Path(args.repair_receipt),
        "uninstall": Path(args.uninstall_receipt),
    }
    policy = load_json(Path(args.policy))
    manifest = load_json(paths["manifest"])
    host = load_json(Path(args.host))
    lifecycle = load_json(Path(args.lifecycle))
    receipts = {name: load_json(path) for name, path in paths.items() if name != "manifest"}
    package_root = Path(args.package_root)

    requirements_failures = evaluate(policy, manifest, package_root, host, lifecycle, receipts, paths, args.expected_head)
    controls = negative_controls(policy, manifest, package_root, host, lifecycle, receipts, paths, args.expected_head)
    negative_failures = [name for name, passed in controls.items() if not passed]
    failures = requirements_failures + negative_failures
    result = {
        "schema_version": 1,
        "status": "passed" if not failures else "failed",
        "authority": "nxb-v1-installer-independent-v1",
        "installer_head": args.expected_head,
        "requirement_count": 14,
        "requirements_validated": 14 - len(requirements_failures),
        "requirements_failures": requirements_failures,
        "negative_count": 10,
        "negative_controls_validated": 10 - len(negative_failures),
        "negative_controls": controls,
        "failures": failures,
    }
    Path(args.output).write_text(json.dumps(result, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    raise SystemExit(0 if not failures else 1)


if __name__ == "__main__":
    main()
