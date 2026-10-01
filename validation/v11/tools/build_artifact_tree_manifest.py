#!/usr/bin/env python3
"""Build the logical nxb-artifact-tree-manifest-v1 document.

This tool is intentionally stdlib-only and does not compute the semantic tree
digest. The next boundary canonicalizes this logical document with the frozen
NXB canonical JSON primitive and hashes those canonical bytes.
"""

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import unicodedata

CONTRACT_ID = "nxb-artifact-tree-manifest-v1"
ROOT_ROLE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
WINDOWS_RESERVED = {
    "CON", "PRN", "AUX", "NUL",
    *(f"COM{i}" for i in range(1, 10)),
    *(f"LPT{i}" for i in range(1, 10)),
}
MAX_I64 = (1 << 63) - 1


class ManifestError(RuntimeError):
    pass


def fail(message: str) -> "NoReturn":
    raise ManifestError(message)


def is_reparse_or_link(path: str) -> bool:
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        return True
    attrs = getattr(st, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attrs & reparse_flag)


def assert_ordinary_directory(path: str, label: str) -> str:
    full = os.path.abspath(path)
    if path != full:
        fail(f"{label} must be absolute: {path}")
    if not os.path.isdir(full):
        fail(f"{label} is not a directory: {full}")
    if is_reparse_or_link(full):
        fail(f"{label} is reparse/symlink-backed: {full}")
    return full


def assert_output_path(path: str) -> str:
    full = os.path.abspath(path)
    if path != full:
        fail(f"output must be absolute: {path}")
    if os.path.exists(full):
        fail(f"output already exists: {full}")
    parent = os.path.dirname(full)
    assert_ordinary_directory(parent, "output parent")
    return full


def validate_relative_path(relative_path: str) -> str:
    if not relative_path or relative_path.startswith("/"):
        fail(f"invalid relative path: {relative_path!r}")
    if "\\" in relative_path:
        fail(f"backslash survived path normalization: {relative_path!r}")
    if unicodedata.normalize("NFC", relative_path) != relative_path:
        fail(f"path is not NFC-normalized: {relative_path!r}")
    if any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in relative_path):
        fail(f"path contains control character: {relative_path!r}")
    parts = relative_path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        fail(f"path contains empty/dot/traversal segment: {relative_path!r}")
    for part in parts:
        if part.endswith((" ", ".")):
            fail(f"path has trailing space/dot segment: {relative_path!r}")
        if ":" in part:
            fail(f"path has ADS/colon segment: {relative_path!r}")
        stem = part.split(".", 1)[0].upper()
        if stem in WINDOWS_RESERVED:
            fail(f"path has reserved Windows device segment: {relative_path!r}")
    return relative_path


def sha256_file(path: str) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with open(path, "rb", buffering=1024 * 1024) as stream:
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            size += len(block)
            if size > MAX_I64:
                fail(f"file exceeds Int64 byte range: {path}")
            digest.update(block)
    return size, digest.hexdigest()


def build_manifest(root: str, root_role: str) -> dict:
    if not ROOT_ROLE_RE.fullmatch(root_role):
        fail("root-role must be non-empty ASCII [A-Za-z0-9._-], max 128 chars")

    root_full = assert_ordinary_directory(root, "root")
    rows: list[dict] = []
    seen_exact: set[str] = set()
    seen_folded: set[str] = set()
    seen_directories_exact: set[str] = set()
    seen_directories_folded: set[str] = set()

    for current, dir_names, file_names in os.walk(root_full, topdown=True, followlinks=False):
        if is_reparse_or_link(current):
            fail(f"traversed directory is reparse/symlink-backed: {current}")

        if current != root_full:
            current_rel = validate_relative_path(
                os.path.relpath(current, root_full).replace("\\", "/")
            )
            current_folded = current_rel.casefold()
            if current_rel in seen_exact:
                fail(f"file/directory path collision: {current_rel}")
            if current_folded in seen_folded:
                fail(f"Windows file/directory case-fold collision: {current_rel}")
            if current_rel in seen_directories_exact:
                fail(f"duplicate directory path: {current_rel}")
            if current_folded in seen_directories_folded:
                fail(f"Windows directory case-fold collision: {current_rel}")
            seen_directories_exact.add(current_rel)
            seen_directories_folded.add(current_folded)

        for name in list(dir_names):
            child = os.path.join(current, name)
            if is_reparse_or_link(child):
                fail(f"child directory is reparse/symlink-backed: {child}")
            if not os.path.isdir(child):
                fail(f"directory enumeration produced non-directory: {child}")
            child_rel = validate_relative_path(
                os.path.relpath(child, root_full).replace("\\", "/")
            )
            child_folded = child_rel.casefold()
            if child_rel in seen_exact:
                fail(f"file/directory path collision: {child_rel}")
            if child_folded in seen_folded:
                fail(f"Windows file/directory case-fold collision: {child_rel}")

        for name in file_names:
            path = os.path.join(current, name)
            if is_reparse_or_link(path):
                fail(f"file is reparse/symlink-backed: {path}")
            st = os.lstat(path)
            if not stat.S_ISREG(st.st_mode):
                fail(f"non-regular file rejected: {path}")

            rel = os.path.relpath(path, root_full).replace("\\", "/")
            rel = validate_relative_path(rel)
            exact_key = rel
            folded_key = rel.casefold()
            if exact_key in seen_directories_exact:
                fail(f"file/directory path collision: {rel}")
            if folded_key in seen_directories_folded:
                fail(f"Windows file/directory case-fold collision: {rel}")
            if exact_key in seen_exact:
                fail(f"duplicate normalized path: {rel}")
            if folded_key in seen_folded:
                fail(f"Windows case-fold path collision: {rel}")
            seen_exact.add(exact_key)
            seen_folded.add(folded_key)

            size, digest = sha256_file(path)
            if not SHA256_RE.fullmatch(digest):
                fail("internal SHA-256 formatting failure")
            rows.append({
                "relative_path": rel,
                "byte_length": size,
                "sha256": digest,
            })

    rows.sort(key=lambda row: row["relative_path"].encode("utf-8"))
    total = sum(row["byte_length"] for row in rows)
    if len(rows) > MAX_I64 or total > MAX_I64:
        fail("manifest count/total exceeds signed Int64 range")

    return {
        "contract_id": CONTRACT_ID,
        "root_role": root_role,
        "file_count": len(rows),
        "total_bytes": total,
        "files": rows,
    }


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False, allow_abbrev=False)
    parser.add_argument("--root", required=True)
    parser.add_argument("--root-role", required=True)
    parser.add_argument("--output", required=True)
    args = parser.parse_args()

    output = assert_output_path(args.output)
    manifest = build_manifest(args.root, args.root_role)
    encoded = json.dumps(
        manifest,
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=False,
    ).encode("utf-8")

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    descriptor = os.open(output, flags, 0o600)
    try:
        with os.fdopen(descriptor, "wb", closefd=True) as stream:
            descriptor = -1
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
    finally:
        if descriptor >= 0:
            os.close(descriptor)

    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as exc:
        print(f"NXB_ARTIFACT_TREE_MANIFEST_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
