#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
RAW_PNP_RE = re.compile(r"(?i)(?:PCI|USB|HID|ACPI|ROOT|SWD|BTH|DISPLAY)\\")
EXPECTED_PROVIDERS = {
    "Microsoft-Windows-Kernel-PnP",
    "Microsoft-Windows-UserPnp",
    "Microsoft-Windows-WHEA-Logger",
    "Microsoft-Windows-Kernel-Power",
    "Microsoft-Windows-Kernel-Processor-Power",
    "Microsoft-Windows-Kernel-Boot",
    "Microsoft-Windows-CodeIntegrity",
    "Microsoft-Windows-DeviceGuard",
}
STATUS_VALUES = {"available", "partial", "unavailable", "failed"}


class ValidationError(RuntimeError):
    pass


def fail(message: str) -> None:
    raise ValidationError(message)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except Exception as exc:  # pragma: no cover - surfaced to operator
        fail(f"invalid JSON: {exc}")
    require(isinstance(value, dict), "snapshot root must be an object")
    return value


def canonical_json(value: Any) -> str:
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def validate_status_block(block: Any, path: str) -> dict[str, Any]:
    require(isinstance(block, dict), f"{path} must be an object")
    require(set(block.keys()) == {"status", "data", "reason"}, f"{path} keys are not canonical")
    status = block["status"]
    require(status in STATUS_VALUES, f"{path}.status invalid: {status!r}")
    reason = block["reason"]
    require(reason is None or (isinstance(reason, str) and reason), f"{path}.reason invalid")
    if status == "available":
        require(block["data"] is not None, f"{path}.data must be present when available")
        require(reason is None, f"{path}.reason must be null when available")
    elif status in {"unavailable", "failed"}:
        require(reason is not None, f"{path}.reason required when {status}")
    return block


def walk(value: Any, path: str = "$"):
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, f"{path}[{index}]")


def validate_no_raw_identifiers(snapshot: dict[str, Any]) -> None:
    forbidden_keys = {
        "serial_number",
        "pnp_device_id",
        "computer_name",
        "machine_uuid",
        "raw_machine_id",
        "raw_device_id",
    }
    for path, value in walk(snapshot):
        if isinstance(value, dict):
            for key in value:
                require(key not in forbidden_keys, f"forbidden raw identifier key at {path}.{key}")
        elif isinstance(value, str):
            require(RAW_PNP_RE.search(value) is None, f"raw PnP identifier-like value exposed at {path}")


def validate_counts(snapshot: dict[str, Any]) -> None:
    devices = snapshot["bindings"]["devices"]
    pnp = validate_status_block(devices["pnp_entities"], "bindings.devices.pnp_entities")
    if pnp["status"] == "available":
        data = pnp["data"]
        require(isinstance(data, dict), "PnP data must be object")
        records = data.get("records")
        require(isinstance(records, list), "PnP records must be array")
        require(data.get("total_count") == len(records), "PnP total_count mismatch")
        require(data.get("pci_count") == sum(1 for item in records if item.get("is_pci") is True), "PnP pci_count mismatch")
        require(
            data.get("problem_count") == sum(1 for item in records if item.get("config_manager_error_code") != 0),
            "PnP problem_count mismatch",
        )
        hashes = []
        for index, item in enumerate(records):
            digest = item.get("device_id_sha256")
            require(isinstance(digest, str) and SHA256_RE.fullmatch(digest), f"PnP record {index} hash invalid")
            hashes.append(digest)
            for path_hash in item.get("location_path_sha256", []):
                require(isinstance(path_hash, str) and SHA256_RE.fullmatch(path_hash), f"PnP location hash invalid at {index}")
        require(hashes == sorted(hashes), "PnP records must be deterministically sorted")

    signed = validate_status_block(devices["signed_drivers"], "bindings.devices.signed_drivers")
    if signed["status"] == "available":
        data = signed["data"]
        records = data.get("records")
        require(isinstance(records, list), "signed driver records must be array")
        require(data.get("emitted_count") == len(records), "signed driver emitted_count mismatch")
        require(data.get("total_count", -1) >= len(records), "signed driver total_count invalid")
        require(data.get("truncated") is (data.get("total_count") > len(records)), "signed driver truncated flag mismatch")
        for item in records:
            digest = item.get("device_id_sha256")
            require(isinstance(digest, str) and SHA256_RE.fullmatch(digest), "signed driver device hash invalid")

    validate_status_block(devices["system_drivers"], "bindings.devices.system_drivers")
    validate_status_block(devices["pci_property_enrichment"], "bindings.devices.pci_property_enrichment")


def validate_snapshot(snapshot: dict[str, Any]) -> dict[str, Any]:
    expected_top = {
        "schema_version",
        "captured_utc",
        "identity",
        "bindings",
        "volatile_state",
        "event_sources",
        "binding_fingerprint_sha256",
        "claims",
        "collection_errors",
    }
    require(set(snapshot.keys()) == expected_top, "top-level keys are not canonical")
    require(snapshot["schema_version"] == 1, "schema_version must be 1")

    identity = snapshot["identity"]
    require(isinstance(identity, dict), "identity must be object")
    machine_hash = identity.get("machine_id_sha256")
    require(isinstance(machine_hash, str) and SHA256_RE.fullmatch(machine_hash), "machine_id_sha256 invalid")
    require(identity.get("machine_id_source") in {"computer_system_product_uuid", "computer_name_fallback"}, "machine_id_source invalid")
    require(isinstance(identity.get("boot_utc"), str) and identity["boot_utc"], "boot_utc missing")
    require(isinstance(identity.get("os_version"), str) and identity["os_version"], "os_version missing")
    require(isinstance(identity.get("os_build"), str) and identity["os_build"], "os_build missing")

    bindings = snapshot["bindings"]
    require(set(bindings.keys()) == {"devices", "power", "firmware_security"}, "bindings keys invalid")
    validate_counts(snapshot)
    validate_status_block(bindings["power"]["active_power_scheme"], "bindings.power.active_power_scheme")
    for name in ("bios", "secure_boot", "tpm", "device_guard", "virtualization", "boot_configuration"):
        validate_status_block(bindings["firmware_security"][name], f"bindings.firmware_security.{name}")

    volatile = snapshot["volatile_state"]
    require(set(volatile.keys()) == {"processor_clock", "battery", "thermal_zones"}, "volatile_state keys invalid")
    for name in ("processor_clock", "battery", "thermal_zones"):
        validate_status_block(volatile[name], f"volatile_state.{name}")

    event_sources = snapshot["event_sources"]
    require(isinstance(event_sources, list), "event_sources must be array")
    provider_names = [item.get("provider_name") for item in event_sources]
    require(set(provider_names) == EXPECTED_PROVIDERS, "event source provider set mismatch")
    require(len(provider_names) == len(EXPECTED_PROVIDERS), "event source providers must be unique")
    require(provider_names == sorted(provider_names), "event source providers must be sorted")
    available_provider_count = 0
    for item in event_sources:
        require(set(item.keys()) == {"provider_name", "status", "provider_guid", "logs"}, "event source keys invalid")
        require(item["status"] in {"available", "unavailable"}, "event source status invalid")
        require(isinstance(item["logs"], list), "event source logs must be array")
        require(item["logs"] == sorted(set(item["logs"])), "event source logs must be sorted and unique")
        if item["status"] == "available":
            available_provider_count += 1

    claims = snapshot["claims"]
    expected_claims = {
        "raw_machine_identifier_exposed",
        "raw_pnp_identifier_exposed",
        "serial_number_exposed",
        "volatile_state_in_binding_fingerprint",
        "pcie_bdf_semantics",
        "device_lifecycle_semantics",
        "thermal_representativeness",
        "power_causality",
        "firmware_causality",
        "root_cause_validated",
    }
    require(set(claims.keys()) == expected_claims, "claim keys invalid")
    for name in expected_claims:
        require(claims[name] is False, f"claim unexpectedly promoted: {name}")

    errors = snapshot["collection_errors"]
    require(isinstance(errors, list), "collection_errors must be array")
    for item in errors:
        require(set(item.keys()) == {"domain", "error_type"}, "collection error keys invalid")
        require(isinstance(item["domain"], str) and item["domain"], "collection error domain invalid")
        require(isinstance(item["error_type"], str) and item["error_type"], "collection error type invalid")

    validate_no_raw_identifiers(snapshot)

    fingerprint = snapshot["binding_fingerprint_sha256"]
    require(isinstance(fingerprint, str) and SHA256_RE.fullmatch(fingerprint), "binding fingerprint invalid")
    fingerprint_material = {
        "identity": snapshot["identity"],
        "bindings": snapshot["bindings"],
        "event_sources": snapshot["event_sources"],
    }
    recomputed = sha256_text(canonical_json(fingerprint_material))
    require(recomputed == fingerprint, f"binding fingerprint mismatch: expected={fingerprint} recomputed={recomputed}")

    pnp_data = bindings["devices"]["pnp_entities"].get("data") or {}
    return {
        "status": "passed",
        "binding_fingerprint_sha256": fingerprint,
        "machine_id_sha256": machine_hash,
        "boot_utc": identity["boot_utc"],
        "pnp_device_count": int(pnp_data.get("total_count", 0)),
        "pci_device_count": int(pnp_data.get("pci_count", 0)),
        "available_event_provider_count": available_provider_count,
        "collection_error_count": len(errors),
        "raw_identifier_scan_passed": True,
        "semantic_claims_promoted": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate an NXB platform binding snapshot")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    try:
        summary = validate_snapshot(load_json(args.input))
    except ValidationError as exc:
        print(f"NXB platform binding validation failed: {exc}")
        return 1

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "NXB platform binding validation passed: "
        f"fingerprint={summary['binding_fingerprint_sha256']} "
        f"pnp={summary['pnp_device_count']} pci={summary['pci_device_count']} "
        f"providers={summary['available_event_provider_count']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
