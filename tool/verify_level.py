#!/usr/bin/env python3
"""Choose and execute the smallest sufficient Site Lens validation level."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

from validation_runner import (
    LEVELS,
    ROOT,
    ValidationConfigurationError,
    build_plan,
    collect_changed_paths,
    execute_plan,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--auto", action="store_true", help="classify the current worktree (default)")
    group.add_argument("--level", choices=LEVELS, help="explicit requested validation level")
    parser.add_argument("--paths", nargs="+", help="paths to classify instead of the whole worktree")
    parser.add_argument("--device", help="Android device id or strict IP:port endpoint")
    parser.add_argument("--report", type=Path, help="write the terminal report to this path")
    parser.add_argument("--cache-dir", type=Path, help="override the .ci_cache directory")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        paths = collect_changed_paths(ROOT, args.paths)
        plan = build_plan(paths, requested_level=args.level, device=args.device)
        report = execute_plan(plan, cache_dir=args.cache_dir)
    except ValidationConfigurationError as exc:
        print(f"validation runner configuration error: {exc}", file=sys.stderr)
        return 3
    except OSError as exc:
        print(f"validation environment unavailable: {exc}", file=sys.stderr)
        return 2
    except RuntimeError as exc:
        print(f"validation runner failed: {exc}", file=sys.stderr)
        return 1

    rendered = report.render()
    print(rendered, end="")
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(rendered)
    return report.exit_code


if __name__ == "__main__":
    raise SystemExit(main())
