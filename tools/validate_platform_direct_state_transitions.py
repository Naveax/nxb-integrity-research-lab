#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    require(isinstance(value, dict), "root must be object")
    return value


def require_sha(value: Any, path: str) -> str:
    require(isinstance(value, str) and SHA256_RE.fullmatch(value) is not None, f"{path} must be lowercase SHA-256")
    return value


def recompute_inventory_fingerprint(record_hashes: list[str]) -> str:
    return hashlib.sha256("\n".join(record_hashes).encode("utf-8")).hexdigest()


def validate_snapshot(value: Any, path: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{path} must be object")
    require(set(value) == {"device_count", "record_hashes", "inventory_fingerprint_sha256"}, f"{path} keys invalid")
    require(isinstance(value["device_count"], int) and value["device_count"] >= 1, f"{path}.device_count invalid")
    hashes = value["record_hashes"]
    require(isinstance(hashes, list), f"{path}.record_hashes must be array")
    require(len(hashes) == value["device_count"], f"{path}.device_count mismatch")
    for index, item in enumerate(hashes):
        require_sha(item, f"{path}.record_hashes[{index}]")
    require(hashes == sorted(hashes), f"{path}.record_hashes must be sorted")
    fingerprint = require_sha(value["inventory_fingerprint_sha256"], f"{path}.inventory_fingerprint_sha256")
    recomputed = recompute_inventory_fingerprint(hashes)
    require(recomputed == fingerprint, f"{path} inventory fingerprint mismatch")
    return {"device_count": len(hashes), "inventory_fingerprint_sha256": recomputed}


def validate_pnp_repeat(value: Any, path: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{path} must be object")
    expected = {
        "repeat",
        "stimulus",
        "exit_code",
        "succeeded",
        "before",
        "after",
        "inventory_stable",
        "device_disable_used",
        "device_remove_used",
        "device_install_used",
    }
    require(set(value) == expected, f"{path} keys invalid")
    require(value["repeat"] in {"A", "B"}, f"{path}.repeat invalid")
    require(value["stimulus"] == "pnputil_scan_devices", f"{path}.stimulus invalid")
    require(value["exit_code"] == 0 and value["succeeded"] is True, f"{path} rescan not successful")
    require(value["device_disable_used"] is False, f"{path} device disable boundary violated")
    require(value["device_remove_used"] is False, f"{path} device remove boundary violated")
    require(value["device_install_used"] is False, f"{path} device install boundary violated")
    before = validate_snapshot(value["before"], f"{path}.before")
    after = validate_snapshot(value["after"], f"{path}.after")
    stable = before["inventory_fingerprint_sha256"] == after["inventory_fingerprint_sha256"]
    require(value["inventory_stable"] is stable, f"{path}.inventory_stable mismatch")
    return {"repeat": value["repeat"], "inventory_stable": stable}


def validate_power_repeat(value: Any, path: str) -> dict[str, Any]:
    require(isinstance(value, dict), f"{path} must be object")
    expected = {
        "repeat",
        "stimulus",
        "original_scheme_guid_sha256",
        "temporary_scheme_guid_sha256",
        "before_active_scheme_guid_sha256",
        "during_active_scheme_guid_sha256",
        "restored_active_scheme_guid_sha256",
        "temporary_scheme_created",
        "temporary_scheme_activated",
        "original_scheme_restored",
        "temporary_scheme_deleted",
        "succeeded",
        "firmware_state_changed",
        "secure_boot_changed",
        "tpm_state_changed",
        "device_guard_changed",
    }
    require(set(value) == expected, f"{path} keys invalid")
    require(value["repeat"] in {"A", "B"}, f"{path}.repeat invalid")
    require(value["stimulus"] == "temporary_power_scheme_direct_state", f"{path}.stimulus invalid")
    original = require_sha(value["original_scheme_guid_sha256"], f"{path}.original_scheme_guid_sha256")
    temporary = require_sha(value["temporary_scheme_guid_sha256"], f"{path}.temporary_scheme_guid_sha256")
    before = require_sha(value["before_active_scheme_guid_sha256"], f"{path}.before_active_scheme_guid_sha256")
    during = require_sha(value["during_active_scheme_guid_sha256"], f"{path}.during_active_scheme_guid_sha256")
    restored = require_sha(value["restored_active_scheme_guid_sha256"], f"{path}.restored_active_scheme_guid_sha256")
    require(original != temporary, f"{path} temporary scheme must differ from original")
    require(before == original, f"{path} before state not original")
    require(during == temporary, f"{path} during state not temporary")
    require(restored == original, f"{path} restored state not original")
    for name in ("temporary_scheme_created", "temporary_scheme_activated", "original_scheme_restored", "temporary_scheme_deleted", "succeeded"):
        require(value[name] is True, f"{path}.{name} must be true")
    for name in ("firmware_state_changed", "secure_boot_changed", "tpm_state_changed", "device_guard_changed"):
        require(value[name] is False, f"{path}.{name} boundary violated")
    return {"repeat": value["repeat"], "mapping_valid": True}


def validate(value: dict[str, Any]) -> dict[str, Any]:
    require(
        set(value)
        == {
            "schema_version",
            "captured_utc",
            "binding_fingerprint_sha256",
            "provider_metadata_fingerprint_sha256",
            "l3_review_zip_sha256",
            "pnp",
            "power",
            "claims",
        },
        "top-level keys invalid",
    )
    require(value["schema_version"] == 1, "schema_version must be 1")
    for name in ("binding_fingerprint_sha256", "provider_metadata_fingerprint_sha256", "l3_review_zip_sha256"):
        require_sha(value[name], name)

    pnp = value["pnp"]
    require(isinstance(pnp, dict), "pnp must be object")
    require(set(pnp) == {"repeat_count", "execution_validated", "inventory_stable_both", "repeats"}, "pnp keys invalid")
    require(pnp["repeat_count"] == 2, "pnp.repeat_count must be 2")
    require(isinstance(pnp["repeats"], list) and len(pnp["repeats"]) == 2, "pnp.repeats invalid")
    pnp_results = [validate_pnp_repeat(item, f"pnp.repeats[{index}]") for index, item in enumerate(pnp["repeats"])]
    require([item["repeat"] for item in pnp_results] == ["A", "B"], "pnp repeats must be A then B")
    require(pnp["execution_validated"] is True, "pnp.execution_validated must be true")
    stable_both = all(item["inventory_stable"] for item in pnp_results)
    require(pnp["inventory_stable_both"] is stable_both, "pnp.inventory_stable_both mismatch")

    power = value["power"]
    require(isinstance(power, dict), "power must be object")
    require(set(power) == {"repeat_count", "direct_state_mapping_validated", "repeats"}, "power keys invalid")
    require(power["repeat_count"] == 2, "power.repeat_count must be 2")
    require(isinstance(power["repeats"], list) and len(power["repeats"]) == 2, "power.repeats invalid")
    power_results = [validate_power_repeat(item, f"power.repeats[{index}]") for index, item in enumerate(power["repeats"])]
    require([item["repeat"] for item in power_results] == ["A", "B"], "power repeats must be A then B")
    require(power["direct_state_mapping_validated"] is True, "power.direct_state_mapping_validated must be true")

    expected_claims = {
        "pnp_rescan_execution_validated": True,
        "pnp_devnode_inventory_stability_observed": stable_both,
        "pnp_lifecycle_semantics": False,
        "power_policy_transition_mapping": True,
        "power_causality": False,
        "firmware_causality": False,
        "raw_pnp_identifier_exposed": False,
        "continuous_trace_completeness": "not_claimed",
    }
    require(value["claims"] == expected_claims, "claim boundary mismatch")

    return {
        "status": "passed",
        "pnp_repeat_count": 2,
        "pnp_inventory_stable_both": stable_both,
        "power_repeat_count": 2,
        "power_policy_transition_mapping": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate NXB SUPERBLOCK 2 L4 direct-state transition evidence")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        summary = validate(load_json(args.input))
    except (ValidationError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"NXB L4 direct-state validation failed: {exc}")
        return 1
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "NXB L4 direct-state validation passed: "
        f"pnp_stable={summary['pnp_inventory_stable_both']} "
        f"power_mapping={summary['power_policy_transition_mapping']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
