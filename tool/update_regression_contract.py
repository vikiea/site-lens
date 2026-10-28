#!/usr/bin/env python3
"""Record a contract change and regenerate its matrix after validating bindings."""

from __future__ import annotations

import argparse
import copy
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

import check_regression_contracts as contracts
import generate_regression_matrix as matrix

ROOT = contracts.ROOT
REGISTRY = ROOT / contracts.REGISTRY_PATH
EDITABLE = {"description", "owner", "changedPaths", "testFiles", "evidence", "validation", "blocking"}
UPDATE_FIELDS = EDITABLE | {"replacedBy"}


def change_contract(
    data: dict[str, Any], *, action: str, summary: str, date: str, version: str,
    contract_id: str | None = None, definition: dict[str, Any] | None = None,
    replaced_by: str | None = None, report: str | None = None, level: str | None = None,
) -> dict[str, Any]:
    """Return a new, validated registry; invalid requests leave the input intact."""
    # Existing paths may have just been moved. Check their audit integrity now,
    # then check filesystem bindings only after applying the requested change.
    errors = contracts.validate_contracts(data, check_files=False)
    if errors:
        raise ValueError("; ".join(errors))
    if not contracts._text(summary) or not contracts.is_date(date):
        raise ValueError("a reason and a non-future ISO date are required")
    contracts._version_key(version)
    candidate = copy.deepcopy(data)
    rows = {row["id"]: row for row in candidate["contracts"]}
    if action == "add":
        if not isinstance(definition, dict) or set(definition) - (EDITABLE | {"id", "introducedIn"}):
            raise ValueError("add definition accepts editable fields, id, and introducedIn")
        cid = definition.get("id")
        if not isinstance(cid, str) or not contracts.ID_RE.fullmatch(cid) or cid in rows:
            raise ValueError("a unique contract id is required")
        row = {
            **definition, "introducedIn": definition.get("introducedIn", version),
            "revision": 1, "status": "active", "replacedBy": None, "lastVerified": None,
        }
        candidate["contracts"].append(row)
        event_action = "introduced"
    else:
        if contract_id not in rows:
            raise ValueError(f"unknown contract: {contract_id}")
        row = rows[contract_id]
        if row["status"] == "revoked":
            raise ValueError("revoked tombstones are immutable; use a new contract id")
        previous = copy.deepcopy(row)
        if action == "update":
            if not isinstance(definition, dict) or not definition or set(definition) - UPDATE_FIELDS:
                raise ValueError("update definition must contain editable fields only")
            row.update(copy.deepcopy(definition))
            event_action = "updated"
        elif action == "deprecate":
            if row["status"] != "active" or not replaced_by:
                raise ValueError("deprecation requires an active contract and --replaced-by")
            row.update(status="deprecated", replacedBy=replaced_by)
            event_action = "deprecated"
        elif action == "revoke":
            row.update(status="revoked", testFiles=[], blocking=False)
            event_action = "revoked"
        elif action == "verify":
            if not report or level not in contracts.LEVELS:
                raise ValueError("verification record requires --report and --level")
            row["lastVerified"] = {"date": date, "level": level, "report": report}
            evidence = {"kind": "report", "ref": report}
            if evidence not in row["evidence"]:
                row["evidence"].append(evidence)
            event_action = "verified"
        else:
            raise ValueError(f"unknown action: {action}")
        if action != "verify":
            row["lastVerified"] = None
        if row == previous:
            raise ValueError("request does not change the contract")
        row["revision"] += 1
    candidate["history"].append({
        "id": row["id"], "revision": row["revision"], "action": event_action,
        "date": date, "version": version, "summary": summary,
        "status": row["status"], "stateHash": contracts.state_hash(row),
        "behaviorHash": contracts.behavior_hash(row),
    })
    errors = contracts.validate_contracts(candidate)
    errors.extend(contracts.validate_registry_changes(data, candidate))
    if errors:
        raise ValueError("; ".join(errors))
    return candidate


def _stage(path: Path, content: bytes) -> Path:
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix="." + path.name + "-", delete=False) as stream:
        staged = Path(stream.name)
        try:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
            os.chmod(staged, path.stat().st_mode & 0o777 if path.exists() else 0o644)
        except BaseException:
            staged.unlink(missing_ok=True)
            raise
    return staged


def write_registry(data: dict[str, Any]) -> None:
    """Prepare both outputs before publishing and restore JSON if matrix publish fails."""
    expected = matrix.render_matrix(data)
    registry_bytes = (json.dumps(data, ensure_ascii=False, indent=2) + "\n").encode()
    old = REGISTRY.read_bytes()
    staged_registry = _stage(REGISTRY, registry_bytes)
    try:
        staged_matrix = _stage(matrix.OUTPUT, expected.encode())
        try:
            os.replace(staged_registry, REGISTRY)
            try:
                os.replace(staged_matrix, matrix.OUTPUT)
            except OSError:
                rollback = _stage(REGISTRY, old)
                try:
                    os.replace(rollback, REGISTRY)
                finally:
                    rollback.unlink(missing_ok=True)
                raise
        finally:
            staged_matrix.unlink(missing_ok=True)
    finally:
        staged_registry.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("add", "update", "deprecate", "revoke", "verify"))
    parser.add_argument("--id", dest="contract_id")
    parser.add_argument("--definition", type=Path, help="Authored contract or partial update JSON")
    parser.add_argument("--summary", required=True, help="Reason retained in append-only history")
    parser.add_argument("--replaced-by")
    parser.add_argument("--report", help="Existing validation report; this command does not execute validation")
    parser.add_argument("--level", choices=sorted(contracts.LEVELS))
    parser.add_argument("--date", default=contracts.today().isoformat())
    parser.add_argument("--version", help="Defaults to pubspec.yaml")
    args = parser.parse_args(argv)
    try:
        data = json.loads(REGISTRY.read_text())
        definition = json.loads(args.definition.read_text()) if args.definition else None
        candidate = change_contract(
            data, action=args.action, summary=args.summary, date=args.date,
            version=args.version or contracts.current_version(),
            contract_id=args.contract_id, definition=definition,
            replaced_by=args.replaced_by, report=args.report, level=args.level,
        )
        errors = contracts.validate_marker_bindings(candidate, contracts.discover_markers())
        if errors:
            raise ValueError("; ".join(errors))
        write_registry(candidate)
        print(f"Recorded {args.action}; registry and regression matrix updated.")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Contract update failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
