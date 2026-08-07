#!/usr/bin/env python3
"""Normalize Xperf dumper text into the NXB memory event export contract."""

from __future__ import annotations

import argparse
import codecs
import csv
import hashlib
import json
import locale
import re
import sys
from pathlib import Path

NORMALIZED_HEADER = [
    "event_type",
    "timestamp_us",
    "process_id",
    "thread_id",
    "size_bytes",
]

EVENT_ALIASES = {
    "hardfault": "hard_fault",
    "pagefaulthard": "hard_fault",
    "pagefaultdemandzero": "demand_zero_fault",
    "demandzerofault": "demand_zero_fault",
    "pagefaultcopyonwrite": "copy_on_write_fault",
    "copyonwrite": "copy_on_write_fault",
    "pagefaulttransition": "transition_fault",
    "transitionfault": "transition_fault",
    "pagefaultguard": "guard_page_fault",
    "guardpagefault": "guard_page_fault",
    "virtualalloc": "virtual_allocation",
    "virtualallocation": "virtual_allocation",
    "virtualfree": "virtual_free",
    "pagefilemappedsectioncreate": "mapped_section_create",
    "pagefilemappedsectiondelete": "mapped_section_delete",
}

KNOWN_UNMAPPED_MEMORY_EVENTS = {
    "pagefaultav",
    "pagefilebackedimagemapping",
    "mapfile",
    "unmapfile",
}

BYTE_REQUIRED = {"virtual_allocation", "virtual_free"}

HEADER_TIMESTAMP = {
    "timestamp",
    "timestampus",
    "timestampusec",
    "timestampmicroseconds",
    "time",
}
HEADER_PROCESS = {
    "process",
    "processid",
    "pid",
    "processnamepid",
    "processname",
    "processnameprocessid",
}
HEADER_THREAD = {"thread", "threadid", "tid"}
HEADER_SIZE = {
    "size",
    "sizebytes",
    "regionsize",
    "allocationsize",
    "requestedsize",
    "bytes",
    "impactingsize",
}


class BridgeFailure(ValueError):
    """Raised when Xperf dumper normalization must fail closed."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise BridgeFailure(message)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--normalizer-sha256", required=True)
    parser.add_argument("--max-event-count", type=int, default=1_000_000)
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def encoding_is_valid(path: Path, encoding: str) -> bool:
    try:
        decoder_factory = codecs.getincrementaldecoder(encoding)
    except LookupError:
        return False

    decoder = decoder_factory(errors="strict")
    try:
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1024 * 1024), b""):
                decoder.decode(block, final=False)
        decoder.decode(b"", final=True)
    except (UnicodeDecodeError, LookupError):
        return False
    return True


def select_xperf_encoding(path: Path) -> tuple[str, str]:
    with path.open("rb") as handle:
        prefix = handle.read(4)

    if prefix.startswith(codecs.BOM_UTF8):
        return "utf-8-sig", "utf-8-sig"
    if prefix.startswith(codecs.BOM_UTF16_LE) or prefix.startswith(codecs.BOM_UTF16_BE):
        return "utf-16", "utf-16"

    candidates: list[tuple[str, str]] = []
    preferred = locale.getpreferredencoding(False)
    if preferred:
        candidates.append((preferred, preferred))
    candidates.extend(
        [
            ("utf-8", "utf-8"),
            ("cp1252", "cp1252"),
        ]
    )

    seen: set[str] = set()
    for label, encoding in candidates:
        key = encoding.lower()
        if key in seen:
            continue
        seen.add(key)
        if encoding_is_valid(path, encoding):
            return encoding, label

    raise BridgeFailure("Unable to decode Xperf dumper text.")


def normalize_token(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.strip().lower())


def event_alias(value: str) -> str | None:
    return EVENT_ALIASES.get(normalize_token(value))


def parse_non_negative_int(value: str, label: str) -> int:
    text = value.strip()
    require(bool(text), f"Missing {label}.")
    base = 16 if text.lower().startswith("0x") else 10
    try:
        parsed = int(text, base)
    except ValueError as exc:
        raise BridgeFailure(f"Invalid {label}: {value}") from exc
    require(parsed >= 0, f"Invalid {label}: {value}")
    return parsed


def parse_process_id(value: str) -> int:
    text = value.strip()
    if not text:
        return 0
    direct = re.fullmatch(r"(?:0x[0-9a-fA-F]+|\d+)", text)
    if direct:
        return parse_non_negative_int(text, "process_id")
    match = re.search(r"\((\d+)\)\s*$", text)
    if match:
        return int(match.group(1), 10)
    return 0


def parse_thread_id(value: str) -> int:
    text = value.strip()
    if not text:
        return 0
    direct = re.search(r"(?:0x[0-9a-fA-F]+|\d+)", text)
    if not direct:
        return 0
    return parse_non_negative_int(direct.group(0), "thread_id")


def header_indices(fields: list[str]) -> dict[str, int]:
    normalized = [normalize_token(field) for field in fields]
    result: dict[str, int] = {}
    for index, token in enumerate(normalized):
        if token in HEADER_TIMESTAMP and "timestamp" not in result:
            result["timestamp"] = index
        if token in HEADER_PROCESS and "process" not in result:
            result["process"] = index
        if token in HEADER_THREAD and "thread" not in result:
            result["thread"] = index
        if token in HEADER_SIZE and "size" not in result:
            result["size"] = index
    return result


def is_header(fields: list[str], normalized_event: str | None) -> bool:
    if normalized_event is None:
        return False
    indices = header_indices(fields[1:])
    return "timestamp" in indices


def value_at(fields: list[str], index: int | None) -> str:
    if index is None:
        return ""
    absolute = index + 1
    if absolute >= len(fields):
        return ""
    return fields[absolute].strip()


def normalize_stream(args: argparse.Namespace) -> dict[str, object]:
    require(args.max_event_count > 0, "MaxEventCount must be positive.")
    require(args.input.is_file(), f"Input file not found: {args.input}")
    require(
        re.fullmatch(r"[0-9a-f]{64}", args.normalizer_sha256) is not None,
        "normalizer-sha256 must be lowercase SHA-256.",
    )

    encoding, encoding_label = select_xperf_encoding(args.input)
    headers: dict[str, dict[str, int]] = {}
    observed_raw_types: set[str] = set()
    unsupported_raw_types: set[str] = set()
    row_counts: dict[str, int] = {}
    hard_fault_raw_aliases_with_data: set[str] = set()
    unmapped_hard_fault_count = 0
    normalized_event_count = 0
    process_attribution_partial = False

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.input.open(
        "r",
        encoding=encoding,
        errors="strict",
        newline="",
    ) as source, args.output.open(
        "w",
        encoding="utf-8",
        newline="",
    ) as destination:
        reader = csv.reader(source, skipinitialspace=True)
        writer = csv.DictWriter(destination, fieldnames=NORMALIZED_HEADER)
        writer.writeheader()

        for fields in reader:
            if not fields or all(not item.strip() for item in fields):
                continue
            fields = [item.strip() for item in fields]
            raw_event = fields[0].strip()
            raw_key = normalize_token(raw_event)
            normalized_event = event_alias(raw_event)

            if normalized_event is not None and is_header(fields, normalized_event):
                headers[raw_key] = header_indices(fields[1:])
                observed_raw_types.add(raw_event)
                continue

            if raw_key in KNOWN_UNMAPPED_MEMORY_EVENTS:
                unsupported_raw_types.add(raw_event)
                continue

            if normalized_event is None:
                continue

            if raw_key not in headers:
                raise BridgeFailure(
                    "Memory event row appeared before a parseable header at line "
                    f"{reader.line_num}: {raw_event}"
                )

            indices = headers[raw_key]
            timestamp = parse_non_negative_int(
                value_at(fields, indices.get("timestamp")),
                "timestamp_us",
            )
            process_id = parse_process_id(value_at(fields, indices.get("process")))
            thread_id = parse_thread_id(value_at(fields, indices.get("thread")))

            raw_size = value_at(fields, indices.get("size"))
            size_bytes: int | None = None
            if raw_size:
                size_bytes = parse_non_negative_int(raw_size, "size_bytes")

            if normalized_event in BYTE_REQUIRED:
                require(
                    size_bytes is not None,
                    "size field is required for "
                    f"{normalized_event} at line {reader.line_num}.",
                )

            if normalized_event == "hard_fault":
                hard_fault_raw_aliases_with_data.add(raw_key)
                if len(hard_fault_raw_aliases_with_data) > 1:
                    raise BridgeFailure(
                        "Both HardFault and PagefaultHard data were observed; "
                        "refusing to merge potentially overlapping hard-fault streams."
                    )
                if size_bytes is None:
                    unmapped_hard_fault_count += 1
                    continue

            normalized_event_count += 1
            require(
                normalized_event_count <= args.max_event_count,
                "Normalized event count exceeds MaxEventCount: "
                f"{args.max_event_count}",
            )
            if process_id == 0:
                process_attribution_partial = True

            writer.writerow(
                {
                    "event_type": normalized_event,
                    "timestamp_us": timestamp,
                    "process_id": process_id,
                    "thread_id": thread_id,
                    "size_bytes": "" if size_bytes is None else size_bytes,
                }
            )
            row_counts[normalized_event] = row_counts.get(normalized_event, 0) + 1

    covered_event_types = sorted(row_counts)
    require(
        bool(covered_event_types),
        "No supported Xperf memory events were normalized.",
    )

    manifest: dict[str, object] = {
        "schema_version": 1,
        "source_format": "xperf_dumper_text",
        "input_sha256": sha256_file(args.input),
        "normalizer_sha256": args.normalizer_sha256,
        "input_encoding": encoding_label,
        "normalized_event_count": normalized_event_count,
        "covered_event_types": covered_event_types,
        "event_counts": {
            name: row_counts[name] for name in covered_event_types
        },
        "observed_memory_headers": sorted(observed_raw_types),
        "known_unmapped_memory_event_names": sorted(unsupported_raw_types),
        "hard_fault_bytes_semantics": (
            "header_field"
            if "hard_fault" in covered_event_types
            else "not_available_from_observed_header"
        ),
        "unmapped_event_counts": (
            {"hard_fault": unmapped_hard_fault_count}
            if unmapped_hard_fault_count
            else {}
        ),
        "process_attribution": (
            "partial" if process_attribution_partial else "complete"
        ),
        "claims": {
            "missing_event_type_means_zero": False,
            "hard_fault_bytes_exact": False,
            "parser_completeness": "not_claimed",
        },
    }
    return manifest


def main() -> int:
    try:
        args = parse_args()
        manifest = normalize_stream(args)
        args.manifest.parent.mkdir(parents=True, exist_ok=True)
        manifest["normalized_csv_sha256"] = sha256_file(args.output)
        args.manifest.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
    except (BridgeFailure, OSError, UnicodeError, csv.Error) as exc:
        print(
            f"Xperf memory dumper normalization failed: {exc}",
            file=sys.stderr,
        )
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
