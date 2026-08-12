#!/usr/bin/env python3
import argparse
import copy
import hashlib
import json
from pathlib import Path, PurePosixPath
from typing import Any, Dict, List, Tuple


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_text(text: str) -> str:
    return sha256_bytes(text.encode("utf-8"))


def file_sha256(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def load_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def lower_hex(value: Any, length: int) -> bool:
    text = str(value or "")
    return len(text) == length and all(c in "0123456789abcdef" for c in text)


def canonical_sha256(value: Any) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return sha256_text(payload)


def finding_id(item: Dict[str, Any]) -> str:
    material = "\n".join(
        [
            str(item["target_id"]),
            str(item["root_cause_key"]),
            str(item["class"]),
            str(item["evidence_sha256"]),
        ]
    )
    return "finding-" + sha256_text(material)[:32]


def validate_receipt_head(receipt: Dict[str, Any], head: str) -> bool:
    return receipt.get("status") == "passed" and receipt.get("head_sha") == head


def safe_package_path(text: str) -> PurePosixPath | None:
    if not text or "\\" in text:
        return None
    path = PurePosixPath(text)
    if path.is_absolute() or ".." in path.parts or "." in path.parts:
        return None
    return path


def validate_all(
    head: str,
    repository_root: Path,
    part6: Dict[str, Any],
    part7: Dict[str, Any],
    part8: Dict[str, Any],
    part9: Dict[str, Any],
    part10: Dict[str, Any],
    package: Dict[str, Any],
    evidence_index: Dict[str, Any],
    report: Dict[str, Any],
) -> Tuple[bool, List[str]]:
    failures: List[str] = []
    for name, receipt in [("part6", part6), ("part7", part7), ("part8", part8), ("part9", part9), ("part10", part10)]:
        if not validate_receipt_head(receipt, head):
            failures.append(f"{name}_authority_binding")

    if part6.get("findings_output") != 2 or part6.get("duplicate_suppressed") != 1:
        failures.append("part6_correlation_counts")
    if part6.get("severity_promoted") is not False:
        failures.append("part6_severity_boundary")
    if part6.get("target_session_binding") is not True or part6.get("orchestration_mode") != "bounded-authorized-session":
        failures.append("part6_target_session_binding")
    if part6.get("scope_authorized") is not True or part6.get("evidence_only") is not True or part6.get("destructive_validation_allowed") is not False:
        failures.append("part6_orchestration_safety")
    for item in part6.get("findings", []):
        hashes = sorted(set(str(x) for x in item.get("evidence_hashes", [])))
        aggregate = sha256_text("\n".join(hashes))
        if aggregate != item.get("evidence_sha256"):
            failures.append("part6_evidence_aggregate")
            break
        if finding_id(item) != item.get("finding_id"):
            failures.append("part6_finding_id")
            break
        if item.get("target_id") != part6.get("target_id") or item.get("session_id") != part6.get("session_id"):
            failures.append("part6_finding_session_escape")
            break

    if part7.get("loopback_native_probe") is not True:
        failures.append("part7_loopback_probe")
    if part7.get("production_secret_in_evidence") is not False:
        failures.append("part7_secret_boundary")
    if part7.get("permit_required_for_noncertification") is not True:
        failures.append("part7_permit_boundary")
    if part7.get("permit_target_binding") is not True or part7.get("permit_method_binding") is not True:
        failures.append("part7_permit_binding")
    if part7.get("kill_switch_required_for_noncertification") is not True:
        failures.append("part7_kill_switch")
    if part7.get("browser_api_session_boundary") is not True or part7.get("credential_reference_only") is not True:
        failures.append("part7_browser_api_boundary")
    session = part7.get("session_boundary", {})
    if session.get("read_only_default") is not True or session.get("secret_material_embedded") is not False:
        failures.append("part7_session_secret_boundary")
    if sorted(session.get("adapter_modes", [])) != ["browser", "http-api"]:
        failures.append("part7_adapter_modes")
    if not lower_hex(session.get("credential_reference_sha256"), 64):
        failures.append("part7_credential_reference")

    faults = part8.get("fault_matrix", [])
    if len(faults) < 5 or any(row.get("rejected") is not True for row in faults):
        failures.append("part8_fault_matrix")
    if part8.get("ps7_compatibility") is not True or part8.get("ps51_compatibility") is not True:
        failures.append("part8_dual_runtime")
    if int(part8.get("artifact_bytes", -1)) < 0:
        failures.append("part8_artifact_budget")

    if part9.get("staged_update_only") is not True or part9.get("auto_apply") is not False:
        failures.append("part9_update_boundary")
    if part9.get("staged_update_executed") is not True or int(part9.get("staged_file_count", -1)) != int(part9.get("package_file_count", -2)):
        failures.append("part9_staging_replay")
    if part9.get("unified_cli") is not True or part9.get("tamper_rejection") is not True or part9.get("deterministic_package_manifest") is not True:
        failures.append("part9_cli_or_tamper")
    if part9.get("autonomous_certification_workflow") is not True:
        failures.append("part9_autonomous_workflow")
    if package.get("staged_only") is not True or package.get("auto_apply") is not False:
        failures.append("part9_package_boundary")
    if package.get("exact_head") != head or package.get("version") != part10.get("release_version"):
        failures.append("part9_package_authority_binding")
    signer = str(package.get("signer_fingerprint_sha256", ""))
    if not lower_hex(signer, 64):
        failures.append("part9_signer_fingerprint")

    seen_paths = set()
    package_files = package.get("files", [])
    if len(package_files) < 15:
        failures.append("part9_package_cardinality")
    for row in package_files:
        relative = safe_package_path(str(row.get("path", "")))
        digest = str(row.get("sha256", ""))
        if relative is None or str(relative) in seen_paths:
            failures.append("part9_file_path")
            break
        seen_paths.add(str(relative))
        if not lower_hex(digest, 64):
            failures.append("part9_file_hash")
            break
        if int(row.get("bytes", -1)) < 0:
            failures.append("part9_file_size")
            break
        full = repository_root.joinpath(*relative.parts)
        if not full.is_file() or full.is_symlink():
            failures.append("part9_repository_file")
            break
        if file_sha256(full) != digest or full.stat().st_size != int(row.get("bytes", -1)):
            failures.append("part9_repository_rehash")
            break

    if part10.get("production_safety_gate") is not True:
        failures.append("part10_safety_gate")
    if part10.get("production_merge_performed") is not False:
        failures.append("part10_merge_boundary")
    if part10.get("v1_freeze_candidate") is not True:
        failures.append("part10_freeze")
    if int(part10.get("known_error_findings", -1)) != 0 or int(part10.get("analyzer_findings", -1)) != 0:
        failures.append("part10_zero_error_gate")
    if part10.get("independent_validation") is not True:
        failures.append("part10_independent_validation")

    if evidence_index.get("exact_head") != head:
        failures.append("evidence_index_head")
    if report.get("exact_head") != head or report.get("production_merge_performed") is not False:
        failures.append("report_boundary")
    if report.get("release_version") != part10.get("release_version"):
        failures.append("release_version_binding")

    return len(failures) == 0, failures


def run_negative_controls(head: str, repository_root: Path, objects: Dict[str, Dict[str, Any]]) -> List[Dict[str, Any]]:
    cases = []

    def case(name: str, key: str, mutate) -> None:
        clone = {k: copy.deepcopy(v) for k, v in objects.items()}
        mutate(clone[key])
        ok, _ = validate_all(
            head, repository_root,
            clone["part6"], clone["part7"], clone["part8"], clone["part9"], clone["part10"],
            clone["package"], clone["index"], clone["report"],
        )
        cases.append({"name": name, "rejected": not ok})

    case("part6_stale_head", "part6", lambda x: x.__setitem__("head_sha", "0" * 40))
    case("part6_severity_promoted", "part6", lambda x: x.__setitem__("severity_promoted", True))
    case("part7_secret_leak", "part7", lambda x: x.__setitem__("production_secret_in_evidence", True))
    case("part7_permit_disabled", "part7", lambda x: x.__setitem__("permit_required_for_noncertification", False))
    case("part8_fault_accepted", "part8", lambda x: x["fault_matrix"][0].__setitem__("rejected", False))
    case("part8_ps51_false", "part8", lambda x: x.__setitem__("ps51_compatibility", False))
    case("part9_auto_apply", "part9", lambda x: x.__setitem__("auto_apply", True))
    case("package_auto_apply", "package", lambda x: x.__setitem__("auto_apply", True))
    case("part10_merge_claim", "part10", lambda x: x.__setitem__("production_merge_performed", True))
    case("part10_known_error", "part10", lambda x: x.__setitem__("known_error_findings", 1))
    case("index_stale_head", "index", lambda x: x.__setitem__("exact_head", "f" * 40))
    case("report_merge_claim", "report", lambda x: x.__setitem__("production_merge_performed", True))
    return cases


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--repository-root", required=True)
    parser.add_argument("--part6", required=True)
    parser.add_argument("--part7", required=True)
    parser.add_argument("--part8", required=True)
    parser.add_argument("--part9", required=True)
    parser.add_argument("--part10", required=True)
    parser.add_argument("--package", required=True)
    parser.add_argument("--evidence-index", required=True)
    parser.add_argument("--report", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    repository_root = Path(args.repository_root).resolve()
    paths = {name: Path(getattr(args, name)) for name in ["part6", "part7", "part8", "part9", "part10", "package", "report"]}
    paths["index"] = Path(args.evidence_index)
    objects = {name: load_json(path) for name, path in paths.items()}

    passed, failures = validate_all(
        args.expected_head, repository_root,
        objects["part6"], objects["part7"], objects["part8"], objects["part9"], objects["part10"],
        objects["package"], objects["index"], objects["report"],
    )
    negatives = run_negative_controls(args.expected_head, repository_root, objects)
    negative_pass = all(row["rejected"] for row in negatives) and len(negatives) == 12

    result = {
        "schema_version": 1,
        "status": "passed" if passed and negative_pass else "failed",
        "expected_head": args.expected_head,
        "requirements_validated": 48 if passed else 0,
        "negative_controls_validated": sum(1 for row in negatives if row["rejected"]),
        "negative_controls": negatives,
        "failures": failures,
        "receipt_hashes": {name: file_sha256(path) for name, path in paths.items()},
        "canonical_report_sha256": canonical_sha256(objects["report"]),
    }
    Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0 if result["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
