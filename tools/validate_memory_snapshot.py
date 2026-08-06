#!/usr/bin/env python3
"""Validate NXB memory snapshot evidence."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Iterable

from jsonschema import Draft202012Validator, FormatChecker


class ValidationFailure(ValueError):
    """Raised when schema or semantic validation fails."""


SYSTEM_FIELDS = (
    "physical_memory_total_bytes",
    "physical_memory_available_bytes",
    "commit_limit_bytes",
    "commit_used_bytes",
    "standby_cache_bytes",
    "modified_page_list_bytes",
    "compression_store_bytes",
)

PROCESS_FIELDS = (
    "working_set_bytes",
    "peak_working_set_bytes",
    "private_bytes",
    "virtual_size_bytes",
    "peak_virtual_size_bytes",
    "paged_memory_bytes",
    "page_fault_count",
    "hard_fault_count",
    "soft_fault_count",
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    return parser.parse_args()


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise ValidationFailure(f"JSON file not found: {path}") from exc
    except json.JSONDecodeError as exc:
        raise ValidationFailure(
            f"Invalid JSON in {path}: line {exc.lineno}, column {exc.colno}: {exc.msg}"
        ) from exc


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationFailure(message)


def format_json_path(parts: Iterable[Any]) -> str:
    path = "$"
    for part in parts:
        path += f"[{part}]" if isinstance(part, int) else f".{part}"
    return path


def validate_schema(schema: Any, document: Any) -> None:
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(validator.iter_errors(document), key=lambda error: list(error.path))
    if errors:
        rendered = [
            f"{format_json_path(error.absolute_path)}: {error.message}"
            for error in errors
        ]
        raise ValidationFailure("Schema validation failed:\n" + "\n".join(rendered))


def parse_utc(value: str, label: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ValidationFailure(f"{label} is not a valid ISO-8601 date-time") from exc
    require(parsed.tzinfo is not None, f"{label} must include a UTC offset")
    return parsed


def measured(measurement: dict[str, Any]) -> bool:
    return measurement["status"] == "measured"


def measurement_value(measurement: dict[str, Any]) -> int | None:
    return int(measurement["value"]) if measured(measurement) else None


def validate_measurement(measurement: dict[str, Any], label: str) -> None:
    if measured(measurement):
        require(measurement["value"] is not None, f"{label}.value is required")
        require(measurement["source"] is not None, f"{label}.source is required")
        require(measurement["reason"] is None, f"{label}.reason must be null")
    else:
        require(measurement["value"] is None, f"{label}.value must be null")
        require(
            isinstance(measurement["reason"], str)
            and bool(measurement["reason"].strip()),
            f"{label}.reason is required",
        )


def validate_identity(document: dict[str, Any]) -> None:
    expected_relative = f"experiments/{document['experiment_id']}"
    require(
        document["experiment_relative_path"] == expected_relative,
        f"experiment_relative_path must be '{expected_relative}'",
    )
    captured = parse_utc(document["captured_utc"], "captured_utc")
    target_start = parse_utc(
        document["target"]["process_start_utc"],
        "target.process_start_utc",
    )
    require(target_start <= captured, "target process started after snapshot capture")


def validate_system(document: dict[str, Any]) -> int:
    system = document["system"]
    for name in SYSTEM_FIELDS:
        validate_measurement(system[name], f"system.{name}")

    total = measurement_value(system["physical_memory_total_bytes"])
    available = measurement_value(system["physical_memory_available_bytes"])
    if total is not None and available is not None:
        require(
            available <= total,
            "physical_memory_available_bytes cannot exceed physical_memory_total_bytes",
        )

    commit_limit = measurement_value(system["commit_limit_bytes"])
    commit_used = measurement_value(system["commit_used_bytes"])
    if commit_limit is not None and commit_used is not None:
        require(
            commit_used <= commit_limit,
            "commit_used_bytes cannot exceed commit_limit_bytes",
        )

    return sum(1 for name in SYSTEM_FIELDS if measured(system[name]))


def validate_processes(document: dict[str, Any]) -> tuple[int, int, int]:
    captured = parse_utc(document["captured_utc"], "captured_utc")
    target = document["target"]
    target_key = (
        int(target["process_id"]),
        target["process_start_utc"],
        target["image_sha256"],
    )

    seen: set[tuple[int, str, str]] = set()
    target_matches = 0
    measured_count = 0
    failed_count = 0

    for index, process in enumerate(document["processes"]):
        label = f"processes[{index}]"
        process_start = parse_utc(
            process["process_start_utc"],
            f"{label}.process_start_utc",
        )
        require(process_start <= captured, f"{label} started after snapshot capture")
        key = (
            int(process["process_id"]),
            process["process_start_utc"],
            process["image_sha256"],
        )
        require(key not in seen, f"duplicate process identity at {label}")
        seen.add(key)

        is_target_identity = key == target_key
        require(
            bool(process["is_target"]) is is_target_identity,
            f"{label}.is_target is inconsistent with target identity",
        )
        if is_target_identity:
            target_matches += 1

        for name in PROCESS_FIELDS:
            measurement = process[name]
            validate_measurement(measurement, f"{label}.{name}")
            if measured(measurement):
                measured_count += 1
            elif measurement["status"] == "failed":
                failed_count += 1

        working_set = measurement_value(process["working_set_bytes"])
        peak_working_set = measurement_value(process["peak_working_set_bytes"])
        if working_set is not None and peak_working_set is not None:
            require(
                working_set <= peak_working_set,
                f"{label}.working_set_bytes cannot exceed peak_working_set_bytes",
            )

        virtual_size = measurement_value(process["virtual_size_bytes"])
        peak_virtual_size = measurement_value(process["peak_virtual_size_bytes"])
        if virtual_size is not None and peak_virtual_size is not None:
            require(
                virtual_size <= peak_virtual_size,
                f"{label}.virtual_size_bytes cannot exceed peak_virtual_size_bytes",
            )

        hard_faults = measurement_value(process["hard_fault_count"])
        soft_faults = measurement_value(process["soft_fault_count"])
        total_faults = measurement_value(process["page_fault_count"])
        if hard_faults is not None and total_faults is not None:
            require(
                hard_faults <= total_faults,
                f"{label}.hard_fault_count cannot exceed page_fault_count",
            )
        if soft_faults is not None and total_faults is not None:
            require(
                soft_faults <= total_faults,
                f"{label}.soft_fault_count cannot exceed page_fault_count",
            )

    require(target_matches == 1, "exactly one process must match target identity")
    return len(document["processes"]), measured_count, failed_count


def validate_summary(
    document: dict[str, Any],
    system_measured: int,
    process_count: int,
    process_measured: int,
    process_failed: int,
) -> None:
    summary = document["summary"]
    system_failed = sum(
        1
        for name in SYSTEM_FIELDS
        if document["system"][name]["status"] == "failed"
    )
    failed_count = system_failed + process_failed
    total_possible = len(SYSTEM_FIELDS) + process_count * len(PROCESS_FIELDS)
    total_measured = system_measured + process_measured

    require(
        summary["system_measurement_count"] == system_measured,
        "summary.system_measurement_count mismatch",
    )
    require(summary["process_count"] == process_count, "summary.process_count mismatch")
    require(
        summary["process_measurement_count"] == process_measured,
        "summary.process_measurement_count mismatch",
    )
    require(
        summary["failed_measurement_count"] == failed_count,
        "summary.failed_measurement_count mismatch",
    )

    if failed_count > 0:
        expected = "failed"
    elif total_measured == total_possible:
        expected = "complete"
    elif total_measured > 0:
        expected = "partial"
    else:
        expected = "unavailable"

    require(
        summary["evidence_completeness"] == expected,
        f"summary.evidence_completeness must be '{expected}'",
    )


def validate_semantics(document: dict[str, Any]) -> None:
    validate_identity(document)
    system_measured = validate_system(document)
    process_count, process_measured, process_failed = validate_processes(document)
    validate_summary(
        document,
        system_measured,
        process_count,
        process_measured,
        process_failed,
    )


def main() -> int:
    args = parse_args()
    try:
        schema = load_json(args.schema)
        document = load_json(args.manifest)
        validate_schema(schema, document)
        validate_semantics(document)
    except ValidationFailure as exc:
        print(str(exc), file=sys.stderr)
        return 1
    print(f"Memory snapshot valid: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
