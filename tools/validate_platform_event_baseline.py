#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any

SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
EXPECTED_GUIDS = {
    "Microsoft-Windows-CodeIntegrity": "4ee76bd8-3cf4-44a0-a0ac-3937643e37a3",
    "Microsoft-Windows-DeviceGuard": "f717d024-f5b4-4f03-9ab9-331b2dc38ffb",
    "Microsoft-Windows-Kernel-Boot": "15ca44ff-4d7a-4baa-bba5-0998955e531e",
    "Microsoft-Windows-Kernel-PnP": "9c205a39-1250-487d-abd7-e831c6290539",
    "Microsoft-Windows-Kernel-Power": "331c3b3a-2005-44c2-ac5e-77220c37d6b4",
    "Microsoft-Windows-Kernel-Processor-Power": "0f67e49f-fe51-4e9f-b490-6f2948cc6027",
    "Microsoft-Windows-UserPnp": "96f4a050-7e31-453c-88be-9634f4e02139",
    "Microsoft-Windows-WHEA-Logger": "c26c4f3c-3f66-4e99-8f8a-39405cfed220",
}
FORBIDDEN_KEYS = {
    "message",
    "xml",
    "payload",
    "properties",
    "event_data",
    "user_data",
    "raw_event",
    "raw_xml",
    "raw_message",
}


class ValidationError(RuntimeError):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    require(isinstance(value, dict), "baseline root must be an object")
    return value


def walk(value: Any, path: str = "$"):
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from walk(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from walk(child, f"{path}[{index}]")


def validate_no_raw_event_content(value: dict[str, Any]) -> None:
    for path, node in walk(value):
        if isinstance(node, dict):
            for key in node:
                require(key.lower() not in FORBIDDEN_KEYS, f"forbidden raw event field at {path}.{key}")


def definition_sort_key(item: dict[str, Any]) -> tuple[Any, ...]:
    return (
        item["id"],
        item["version"],
        item["level"] or "",
        item["task"] or "",
        item["opcode"] or "",
    )


def shape_sort_key(item: dict[str, Any]) -> tuple[Any, ...]:
    return (
        item["id"],
        item["version"],
        item["level"],
        item["task"],
        item["opcode"],
    )


def validate_definition(item: Any, path: str) -> None:
    require(isinstance(item, dict), f"{path} must be an object")
    require(set(item) == {"id", "version", "level", "task", "opcode", "keywords"}, f"{path} keys invalid")
    require(isinstance(item["id"], int) and item["id"] >= 0, f"{path}.id invalid")
    require(isinstance(item["version"], int) and item["version"] >= 0, f"{path}.version invalid")
    for name in ("level", "task", "opcode"):
        require(item[name] is None or isinstance(item[name], str), f"{path}.{name} invalid")
    require(isinstance(item["keywords"], list), f"{path}.keywords must be array")
    require(item["keywords"] == sorted(set(item["keywords"])), f"{path}.keywords must be sorted unique")
    require(all(isinstance(value, str) and value for value in item["keywords"]), f"{path}.keywords invalid")


def validate_shape(item: Any, path: str) -> None:
    require(isinstance(item, dict), f"{path} must be an object")
    require(set(item) == {"id", "version", "level", "task", "opcode", "count"}, f"{path} keys invalid")
    require(isinstance(item["id"], int) and item["id"] >= 0, f"{path}.id invalid")
    require(isinstance(item["version"], int) and item["version"] >= 0, f"{path}.version invalid")
    for name in ("level", "task", "opcode"):
        require(isinstance(item[name], str), f"{path}.{name} invalid")
    require(isinstance(item["count"], int) and item["count"] > 0, f"{path}.count invalid")


def validate_log(item: Any, path: str, max_events: int) -> None:
    require(isinstance(item, dict), f"{path} must be object")
    require(
        set(item) == {
            "log_name",
            "status",
            "enabled",
            "record_count",
            "sampled_event_count",
            "oldest_sample_utc",
            "newest_sample_utc",
            "shapes",
            "reason",
        },
        f"{path} keys invalid",
    )
    require(isinstance(item["log_name"], str) and item["log_name"], f"{path}.log_name invalid")
    require(item["status"] in {"available", "disabled", "unavailable"}, f"{path}.status invalid")
    require(item["enabled"] is None or isinstance(item["enabled"], bool), f"{path}.enabled invalid")
    require(item["record_count"] is None or (isinstance(item["record_count"], int) and item["record_count"] >= 0), f"{path}.record_count invalid")
    require(isinstance(item["shapes"], list), f"{path}.shapes must be array")
    for index, shape in enumerate(item["shapes"]):
        validate_shape(shape, f"{path}.shapes[{index}]")
    require(item["shapes"] == sorted(item["shapes"], key=shape_sort_key), f"{path}.shapes not sorted")
    if item["status"] == "available":
        count = item["sampled_event_count"]
        require(isinstance(count, int) and 0 <= count <= max_events, f"{path}.sampled_event_count invalid")
        require(sum(shape["count"] for shape in item["shapes"]) == count, f"{path} shape counts mismatch")
        require(item["enabled"] is True, f"{path}.enabled must be true")
        require(item["reason"] is None, f"{path}.reason must be null")
        if count == 0:
            require(item["oldest_sample_utc"] is None and item["newest_sample_utc"] is None, f"{path} empty sample timestamps invalid")
        else:
            require(isinstance(item["oldest_sample_utc"], str) and item["oldest_sample_utc"], f"{path}.oldest missing")
            require(isinstance(item["newest_sample_utc"], str) and item["newest_sample_utc"], f"{path}.newest missing")
    elif item["status"] == "disabled":
        require(item["enabled"] is False, f"{path}.enabled must be false")
        require(item["sampled_event_count"] == 0, f"{path}.sampled_event_count must be zero")
        require(item["shapes"] == [], f"{path}.shapes must be empty")
        require(item["reason"] == "log_disabled", f"{path}.reason invalid")
    else:
        require(item["sampled_event_count"] is None, f"{path}.sampled_event_count must be null")
        require(item["shapes"] == [], f"{path}.shapes must be empty")
        require(isinstance(item["reason"], str) and item["reason"], f"{path}.reason required")


def validate_baseline(value: dict[str, Any]) -> dict[str, Any]:
    require(
        set(value) == {
            "schema_version",
            "captured_utc",
            "lookback_days",
            "max_events_per_log",
            "binding_fingerprint_sha256",
            "provider_metadata_fingerprint_sha256",
            "providers",
            "claims",
        },
        "top-level keys invalid",
    )
    require(value["schema_version"] == 1, "schema_version must be 1")
    require(isinstance(value["captured_utc"], str) and value["captured_utc"], "captured_utc missing")
    require(isinstance(value["lookback_days"], int) and 1 <= value["lookback_days"] <= 30, "lookback_days invalid")
    max_events = value["max_events_per_log"]
    require(isinstance(max_events, int) and 1 <= max_events <= 512, "max_events_per_log invalid")
    binding = value["binding_fingerprint_sha256"]
    require(isinstance(binding, str) and SHA256_RE.fullmatch(binding), "binding fingerprint invalid")
    metadata_fingerprint = value["provider_metadata_fingerprint_sha256"]
    require(isinstance(metadata_fingerprint, str) and SHA256_RE.fullmatch(metadata_fingerprint), "metadata fingerprint invalid")

    providers = value["providers"]
    require(isinstance(providers, list), "providers must be array")
    require([item.get("provider_name") for item in providers] == sorted(EXPECTED_GUIDS), "provider order/set invalid")
    total_definitions = 0
    total_attached_logs = 0
    available_log_queries = 0
    sampled_events = 0
    metadata_providers: list[dict[str, Any]] = []
    for index, provider in enumerate(providers):
        path = f"providers[{index}]"
        require(isinstance(provider, dict), f"{path} must be object")
        require(
            set(provider) == {
                "provider_name",
                "status",
                "provider_guid",
                "event_definition_count",
                "event_definitions",
                "attached_log_count",
                "logs",
                "reason",
            },
            f"{path} keys invalid",
        )
        name = provider["provider_name"]
        require(provider["status"] == "available", f"{name} provider unavailable")
        require(str(provider["provider_guid"]).lower() == EXPECTED_GUIDS[name], f"{name} GUID mismatch")
        definitions = provider["event_definitions"]
        require(isinstance(definitions, list), f"{name} definitions invalid")
        for def_index, definition in enumerate(definitions):
            validate_definition(definition, f"{path}.event_definitions[{def_index}]")
        require(definitions == sorted(definitions, key=definition_sort_key), f"{name} definitions not sorted")
        require(provider["event_definition_count"] == len(definitions), f"{name} definition count mismatch")
        logs = provider["logs"]
        require(isinstance(logs, list), f"{name} logs invalid")
        require(logs == sorted(logs, key=lambda item: item["log_name"]), f"{name} logs not sorted")
        require(provider["attached_log_count"] == len(logs), f"{name} attached log count mismatch")
        require(provider["reason"] is None, f"{name} reason must be null")
        for log_index, log in enumerate(logs):
            validate_log(log, f"{path}.logs[{log_index}]", max_events)
            if log["status"] == "available":
                available_log_queries += 1
                sampled_events += log["sampled_event_count"]
        total_definitions += len(definitions)
        total_attached_logs += len(logs)
        metadata_providers.append(
            {
                "provider_name": name,
                "status": provider["status"],
                "provider_guid": provider["provider_guid"],
                "event_definition_count": provider["event_definition_count"],
                "event_definitions": definitions,
                "attached_log_count": provider["attached_log_count"],
                "attached_logs": [log["log_name"] for log in logs],
                "reason": provider["reason"],
            }
        )

    metadata_material = {
        "binding_fingerprint_sha256": binding,
        "providers": metadata_providers,
    }
    recomputed = sha256_text(canonical_json(metadata_material))
    require(recomputed == metadata_fingerprint, f"provider metadata fingerprint mismatch: expected={metadata_fingerprint} recomputed={recomputed}")

    claims = value["claims"]
    expected_claims = {
        "raw_event_message_exposed": False,
        "raw_event_xml_exposed": False,
        "raw_event_payload_exposed": False,
        "provider_metadata_inventory": True,
        "bounded_recent_event_shape_inventory": True,
        "event_id_semantics": False,
        "event_task_opcode_semantics": False,
        "device_lifecycle_semantics": False,
        "power_causality": False,
        "firmware_causality": False,
        "continuous_trace_completeness": "not_claimed",
    }
    require(claims == expected_claims, "claim boundary mismatch")
    validate_no_raw_event_content(value)

    return {
        "status": "passed",
        "binding_fingerprint_sha256": binding,
        "provider_metadata_fingerprint_sha256": metadata_fingerprint,
        "provider_count": len(providers),
        "event_definition_count": total_definitions,
        "attached_log_count": total_attached_logs,
        "available_log_query_count": available_log_queries,
        "sampled_event_count": sampled_events,
        "raw_event_content_scan_passed": True,
        "semantic_claims_promoted": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate NXB SUPERBLOCK 2 platform event baseline")
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    try:
        summary = validate_baseline(load_json(args.input))
    except (ValidationError, ValueError, TypeError, json.JSONDecodeError) as exc:
        print(f"NXB platform event baseline validation failed: {exc}")
        return 1
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        "NXB platform event baseline validation passed: "
        f"providers={summary['provider_count']} definitions={summary['event_definition_count']} "
        f"logs={summary['attached_log_count']} sampled={summary['sampled_event_count']} "
        f"metadata={summary['provider_metadata_fingerprint_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
