#!/usr/bin/env python3
"""Read immutable versionCode reservation refs from GitHub's refs API output."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any, Iterable

MARKER_PREFIX = "version-code/"
MARKER_PATTERN = re.compile(r"^refs/tags/" + re.escape(MARKER_PREFIX) + r"([1-9][0-9]*)-(.+)$")


def tag_slug(tag: str) -> str:
    """Return the stable suffix used in a reservation ref for a release tag."""
    slug = re.sub(r"[^A-Za-z0-9._-]", "-", tag).strip("-")
    if not slug:
        raise ValueError(f"release tag has no usable reservation suffix: {tag!r}")
    return slug


def reservation_ref(tag: str, version_code: int) -> str:
    if version_code <= 0:
        raise ValueError("versionCode must be positive")
    return f"refs/tags/{MARKER_PREFIX}{version_code}-{tag_slug(tag)}"


def _items(value: Any) -> Iterable[dict[str, Any]]:
    if isinstance(value, dict):
        yield value
    elif isinstance(value, list):
        for child in value:
            yield from _items(child)
    else:
        raise ValueError("GitHub refs response must contain objects or arrays")


def summarize(payload: Any, tag: str) -> dict[str, Any]:
    """Summarize reservation refs and find the existing marker for ``tag``."""
    slug = tag_slug(tag)
    reservations: dict[str, int] = {}
    matching_codes: set[int] = set()
    for item in _items(payload):
        ref = item.get("ref")
        if not isinstance(ref, str):
            continue
        match = MARKER_PATTERN.fullmatch(ref)
        if not match:
            continue
        code = int(match.group(1))
        reservations[ref] = code
        if match.group(2) == slug:
            matching_codes.add(code)
    if len(matching_codes) > 1:
        values = ", ".join(str(value) for value in sorted(matching_codes))
        raise ValueError(f"release tag {tag} has multiple versionCode reservations: {values}")
    existing_code = next(iter(matching_codes), None)
    return {
        "tag": tag,
        "slug": slug,
        "existing_code": existing_code,
        "highest_reserved_version_code": max(reservations.values(), default=0),
        "reservations": dict(sorted(reservations.items())),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = summarize(json.loads(args.input.read_text()), args.tag)
    rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered)
    else:
        print(rendered, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
