#!/usr/bin/env python3
"""Verify that a release tag, source tree and pubspec are one identity."""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VERSION_RE = re.compile(r"^version:\s*(?P<version>[^+\s]+)\+(?P<code>\d+)", re.MULTILINE)


def command(*args: str) -> str:
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def normalize_tag(tag: str) -> str:
    value = tag[1:] if tag.startswith("v") else tag
    match = re.fullmatch(r"(\d+\.\d+\.\d+)\.(alpha|beta|rc)(\d+)", value)
    if match is not None:
        return f"{match.group(1)}-{match.group(2)}{match.group(3)}"
    return value


def verify(tag: str, version_code: int | None = None) -> list[str]:
    errors: list[str] = []
    try:
        head = command("git", "rev-parse", "HEAD")
        tag_commit = command("git", "rev-parse", f"{tag}^{{commit}}")
    except subprocess.CalledProcessError as error:
        return [f"tag cannot be resolved: {tag}: {error}"]
    if head != tag_commit:
        errors.append(f"HEAD {head} does not match tag {tag} commit {tag_commit}")
    if command("git", "status", "--porcelain"):
        errors.append("release worktree is not clean")
    pubspec = (ROOT / "pubspec.yaml").read_text()
    match = VERSION_RE.search(pubspec)
    if match is None:
        errors.append("pubspec.yaml has no version with versionCode")
    else:
        if match.group("version") != normalize_tag(tag):
            errors.append(
                f"pubspec version {match.group('version')} does not match tag {tag}"
            )
        if version_code is not None and int(match.group("code")) != version_code:
            errors.append(
                f"pubspec versionCode {match.group('code')} does not match requested {version_code}"
            )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--version-code", type=int)
    args = parser.parse_args()
    errors = verify(args.tag, args.version_code)
    if errors:
        print("Release identity check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    head = command("git", "rev-parse", "HEAD")
    print(f"Release identity check PASS: {args.tag} -> {head}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
