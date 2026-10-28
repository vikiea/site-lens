#!/usr/bin/env python3
"""Check regression contracts, their append-only history, and source bindings."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

ROOT = Path(__file__).resolve().parents[1]
REGISTRY_PATH = "tool/regression_contracts.json"
REGISTRY = ROOT / REGISTRY_PATH
SCHEMA_VERSION = 2
LEVELS = {"L0", "L1", "L2", "L3", "L4"}
STATUSES = {"active", "deprecated", "revoked"}
ACTIONS = {"introduced", "updated", "deprecated", "revoked", "verified"}
ID_RE = re.compile(r"[A-Z][A-Z0-9]*(?:-[A-Z0-9]+)*-[0-9]{3}")
MARKER_RE = re.compile(r"^\s*(?://+|#|/\*+|\*)\s*REGRESSION CONTRACT:\s*(.*?)\s*(?:\*/)?$")
VERSION_RE = re.compile(r"v?(\d+)\.(\d+)\.(\d+)(?:[.-](alpha|beta|rc)(\d+))?")
PUBSPEC_RE = re.compile(r"^version:\s*([^+\s]+)", re.MULTILINE)
DOC_VERSION_RE = re.compile(r"^v(\d+\.\d+\.\d+\.(?:alpha|beta|rc)\d+)")
SCAN_ROOTS = ("test", "integration_test", "tool", "android/app/src/test", "ios/RunnerTests")
SCAN_SUFFIXES = {".dart", ".py", ".sh", ".mjs", ".js", ".ts", ".kt", ".swift"}
FIELDS = {
    "id", "description", "status", "owner", "introducedIn", "lastVerified",
    "replacedBy", "changedPaths", "testFiles", "evidence", "validation",
    "blocking", "revision",
}
HISTORY_FIELDS = {"id", "revision", "action", "date", "version", "summary", "status", "stateHash", "behaviorHash"}


def today() -> dt.date:
    return dt.datetime.now(dt.timezone(dt.timedelta(hours=8))).date()


def _version_key(value: str) -> tuple[int, ...]:
    match = VERSION_RE.fullmatch(value) if isinstance(value, str) else None
    if match is None:
        raise ValueError(f"invalid version: {value!r}")
    major, minor, patch, channel, sequence = match.groups()
    return (int(major), int(minor), int(patch),
            {"alpha": 0, "beta": 1, "rc": 2}.get(channel, 3), int(sequence or 0))


def is_date(value: Any) -> bool:
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d{2}-\d{2}", value):
        return False
    try:
        return dt.date.fromisoformat(value) <= today()
    except ValueError:
        return False


def is_path(value: Any) -> bool:
    if not isinstance(value, str) or not value or "\\" in value or "\x00" in value:
        return False
    path = PurePosixPath(value)
    return (not path.is_absolute() and ".." not in path.parts and
            str(path) == value and str(path) != "." and not any(c in value for c in "*?[]"))


def repository_path(value: str) -> Path:
    path = ROOT / value
    if not is_path(value) or not path.resolve().is_relative_to(ROOT.resolve()):
        raise ValueError(f"path must stay inside repository: {value!r}")
    return path


def state_hash(contract: dict[str, Any]) -> str:
    canonical = json.dumps(contract, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(canonical.encode()).hexdigest()


def behavior_hash(contract: dict[str, Any]) -> str:
    behavior = {key: value for key, value in contract.items() if key not in {"revision", "lastVerified", "evidence"}}
    evidence = contract.get("evidence")
    behavior["evidence"] = [item for item in evidence if not (isinstance(item, dict) and item.get("kind") == "report")] if isinstance(evidence, list) else evidence
    return state_hash(behavior)


def _read_registry() -> dict[str, Any]:
    return json.loads(REGISTRY.read_text())


def _text(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _valid_file(value: Any) -> bool:
    return is_path(value) and repository_path(value).is_file()


def _list_of_paths(value: Any) -> bool:
    return isinstance(value, list) and all(is_path(item) for item in value) and len(value) == len(set(value))


def is_test_path(value: str) -> bool:
    return any(value.startswith(root + "/") for root in SCAN_ROOTS) and Path(value).suffix in SCAN_SUFFIXES


def validate_contracts(data: Any, *, check_files: bool = True) -> list[str]:
    """Validate structure first so malformed input never reaches downstream readers."""
    errors: list[str] = []
    if not isinstance(data, dict) or set(data) != {"schemaVersion", "contracts", "history"}:
        return ["registry requires schemaVersion, contracts, and history"]
    if type(data["schemaVersion"]) is not int or data["schemaVersion"] != SCHEMA_VERSION:
        errors.append(f"regression contract schemaVersion must be {SCHEMA_VERSION}")
    rows, history = data["contracts"], data["history"]
    if not isinstance(rows, list) or not rows:
        errors.append("registry must contain contracts")
    if not isinstance(history, list) or not history:
        errors.append("registry must contain history")
    if errors:
        return errors
    for row in rows:
        if not isinstance(row, dict) or set(row) != FIELDS:
            errors.append(f"contract requires exactly {sorted(FIELDS)}")
            continue
        cid = row["id"]
        if not isinstance(cid, str) or not ID_RE.fullmatch(cid):
            errors.append("contract id must look like MEDIA-HLS-001")
        for field in ("description", "owner"):
            if not _text(row[field]):
                errors.append(f"{cid}: {field} must be non-empty")
        if not isinstance(row["status"], str) or row["status"] not in STATUSES:
            errors.append(f"{cid}: invalid status")
        if not isinstance(row["validation"], str) or row["validation"] not in LEVELS:
            errors.append(f"{cid}: invalid validation level")
        if type(row["blocking"]) is not bool:
            errors.append(f"{cid}: blocking must be boolean")
        if type(row["revision"]) is not int or row["revision"] < 1:
            errors.append(f"{cid}: revision must be a positive integer")
        try:
            _version_key(row["introducedIn"])
        except ValueError as exc:
            errors.append(f"{cid}: {exc}")
        if row["replacedBy"] is not None and (not isinstance(row["replacedBy"], str) or not ID_RE.fullmatch(row["replacedBy"])):
            errors.append(f"{cid}: invalid replacedBy")
        for field in ("changedPaths", "testFiles"):
            values = row[field]
            if not _list_of_paths(values):
                errors.append(f"{cid}: {field} must contain unique repository paths")
                continue
            if row["status"] != "revoked" and not values:
                errors.append(f"{cid}: live contract requires non-empty {field}")
            for value in values:
                if field == "testFiles" and not is_test_path(value):
                    errors.append(f"{cid}: invalid test file {value}")
                if not check_files or row["status"] == "revoked":
                    continue
                try:
                    path = repository_path(value)
                    if not path.exists():
                        errors.append(f"{cid}: missing {field} path {value}")
                    if field == "testFiles" and not path.is_file():
                        errors.append(f"{cid}: invalid test file {value}")
                except ValueError as exc:
                    errors.append(f"{cid}: {exc}")
        evidence = row["evidence"]
        if not isinstance(evidence, list) or not evidence:
            errors.append(f"{cid}: evidence must be non-empty")
        else:
            for item in evidence:
                if not isinstance(item, dict) or set(item) != {"kind", "ref"}:
                    errors.append(f"{cid}: evidence requires kind and ref")
                elif not isinstance(item["kind"], str) or item["kind"] not in {"test", "command", "report"} or not _text(item["ref"]):
                    errors.append(f"{cid}: invalid evidence")
                elif item["kind"] in {"test", "report"}:
                    if not is_path(item["ref"]):
                        errors.append(f"{cid}: evidence must use repository paths")
                        continue
                    if not check_files or row["status"] == "revoked":
                        continue
                    try:
                        if not _valid_file(item["ref"]):
                            errors.append(f"{cid}: missing evidence file {item['ref']}")
                    except ValueError as exc:
                        errors.append(f"{cid}: {exc}")
        verified = row["lastVerified"]
        if verified is not None:
            if (not isinstance(verified, dict) or set(verified) != {"date", "level", "report"} or
                    not is_date(verified.get("date")) or
                    not isinstance(verified.get("level"), str) or verified.get("level") not in LEVELS):
                errors.append(f"{cid}: lastVerified requires date, level, report, or null")
            else:
                try:
                    if not is_path(verified["report"]) or (check_files and not _valid_file(verified["report"])):
                        errors.append(f"{cid}: verification report is missing")
                    elif not isinstance(evidence, list) or {"kind": "report", "ref": verified["report"]} not in evidence:
                        errors.append(f"{cid}: verification report must be listed in evidence")
                except ValueError as exc:
                    errors.append(f"{cid}: {exc}")
    for event in history:
        if not isinstance(event, dict) or set(event) != HISTORY_FIELDS:
            errors.append(f"history requires exactly {sorted(HISTORY_FIELDS)}")
            continue
        if not isinstance(event["id"], str) or not ID_RE.fullmatch(event["id"]):
            errors.append("history contains invalid contract id")
        if not isinstance(event["action"], str) or event["action"] not in ACTIONS:
            errors.append(f"{event['id']}: invalid history action")
        if not isinstance(event["status"], str) or event["status"] not in STATUSES:
            errors.append(f"{event['id']}: invalid history status")
        if type(event["revision"]) is not int or event["revision"] < 1:
            errors.append(f"{event['id']}: invalid history revision")
        if not is_date(event["date"]) or not _text(event["summary"]):
            errors.append(f"{event['id']}: history requires a non-future date and reason")
        for field in ("stateHash", "behaviorHash"):
            if not isinstance(event[field], str) or not re.fullmatch(r"[0-9a-f]{64}", event[field]):
                errors.append(f"{event['id']}: invalid {field}")
        try:
            _version_key(event["version"])
        except ValueError as exc:
            errors.append(f"{event['id']}: {exc}")
    if errors:
        return errors
    contracts = {row["id"]: row for row in rows}
    if len(contracts) != len(rows):
        errors.append("duplicate contract id")
    grouped: dict[str, list[dict[str, Any]]] = {}
    for event in history:
        if event["id"] not in contracts:
            errors.append(f"history references unknown contract {event['id']}")
        grouped.setdefault(event["id"], []).append(event)
    for cid, row in contracts.items():
        status, replacement = row["status"], row["replacedBy"]
        if status == "active" and replacement is not None:
            errors.append(f"{cid}: active contract cannot have replacedBy")
        if status == "deprecated" and replacement is None:
            errors.append(f"{cid}: deprecated contract requires replacedBy")
        if replacement is not None:
            target = contracts.get(replacement)
            if replacement == cid or target is None or (status == "deprecated" and target["status"] != "active"):
                errors.append(f"{cid}: replacedBy must point to a different active contract")
        if status == "revoked" and (row["testFiles"] or row["blocking"]):
            errors.append(f"{cid}: revoked contract must have no testFiles and cannot block")
        events = grouped.get(cid, [])
        if not events:
            errors.append(f"{cid}: introduced history is missing")
            continue
        previous_status = None
        previous_date = None
        previous_behavior = None
        for revision, event in enumerate(events, 1):
            action, next_status = event["action"], event["status"]
            date = dt.date.fromisoformat(event["date"])
            if event["revision"] != revision:
                errors.append(f"{cid}: history revisions must be consecutive")
            if previous_date is not None and date < previous_date:
                errors.append(f"{cid}: history dates cannot move backwards")
            expected = {
                "introduced": (None, "active"),
                "deprecated": ("active", "deprecated"),
            }.get(action)
            if expected is not None and (previous_status, next_status) != expected:
                errors.append(f"{cid}: invalid {action} status transition")
            if action == "revoked" and (previous_status not in {"active", "deprecated"} or next_status != "revoked"):
                errors.append(f"{cid}: invalid revoked status transition")
            if action in {"updated", "verified"} and (previous_status is None or next_status != previous_status or next_status == "revoked"):
                errors.append(f"{cid}: invalid {action} event")
            if action == "verified" and event["behaviorHash"] != previous_behavior:
                errors.append(f"{cid}: verification cannot change behavior or test bindings")
            previous_status, previous_date = next_status, date
            previous_behavior = event["behaviorHash"]
        latest = events[-1]
        if (latest["revision"], latest["status"], latest["stateHash"]) != (row["revision"], status, state_hash(row)):
            errors.append(f"{cid}: current state does not match latest history; record the change")
        if latest["behaviorHash"] != behavior_hash(row):
            errors.append(f"{cid}: behavior does not match latest history")
        if latest["action"] == "verified":
            if row["lastVerified"] is None or row["lastVerified"]["date"] != latest["date"]:
                errors.append(f"{cid}: verified event requires matching lastVerified evidence")
        elif row["lastVerified"] is not None:
            errors.append(f"{cid}: changes must clear stale lastVerified evidence")
    for cid in contracts:
        visited: set[str] = set()
        cursor = cid
        while cursor in contracts:
            if cursor in visited:
                errors.append(f"{cid}: replacement cycle")
                break
            visited.add(cursor)
            cursor = contracts[cursor]["replacedBy"]
    return errors


def discover_markers() -> dict[str, set[str]]:
    markers: dict[str, set[str]] = {}
    for folder in SCAN_ROOTS:
        root = ROOT / folder
        if not root.is_dir():
            continue
        for path in sorted(root.rglob("*")):
            if not path.is_file() or path.suffix not in SCAN_SUFFIXES:
                continue
            relative = path.relative_to(ROOT).as_posix()
            repository_path(relative)
            for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
                match = MARKER_RE.fullmatch(line)
                if match:
                    cid = match.group(1)
                    if not ID_RE.fullmatch(cid):
                        raise ValueError(f"{relative}:{number}: invalid contract marker {cid!r}")
                    markers.setdefault(cid, set()).add(relative)
    return markers


def validate_marker_bindings(data: dict[str, Any], markers: dict[str, set[str]]) -> list[str]:
    errors: list[str] = []
    contracts = {row["id"]: row for row in data["contracts"]}
    for cid, files in sorted(markers.items()):
        if cid not in contracts:
            errors.append(f"unknown regression contract marker {cid} in {sorted(files)}")
    for cid, row in contracts.items():
        actual, expected = markers.get(cid, set()), set(row["testFiles"])
        if row["status"] == "revoked" and actual:
            errors.append(f"{cid}: revoked contract still has markers in {sorted(actual)}")
        if expected - actual:
            errors.append(f"{cid}: missing markers in {sorted(expected - actual)}")
        if actual - expected:
            errors.append(f"{cid}: marker files missing from testFiles {sorted(actual - expected)}")
    return errors


def validate_registry_changes(previous: dict[str, Any] | None, current: dict[str, Any]) -> list[str]:
    if previous is None:
        return []
    errors: list[str] = []
    before = {row["id"]: row for row in previous["contracts"]}
    after = {row["id"]: row for row in current["contracts"]}
    for cid in sorted(before.keys() - after.keys()):
        errors.append(f"{cid}: contracts cannot be deleted; retain a revoked tombstone permanently")
    if previous.get("schemaVersion") == 1:
        return errors
    old_history, new_history = previous["history"], current["history"]
    if new_history[:len(old_history)] != old_history:
        errors.append("contract history is append-only; existing events cannot be removed or rewritten")
    for cid in before.keys() & after.keys():
        old, new = before[cid], after[cid]
        if old["introducedIn"] != new["introducedIn"]:
            errors.append(f"{cid}: introducedIn is immutable")
        if old["status"] == "revoked" and old != new:
            errors.append(f"{cid}: revoked tombstone is immutable; introduce a successor ID")
        if old != new and (new["revision"] <= old["revision"] or not any(
                event["id"] == cid for event in new_history[len(old_history):])):
            errors.append(f"{cid}: change requires a new revision and history event")
    return errors


def _doc_status_is_explicit(text: str) -> bool:
    header = "\n".join(text.splitlines()[:18]).lower()
    return any(marker in header for marker in (
        "文档状态：历史验证草稿", "文档状态: 历史验证草稿",
        "文档状态：计划中", "文档状态: 计划中", "historical draft", "planned",
    ))


def validate_future_validation_docs(version: str) -> list[str]:
    errors: list[str] = []
    for path in sorted((ROOT / "docs" / "validation").glob("v*.md")):
        match = DOC_VERSION_RE.match(path.name)
        if match and _version_key(match.group(1)) > _version_key(version) and not _doc_status_is_explicit(path.read_text()):
            errors.append(f"future validation document {path.relative_to(ROOT)} must be marked planned or historical draft")
    return errors


def git(*args: str) -> bytes:
    result = subprocess.run(["git", *args], cwd=ROOT, capture_output=True, check=False)
    if result.returncode:
        raise ValueError(f"git {args[0]} failed; comparison history is required (use fetch-depth: 0 or --base)")
    return result.stdout


def resolve_commit(ref: str) -> str:
    if not ref or ref.startswith("-"):
        raise ValueError("invalid comparison revision")
    return git("rev-parse", "--verify", "--end-of-options", ref + "^{commit}").decode().strip()


def comparison_base(explicit: str | None = None) -> tuple[str | None, str]:
    ref = explicit or os.environ.get("REGRESSION_CONTRACT_BASE")
    if ref:
        return resolve_commit(ref), "explicit"
    event_name = os.environ.get("GITHUB_EVENT_NAME")
    if event_name in {"push", "pull_request"}:
        event_path = os.environ.get("GITHUB_EVENT_PATH")
        if not event_path:
            raise ValueError("GitHub event payload is required for comparison")
        event = json.loads(Path(event_path).read_text())
        if event_name == "pull_request":
            base = resolve_commit(event["pull_request"]["base"]["sha"])
            return git("merge-base", base, "HEAD").decode().strip(), "pull_request"
        before = event.get("before")
        if not isinstance(before, str) or not re.fullmatch(r"[0-9a-f]{40,64}", before):
            raise ValueError("push payload requires a before SHA")
        if set(before) != {"0"}:
            return resolve_commit(before), "push"
        # A new branch/tag has no before SHA. Compare against its parent.
    if not event_name and changed_paths():
        return resolve_commit("HEAD"), "worktree"
    parents = git("rev-list", "--parents", "-n", "1", "HEAD").decode().split()
    if len(parents) > 1:
        return resolve_commit(parents[1]), "parent"
    if git("rev-parse", "--is-shallow-repository").strip() == b"true":
        raise ValueError("comparison history unavailable in shallow checkout; use fetch-depth: 0")
    return None, "initial commit"


def changed_paths(base: str | None = None) -> set[str]:
    paths: set[str] = set()
    commands = [
        ("diff", "--name-only", "--no-renames", "-z", "HEAD", "--"),
        ("diff", "--cached", "--name-only", "--no-renames", "-z", "HEAD", "--"),
        ("ls-files", "--others", "--exclude-standard", "-z"),
    ]
    if base:
        commands.append(("diff", "--name-only", "--no-renames", "-z", base, "HEAD", "--"))
    for command in commands:
        paths.update(os.fsdecode(item) for item in git(*command).split(b"\x00") if item)
    return paths


def registry_at(base: str | None) -> dict[str, Any] | None:
    if base is None:
        return None
    present = git("ls-tree", "--name-only", base, "--", REGISTRY_PATH)
    return json.loads(git("show", base + ":" + REGISTRY_PATH)) if present.strip() else None


def _path_matches(changed: str, declared: str) -> bool:
    return changed == declared or changed.startswith(declared + "/")


def impacted_contracts(data: dict[str, Any], paths: Iterable[str], previous: dict[str, Any] | None = None) -> dict[str, set[str]]:
    impacted: dict[str, set[str]] = {}
    before = {row["id"]: row for row in previous["contracts"]} if previous else {}
    for row in data["contracts"]:
        if row["status"] == "revoked":
            continue
        old = before.get(row["id"], {})
        tests = row["testFiles"] + old.get("testFiles", [])
        sources = row["changedPaths"] + old.get("changedPaths", [])
        matches = {path for path in paths if path in tests or any(
            _path_matches(path, declared) for declared in sources)}
        if matches:
            impacted[row["id"]] = matches
    return impacted


def current_version() -> str:
    match = PUBSPEC_RE.search((ROOT / "pubspec.yaml").read_text())
    if match is None:
        raise ValueError("pubspec.yaml has no version")
    return match.group(1)


def run(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="Compare registry history and source changes with this Git commit")
    args = parser.parse_args(argv)
    try:
        registry = _read_registry()
        errors = validate_contracts(registry)
        if not errors:
            errors.extend(validate_marker_bindings(registry, discover_markers()))
            errors.extend(validate_future_validation_docs(current_version()))
            base, mode = comparison_base(args.base)
            previous = registry_at(base)
            errors.extend(validate_registry_changes(previous, registry))
        if errors:
            for error in errors:
                print(f"Regression contract check failed: {error}", file=sys.stderr)
            return 1
        print(f"Regression contract check PASS: {len(registry['contracts'])} contracts; current version {current_version()}")
        print(f"Comparison: {mode} ({base or 'empty registry'})")
        affected = impacted_contracts(registry, changed_paths(base), previous)
        if affected:
            print("Impacted contracts (path-based guidance; does not establish test results):")
            for cid, paths in sorted(affected.items()):
                print(f"- {cid}: {', '.join(sorted(paths))}")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Regression contract check failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(run())
