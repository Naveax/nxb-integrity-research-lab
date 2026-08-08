#!/usr/bin/env python3
"""Validate NXB memory ETL summary evidence."""

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


EVENT_KEYS = (
    "hard_fault",
    "demand_zero_fault",
    "copy_on_write_fault",
    "transition_fault",
    "guard_page_fault",
    "soft_fault_total",
    "virtual_allocation",
    "virtual_free",
    "mapped_section_create",
    "mapped_section_delete",
)
SOFT_COMPONENTS = (
    "demand_zero_fault",
    "copy_on_write_fault",
    "transition_fault",
    "guard_page_fault",
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
            f"Invalid JSON in {path}: line {exc.lineno}, "
            f"column {exc.colno}: {exc.msg}"
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
    validator = Draft202012Validator(
        schema,
        format_checker=FormatChecker(),
    )
    errors = sorted(
        validator.iter_errors(document),
        key=lambda error: list(error.path),
    )
    if errors:
        rendered = [
            f"{format_json_path(error.absolute_path)}: {error.message}"
            for error in errors
        ]
        raise ValidationFailure(
            "Schema validation failed:\n" + "\n".join(rendered)
        )


def parse_time(value: str, label: str) -> datetime:
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise ValidationFailure(
            f"{label} is not a valid ISO-8601 date-time"
        ) from exc
    require(parsed.tzinfo is not None, f"{label} must include a UTC offset")
    return parsed


def measured(entry: dict[str, Any]) -> bool:
    return entry["status"] == "measured"


def validate_event_entry(
    entry: dict[str, Any],
    label: str,
    aggregate: bool,
) -> None:
    if measured(entry):
        require(entry["count"] is not None, f"{label}.count is required")
        require(entry["source"] is not None, f"{label}.source is required")
        require(entry["reason"] is None, f"{label}.reason must be null")
        if aggregate:
            require(
                entry["unattributed_count"] is not None,
                f"{label}.unattributed_count is required",
            )
            require(
                entry["unattributed_count"] <= entry["count"],
                f"{label}.unattributed_count cannot exceed count",
            )
    else:
        require(entry["count"] is None, f"{label}.count must be null")
        require(entry["bytes"] is None, f"{label}.bytes must be null")
        require(
            isinstance(entry["reason"], str)
            and bool(entry["reason"].strip()),
            f"{label}.reason is required",
        )
        if aggregate:
            require(
                entry["unattributed_count"] is None,
                f"{label}.unattributed_count must be null",
            )


def validate_identity(document: dict[str, Any]) -> None:
    expected_relative = f"experiments/{document['experiment_id']}"
    require(
        document["experiment_relative_path"] == expected_relative,
        f"experiment_relative_path must be '{expected_relative}'",
    )

    trace_start = parse_time(document["trace_start_utc"], "trace_start_utc")
    trace_end = parse_time(document["trace_end_utc"], "trace_end_utc")
    require(trace_start <= trace_end, "trace_start_utc is after trace_end_utc")

    target_start = parse_time(
        document["target"]["process_start_utc"],
        "target.process_start_utc",
    )
    require(
        target_start <= trace_end,
        "target process started after trace end",
    )


def validate_processes(document: dict[str, Any]) -> None:
    target = document["target"]
    target_key = (
        int(target["process_id"]),
        target["process_start_utc"],
        target["image_sha256"],
    )
    seen: set[tuple[int, str | None, str | None]] = set()
    target_matches = 0

    for index, process in enumerate(document["processes"]):
        label = f"processes[{index}]"
        key = (
            int(process["process_id"]),
            process["process_start_utc"],
            process["image_sha256"],
        )
        require(key not in seen, f"duplicate process identity at {label}")
        seen.add(key)

        if process["identity_status"] == "complete":
            require(
                process["process_start_utc"] is not None,
                f"{label}.process_start_utc is required for complete identity",
            )
            require(
                process["image_sha256"] is not None,
                f"{label}.image_sha256 is required for complete identity",
            )
        else:
            require(
                not process["is_target"],
                f"{label} target identity cannot be partial",
            )

        is_target_identity = key == target_key
        require(
            bool(process["is_target"]) is is_target_identity,
            f"{label}.is_target is inconsistent with target identity",
        )
        if is_target_identity:
            target_matches += 1

        for name in EVENT_KEYS:
            validate_event_entry(
                process["events"][name],
                f"{label}.events.{name}",
                aggregate=False,
            )

        soft_entries = [process["events"][name] for name in SOFT_COMPONENTS]
        soft_total = process["events"]["soft_fault_total"]
        if all(measured(entry) for entry in soft_entries):
            require(
                measured(soft_total),
                f"{label}.events.soft_fault_total must be measured",
            )
            expected = sum(int(entry["count"]) for entry in soft_entries)
            require(
                int(soft_total["count"]) == expected,
                f"{label}.events.soft_fault_total count mismatch",
            )
        else:
            require(
                not measured(soft_total),
                f"{label}.events.soft_fault_total cannot be measured "
                "when a component is unmeasured",
            )

    require(target_matches == 1, "exactly one process must match target identity")


def validate_aggregates(document: dict[str, Any]) -> None:
    unsupported = set(document["quality"]["unsupported_event_types"])

    for name in EVENT_KEYS:
        aggregate = document["events"][name]
        label = f"events.{name}"
        validate_event_entry(aggregate, label, aggregate=True)

        process_entries = [
            process["events"][name] for process in document["processes"]
        ]
        if measured(aggregate):
            require(
                name not in unsupported,
                f"{label} cannot be measured and unsupported",
            )
            require(
                all(measured(entry) for entry in process_entries),
                f"{label} cannot be measured when process coverage is incomplete",
            )
            attributed = sum(int(entry["count"]) for entry in process_entries)
            require(
                attributed + int(aggregate["unattributed_count"])
                == int(aggregate["count"]),
                f"{label} count does not reconcile with process attribution",
            )
            if aggregate["attribution"] == "complete":
                require(
                    int(aggregate["unattributed_count"]) == 0,
                    f"{label} complete attribution requires zero unattributed events",
                )
            elif aggregate["attribution"] == "none":
                require(
                    attributed == 0,
                    f"{label} none attribution cannot contain process counts",
                )
        elif name in unsupported:
            require(
                aggregate["status"] == "unsupported",
                f"{label} must be unsupported when listed by quality",
            )

    soft_components = [document["events"][name] for name in SOFT_COMPONENTS]
    soft_total = document["events"]["soft_fault_total"]
    if all(measured(entry) for entry in soft_components):
        require(
            measured(soft_total),
            "events.soft_fault_total must be measured",
        )
        expected = sum(int(entry["count"]) for entry in soft_components)
        require(
            int(soft_total["count"]) == expected,
            "events.soft_fault_total count mismatch",
        )
    else:
        require(
            not measured(soft_total),
            "events.soft_fault_total cannot be measured "
            "when a component is unmeasured",
        )


def validate_summary(document: dict[str, Any]) -> None:
    summary = document["summary"]
    entries = list(document["events"].values())
    measured_count = sum(1 for entry in entries if measured(entry))
    failed_count = sum(1 for entry in entries if entry["status"] == "failed")

    require(
        summary["process_count"] == len(document["processes"]),
        "summary.process_count mismatch",
    )
    require(
        summary["measured_event_class_count"] == measured_count,
        "summary.measured_event_class_count mismatch",
    )
    require(
        summary["failed_event_class_count"] == failed_count,
        "summary.failed_event_class_count mismatch",
    )

    quality = document["quality"]
    if failed_count > 0 or quality["parser_completeness"] == "failed":
        expected = "failed"
    elif (
        measured_count == len(EVENT_KEYS)
        and quality["trace_loss"] == "none"
        and quality["circular_overwrite"] == "none"
        and quality["parser_completeness"] == "complete"
    ):
        expected = "complete"
    elif measured_count > 0:
        expected = "partial"
    else:
        expected = "unavailable"

    require(
        summary["evidence_completeness"] == expected,
        f"summary.evidence_completeness must be '{expected}'",
    )


def validate_semantics(document: dict[str, Any]) -> None:
    validate_identity(document)
    validate_processes(document)
    validate_aggregates(document)
    validate_summary(document)


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
    print(f"Memory ETL summary valid: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
