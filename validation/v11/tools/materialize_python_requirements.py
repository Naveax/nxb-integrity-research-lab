#!/usr/bin/env python3
"""Materialize deterministic pip requirements from a V11 canonical JSON lock."""

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

AUTHORITY = "nxb-v11-python-dependency-lock-v1"
TREE_PROFILE = "nxb-artifact-tree-manifest-v1"
PIP_BOOTSTRAP_AUTHORITY = "nxb-v11-pip-bootstrap-v1"
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
MAX_LOCK_BYTES = 1024 * 1024  # Bounded before canonical JSON parsing.
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+!-]{0,127}$")
WHEEL_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,507}\.whl$")
TAG_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,255}$")
SOURCE_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")

TOP_LEVEL_KEYS = {
    "authority", "schema_version", "python_full_version", "architecture",
    "platform_tag", "generation_python_version", "generation_pip_version",
    "source_index_identity", "artifact_tree_profile", "pip_bootstrap", "packages",
}
PIP_BOOTSTRAP_KEYS = {
    "authority", "version", "artifact_name", "artifact_sha256", "source_project",
    "source_index_identity", "publisher_identity", "source_repository",
    "source_commit", "source_tag", "provenance_subject_sha256", "python_requires",
    "artifact_tree_manifest_sha256",
}
PACKAGE_KEYS = {
    "normalized_name", "version", "wheel_filename", "wheel_sha256", "wheel_tags",
}


class ProjectionError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise ProjectionError(message)


def _reject_float(value: str) -> NoReturn:
    fail(f"floating-point JSON number is forbidden: {value}")


def _object_pairs(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            fail(f"duplicate JSON property: {key}")
        result[key] = value
    return result


def _assert_nfc(value: str, label: str) -> None:
    if unicodedata.normalize("NFC", value) != value:
        fail(f"{label} is not NFC-normalized")
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        fail(f"{label} contains a control character")


def _walk_strings(value: Any, label: str = "$") -> None:
    if isinstance(value, str):
        _assert_nfc(value, label)
    elif isinstance(value, list):
        for index, item in enumerate(value):
            _walk_strings(item, f"{label}[{index}]")
    elif isinstance(value, dict):
        for key, item in value.items():
            _assert_nfc(key, f"{label}.<key>")
            _walk_strings(item, f"{label}.{key}")


def load_canonical_json(path: str) -> dict[str, Any]:
    with open(path, "rb") as stream:
        raw = stream.read(MAX_LOCK_BYTES + 1)
    if not raw or len(raw) > MAX_LOCK_BYTES:
        fail("lock byte ceiling exceeded")
    if raw.startswith(b"\xef\xbb\xbf"):
        fail("lock must not contain a UTF-8 BOM")
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        fail(f"lock is not strict UTF-8: {exc}")
    try:
        document = json.loads(
            text,
            object_pairs_hook=_object_pairs,
            parse_float=_reject_float,
            parse_constant=lambda value: fail(f"non-finite JSON number forbidden: {value}"),
        )
    except ProjectionError:
        raise
    except (json.JSONDecodeError, TypeError, ValueError) as exc:
        fail(f"lock is not strict JSON: {exc}")
    if not isinstance(document, dict):
        fail("lock root must be an object")
    _walk_strings(document)
    canonical = json.dumps(
        document,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")
    if raw != canonical:
        fail("lock bytes are not NXB canonical JSON")
    return document


def assert_exact_keys(value: Any, expected: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be an object")
    actual = set(value)
    if actual != expected:
        fail(
            f"{label} property-set drift: "
            f"missing={sorted(expected - actual)} extra={sorted(actual - expected)}"
        )
    return value


def assert_string(value: Any, label: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str) or not value:
        fail(f"{label} must be a non-empty string")
    _assert_nfc(value, label)
    if pattern is not None and pattern.fullmatch(value) is None:
        fail(f"{label} has invalid syntax: {value!r}")
    return value


def assert_sha256(value: Any, label: str) -> str:
    return assert_string(value, label, SHA256_RE)


def is_reparse_or_link(path: str) -> bool:
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        return True
    attrs = getattr(st, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attrs & reparse_flag)


def assert_ordinary_ancestors(full: str, label: str) -> None:
    # Reject regular-looking inputs reached through a junction/symlink parent.
    current = os.path.dirname(full)
    while True:
        try:
            metadata = os.lstat(current)
        except OSError:
            fail(f"{label} ancestor unreadable: {current}")
        if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode) or (
            getattr(metadata, "st_file_attributes", 0)
            & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        ):
            fail(f"{label} ancestor not an ordinary directory: {current}")
        parent = os.path.dirname(current)
        if parent == current:
            return
        current = parent


def assert_ordinary_file(path: str, label: str) -> str:
    if not os.path.isabs(path):
        fail(f"{label} must be absolute: {path}")
    full = os.path.abspath(path)
    if not os.path.isfile(full):
        fail(f"{label} is not an existing file: {full}")
    if is_reparse_or_link(full):
        fail(f"{label} is reparse/symlink-backed: {full}")
    assert_ordinary_ancestors(full, label)
    return full


def assert_ordinary_directory(path: str, label: str) -> str:
    if not os.path.isabs(path):
        fail(f"{label} must be absolute: {path}")
    full = os.path.abspath(path)
    if not os.path.isdir(full):
        fail(f"{label} is not an existing directory: {full}")
    if is_reparse_or_link(full):
        fail(f"{label} is reparse/symlink-backed: {full}")
    assert_ordinary_ancestors(full, label)
    return full


def is_within(child: str, parent: str) -> bool:
    try:
        return os.path.commonpath(
            [os.path.normcase(child), os.path.normcase(parent)]
        ) == os.path.normcase(parent)
    except ValueError:
        return False


def assert_existing_ancestry_ordinary(path: str, stop: str, label: str) -> None:
    current = os.path.abspath(path)
    stop_full = os.path.abspath(stop)
    if not is_within(current, stop_full):
        fail(f"{label} escapes work root")
    while True:
        if os.path.exists(current) and is_reparse_or_link(current):
            fail(f"{label} ancestry is reparse/symlink-backed: {current}")
        if os.path.normcase(current) == os.path.normcase(stop_full):
            break
        parent = os.path.dirname(current)
        if parent == current:
            fail(f"{label} ancestry did not reach work root")
        current = parent


def parse_wheel_identity(filename: str, label: str) -> tuple[str, str, list[str]]:
    """Decode the distribution/version and expanded PEP 427 tags from a wheel name."""
    pieces = filename[:-4].split("-")
    if len(pieces) not in (5, 6):
        fail(f"{label} must contain a complete wheel identity")
    distribution, version = pieces[0], pieces[1]
    if not distribution or not version:
        fail(f"{label} has an empty wheel distribution/version")
    if len(pieces) == 6 and re.fullmatch(r"[0-9][A-Za-z0-9_.]*", pieces[2]) is None:
        fail(f"{label} has an invalid wheel build tag")
    tag_parts = [group.split(".") for group in pieces[-3:]]
    if any(not group or any(TAG_RE.fullmatch(tag) is None for tag in group) for group in tag_parts):
        fail(f"{label} has invalid wheel compatibility tags")
    expanded = sorted(
        f"{python}-{abi}-{platform}"
        for python in tag_parts[0]
        for abi in tag_parts[1]
        for platform in tag_parts[2]
    )
    normalized = re.sub(r"[-_.]+", "-", distribution).lower()
    return normalized, version, sorted(set(expanded))


def validate_lock(document: dict[str, Any]) -> list[dict[str, Any]]:
    root = assert_exact_keys(document, TOP_LEVEL_KEYS, "lock")
    if root["authority"] != AUTHORITY:
        fail("lock.authority drift")
    if type(root["schema_version"]) is not int or root["schema_version"] != 1:
        fail("lock.schema_version must equal integer 1")
    assert_string(root["python_full_version"], "lock.python_full_version", VERSION_RE)
    if root["architecture"] not in {"x64", "arm64"}:
        fail("lock.architecture must be x64 or arm64")
    assert_string(root["platform_tag"], "lock.platform_tag", TAG_RE)
    assert_string(root["generation_python_version"], "lock.generation_python_version", VERSION_RE)
    assert_string(root["generation_pip_version"], "lock.generation_pip_version", VERSION_RE)
    assert_string(root["source_index_identity"], "lock.source_index_identity")
    if root["artifact_tree_profile"] != TREE_PROFILE:
        fail("lock.artifact_tree_profile drift")

    bootstrap = assert_exact_keys(
        root["pip_bootstrap"], PIP_BOOTSTRAP_KEYS, "lock.pip_bootstrap"
    )
    if bootstrap["authority"] != PIP_BOOTSTRAP_AUTHORITY:
        fail("lock.pip_bootstrap.authority drift")
    assert_string(bootstrap["version"], "lock.pip_bootstrap.version", VERSION_RE)
    assert_string(
        bootstrap["artifact_name"], "lock.pip_bootstrap.artifact_name", WHEEL_RE
    )
    assert_sha256(
        bootstrap["artifact_sha256"], "lock.pip_bootstrap.artifact_sha256"
    )
    if bootstrap["source_project"] != "pip":
        fail("lock.pip_bootstrap.source_project must be pip")
    for key in (
        "source_index_identity", "publisher_identity", "source_repository",
        "source_tag", "python_requires",
    ):
        assert_string(bootstrap[key], f"lock.pip_bootstrap.{key}")
    assert_string(
        bootstrap["source_commit"], "lock.pip_bootstrap.source_commit",
        SOURCE_COMMIT_RE,
    )
    assert_sha256(
        bootstrap["provenance_subject_sha256"],
        "lock.pip_bootstrap.provenance_subject_sha256",
    )
    assert_sha256(
        bootstrap["artifact_tree_manifest_sha256"],
        "lock.pip_bootstrap.artifact_tree_manifest_sha256",
    )
    if bootstrap["source_index_identity"] != root["source_index_identity"]:
        fail("pip bootstrap source index identity differs from lock source index")
    if bootstrap["provenance_subject_sha256"] != bootstrap["artifact_sha256"]:
        fail("pip bootstrap provenance subject digest must equal artifact SHA-256")
    bootstrap_name, bootstrap_version, _ = parse_wheel_identity(
        bootstrap["artifact_name"], "lock.pip_bootstrap.artifact_name"
    )
    if bootstrap_name != "pip" or bootstrap_version != bootstrap["version"]:
        fail("pip bootstrap wheel distribution/version differs from declared pip identity")

    packages = root["packages"]
    if not isinstance(packages, list) or not packages:
        fail("lock.packages must be a non-empty array")
    names: set[str] = set()
    filenames: set[str] = set()
    folded_filenames: set[str] = set()
    last_name: bytes | None = None
    validated: list[dict[str, Any]] = []
    for index, item in enumerate(packages):
        package = assert_exact_keys(item, PACKAGE_KEYS, f"lock.packages[{index}]")
        name = assert_string(
            package["normalized_name"],
            f"lock.packages[{index}].normalized_name",
            NAME_RE,
        )
        version = assert_string(
            package["version"], f"lock.packages[{index}].version", VERSION_RE
        )
        filename = assert_string(
            package["wheel_filename"],
            f"lock.packages[{index}].wheel_filename",
            WHEEL_RE,
        )
        digest = assert_sha256(
            package["wheel_sha256"], f"lock.packages[{index}].wheel_sha256"
        )
        tags = package["wheel_tags"]
        if not isinstance(tags, list) or not tags:
            fail(f"lock.packages[{index}].wheel_tags must be non-empty")
        if any(not isinstance(tag, str) or TAG_RE.fullmatch(tag) is None for tag in tags):
            fail(f"lock.packages[{index}].wheel_tags contains invalid tag")
        if tags != sorted(set(tags)):
            fail(
                f"lock.packages[{index}].wheel_tags must be ordinal-sorted and unique"
            )
        if name in names:
            fail(f"duplicate normalized package name: {name}")
        names.add(name)
        if filename in filenames:
            fail(f"duplicate wheel filename: {filename}")
        folded = filename.casefold()
        if folded in folded_filenames:
            fail(f"Windows case-fold wheel filename collision: {filename}")
        filenames.add(filename)
        folded_filenames.add(folded)
        wheel_name, wheel_version, wheel_tags = parse_wheel_identity(
            filename, f"lock.packages[{index}].wheel_filename"
        )
        if wheel_name != name:
            fail(f"lock.packages[{index}] wheel distribution name differs from normalized_name")
        if wheel_version != version:
            fail(f"lock.packages[{index}] wheel version differs from declared version")
        if wheel_tags != tags:
            fail(f"lock.packages[{index}] wheel tags differ from declared wheel_tags")
        name_bytes = name.encode("utf-8")
        if last_name is not None and name_bytes <= last_name:
            fail("lock.packages must be strictly sorted by UTF-8 normalized_name bytes")
        last_name = name_bytes
        validated.append(
            {
                "normalized_name": name,
                "version": version,
                "wheel_filename": filename,
                "wheel_sha256": digest,
                "wheel_tags": tags,
            }
        )
    return validated


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--lock", required=True)
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    lock_path = assert_ordinary_file(args.lock, "lock")
    work_root = assert_ordinary_directory(args.work_root, "work root")
    if not os.path.isabs(args.output):
        fail("output must be absolute")
    output = os.path.abspath(args.output)
    if os.path.exists(output):
        fail(f"output already exists: {output}")
    parent = assert_ordinary_directory(os.path.dirname(output), "output parent")
    if not is_within(parent, work_root):
        fail("output parent must be beneath the declared work root")
    assert_existing_ancestry_ordinary(parent, work_root, "output parent")

    packages = validate_lock(load_canonical_json(lock_path))
    lines = [
        f"{p['normalized_name']}=={p['version']} --hash=sha256:{p['wheel_sha256']}"
        for p in packages
    ]
    payload = ("\n".join(lines) + "\n").encode("utf-8")
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            descriptor = -1
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    print(
        "NXB_V11_PYTHON_REQUIREMENTS_PROJECTION_PASS "
        f"count={len(packages)} sha256={hashlib.sha256(payload).hexdigest()}"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ProjectionError as exc:
        print(f"NXB_V11_PYTHON_REQUIREMENTS_PROJECTION_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)