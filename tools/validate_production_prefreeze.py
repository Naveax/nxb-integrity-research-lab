#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import Any, Dict, List


def load(path: str) -> Dict[str, Any]:
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


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
    if part7.get("loopback_native_probe") is not True or part7.get("production_secret_in_evidence") is not False:
        failures.append("part7_active_validation_boundary")
    if part7.get("permit_required_for_noncertification") is not True or part7.get("kill_switch_required_for_noncertification") is not True:
        failures.append("part7_scope_boundary")
    if part8.get("ps7_compatibility") is not True or part8.get("ps51_compatibility") is not True:
        failures.append("part8_compatibility")
    if any(item.get("rejected") is not True for item in part8.get("fault_matrix", [])):
        failures.append("part8_fault_matrix")
    if part9.get("staged_update_only") is not True or part9.get("auto_apply") is not False:
        failures.append("part9_update_boundary")
    if part9.get("tamper_rejection") is not True or part9.get("unified_cli") is not True:
        failures.append("part9_supply_chain")

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
