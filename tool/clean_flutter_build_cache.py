#!/usr/bin/env python3
"""Prune historical Flutter build-state directories without removing the current build.

Only direct child directories of .dart_tool/flutter_build are considered. The newest
N directories are kept; build/, pub caches, package metadata, and all source files are
left untouched.
"""

from __future__ import annotations

import argparse
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CacheEntry:
    path: Path
    mtime_ns: int
    size_bytes: int


def disk_usage_bytes(path: Path) -> int:
    result = subprocess.run(
        ["/usr/bin/du", "-sk", str(path)],
        check=True,
        capture_output=True,
        text=True,
    )
    return int(result.stdout.split()[0]) * 1024


def latest_mtime_ns(path: Path) -> int:
    """Include file updates: reusing a build need not update its directory mtime."""
    return max([path.stat().st_mtime_ns] + [
        child.lstat().st_mtime_ns for child in path.rglob("*")
    ])


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Remove old .dart_tool/flutter_build directories while keeping the newest entries."
    )
    parser.add_argument(
        "--keep",
        type=int,
        default=12,
        help="number of newest build-cache directories to keep (default: 12)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would be removed without deleting anything",
    )
    return parser.parse_args()


def clean_cache(repo: Path, keep_count: int, dry_run: bool) -> int:
    if keep_count < 1:
        raise SystemExit("--keep must be at least 1")

    repo = repo.resolve()
    cache_root = repo / ".dart_tool" / "flutter_build"
    if cache_root.parent.is_symlink() or cache_root.is_symlink():
        raise SystemExit(f"refusing symlinked cache path: {cache_root}")
    if not (repo / "pubspec.yaml").is_file():
        raise SystemExit(f"refusing to run outside a Flutter project: {repo}")
    if not cache_root.is_dir():
        print(f"No Flutter build cache found: {cache_root}")
        return 0

    entries = []
    for path in cache_root.iterdir():
        if not re.fullmatch(r"[0-9a-f]{32}", path.name) or not path.is_dir() or path.is_symlink():
            continue
        mtime_ns = latest_mtime_ns(path)
        entries.append(CacheEntry(path, mtime_ns, disk_usage_bytes(path)))

    entries.sort(key=lambda entry: (entry.mtime_ns, entry.path.name), reverse=True)
    keep = entries[:keep_count]
    remove = entries[keep_count:]
    keep_bytes = sum(entry.size_bytes for entry in keep)
    remove_bytes = sum(entry.size_bytes for entry in remove)
    total_bytes = keep_bytes + remove_bytes

    print(f"Cache root: {cache_root}")
    print(f"Found: {len(entries)} directories ({total_bytes / 1e9:.3f} GB)")
    print(f"Keep: {len(keep)} newest directories ({keep_bytes / 1e9:.3f} GB)")
    print(f"Remove: {len(remove)} older directories ({remove_bytes / 1e9:.3f} GB)")
    if keep:
        print(f"Oldest kept: {keep[-1].path.name}")

    if dry_run:
        print("Dry run: no files changed.")
        return 0

    for entry in remove:
        path = entry.path
        if (cache_root.parent.is_symlink() or cache_root.is_symlink()
                or path.parent != cache_root or not path.is_dir() or path.is_symlink()):
            raise SystemExit(f"refusing unsafe removal path: {path}")
        if latest_mtime_ns(path) != entry.mtime_ns:
            raise SystemExit(f"cache changed during scan; refusing removal: {path}")
    for entry in remove:
        shutil.rmtree(entry.path)

    print(f"Removed {len(remove)} historical directories.")
    print(f"Remaining cache size: {disk_usage_bytes(cache_root) / 1e9:.3f} GB")
    return 0


def main() -> int:
    args = parse_args()
    repo = Path(__file__).resolve().parent.parent
    return clean_cache(repo, args.keep, args.dry_run)


if __name__ == "__main__":
    raise SystemExit(main())
