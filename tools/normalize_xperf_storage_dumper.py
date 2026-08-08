#!/usr/bin/env python3
"""Normalize observed Xperf storage dumper rows without inventing timing units."""

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

OUTPUT_HEADER = [
    "event_type",
    "timestamp_raw",
    "process_id",
    "thread_id",
    "disk_number",
    "file_key",
    "path",
    "offset_bytes",
    "transfer_bytes",
    "duration_raw",
    "disk_service_time_raw",
    "result_raw",
]

EVENT_ALIASES = {
    "diskread": "disk_read",
    "diskwrite": "disk_write",
    "diskflush": "disk_flush",
    "fileioread": "file_read",
    "fileiowrite": "file_write",
    "fileioflush": "file_flush",
    "fileiocreate": "file_create",
    "fileioclose": "file_close",
    "fileiodelete": "file_delete",
    "fileiorename": "file_rename",
    "splitio": "split_io",
}

KNOWN_STORAGE_CANDIDATE_PREFIXES = (
    "disk",
    "fileio",
    "filename",
    "logicaldisk",
    "physicaldisk",
    "mapfile",
    "unmapfile",
    "splitio",
)

HEADER_ALIASES = {
    "timestamp": {"timestamp"},
    "process": {"processnamepid", "processid", "pid"},
    "thread": {"threadid", "tid"},
    "disk": {"disknum", "disknumber"},
    "file_key": {"fileobject"},
    "path": {"filename"},
    "offset": {"byteoffset", "offset"},
    "transfer": {"iosize", "size", "transfersize"},
    "duration": {"elapsedtime"},
    "disk_service": {"disksvctime"},
    "result": {"status"},
}


class NormalizationFailure(ValueError):
    """Raised when normalization must fail closed."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise NormalizationFailure(message)


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


def looks_like_utf16_without_bom(prefix: bytes) -> str | None:
    sample = prefix[:4096]
    if len(sample) < 8:
        return None
    even_nul = sum(1 for index in range(0, len(sample), 2) if sample[index] == 0)
    odd_nul = sum(1 for index in range(1, len(sample), 2) if sample[index] == 0)
    half = max(1, len(sample) // 2)
    if odd_nul / half > 0.35 and even_nul / half < 0.05:
        return "utf-16-le"
    if even_nul / half > 0.35 and odd_nul / half < 0.05:
        return "utf-16-be"
    return None


def select_encoding(path: Path) -> tuple[str, str, str]:
    with path.open("rb") as handle:
        prefix = handle.read(4096)
    if prefix.startswith(codecs.BOM_UTF8):
        return "utf-8-sig", "utf-8-sig", "strict"
    if prefix.startswith(codecs.BOM_UTF16_LE) or prefix.startswith(codecs.BOM_UTF16_BE):
        return "utf-16", "utf-16", "strict"
    inferred = looks_like_utf16_without_bom(prefix)
    if inferred is not None:
        return inferred, inferred + "-no-bom", "strict"
    if sys.platform == "win32":
        try:
            codecs.lookup("mbcs")
            return "mbcs", "windows-ansi", "replace"
        except LookupError:
            pass
    preferred = locale.getencoding() if hasattr(locale, "getencoding") else locale.getpreferredencoding(False)
    if preferred:
        try:
            codecs.lookup(preferred)
            return preferred, preferred, "replace"
        except LookupError:
            pass
    return "latin-1", "single-byte-structural-fallback", "strict"


def normalize_token(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "", value.strip().lower())


def event_alias(value: str) -> str | None:
    return EVENT_ALIASES.get(normalize_token(value))


def header_indices(fields: list[str]) -> dict[str, int]:
    normalized = [normalize_token(field) for field in fields]
    result: dict[str, int] = {}
    for index, token in enumerate(normalized):
        for name, aliases in HEADER_ALIASES.items():
            if token in aliases and name not in result:
                result[name] = index
    return result


def value_at(fields: list[str], index: int | None) -> str:
    if index is None:
        return ""
    absolute = index + 1
    if absolute >= len(fields):
        return ""
    return fields[absolute].strip()


def parse_optional_int(value: str, label: str) -> int | None:
    text = value.strip()
    if not text:
        return None
    base = 16 if text.lower().startswith("0x") else 10
    try:
        parsed = int(text, base)
    except ValueError as exc:
        raise NormalizationFailure(f"Invalid {label}: {value}") from exc
    require(parsed >= 0, f"Invalid {label}: {value}")
    return parsed


def parse_process_id(value: str) -> int | None:
    text = value.strip()
    if not text:
        return None
    if re.fullmatch(r"(?:0x[0-9a-fA-F]+|\d+)", text):
        return parse_optional_int(text, "process_id")
    match = re.search(r"\(\s*(\d+)\s*\)\s*$", text)
    return int(match.group(1), 10) if match else None


def parse_thread_id(value: str) -> int | None:
    text = value.strip()
    if not text:
        return None
    match = re.search(r"(?:0x[0-9a-fA-F]+|\d+)", text)
    return parse_optional_int(match.group(0), "thread_id") if match else None


def candidate_storage_name(raw_event: str) -> bool:
    token = normalize_token(raw_event)
    return any(token.startswith(prefix) for prefix in KNOWN_STORAGE_CANDIDATE_PREFIXES)


def normalize_stream(args: argparse.Namespace) -> dict[str, object]:
    require(args.max_event_count > 0, "max-event-count must be positive")
    require(args.input.is_file(), f"Input file not found: {args.input}")
    require(
        re.fullmatch(r"[0-9a-f]{64}", args.normalizer_sha256) is not None,
        "normalizer-sha256 must be lowercase SHA-256",
    )

    encoding, encoding_label, decode_errors = select_encoding(args.input)
    headers: dict[str, dict[str, int]] = {}
    observed_supported_raw: set[str] = set()
    observed_unmapped_candidates: set[str] = set()
    row_counts: dict[str, int] = {}
    normalized_event_count = 0
    decode_replacement_count = 0
    process_attribution_missing = 0
    thread_attribution_missing = 0
    disk_attribution_missing = 0
    file_attribution_missing = 0

    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.input.open("r", encoding=encoding, errors=decode_errors, newline="") as source, args.output.open(
        "w", encoding="utf-8", newline=""
    ) as destination:
        reader = csv.reader(source, skipinitialspace=True)
        writer = csv.DictWriter(destination, fieldnames=OUTPUT_HEADER)
        writer.writeheader()

        for fields in reader:
            if not fields or all(not item.strip() for item in fields):
                continue
            decode_replacement_count += sum(item.count("\ufffd") for item in fields)
            fields = [item.strip() for item in fields]
            raw_event = fields[0]
            raw_key = normalize_token(raw_event)
            normalized_event = event_alias(raw_event)
            indices = header_indices(fields[1:])

            if normalized_event is not None and "timestamp" in indices:
                headers[raw_key] = indices
                observed_supported_raw.add(raw_event)
                continue

            if normalized_event is None:
                if candidate_storage_name(raw_event) and "timestamp" in indices:
                    observed_unmapped_candidates.add(raw_event)
                continue

            if raw_key not in headers:
                raise NormalizationFailure(
                    f"Storage event row appeared before a parseable header at line {reader.line_num}: {raw_event}"
                )

            indices = headers[raw_key]
            timestamp_raw = value_at(fields, indices.get("timestamp"))
            require(bool(timestamp_raw), f"Missing TimeStamp at line {reader.line_num}")

            process_id = parse_process_id(value_at(fields, indices.get("process")))
            thread_id = parse_thread_id(value_at(fields, indices.get("thread")))
            disk_number = parse_optional_int(value_at(fields, indices.get("disk")), "disk_number")
            file_key = value_at(fields, indices.get("file_key")) or None
            path = value_at(fields, indices.get("path")) or None
            offset_bytes = parse_optional_int(value_at(fields, indices.get("offset")), "offset_bytes")
            transfer_bytes = parse_optional_int(value_at(fields, indices.get("transfer")), "transfer_bytes")
            duration_raw = value_at(fields, indices.get("duration")) or None
            disk_service_time_raw = value_at(fields, indices.get("disk_service")) or None
            result_raw = value_at(fields, indices.get("result")) or None

            normalized_event_count += 1
            require(
                normalized_event_count <= args.max_event_count,
                f"Normalized event count exceeds max-event-count={args.max_event_count}",
            )
            row_counts[normalized_event] = row_counts.get(normalized_event, 0) + 1
            if process_id is None:
                process_attribution_missing += 1
            if thread_id is None:
                thread_attribution_missing += 1
            if normalized_event.startswith("disk_") and disk_number is None:
                disk_attribution_missing += 1
            if normalized_event.startswith("file_") and file_key is None and path is None:
                file_attribution_missing += 1

            writer.writerow(
                {
                    "event_type": normalized_event,
                    "timestamp_raw": timestamp_raw,
                    "process_id": "" if process_id is None else process_id,
                    "thread_id": "" if thread_id is None else thread_id,
                    "disk_number": "" if disk_number is None else disk_number,
                    "file_key": "" if file_key is None else file_key,
                    "path": "" if path is None else path,
                    "offset_bytes": "" if offset_bytes is None else offset_bytes,
                    "transfer_bytes": "" if transfer_bytes is None else transfer_bytes,
                    "duration_raw": "" if duration_raw is None else duration_raw,
                    "disk_service_time_raw": "" if disk_service_time_raw is None else disk_service_time_raw,
                    "result_raw": "" if result_raw is None else result_raw,
                }
            )

    require(normalized_event_count > 0, "No supported storage event rows were normalized")
    output_hash = sha256_file(args.output)
    manifest = {
        "schema_version": 1,
        "source_format": "xperf_storage_dumper_text_v1",
        "input_sha256": sha256_file(args.input),
        "normalizer_sha256": args.normalizer_sha256,
        "normalized_csv_sha256": output_hash,
        "normalized_event_count": normalized_event_count,
        "row_counts": {key: row_counts[key] for key in sorted(row_counts)},
        "observed_supported_raw_event_types": sorted(observed_supported_raw),
        "observed_unmapped_storage_candidate_headers": sorted(observed_unmapped_candidates),
        "parser_completeness": "partial",
        "attribution": {
            "missing_process_count": process_attribution_missing,
            "missing_thread_count": thread_attribution_missing,
            "missing_disk_count": disk_attribution_missing,
            "missing_file_count": file_attribution_missing,
        },
        "timing": {
            "timestamp_raw_unit": "unresolved",
            "elapsed_time_raw_unit": "unresolved",
            "disk_service_time_raw_unit": "unresolved",
            "normalized_duration_us_available": False,
        },
        "claims": {
            "queue_depth_semantics": False,
            "queue_latency_semantics": False,
            "service_time_semantics": False,
            "throughput_representativeness": False,
            "iops_representativeness": False,
            "trace_completeness": "not_claimed",
        },
        "text_encoding": encoding_label,
        "decode_replacement_count": decode_replacement_count,
    }
    with args.manifest.open("w", encoding="utf-8", newline="") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
        handle.write("\n")
    return manifest


def main() -> int:
    args = parse_args()
    try:
        normalize_stream(args)
    except NormalizationFailure as exc:
        print(f"storage xperf normalization failed: {exc}", file=sys.stderr)
        return 1
    except Exception as exc:
        print(f"storage xperf normalizer error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
