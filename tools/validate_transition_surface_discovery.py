#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
FAMILY_PATTERNS = {
    "pnp": re.compile(r"(pnp|device|setup|install)", re.IGNORECASE),
    "power": re.compile(r"(power|energy|battery|processor)", re.IGNORECASE),
}


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    require(isinstance(value, dict), "discovery root must be object")
    return value


def ordinal_key(text: str) -> bytes:
    return text.encode("utf-8")


def validate_text(text: Any, path: str, allow_empty: bool = False) -> str:
    require(isinstance(text, str), f"{path} must be string")
    if not allow_empty:
        require(bool(text), f"{path} must be non-empty")
    require("\t" not in text and "\r" not in text and "\n" not in text and "|" not in text, f"{path} contains reserved delimiter")
    return text


def expected_families(provider_name: str) -> list[str]:
    values = [name for name, pattern in FAMILY_PATTERNS.items() if pattern.search(provider_name)]
    return sorted(set(values), key=ordinal_key)


def recompute_fingerprint(value: dict[str, Any]) -> str:
    lines = [
        f"binding\t{value['binding_fingerprint_sha256']}",
        f"metadata\t{value['provider_metadata_fingerprint_sha256']}",
    ]
    for provider in value["providers"]:
        lines.append(
            "P\t"
            + provider["provider_name"]
            + "\t"
            + provider["provider_guid"]
            + "\t"
            + "|".join(provider["families"])
            + "\t"
            + "|".join(provider["attached_logs"])
        )
    for surface in value["surfaces"]:
        enabled = "null" if surface["enabled"] is None else ("true" if surface["enabled"] else "false")
        reason = "" if surface["reason"] is None else surface["reason"]
        lines.append(
            "S\t"
            + surface["provider_name"]
            + "\t"
            + surface["provider_guid"]
            + "\t"
            + "|".join(surface["families"])
            + "\t"
            + surface["log_name"]
            + "\t"
            + surface["status"]
            + "\t"
            + enabled
            + "\t"
            + reason
        )
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()


def validate_discovery(value: dict[str, Any]) -> dict[str, Any]:
    require(
        set(value)
        == {
            "schema_version",
            "captured_utc",
            "binding_fingerprint_sha256",
            "provider_metadata_fingerprint_sha256",
            "discovery_fingerprint_sha256",
            "fingerprint_contract",
            "max_providers",
            "max_surfaces",
            "provider_count",
            "surface_count",
            "usable_surface_count",
            "providers",
            "surfaces",
            "claims",
        },
        "top-level keys invalid",
    )
    require(value["schema_version"] == 2, "schema_version must be 2")
    require(value["fingerprint_contract"] == "ordinal_tsv_v1", "fingerprint contract invalid")
    for name in ("binding_fingerprint_sha256", "provider_metadata_fingerprint_sha256", "discovery_fingerprint_sha256"):
        require(isinstance(value[name], str) and SHA256_RE.fullmatch(value[name]), f"{name} invalid")
    require(isinstance(value["max_providers"], int) and 8 <= value["max_providers"] <= 128, "max_providers invalid")
    require(isinstance(value["max_surfaces"], int) and 8 <= value["max_surfaces"] <= 256, "max_surfaces invalid")

    providers = value["providers"]
    require(isinstance(providers, list), "providers must be array")
    require(len(providers) == value["provider_count"], "provider_count mismatch")
    require(len(providers) <= value["max_providers"], "provider cap exceeded")
    provider_names: list[str] = []
    provider_map: dict[str, dict[str, Any]] = {}
    for index, provider in enumerate(providers):
        path = f"providers[{index}]"
        require(set(provider) == {"provider_name", "provider_guid", "families", "attached_logs"}, f"{path} keys invalid")
        name = validate_text(provider["provider_name"], f"{path}.provider_name")
        guid = validate_text(provider["provider_guid"], f"{path}.provider_guid", allow_empty=True)
        families = provider["families"]
        logs = provider["attached_logs"]
        require(isinstance(families, list) and all(isinstance(x, str) for x in families), f"{path}.families invalid")
        require(isinstance(logs, list) and all(isinstance(x, str) for x in logs), f"{path}.attached_logs invalid")
        require(families == sorted(set(families), key=ordinal_key), f"{path}.families not ordinal unique")
        require(logs == sorted(set(logs), key=ordinal_key), f"{path}.attached_logs not ordinal unique")
        require(families == expected_families(name), f"{path}.families do not match provider name")
        for log_index, log_name in enumerate(logs):
            validate_text(log_name, f"{path}.attached_logs[{log_index}]")
        provider_names.append(name)
        provider_map[name] = provider
        _ = guid
    require(provider_names == sorted(provider_names, key=ordinal_key), "providers not ordinal sorted")
    require(len(provider_names) == len(set(provider_names)), "provider names duplicated")

    surfaces = value["surfaces"]
    require(isinstance(surfaces, list), "surfaces must be array")
    require(len(surfaces) == value["surface_count"], "surface_count mismatch")
    require(len(surfaces) <= value["max_surfaces"], "surface cap exceeded")
    surface_keys: list[tuple[bytes, bytes]] = []
    usable = 0
    for index, surface in enumerate(surfaces):
        path = f"surfaces[{index}]"
        require(
            set(surface) == {"provider_name", "provider_guid", "families", "log_name", "status", "enabled", "reason"},
            f"{path} keys invalid",
        )
        name = validate_text(surface["provider_name"], f"{path}.provider_name")
        log_name = validate_text(surface["log_name"], f"{path}.log_name")
        require(name in provider_map, f"{path} provider missing from provider inventory")
        provider = provider_map[name]
        require(surface["provider_guid"] == provider["provider_guid"], f"{path}.provider_guid mismatch")
        require(surface["families"] == provider["families"], f"{path}.families mismatch")
        require(log_name in provider["attached_logs"], f"{path}.log not attached to provider")
        require(surface["status"] in {"available", "disabled", "unavailable"}, f"{path}.status invalid")
        require(surface["enabled"] is None or isinstance(surface["enabled"], bool), f"{path}.enabled invalid")
        require(surface["reason"] is None or isinstance(surface["reason"], str), f"{path}.reason invalid")
        if surface["status"] == "available":
            require(surface["enabled"] is True and surface["reason"] is None, f"{path} available state invalid")
            usable += 1
        elif surface["status"] == "disabled":
            require(surface["enabled"] is False and surface["reason"] == "log_disabled", f"{path} disabled state invalid")
        else:
            require(surface["reason"] == "list_log_failed", f"{path} unavailable reason invalid")
        surface_keys.append((ordinal_key(name), ordinal_key(log_name)))
    require(surface_keys == sorted(surface_keys), "surfaces not ordinal sorted")
    require(len(surface_keys) == len(set(surface_keys)), "surface pairs duplicated")
    require(usable == value["usable_surface_count"], "usable_surface_count mismatch")

    expected_claims = {
        "provider_name_family_discovery": True,
        "attached_log_discovery": True,
        "event_id_semantics": False,
        "device_lifecycle_semantics": False,
        "power_causality": False,
        "firmware_causality": False,
        "continuous_trace_completeness": "not_claimed",
    }
    require(value["claims"] == expected_claims, "claim boundary mismatch")

    recomputed = recompute_fingerprint(value)
    require(recomputed == value["discovery_fingerprint_sha256"], f"discovery fingerprint mismatch: expected={value['discovery_fingerprint_sha256']} recomputed={recomputed}")
    return {
        "status": "passed",
        "discovery_fingerprint_sha256": recomputed,
        "provider_count": len(providers),
        "surface_count": len(surfaces),
        "usable_surface_count": usable,
        "pnp_provider_count": sum("pnp" in item["families"] for item in providers),
        "power_provider_count": sum("power" in item["families"] for item in providers),
        "pnp_usable_surface_count": sum(item["status"] == "available" and "pnp" in item["families"] for item in surfaces),
        "power_usable_surface_count": sum(item["status"] == "available" and "power" in item["families"] for item in surfaces),
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate NXB SUPERBLOCK 2 L3 transition surface discovery")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        summary = validate_discovery(load_json(args.input))
    except (ValidationError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"NXB transition surface discovery validation failed: {exc}")
        return 1
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "NXB transition surface discovery validation passed: "
        f"providers={summary['provider_count']} surfaces={summary['surface_count']} usable={summary['usable_surface_count']} "
        f"pnp_usable={summary['pnp_usable_surface_count']} power_usable={summary['power_usable_surface_count']} "
        f"fingerprint={summary['discovery_fingerprint_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
