#!/usr/bin/env python3
"""Safely update scalar values in PalWorldSettings.ini.

Palworld stores its options inside one Unreal Engine OptionSettings=(...) tuple.
This utility edits only existing scalar keys and writes the file atomically.
"""

from __future__ import annotations

import argparse
import os
import re
import stat
import tempfile
from pathlib import Path


KEY_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]*$")


def split_assignment(value: str) -> tuple[str, str]:
    if "=" not in value:
        raise argparse.ArgumentTypeError("expected KEY=VALUE")
    key, item = value.split("=", 1)
    if not KEY_RE.fullmatch(key):
        raise argparse.ArgumentTypeError(f"invalid Palworld option key: {key}")
    return key, item


def quote_unreal(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def replace_scalar(text: str, key: str, serialized: str) -> str:
    pattern = re.compile(
        rf"(?<![A-Za-z0-9_]){re.escape(key)}="
        r'(?P<value>"(?:\\.|[^"\\])*"|[^,\r\n)]*)'
    )
    updated, count = pattern.subn(lambda _: f"{key}={serialized}", text)
    if count != 1:
        raise ValueError(f"expected exactly one existing {key}= option, found {count}")
    return updated


def atomic_write(path: Path, content: str) -> None:
    original = path.stat()
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", newline="", dir=path.parent, delete=False
    ) as handle:
        temporary = Path(handle.name)
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())

    os.chmod(temporary, stat.S_IMODE(original.st_mode))
    try:
        os.chown(temporary, original.st_uid, original.st_gid)
    except PermissionError:
        pass
    os.replace(temporary, path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--file", required=True, type=Path)
    parser.add_argument("--string", action="append", default=[], type=split_assignment)
    parser.add_argument("--string-file", action="append", default=[], type=split_assignment)
    parser.add_argument("--bool", action="append", default=[], type=split_assignment)
    parser.add_argument("--int", action="append", default=[], type=split_assignment)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    text = args.file.read_text(encoding="utf-8")
    if "OptionSettings=(" not in text:
        raise ValueError("OptionSettings tuple was not found")

    replacements: list[tuple[str, str]] = []
    replacements.extend((key, quote_unreal(value)) for key, value in args.string)
    for key, filename in args.string_file:
        value = Path(filename).read_text(encoding="utf-8").splitlines()[0]
        replacements.append((key, quote_unreal(value)))

    for key, value in args.bool:
        normalized = value.lower()
        if normalized not in {"true", "false"}:
            raise ValueError(f"{key} expects true or false")
        replacements.append((key, "True" if normalized == "true" else "False"))

    for key, value in args.int:
        if not re.fullmatch(r"[0-9]+", value):
            raise ValueError(f"{key} expects a non-negative integer")
        replacements.append((key, value))

    if not replacements:
        raise ValueError("no settings were requested")
    for key, value in replacements:
        text = replace_scalar(text, key, value)

    atomic_write(args.file, text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
