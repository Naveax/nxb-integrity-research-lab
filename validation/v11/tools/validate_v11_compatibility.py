#!/usr/bin/env python3
"""NXB V11 six-entry review ZIP envelope inspector (stdlib-only).

IMPORTANT: The only supported mode is *structural preflight*. A successful
result DOES NOT admit a compatibility cell, certify a native machine, or
validate GitHub-side runner/candidate/policy/provenance authority. The future
independent admission mode must implement those gates separately.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import unicodedata
import zipfile
from pathlib import Path
from typing import Any, NoReturn

AUTHORITY = "nxb-v11-review-zip-envelope-preflight-v1"
EXPECTED_NAMES = frozenset(
    {
        "environment-fingerprint.json",
        "compatibility-plan.json",
        "endurance-cycle-summary.json",
        "known-error-scan.json",
        "independent-validation.json",
        "compatibility-certification-receipt.json",
    }
)
# These are deliberately conservative preflight limits, NOT policy admission.
MAX_ENTRY_BYTES = 1024 * 1024
MAX_TOTAL_UNCOMPRESSED = len(EXPECTED_NAMES) * MAX_ENTRY_BYTES
MAX_ZIP_BYTES = 12 * 1024 * 1024
I64_MAX = (1 << 63) - 1
I64_MIN = -(1 << 63)
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
KNOWN_AUTHORITY = {
    "environment-fingerprint.json": "nxb-compatibility-environment-fingerprint-v1",
    "compatibility-plan.json": "nxb-v11-compatibility-plan-v1",
    "endurance-cycle-summary.json": "nxb-v11-endurance-cycle-summary-v1",
    "known-error-scan.json": "nxb-v11-known-error-scan-v1",
    "independent-validation.json": "nxb-v11-compatibility-independent-v1",
}


class PreflightError(ValueError):
    """Expected fail-closed rejection, exit status 2."""


def fail(reason: str) -> NoReturn:
    raise PreflightError(reason)


def _pairs_unique(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail("duplicate JSON object key")
        result[key] = value
    return result


def _parse_integer(value: str) -> int:
    number = int(value)
    if not I64_MIN <= number <= I64_MAX:
        fail("JSON integer outside signed 64-bit range")
    return number


def _parse_float(_value: str) -> NoReturn:
    fail("floating-point JSON numbers are forbidden")


def _parse_constant(_value: str) -> NoReturn:
    fail("non-finite JSON numbers are forbidden")


def _check_strings(value: Any) -> None:
    if isinstance(value, str):
        if unicodedata.normalize("NFC", value) != value:
            fail("non-NFC JSON string")
        if any(ord(char) < 0x20 or ord(char) == 0x7f for char in value):
            fail("JSON string contains a control character")
    elif isinstance(value, dict):
        for key, child in value.items():
            _check_strings(key)
            if not key.isascii():
                fail("JSON object key outside ASCII contract")
            _check_strings(child)
    elif isinstance(value, list):
        for child in value:
            _check_strings(child)


def _canonical_document(content: bytes, name: str) -> dict[str, Any]:
    if content.startswith(b"\xef\xbb\xbf"):
        fail(f"{name}: UTF-8 BOM forbidden")
    try:
        decoded = content.decode("utf-8", "strict")
    except UnicodeDecodeError:
        fail(f"{name}: invalid UTF-8")
    try:
        document = json.loads(
            decoded,
            object_pairs_hook=_pairs_unique,
            parse_int=_parse_integer,
            parse_float=_parse_float,
            parse_constant=_parse_constant,
        )
    except (ValueError, TypeError) as exc:
        if isinstance(exc, PreflightError):
            raise
        fail(f"{name}: malformed JSON")
    if not isinstance(document, dict):
        fail(f"{name}: JSON root must be an object")
    _check_strings(document)
    canonical = json.dumps(
        document, ensure_ascii=False, sort_keys=True, separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    if content != canonical:
        fail(f"{name}: non-canonical JSON bytes")
    expected_authority = KNOWN_AUTHORITY.get(name)
    if expected_authority is not None and document.get("authority") != expected_authority:
        fail(f"{name}: wrong authority identifier")
    return document


def _regular_zip_entry(info: zipfile.ZipInfo) -> None:
    name = info.filename
    if name not in EXPECTED_NAMES:
        fail("unexpected, nested or unsafe review entry")
    if info.is_dir():
        fail("directory review entry forbidden")
    if info.flag_bits & 0x1:
        fail("encrypted review entry forbidden")
    if info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
        fail("unsupported review compression method")
    if info.file_size < 0 or info.file_size > MAX_ENTRY_BYTES:
        fail("review entry exceeds preflight byte ceiling")
    if info.compress_size < 0 or info.compress_size > MAX_ZIP_BYTES:
        fail("review entry compressed byte ceiling exceeded")
    if info.create_system == 3:
        unix_mode = (info.external_attr >> 16) & 0xffff
        if unix_mode:
            kind = stat.S_IFMT(unix_mode)
            if kind not in (0, stat.S_IFREG):
                fail("nonregular UNIX review entry metadata")
    if info.external_attr & 0x10:
        fail("directory-attribute review entry forbidden")
    if info.filename != unicodedata.normalize("NFC", info.filename):
        fail("non-NFC review entry path")


def _ordinary_zip(path: Path) -> None:
    if not path.is_absolute():
        fail("ZIP path must be absolute")
    try:
        metadata = path.lstat()
    except OSError:
        fail("review ZIP is absent or unreadable")
    if not stat.S_ISREG(metadata.st_mode):
        fail("review ZIP must be an ordinary regular file")
    if getattr(metadata, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400):
        fail("review ZIP reparse-point forbidden")
    if metadata.st_size <= 0 or metadata.st_size > MAX_ZIP_BYTES:
        fail("review ZIP exceeds bounded preflight size")
    # A regular leaf under a symlink/junction parent is not an ordinary path.
    current = path.parent
    while True:
        try:
            parent_metadata = current.lstat()
        except OSError:
            fail("review ZIP parent path is unreadable")
        if not stat.S_ISDIR(parent_metadata.st_mode):
            fail("review ZIP parent is not an ordinary directory")
        if getattr(parent_metadata, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400):
            fail("review ZIP parent reparse-point forbidden")
        if current.parent == current:
            break
        current = current.parent


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def inspect_zip(path: Path, expected_digest: str | None = None) -> dict[str, Any]:
    """Check byte/path/canonical JSON structure only. Never return 'admitted'."""
    _ordinary_zip(path)
    outer_sha = _sha256(path)
    if expected_digest is not None:
        if SHA256_RE.fullmatch(expected_digest) is None:
            fail("expected ZIP digest must be lowercase SHA-256")
        if outer_sha != expected_digest:
            fail("independently supplied ZIP digest mismatch")

    try:
        with zipfile.ZipFile(path, mode="r", allowZip64=False) as archive:
            entries = archive.infolist()
            if len(entries) != len(EXPECTED_NAMES):
                fail("review entry count is not exactly six")
            if archive.comment:
                fail("review ZIP comment forbidden")
            names = [entry.filename for entry in entries]
            if len(set(names)) != len(names) or len({name.casefold() for name in names}) != len(names):
                fail("duplicate or case-colliding review entries")
            if set(names) != EXPECTED_NAMES:
                fail("review ZIP names differ from exact six-entry contract")
            for entry in entries:
                _regular_zip_entry(entry)
            if sum(entry.file_size for entry in entries) > MAX_TOTAL_UNCOMPRESSED:
                fail("review uncompressed bytes exceed preflight ceiling")
            rows: list[dict[str, Any]] = []
            for entry in sorted(entries, key=lambda item: item.filename.encode("utf-8")):
                try:
                    with archive.open(entry, "r") as data:
                        content = data.read(MAX_ENTRY_BYTES + 1)
                        if len(content) > MAX_ENTRY_BYTES or data.read(1):
                            fail("decompressed entry exceeds preflight ceiling")
                except (RuntimeError, OSError, EOFError, ValueError, zipfile.BadZipFile) as exc:
                    if isinstance(exc, PreflightError):
                        raise
                    fail("ZIP entry failed decompression/CRC verification")
                _canonical_document(content, entry.filename)
                rows.append({
                    "name": entry.filename,
                    "byte_length": len(content),
                    "sha256": hashlib.sha256(content).hexdigest(),
                })
    except (OSError, zipfile.BadZipFile, zipfile.LargeZipFile):
        fail("malformed or unsupported ZIP envelope")

    return {
        "authority": AUTHORITY,
        "status": "STRUCTURE_ONLY",
        "admitted": False,
        "physical_compatibility_claimed": False,
        "native_wpt_dispatch_performed": False,
        "repository_mutated": False,
        "zip_sha256": outer_sha,
        "entry_count": len(rows),
        "entries": rows,
        "unverified_gates": [
            "schema_semantics",
            "internal_evidence_dag",
            "policy_and_lock_bindings",
            "predecessor_replay",
            "github_run_artifact_and_job_provenance",
            "trusted_native_identity",
            "pre_post_environment_stability",
            "negative_control_admission",
        ],
    }


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--mode", choices=["structural-preflight"], required=True)
    parser.add_argument("--zip", required=True, help="absolute path to six-entry review ZIP")
    parser.add_argument("--expected-zip-sha256", help="independently supplied lowercase ZIP SHA-256")
    args = parser.parse_args()
    report = inspect_zip(Path(args.zip), args.expected_zip_sha256)
    print(json.dumps(report, sort_keys=True, ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PreflightError as exc:
        print(f"NXB_V11_REVIEW_ZIP_PREFLIGHT_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
