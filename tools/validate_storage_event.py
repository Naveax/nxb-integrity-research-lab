#!/usr/bin/env python3
"""Validate one normalized NXB storage event."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Iterable

from jsonschema import Draft202012Validator, FormatChecker


class ValidationFailure(ValueError):
    """Raised when schema or semantic validation fails."""


DISK_EVENTS = {"disk_read", "disk_write", "disk_flush", "split_io"}
FILE_EVENTS = {
    "file_read",
    "file_write",
    "file_flush",
    "file_create",
    "file_close",
    "file_delete",
    "file_rename",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", required=True, type=Path)
    parser.add_argument("--event", required=True, type=Path)
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
    validator = Draft202012Validator(schema, format_checker=FormatChecker())
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


def validate_value_state(
    value: Any,
    state: str,
    label: str,
) -> None:
    if state == "measured":
        require(value is not None, f"{label} must be present when measured")
    else:
        require(value is None, f"{label} must be null when not measured")


def validate_document(document: dict[str, Any]) -> None:
    event_type = document["event_type"]
    domain = document["domain"]
    identity = document["identity"]
    operation = document["operation"]
    semantics = document["semantics"]

    if event_type in DISK_EVENTS:
        require(domain == "storage", f"{event_type} must use domain=storage")
    elif event_type in FILE_EVENTS:
        require(domain == "filesystem", f"{event_type} must use domain=filesystem")
    else:  # schema should already make this unreachable
        raise ValidationFailure(f"unknown storage event_type: {event_type}")

    require(
        semantics["timestamp"] == "measured",
        "timestamp semantics must be measured because timestamp_utc is required",
    )
    require(
        semantics["queue_semantics"] != "measured",
        "queue semantics cannot be measured before real ETL field validation",
    )

    validate_value_state(
        operation["duration_us"],
        semantics["duration"],
        "operation.duration_us",
    )
    validate_value_state(
        operation["transfer_bytes"],
        semantics["transfer_size"],
        "operation.transfer_bytes",
    )
    validate_value_state(
        identity["process_id"],
        semantics["process_attribution"],
        "identity.process_id",
    )
    validate_value_state(
        identity["thread_id"],
        semantics["thread_attribution"],
        "identity.thread_id",
    )
    validate_value_state(
        identity["disk_number"],
        semantics["disk_attribution"],
        "identity.disk_number",
    )

    file_state = semantics["file_attribution"]
    file_values_present = (
        identity["file_key"] is not None or identity["path"] is not None
    )
    if file_state == "measured":
        require(
            file_values_present,
            "file attribution requires file_key or path when measured",
        )
    else:
        require(
            not file_values_present,
            "file_key/path must be null when file attribution is not measured",
        )

    if event_type in FILE_EVENTS:
        require(
            file_state == "measured",
            f"{event_type} requires measured file attribution",
        )


def main() -> int:
    args = parse_args()
    try:
        schema = load_json(args.schema)
        document = load_json(args.event)
        validate_schema(schema, document)
        validate_document(document)
    except ValidationFailure as exc:
        print(f"storage event validation failed: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:  # fail closed for unexpected validator errors
        print(f"storage event validator error: {exc}", file=sys.stderr)
        return 2

    print("storage event validation passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
