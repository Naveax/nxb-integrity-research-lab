#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Optional

CLAIMS = (
    "pnp_lifecycle_semantics",
    "pcie_bdf_semantics",
    "event_id_semantics",
    "event_task_opcode_semantics",
    "power_causality",
    "firmware_causality",
    "root_cause_validated",
    "continuous_trace_completeness",
)
STATUSES = ("validated", "failed", "unavailable")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
RECEIPT_ID = re.compile(r"^[a-z0-9][a-z0-9._-]{2,127}$")


def fail(message: str) -> None:
    raise SystemExit(message)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def require_object(value: Any, label: str, names: tuple[str, ...]) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    if set(value) != set(names):
        missing = sorted(set(names) - set(value))
        extra = sorted(set(value) - set(names))
        fail(f"{label} property set mismatch: missing={missing} extra={extra}")
    return value


def require_string(value: Any, label: str, minimum: int, maximum: int, single_line: bool = False) -> str:
    if not isinstance(value, str):
        fail(f"{label} must be a string")
    if len(value) < minimum or len(value) > maximum or not value.strip():
        fail(f"{label} length/content is invalid")
    if single_line and ("\r" in value or "\n" in value):
        fail(f"{label} must be single-line")
    return value


def require_integer(value: Any, label: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        fail(f"{label} must be an integer")
    if value < minimum or value > maximum:
        fail(f"{label} is outside the allowed range")
    return value


def require_boolean(value: Any, label: str) -> bool:
    if not isinstance(value, bool):
        fail(f"{label} must be boolean")
    return value


def require_hex(value: Any, label: str, pattern: re.Pattern[str]) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        fail(f"{label} has invalid lowercase hexadecimal form")
    return value


def parse_timestamp(value: Any, label: str) -> datetime:
    if not isinstance(value, str):
        fail(f"{label} must be a JSON string")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        fail(f"{label} is invalid: {exc}")
    if parsed.tzinfo is None:
        fail(f"{label} must contain timezone information")
    return parsed.astimezone(timezone.utc)


def canonical_material(receipt: dict[str, Any]) -> str:
    authority = receipt["authority"]
    machine = receipt["machine"]
    capture = receipt["capture"]
    evidence = receipt["evidence"]
    validation = receipt["validation"]

    scope_hash = sha256_text(capture["scope"])
    limitation_hash = sha256_text("\n".join(validation["limitations"]))
    lines = (
        "schema=1",
        f"receipt_id={receipt['receipt_id']}",
        f"claim_name={receipt['claim_name']}",
        f"status={receipt['status']}",
        f"repository={authority['repository']}",
        f"exact_head={authority['exact_head']}",
        f"policy_sha256={authority['policy_sha256']}",
        f"machine_id_sha256={machine['machine_id_sha256']}",
        f"scope_sha256={scope_hash}",
        f"source_kind={capture['source_kind']}",
        f"bounded_session_seconds={capture['bounded_session_seconds']}",
        f"artifact_count={evidence['artifact_count']}",
        f"artifact_index_sha256={evidence['artifact_index_sha256']}",
        f"negative_controls_passed={str(validation['negative_controls_passed']).lower()}",
        f"cleanup_verified={str(validation['cleanup_verified']).lower()}",
        f"independent_validation_passed={str(validation['independent_validation_passed']).lower()}",
        f"validator_name={validation['validator_name']}",
        f"validator_version={validation['validator_version']}",
        f"validator_implementation_sha256={validation['validator_implementation_sha256']}",
        f"limitations_sha256={limitation_hash}",
    )
    return "\n".join(lines)


def validate_receipt(
    path: Path,
    expected_head: str,
    expected_policy_sha256: str,
    expected_repository: str,
    expected_machine_id_sha256: Optional[str],
) -> dict[str, Any]:
    raw = path.read_bytes()
    try:
        receipt = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"semantic receipt is not valid UTF-8 JSON: {exc}")

    receipt = require_object(
        receipt,
        "receipt",
        (
            "schema_version",
            "receipt_id",
            "claim_name",
            "status",
            "authority",
            "machine",
            "capture",
            "evidence",
            "validation",
            "receipt_fingerprint_sha256",
        ),
    )
    authority = require_object(receipt["authority"], "authority", ("repository", "exact_head", "policy_sha256"))
    machine = require_object(receipt["machine"], "machine", ("machine_id_sha256",))
    capture = require_object(
        receipt["capture"],
        "capture",
        ("scope", "source_kind", "started_utc", "ended_utc", "bounded_session_seconds"),
    )
    evidence = require_object(receipt["evidence"], "evidence", ("artifact_count", "artifact_index_sha256"))
    validation = require_object(
        receipt["validation"],
        "validation",
        (
            "negative_controls_passed",
            "cleanup_verified",
            "independent_validation_passed",
            "validator_name",
            "validator_version",
            "validator_implementation_sha256",
            "limitations",
        ),
    )

    if isinstance(receipt["schema_version"], bool) or receipt["schema_version"] != 1:
        fail("schema_version must be integer 1")

    receipt_id = require_string(receipt["receipt_id"], "receipt_id", 3, 128, True)
    if RECEIPT_ID.fullmatch(receipt_id) is None:
        fail("receipt_id format is invalid")

    claim = require_string(receipt["claim_name"], "claim_name", 1, 128, True)
    if claim not in CLAIMS:
        fail(f"unknown semantic claim: {claim}")

    status = require_string(receipt["status"], "status", 1, 32, True)
    if status not in STATUSES:
        fail(f"unknown semantic receipt status: {status}")

    repository = require_string(authority["repository"], "authority.repository", 3, 256, True)
    if repository != expected_repository:
        fail(f"repository mismatch: expected={expected_repository} actual={repository}")

    exact_head = require_hex(authority["exact_head"], "authority.exact_head", HEX40)
    if exact_head != expected_head:
        fail(f"exact-head mismatch: expected={expected_head} actual={exact_head}")

    policy_hash = require_hex(authority["policy_sha256"], "authority.policy_sha256", HEX64)
    if policy_hash != expected_policy_sha256:
        fail(f"policy mismatch: expected={expected_policy_sha256} actual={policy_hash}")

    machine_hash = require_hex(machine["machine_id_sha256"], "machine.machine_id_sha256", HEX64)
    if expected_machine_id_sha256 is not None:
        if HEX64.fullmatch(expected_machine_id_sha256) is None:
            fail("expected machine id must be lowercase 64-hex")
        if machine_hash != expected_machine_id_sha256:
            fail(f"machine mismatch: expected={expected_machine_id_sha256} actual={machine_hash}")

    require_string(capture["scope"], "capture.scope", 1, 2048)
    require_string(capture["source_kind"], "capture.source_kind", 1, 128, True)
    bounded_seconds = require_integer(capture["bounded_session_seconds"], "capture.bounded_session_seconds", 1, 86400)
    started = parse_timestamp(capture["started_utc"], "capture.started_utc")
    ended = parse_timestamp(capture["ended_utc"], "capture.ended_utc")
    if ended <= started:
        fail("capture end must be after capture start")
    observed_seconds = (ended - started).total_seconds()
    if observed_seconds > bounded_seconds + 0.001:
        fail(f"observed duration exceeds bound: observed={observed_seconds} bounded={bounded_seconds}")

    artifact_count = require_integer(evidence["artifact_count"], "evidence.artifact_count", 0, 1_000_000)
    require_hex(evidence["artifact_index_sha256"], "evidence.artifact_index_sha256", HEX64)

    negative_controls = require_boolean(validation["negative_controls_passed"], "validation.negative_controls_passed")
    cleanup_verified = require_boolean(validation["cleanup_verified"], "validation.cleanup_verified")
    independent_validation = require_boolean(
        validation["independent_validation_passed"], "validation.independent_validation_passed"
    )
    require_string(validation["validator_name"], "validation.validator_name", 1, 128, True)
    require_string(validation["validator_version"], "validation.validator_version", 1, 64, True)
    require_hex(
        validation["validator_implementation_sha256"],
        "validation.validator_implementation_sha256",
        HEX64,
    )

    limitations = validation["limitations"]
    if not isinstance(limitations, list):
        fail("validation.limitations must be an array")
    if len(limitations) > 64:
        fail("validation.limitations exceeds 64 entries")
    for index, limitation in enumerate(limitations):
        require_string(limitation, f"validation.limitations[{index}]", 1, 256, True)

    promotable = status == "validated"
    if promotable:
        if artifact_count < 1:
            fail("validated receipt requires at least one evidence artifact")
        if not negative_controls:
            fail("validated receipt requires negative controls to pass")
        if not cleanup_verified:
            fail("validated receipt requires cleanup verification")
        if not independent_validation:
            fail("validated receipt requires independent validation")

    fingerprint = require_hex(receipt["receipt_fingerprint_sha256"], "receipt_fingerprint_sha256", HEX64)
    computed_fingerprint = sha256_text(canonical_material(receipt))
    if fingerprint != computed_fingerprint:
        fail(f"receipt fingerprint mismatch: expected={fingerprint} computed={computed_fingerprint}")

    return {
        "schema_version": 1,
        "status": "passed",
        "promotable": promotable,
        "claim_name": claim,
        "receipt_id": receipt_id,
        "repository": repository,
        "exact_head": exact_head,
        "policy_sha256": policy_hash,
        "machine_id_sha256": machine_hash,
        "artifact_count": artifact_count,
        "receipt_fingerprint_sha256": computed_fingerprint,
        "receipt_file_sha256": hashlib.sha256(raw).hexdigest(),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description="Validate an NXB semantic evidence receipt independently.")
    parser.add_argument("receipt", type=Path)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--expected-policy-sha256", required=True)
    parser.add_argument("--expected-repository", default="Naveax/nxb-integrity-research-lab")
    parser.add_argument("--expected-machine-id-sha256")
    args = parser.parse_args()

    if HEX40.fullmatch(args.expected_head) is None:
        fail("--expected-head must be lowercase 40-hex")
    if HEX64.fullmatch(args.expected_policy_sha256) is None:
        fail("--expected-policy-sha256 must be lowercase 64-hex")

    result = validate_receipt(
        args.receipt,
        args.expected_head,
        args.expected_policy_sha256,
        args.expected_repository,
        args.expected_machine_id_sha256,
    )
    print(json.dumps(result, sort_keys=True, separators=(",", ":")))


if __name__ == "__main__":
    main()
