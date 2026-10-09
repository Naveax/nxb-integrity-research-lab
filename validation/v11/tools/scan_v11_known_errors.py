#!/usr/bin/env python3
"""Deterministic successor-only known-error source scanner."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import unicodedata
from typing import Any, NoReturn

POLICY_AUTHORITY = "nxb-v11-known-error-signatures-v1"
INPUT_AUTHORITY = "nxb-v11-known-error-scan-input-v1"
OUTPUT_AUTHORITY = "nxb-v11-known-error-scan-v1"
# Reject oversized external JSON and source bytes before decoding or regex scanning.
MAX_CANONICAL_INPUT_BYTES = 8 * 1024 * 1024
MAX_SOURCE_BYTES = 8 * 1024 * 1024
VALIDATION_CLASSES = {
    "workflow_orchestration",
    "executable_powershell",
    "executable_python",
    "pester_test",
    "strict_json_policy_or_schema",
    "locked_dependency_manifest",
    "logical_fixture_spec",
    "authority_documentation",
}
RULE_ID_RE = re.compile(r"^NXB-V11-ERR-[0-9]{3}$")
FLAG_MAP = {
    "IGNORECASE": re.IGNORECASE,
    "MULTILINE": re.MULTILINE,
    "DOTALL": re.DOTALL,
}


class ScanError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise ScanError(message)


def reject_float(value: str) -> NoReturn:
    fail(f"floating-point JSON number forbidden: {value}")


def object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON property: {key}")
        result[key] = value
    return result


def validate_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty string")
    if unicodedata.normalize("NFC", value) != value:
        fail(f"{label} must be NFC-normalized")
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        fail(f"{label} contains a control character")
    # JSON escapes can parse isolated UTF-16 surrogates that strict UTF-8
    # canonical output cannot encode. Reject them as ordinary ScanError.
    if any(0xD800 <= ord(ch) <= 0xDFFF for ch in value):
        fail(f"{label} contains invalid Unicode surrogate")
    return value


def canonical_bytes(value: Any) -> bytes:
    def walk(item: Any, label: str = "$") -> None:
        if item is None or isinstance(item, (bool, int)):
            return
        if isinstance(item, float):
            fail(f"{label} contains floating-point value")
        if isinstance(item, str):
            validate_string(item, label)
            return
        if isinstance(item, list):
            for index, child in enumerate(item):
                walk(child, f"{label}[{index}]")
            return
        if isinstance(item, dict):
            for key, child in item.items():
                validate_string(key, f"{label}.<key>")
                walk(child, f"{label}.{key}")
            return
        fail(f"{label} contains unsupported type: {type(item).__name__}")

    walk(value)
    return json.dumps(
        value,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def _assert_stable_source_identity(expected: os.stat_result, observed: os.stat_result, label: str) -> None:
    fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns")
    if (
        not stat.S_ISREG(observed.st_mode)
        or stat.S_ISLNK(observed.st_mode)
        or getattr(observed, "st_file_attributes", 0)
        & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        or any(getattr(expected, field) != getattr(observed, field) for field in fields)
    ):
        fail(f"{label} source file changed during read")


def load_canonical_json(path: str, label: str) -> tuple[dict[str, Any], bytes]:
    full = os.path.abspath(path)
    assert_ordinary_directory_chain(os.path.dirname(full), label)
    try:
        expected = os.lstat(full)
        _assert_stable_source_identity(expected, expected, label)
        with open(full, "rb") as stream:
            _assert_stable_source_identity(expected, os.fstat(stream.fileno()), label)
            raw = stream.read(MAX_CANONICAL_INPUT_BYTES + 1)
            _assert_stable_source_identity(expected, os.fstat(stream.fileno()), label)
        _assert_stable_source_identity(expected, os.lstat(full), label)
    except OSError:
        fail(f"{label} source file became unavailable during canonical read")
    if len(raw) > MAX_CANONICAL_INPUT_BYTES:
        fail(f"{label} exceeds canonical input byte ceiling")
    if raw.startswith(b"\xef\xbb\xbf"):
        fail(f"{label} must not contain a UTF-8 BOM")
    try:
        text = raw.decode("utf-8", "strict")
        value = json.loads(
            text,
            object_pairs_hook=object_pairs,
            parse_float=reject_float,
            parse_constant=lambda x: fail(f"{label} non-finite number forbidden: {x}"),
        )
    except ScanError:
        raise
    except (UnicodeDecodeError, json.JSONDecodeError, TypeError, ValueError, RecursionError) as exc:
        fail(f"{label} is not strict UTF-8 JSON: {exc}")
    if not isinstance(value, dict):
        fail(f"{label} root must be an object")
    try:
        canonical = canonical_bytes(value)
    except RecursionError:
        fail(f"{label} JSON nesting exceeds safe recursion depth")
    if raw != canonical:
        fail(f"{label} bytes are not canonical JSON")
    return value, raw


def exact_keys(obj: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(obj, dict):
        fail(f"{label} must be an object")
    actual = set(obj)
    if actual != expected:
        fail(
            f"{label} property drift: "
            f"missing={sorted(expected-actual)} extra={sorted(actual-expected)}"
        )
    return obj


def validate_repo_path(value: Any, label: str) -> str:
    path = validate_string(value, label)
    if path.startswith("/") or "\\" in path:
        fail(f"{label} must be repository-relative with '/' separators")
    if "//" in path:
        fail(f"{label} contains an empty segment")
    parts = path.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        fail(f"{label} contains dot/empty traversal segment")
    return path


def is_reparse_or_link(path: str) -> bool:
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        return True
    attrs = getattr(st, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attrs & reparse_flag)


def assert_ordinary_directory_chain(path: str, label: str, *, stop: str | None = None) -> None:
    # Reject a junction/symlink in any parent, not just the final directory.
    current = path
    while True:
        try:
            metadata = os.lstat(current)
        except OSError:
            fail(f"{label} directory ancestor is unreadable: {current}")
        if not stat.S_ISDIR(metadata.st_mode):
            fail(f"{label} directory ancestor is not ordinary: {current}")
        if stat.S_ISLNK(metadata.st_mode) or (
            getattr(metadata, "st_file_attributes", 0)
            & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        ):
            fail(f"{label} directory ancestor is reparse/symlink-backed: {current}")
        if current == stop:
            return
        parent = os.path.dirname(current)
        if parent == current:
            return
        current = parent


def assert_repository_root(path: str) -> str:
    full = os.path.abspath(path)
    if not os.path.isabs(path):
        fail("repository root must be an existing absolute directory")
    assert_ordinary_directory_chain(full, "repository root")
    return full


def resolve_repository_file(root: str, relative: str) -> str:
    candidate = os.path.abspath(os.path.join(root, *relative.split("/")))
    try:
        inside = os.path.commonpath(
            [os.path.normcase(candidate), os.path.normcase(root)]
        ) == os.path.normcase(root)
    except ValueError:
        inside = False
    if not inside:
        fail(f"scan path escapes repository root: {relative}")
    assert_ordinary_directory_chain(
        os.path.dirname(candidate), f"scan path {relative}", stop=root
    )
    if not os.path.isfile(candidate):
        fail(f"scan path missing/non-file: {relative}")
    if is_reparse_or_link(candidate):
        fail(f"scan path is reparse/symlink-backed: {relative}")
    return candidate


def read_source(path: str, relative: str) -> str:
    full = os.path.abspath(path)
    assert_ordinary_directory_chain(os.path.dirname(full), f"scan source {relative}")
    try:
        expected = os.lstat(full)
        _assert_stable_source_identity(expected, expected, f"scan source {relative}")
        with open(full, "rb") as stream:
            _assert_stable_source_identity(expected, os.fstat(stream.fileno()), f"scan source {relative}")
            raw = stream.read(MAX_SOURCE_BYTES + 1)
            _assert_stable_source_identity(expected, os.fstat(stream.fileno()), f"scan source {relative}")
        _assert_stable_source_identity(expected, os.lstat(full), f"scan source {relative}")
    except OSError:
        fail(f"scan source became unavailable: {relative}")
    if len(raw) > MAX_SOURCE_BYTES:
        fail(f"scan source byte ceiling exceeded: {relative}")
    if raw.startswith(b"\xef\xbb\xbf"):
        fail(f"scan path contains UTF-8 BOM: {relative}")
    try:
        return raw.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        fail(f"scan path is not strict UTF-8: {relative}: {exc}")


def validate_policy(value: dict[str, Any]) -> list[dict[str, Any]]:
    root = exact_keys(value, {"authority", "schema_version", "rules"}, "policy")
    if (
        root["authority"] != POLICY_AUTHORITY
        or type(root["schema_version"]) is not int
        or root["schema_version"] != 1
    ):
        fail("policy authority/schema_version drift")
    rules = root["rules"]
    if not isinstance(rules, list) or not rules:
        fail("policy.rules must be non-empty")

    seen_ids: set[str] = set()
    parsed: list[dict[str, Any]] = []
    for index, item in enumerate(rules):
        row = exact_keys(
            item,
            {
                "id",
                "description",
                "applies_to",
                "regex",
                "flags",
                "severity",
                "failure_override_permitted",
            },
            f"policy.rules[{index}]",
        )
        rule_id = validate_string(row["id"], f"policy.rules[{index}].id")
        if RULE_ID_RE.fullmatch(rule_id) is None:
            fail(f"policy.rules[{index}].id syntax invalid")
        if rule_id in seen_ids:
            fail(f"duplicate known-error rule id: {rule_id}")
        seen_ids.add(rule_id)

        validate_string(row["description"], f"policy.rules[{index}].description")
        applies = row["applies_to"]
        if not isinstance(applies, list) or not applies:
            fail(f"policy.rules[{index}].applies_to must be non-empty")
        if any(not isinstance(item, str) for item in applies):
            fail(f"policy.rules[{index}].applies_to must contain only strings")
        if len(applies) != len(set(applies)):
            fail(f"policy.rules[{index}].applies_to contains duplicates")
        if any(x not in VALIDATION_CLASSES for x in applies):
            fail(f"policy.rules[{index}].applies_to contains unknown class")

        pattern = validate_string(row["regex"], f"policy.rules[{index}].regex")
        flags = row["flags"]
        if not isinstance(flags, list):
            fail(f"policy.rules[{index}].flags invalid")
        if any(not isinstance(flag, str) for flag in flags):
            fail(f"policy.rules[{index}].flags must contain only strings")
        if len(flags) != len(set(flags)):
            fail(f"policy.rules[{index}].flags invalid")
        if any(flag not in FLAG_MAP for flag in flags):
            fail(f"policy.rules[{index}].flags contains unknown flag")
        if row["severity"] != "error" or row["failure_override_permitted"] is not False:
            fail(f"policy.rules[{index}] may not suppress/reclassify failure")

        options = 0
        for flag in flags:
            options |= FLAG_MAP[flag]
        try:
            compiled = re.compile(pattern, options)
        except re.error as exc:
            fail(f"policy.rules[{index}].regex invalid: {exc}")
        parsed.append(
            {
                "id": rule_id,
                "applies_to": set(applies),
                "regex": compiled,
            }
        )
    return parsed


def validate_input(value: dict[str, Any]) -> list[dict[str, str]]:
    root = exact_keys(
        value,
        {"authority", "schema_version", "repository", "entries"},
        "input",
    )
    if (
        root["authority"] != INPUT_AUTHORITY
        or type(root["schema_version"]) is not int
        or root["schema_version"] != 1
    ):
        fail("input authority/schema_version drift")
    validate_string(root["repository"], "input.repository")

    entries = root["entries"]
    if not isinstance(entries, list) or not entries:
        fail("input.entries must be non-empty")
    parsed: list[dict[str, str]] = []
    seen_exact: set[str] = set()
    seen_folded: set[str] = set()
    for index, item in enumerate(entries):
        row = exact_keys(item, {"path", "validation_class"}, f"input.entries[{index}]")
        path = validate_repo_path(row["path"], f"input.entries[{index}].path")
        validation_class = row["validation_class"]
        if not isinstance(validation_class, str):
            fail(f"input.entries[{index}].validation_class must be a string")
        if validation_class not in VALIDATION_CLASSES:
            fail(f"input.entries[{index}].validation_class unknown")
        if path in seen_exact:
            fail(f"duplicate scan path: {path}")
        folded = path.casefold()
        if folded in seen_folded:
            fail(f"case-fold scan path collision: {path}")
        seen_exact.add(path)
        seen_folded.add(folded)
        parsed.append({"path": path, "validation_class": validation_class})
    return sorted(parsed, key=lambda row: row["path"].encode("utf-8"))


def line_number(text: str, index: int) -> int:
    return text.count("\n", 0, index) + 1


def preview(value: str) -> str:
    compact = re.sub(r"[\r\n]+", " ", value).strip()
    return compact[:180]


def assert_output_path(path: str) -> str:
    full = os.path.abspath(path)
    assert_ordinary_directory_chain(os.path.dirname(full), "output parent")
    if os.path.lexists(full):
        fail("output already exists")
    return full


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--repository-root", required=True)
    parser.add_argument("--policy", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    output_path = assert_output_path(args.output)
    root = assert_repository_root(args.repository_root)
    policy_obj, policy_raw = load_canonical_json(args.policy, "policy")
    rules = validate_policy(policy_obj)
    input_obj, _ = load_canonical_json(args.input, "input")
    entries = validate_input(input_obj)

    findings: list[dict[str, Any]] = []
    for entry in entries:
        source_path = resolve_repository_file(root, entry["path"])
        source = read_source(source_path, entry["path"])
        for rule in rules:
            if entry["validation_class"] not in rule["applies_to"]:
                continue
            for match in rule["regex"].finditer(source):
                findings.append(
                    {
                        "id": rule["id"],
                        "path": entry["path"],
                        "validation_class": entry["validation_class"],
                        "index": match.start(),
                        "line": line_number(source, match.start()),
                        "preview": preview(match.group(0)),
                    }
                )

    findings.sort(
        key=lambda row: (
            row["id"],
            row["path"].encode("utf-8"),
            row["index"],
        )
    )
    result = {
        "authority": OUTPUT_AUTHORITY,
        "schema_version": 1,
        "signature_policy_sha256": hashlib.sha256(policy_raw).hexdigest(),
        "entry_count": len(entries),
        "rule_count": len(rules),
        "finding_count": len(findings),
        "status": "passed" if not findings else "failed",
        "failure_override_permitted": False,
        "findings": findings,
    }
    payload = canonical_bytes(result)

    assert_output_path(output_path)
    try:
        descriptor = os.open(
            output_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
    except FileExistsError:
        fail(f"output already exists: {output_path}")
    except OSError:
        fail(f"output became unavailable during exclusive creation: {output_path}")
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    except OSError:
        fail(f"output write or sync failed: {output_path}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)

    print(
        "NXB_V11_KNOWN_ERROR_SCAN_PASS "
        f"status={result['status']} "
        f"findings={len(findings)} "
        f"entries={len(entries)}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ScanError as exc:
        print(f"NXB_V11_KNOWN_ERROR_SCAN_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
