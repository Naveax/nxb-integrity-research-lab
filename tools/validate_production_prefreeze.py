#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
from typing import Any, Dict, List


def load(path: str) -> Dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def lower_hex(value: Any, length: int) -> bool:
    text = str(value or "")
    return len(text) == length and all(c in "0123456789abcdef" for c in text)


def canonical_sha256(value: Any) -> str:
    payload = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def validate_part8_faults(part8: Dict[str, Any], expected_head: str) -> bool:
    base = part8.get("base_evidence", {})
    if base.get("head_sha") != expected_head:
        return False
    if not lower_hex(base.get("evidence_sha256"), 64) or not lower_hex(base.get("payload_sha256"), 64):
        return False
    if canonical_sha256(base) != part8.get("base_evidence_canonical_sha256"):
        return False
    rows = part8.get("fault_matrix", [])
    if len(rows) != 5:
        return False
    by_name = {str(row.get("name")): row for row in rows}
    expected_names = {"stale_head", "cross_session", "missing_evidence", "tampered_payload", "evidence_hash_mismatch"}
    if set(by_name) != expected_names:
        return False
    if any(row.get("rejected") is not True for row in rows):
        return False

    stale = by_name["stale_head"].get("mutation", {})
    if stale.get("head_sha") == expected_head or stale.get("session_id") != base.get("session_id") or stale.get("evidence_sha256") != base.get("evidence_sha256") or stale.get("payload_sha256") != base.get("payload_sha256"):
        return False

    cross = by_name["cross_session"].get("mutation", {})
    if cross.get("head_sha") != expected_head or cross.get("session_id") == base.get("session_id") or cross.get("evidence_sha256") != base.get("evidence_sha256") or cross.get("payload_sha256") != base.get("payload_sha256"):
        return False

    missing = by_name["missing_evidence"].get("mutation", {})
    if missing.get("head_sha") != expected_head or missing.get("session_id") != base.get("session_id") or missing.get("evidence_sha256") != "" or missing.get("payload_sha256") != base.get("payload_sha256"):
        return False

    tampered = by_name["tampered_payload"].get("mutation", {})
    if tampered.get("head_sha") != expected_head or tampered.get("session_id") != base.get("session_id") or tampered.get("evidence_sha256") != base.get("evidence_sha256") or tampered.get("payload_sha256") == base.get("payload_sha256") or canonical_sha256(tampered) == canonical_sha256(base):
        return False

    wrong_hash = by_name["evidence_hash_mismatch"].get("mutation", {})
    if wrong_hash.get("head_sha") != expected_head or wrong_hash.get("session_id") != base.get("session_id") or wrong_hash.get("evidence_sha256") == base.get("evidence_sha256") or wrong_hash.get("payload_sha256") != base.get("payload_sha256") or canonical_sha256(wrong_hash) == canonical_sha256(base):
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--part6", required=True)
    parser.add_argument("--part7", required=True)
    parser.add_argument("--part8", required=True)
    parser.add_argument("--part9", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    receipts = [load(args.part6), load(args.part7), load(args.part8), load(args.part9)]
    failures: List[str] = []
    for index, receipt in enumerate(receipts, start=6):
        if receipt.get("status") != "passed" or receipt.get("head_sha") != args.expected_head:
            failures.append(f"part{index}_authority_binding")

    part6, part7, part8, part9 = receipts
    if part6.get("findings_output") != 2 or part6.get("severity_promoted") is not False:
        failures.append("part6_finding_boundary")
    if part6.get("target_session_binding") is not True or part6.get("orchestration_mode") != "bounded-authorized-session":
        failures.append("part6_target_session_binding")
    if part6.get("scope_authorized") is not True or part6.get("evidence_only") is not True or part6.get("destructive_validation_allowed") is not False:
        failures.append("part6_orchestration_safety")

    if part7.get("loopback_native_probe") is not True or part7.get("production_secret_in_evidence") is not False:
        failures.append("part7_active_validation_boundary")
    if part7.get("permit_required_for_noncertification") is not True or part7.get("kill_switch_required_for_noncertification") is not True:
        failures.append("part7_scope_boundary")
    if part7.get("permit_target_binding") is not True or part7.get("permit_method_binding") is not True or part7.get("permit_canonical_hash_binding") is not True:
        failures.append("part7_permit_binding")
    if part7.get("browser_api_session_boundary") is not True or part7.get("credential_reference_only") is not True:
        failures.append("part7_browser_api_boundary")
    session = part7.get("session_boundary", {})
    if session.get("read_only_default") is not True or session.get("secret_material_embedded") is not False:
        failures.append("part7_session_secret_boundary")
    if sorted(session.get("adapter_modes", [])) != ["browser", "http-api"]:
        failures.append("part7_adapter_modes")
    if not lower_hex(session.get("credential_reference_sha256"), 64):
        failures.append("part7_credential_reference")

    if part8.get("ps7_compatibility") is not True or part8.get("ps51_compatibility") is not True:
        failures.append("part8_compatibility")
    if not validate_part8_faults(part8, args.expected_head):
        failures.append("part8_independent_fault_replay")
    if int(part8.get("artifact_bytes", -1)) < 0:
        failures.append("part8_artifact_budget")

    if part9.get("staged_update_only") is not True or part9.get("auto_apply") is not False:
        failures.append("part9_update_boundary")
    if part9.get("staged_update_executed") is not True or int(part9.get("staged_file_count", -1)) != int(part9.get("package_file_count", -2)):
        failures.append("part9_staging")
    if part9.get("tamper_rejection") is not True or part9.get("unified_cli") is not True or part9.get("deterministic_package_manifest") is not True:
        failures.append("part9_supply_chain")
    if part9.get("autonomous_certification_workflow") is not True:
        failures.append("part9_autonomous_workflow")

    result = {
        "schema_version": 1,
        "status": "passed" if not failures else "failed",
        "expected_head": args.expected_head,
        "parts_validated": 4 if not failures else 0,
        "requirements_validated": sum(int(r.get("requirements_validated", 0)) for r in receipts) if not failures else 0,
        "failures": failures,
    }
    Path(args.output).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
