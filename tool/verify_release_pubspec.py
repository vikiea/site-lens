#!/usr/bin/env python3
"""Keep the tagged source version and the shipped Android version identical."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

from determine_release_version import parse_tag


def verify(source: str, tag: str, version_code: int | None = None) -> int:
    parsed = parse_tag(tag)
    match = re.search(r"^version:\s*([^\s+]+)\+([1-9][0-9]*)\s*$", source, re.M)
    if match is None:
        raise ValueError("pubspec.yaml must declare version: NAME+CODE")
    expected = ".".join(map(str, parsed.base))
    if parsed.kind is not None:
        expected += f"-{parsed.kind}{parsed.sequence}"
    if match.group(1) != expected:
        raise ValueError(f"pubspec version {match.group(1)} does not match {tag}; update it before tagging")
    code = int(match.group(2))
    if version_code is not None and code != version_code:
        raise ValueError(f"pubspec build {code} differs from reserved versionCode {version_code}")
    return code


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pubspec", type=Path, default=Path("pubspec.yaml"))
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version-code", type=int)
    args = parser.parse_args()
    print(verify(args.pubspec.read_text(), args.tag, args.version_code))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
