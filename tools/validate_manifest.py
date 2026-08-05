#!/usr/bin/env python3
"""Validate a JSON document against a Draft 2020-12 JSON Schema."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    from jsonschema import Draft202012Validator, FormatChecker
    from jsonschema.exceptions import SchemaError
except ImportError as exc:  # pragma: no cover - exercised by wrapper failure path
    print(
        "The 'jsonschema' package is required. Install with: "
        "python -m pip install jsonschema",
        file=sys.stderr,
    )
    raise SystemExit(3) from exc


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8-sig") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"Cannot read JSON '{path}': {exc}") from exc


def format_path(parts: list[Any]) -> str:
    if not parts:
        return "$"
    rendered = "$"
    for part in parts:
        if isinstance(part, int):
            rendered += f"[{part}]"
        else:
            rendered += f".{part}"
    return rendered


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--schema", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()

    try:
        schema = load_json(args.schema)
        manifest = load_json(args.manifest)
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        return 4

    try:
        Draft202012Validator.check_schema(schema)
    except SchemaError as exc:
        print(f"Invalid Draft 2020-12 schema '{args.schema}': {exc.message}", file=sys.stderr)
        return 5

    validator = Draft202012Validator(schema, format_checker=FormatChecker())
    errors = sorted(
        validator.iter_errors(manifest),
        key=lambda error: (list(error.absolute_path), error.message),
    )

    if errors:
        for error in errors:
            location = format_path(list(error.absolute_path))
            print(f"{location}: {error.message}", file=sys.stderr)
        return 2

    print(f"Document valid: {args.manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
