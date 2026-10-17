#!/usr/bin/env python3
"""Extract versionCode records from GitHub Release JSON bodies."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


GENERATED_VERSION_CODE = re.compile(
    r"^\s*-\s*Android versionCode:\s*`?([1-9][0-9]*)`?\s*\.?\s*$",
    re.I | re.M,
)
LEGACY_VERSION_CODE = re.compile(
    r"^\s*-\s*版本：.*\bversionCode\s*`([1-9][0-9]*)`\s*$",
    re.I | re.M,
)


def extract(releases: list[dict[str, object]]) -> dict[str, int]:
    result: dict[str, int] = {}
    for release in releases:
        tag = release.get("tag_name")
        body = release.get("body")
        if release.get("draft") is True:
            continue
        if not isinstance(tag, str) or not isinstance(body, str):
            continue
        match = GENERATED_VERSION_CODE.search(body) or LEGACY_VERSION_CODE.search(body)
        if match:
            result[tag] = int(match.group(1))
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    payload = json.loads(args.input.read_text())
    if isinstance(payload, list) and all(isinstance(item, list) for item in payload):
        releases = [release for page in payload for release in page]
    else:
        releases = payload
    if not isinstance(releases, list):
        raise SystemExit("GitHub releases JSON must be a list")
    args.output.write_text(
        "".join(f"{tag} {code}\n" for tag, code in extract(releases).items())
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
