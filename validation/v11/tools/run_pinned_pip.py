#!/usr/bin/env python3
"""Run pip only from a verified bootstrap tree under an admitted Python."""

from __future__ import annotations

import argparse
import importlib
import importlib.util
import os
import re
import runpy
import stat
import sys
from email.parser import Parser
from typing import NoReturn

VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+!-]{0,127}$")
ALLOWED_PIP_ENV = {"PIP_CONFIG_FILE", "PIP_DISABLE_PIP_VERSION_CHECK"}
MAX_PIP_METADATA_BYTES = 1024 * 1024  # Fail closed before parsing untrusted METADATA.


class PinnedPipError(RuntimeError):
    pass


def fail(message: str) -> NoReturn:
    raise PinnedPipError(message)


def is_reparse_or_link(path: str) -> bool:
    st = os.lstat(path)
    if stat.S_ISLNK(st.st_mode):
        return True
    attrs = getattr(st, "st_file_attributes", 0)
    reparse_flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(attrs & reparse_flag)


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


def is_within(child: str, parent: str) -> bool:
    try:
        return os.path.commonpath(
            [os.path.normcase(child), os.path.normcase(parent)]
        ) == os.path.normcase(parent)
    except ValueError:
        return False


def assert_ancestry_ordinary(path: str, stop: str, label: str) -> None:
    current = os.path.abspath(path)
    stop_full = os.path.abspath(stop)
    if not is_within(current, stop_full):
        fail(f"{label} escapes expected root")
    while True:
        if is_reparse_or_link(current):
            fail(f"{label} ancestry is reparse/symlink-backed: {current}")
        if os.path.normcase(current) == os.path.normcase(stop_full):
            break
        parent = os.path.dirname(current)
        if parent == current:
            fail(f"{label} ancestry did not reach expected root")
        current = parent


def assert_sanitized_environment() -> None:
    pip_keys = {key for key in os.environ if key.upper().startswith("PIP_")}
    extras = sorted(
        key for key in pip_keys if key.upper() not in ALLOWED_PIP_ENV
    )
    if extras:
        fail(f"ambient PIP_* environment entries are forbidden: {extras}")
    config = os.environ.get("PIP_CONFIG_FILE")
    if config is None or os.path.normcase(os.path.abspath(config)) != os.path.normcase(os.path.abspath(os.devnull)):
        fail("PIP_CONFIG_FILE must equal the platform null device")
    if os.environ.get("PIP_DISABLE_PIP_VERSION_CHECK") != "1":
        fail("PIP_DISABLE_PIP_VERSION_CHECK must equal 1")
    if "PYTHONPATH" in os.environ or "PYTHONHOME" in os.environ:
        fail("PYTHONPATH/PYTHONHOME must not be inherited")


def _assert_metadata_source_identity(expected: os.stat_result, observed: os.stat_result) -> None:
    fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns")
    if (
        not stat.S_ISREG(observed.st_mode)
        or stat.S_ISLNK(observed.st_mode)
        or getattr(observed, "st_file_attributes", 0)
        & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
        or any(getattr(expected, field) != getattr(observed, field) for field in fields)
    ):
        fail("pip METADATA source file changed during checked read")


def read_dist_info_version(dist_info: str) -> tuple[str, str]:
    metadata = assert_ordinary_file(os.path.join(dist_info, "METADATA"), "pip METADATA")
    try:
        expected = os.lstat(metadata)
        _assert_metadata_source_identity(expected, expected)
        with open(metadata, "rb") as stream:
            _assert_metadata_source_identity(expected, os.fstat(stream.fileno()))
            raw = stream.read(MAX_PIP_METADATA_BYTES + 1)
            _assert_metadata_source_identity(expected, os.fstat(stream.fileno()))
        _assert_metadata_source_identity(expected, os.lstat(metadata))
    except OSError:
        fail("pip METADATA source became unavailable during checked read")
    if not raw or len(raw) > MAX_PIP_METADATA_BYTES:
        fail("pip METADATA byte ceiling exceeded")
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError as exc:
        fail(f"pip METADATA is not strict UTF-8: {exc}")
    message = Parser().parsestr(text)
    name = message.get("Name")
    version = message.get("Version")
    if not name or not version:
        fail("pip METADATA missing Name or Version")
    return name, version


def main() -> int:
    parser = argparse.ArgumentParser(allow_abbrev=False)
    parser.add_argument("--work-root", required=True)
    parser.add_argument("--bootstrap-root", required=True)
    parser.add_argument("--runtime-root", required=True)
    parser.add_argument("--repository-root", required=True)
    parser.add_argument("--expected-python-executable", required=True)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("pip_args", nargs=argparse.REMAINDER)
    args = parser.parse_args()

    work_root = assert_ordinary_directory(args.work_root, "work root")
    bootstrap_root = assert_ordinary_directory(args.bootstrap_root, "bootstrap root")
    runtime_root = assert_ordinary_directory(args.runtime_root, "runtime root")
    repository_root = assert_ordinary_directory(args.repository_root, "repository root")
    expected_python = assert_ordinary_file(
        args.expected_python_executable, "expected Python executable"
    )

    if VERSION_RE.fullmatch(args.expected_version) is None:
        fail("expected pip version syntax is invalid")
    if not is_within(bootstrap_root, work_root) or os.path.normcase(bootstrap_root) == os.path.normcase(work_root):
        fail("bootstrap root must be a strict descendant of work root")
    if is_within(bootstrap_root, runtime_root):
        fail("bootstrap root must be outside immutable runtime root")
    if is_within(bootstrap_root, repository_root):
        fail("bootstrap root must be outside repository root")
    assert_ancestry_ordinary(bootstrap_root, work_root, "bootstrap root")

    actual_python = os.path.abspath(sys.executable)
    if os.path.normcase(actual_python) != os.path.normcase(os.path.abspath(expected_python)):
        fail(f"runtime substitution: expected={expected_python} actual={actual_python}")
    if not is_within(actual_python, runtime_root):
        fail("selected Python executable is outside runtime root")
    if not getattr(sys.flags, "isolated", 0):
        fail("Python must run in isolated mode")
    if not getattr(sys.flags, "ignore_environment", 0):
        fail("Python must ignore ambient Python environment")
    if not getattr(sys.flags, "no_user_site", 0):
        fail("user site must be disabled")
    if "site" in sys.modules:
        fail("site module was imported before bootstrap activation")
    if any(name == "pip" or name.startswith("pip.") for name in sys.modules):
        fail("pip was imported before bootstrap activation")
    assert_sanitized_environment()

    children = os.listdir(bootstrap_root)
    pip_dirs = [
        name for name in children
        if name.casefold() == "pip" and os.path.isdir(os.path.join(bootstrap_root, name))
    ]
    if pip_dirs != ["pip"]:
        fail(f"bootstrap root must contain exactly one exact-case pip package directory: {pip_dirs}")
    dist_infos = [
        name for name in children
        if name.casefold().startswith("pip-")
        and name.casefold().endswith(".dist-info")
        and os.path.isdir(os.path.join(bootstrap_root, name))
    ]
    expected_dist = f"pip-{args.expected_version}.dist-info"
    if dist_infos != [expected_dist]:
        fail(f"bootstrap root pip dist-info mismatch: expected={expected_dist} actual={dist_infos}")

    pip_root = os.path.join(bootstrap_root, "pip")
    dist_root = os.path.join(bootstrap_root, expected_dist)
    assert_ancestry_ordinary(pip_root, bootstrap_root, "pip package root")
    assert_ancestry_ordinary(dist_root, bootstrap_root, "pip dist-info root")
    metadata_name, metadata_version = read_dist_info_version(dist_root)
    if metadata_name.casefold() != "pip" or metadata_version != args.expected_version:
        fail("pip METADATA identity/version drift")

    pip_args = list(args.pip_args)
    if pip_args and pip_args[0] == "--":
        pip_args = pip_args[1:]
    if not pip_args:
        fail("at least one pip argument is required")

    original_sys_path = list(sys.path)
    if any(
        os.path.normcase(os.path.abspath(item or os.curdir))
        == os.path.normcase(bootstrap_root)
        for item in original_sys_path
    ):
        fail("bootstrap root was already present on sys.path")
    sys.path.insert(0, bootstrap_root)

    spec = importlib.util.find_spec("pip")
    if spec is None or spec.origin is None:
        fail("pip module is not importable from bootstrap root")
    origin = os.path.abspath(spec.origin)
    if not is_within(origin, bootstrap_root):
        fail(f"pip module resolved outside bootstrap root: {origin}")

    pip_module = importlib.import_module("pip")
    module_file = os.path.abspath(getattr(pip_module, "__file__", ""))
    if not module_file or not is_within(module_file, bootstrap_root):
        fail(f"pip module file resolved outside bootstrap root: {module_file}")
    actual_version = getattr(pip_module, "__version__", None)
    if actual_version != args.expected_version:
        fail(f"pip version drift: expected={args.expected_version} actual={actual_version}")

    sys.argv = ["pip", *pip_args]
    runpy.run_module("pip", run_name="__main__", alter_sys=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PinnedPipError as exc:
        print(f"NXB_V11_PINNED_PIP_ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)