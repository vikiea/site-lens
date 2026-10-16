#!/usr/bin/env python3
"""Create and approve auditable manual validation evidence."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from validation_runner import (
    LEVELS,
    ROOT,
    ValidationConfigurationError,
    collect_changed_paths,
    manual_evidence_template,
    validate_manual_evidence,
    build_plan,
)


def _write_json(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(path)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    template = subparsers.add_parser("template", help="create a pending checklist")
    template.add_argument("--level", choices=LEVELS, required=True)
    template.add_argument("--device", help="device used for the manual check")
    template.add_argument("--output", type=Path, required=True)
    template.add_argument("--operator", default="")

    approve = subparsers.add_parser("approve", help="prompt through every checklist item")
    approve.add_argument("--evidence", type=Path, required=True)
    approve.add_argument("--operator")
    approve.add_argument("--notes", default="")
    return parser.parse_args()


def _template(args: argparse.Namespace) -> int:
    paths = collect_changed_paths(ROOT)
    evidence = manual_evidence_template(args.level, args.device, paths, root=ROOT)
    evidence["operator"] = args.operator or None
    _write_json(args.output, evidence)
    print(f"manual evidence template written: {args.output}")
    print("Run the app and complete every checklist item, then run:")
    print(f"  python3 tool/manual_validation.py approve --evidence {args.output}")
    return 0


def _approve(args: argparse.Namespace) -> int:
    try:
        evidence = json.loads(args.evidence.read_text())
    except FileNotFoundError:
        print(f"manual evidence file does not exist: {args.evidence}", file=sys.stderr)
        return 2
    except (OSError, json.JSONDecodeError) as exc:
        print(f"manual evidence cannot be read: {exc}", file=sys.stderr)
        return 2

    if not isinstance(evidence, dict) or evidence.get("status") != "pending":
        print("manual evidence must be a pending template", file=sys.stderr)
        return 2

    checks = evidence.get("checks")
    if not isinstance(checks, list) or not checks:
        print("manual evidence has no checklist", file=sys.stderr)
        return 2

    for check in checks:
        if not isinstance(check, dict):
            print("manual evidence contains an invalid checklist item", file=sys.stderr)
            return 2
        answer = input(f"通过人工检查：{check.get('label', check.get('id'))}？ [y/N] ")
        if answer.strip().lower() not in {"y", "yes"}:
            print("manual evidence remains pending")
            return 1
        check["passed"] = True

    evidence["status"] = "passed"
    evidence["verified_at"] = datetime.now(timezone.utc).isoformat()
    if args.operator:
        evidence["operator"] = args.operator
    if args.notes:
        evidence["notes"] = args.notes
    _write_json(args.evidence, evidence)

    # Revalidate the exact current worktree before claiming success.
    level = evidence.get("level")
    if not isinstance(level, str) or level not in LEVELS:
        print("manual evidence has an invalid level", file=sys.stderr)
        return 2
    paths = collect_changed_paths(ROOT)
    plan = build_plan(paths, requested_level=level, device=None, manual_evidence=args.evidence)
    try:
        validate_manual_evidence(args.evidence, plan, root=ROOT)
    except ValidationConfigurationError as exc:
        print(f"manual evidence was not accepted: {exc}", file=sys.stderr)
        return 2
    print(f"manual evidence passed: {args.evidence}")
    return 0


def main() -> int:
    args = _parse_args()
    if args.command == "template":
        return _template(args)
    return _approve(args)


if __name__ == "__main__":
    raise SystemExit(main())
