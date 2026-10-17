#!/usr/bin/env python3
"""Compute a globally monotonic Android versionCode for a release build."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


ANDROID_MAX_VERSION_CODE = 2_100_000_000


def _read_codes(path: Path | None) -> dict[str, int]:
    if path is None:
        return {}
    result: dict[str, int] = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        tag, separator, raw_code = line.partition(" ")
        if not separator:
            tag, separator, raw_code = line.partition("=")
        if not separator:
            raise ValueError(f"invalid versionCode record: {line}")
        code = int(raw_code.strip())
        if code <= 0:
            raise ValueError(f"versionCode must be positive: {line}")
        result[tag] = code
    return result


def determine(
    tag: str,
    channel: str,
    *,
    published_codes: dict[str, int] | None = None,
    minimum_code: int = 0,
    main_stable_code: int = 0,
    override: int | None = None,
) -> dict[str, object]:
    if channel not in {"stable", "beta"}:
        raise ValueError(f"unsupported release channel: {channel}")
    if minimum_code < 0:
        raise ValueError("minimum versionCode must be non-negative")
    if main_stable_code < 0:
        raise ValueError("main stable versionCode must be non-negative")
    known = published_codes or {}
    highest_published = max(known.values(), default=0)
    floor = max(highest_published, minimum_code, main_stable_code)
    selected = floor + 1 if override is None else override
    if selected <= floor:
        raise ValueError(
            f"versionCode {selected} must be greater than the existing/install floor {floor}"
        )
    if selected > ANDROID_MAX_VERSION_CODE:
        raise ValueError(f"versionCode exceeds Android's limit: {selected}")
    return {
        "tag": tag,
        "channel": channel,
        "version_code": selected,
        "highest_published_version_code": highest_published,
        "minimum_version_code": minimum_code,
        "main_stable_version_code": main_stable_code,
        "existing_install_floor": floor,
        "override": override is not None,
        "known_release_count": len(known),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--channel", choices=("stable", "beta"), required=True)
    parser.add_argument("--published-codes-file", type=Path)
    parser.add_argument("--minimum-code", type=int, default=0)
    parser.add_argument("--main-stable-code", type=int, default=0)
    parser.add_argument("--override", type=int)
    args = parser.parse_args()
    print(
        json.dumps(
            determine(
                args.tag,
                args.channel,
                published_codes=_read_codes(args.published_codes_file),
                minimum_code=args.minimum_code,
                main_stable_code=args.main_stable_code,
                override=args.override,
            ),
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
