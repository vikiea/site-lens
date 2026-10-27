#!/usr/bin/env python3
"""Validate the machine-readable regression contract registry."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
REGISTRY = ROOT / "tool" / "regression_contracts.json"
VERSION_RE = re.compile(
    r"v?(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)"
    r"(?:[.-](?P<channel>alpha|beta|rc)(?P<sequence>\d+))?"
)
PUBSPEC_RE = re.compile(r"^version:\s*(?P<version>[^+\s]+)", re.MULTILINE)
DOC_VERSION_RE = re.compile(
    r"(?:^|/)v(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)"
    r"\.(?P<channel>alpha|beta|rc)(?P<sequence>\d+)"
)


def _version_key(value: str) -> tuple[int, int, int, int, int]:
    match = VERSION_RE.search(value)
    if match is None:
        raise ValueError(f"invalid version: {value}")
    channel = match.group("channel")
    channel_rank = {"alpha": 0, "beta": 1, "rc": 2}.get(channel, 3)
    return (
        int(match.group("major")),
        int(match.group("minor")),
        int(match.group("patch")),
        channel_rank,
        int(match.group("sequence") or 0),
    )


def _read_registry() -> dict[str, Any]:
    data = json.loads(REGISTRY.read_text())
    if data.get("schemaVersion") != 1:
        raise ValueError("regression contract schemaVersion must be 1")
    if not isinstance(data.get("contracts"), list) or not data["contracts"]:
        raise ValueError("regression contract registry must contain contracts")
    return data


def validate_contracts(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    seen: set[str] = set()
    required = {"id", "description", "changedPaths", "testFiles", "validation", "blocking"}
    for contract in data["contracts"]:
        if not isinstance(contract, dict):
            errors.append("contract entry must be an object")
            continue
        missing = required - contract.keys()
        if missing:
            errors.append(f"contract {contract.get('id', '<unknown>')} missing {sorted(missing)}")
            continue
        contract_id = contract["id"]
        if not isinstance(contract_id, str) or not contract_id:
            errors.append("contract id must be a non-empty string")
            continue
        if contract_id in seen:
            errors.append(f"duplicate contract id: {contract_id}")
        seen.add(contract_id)
        if contract["validation"] not in {"L0", "L1", "L2", "L3", "L4"}:
            errors.append(f"{contract_id}: invalid validation level")
        if not isinstance(contract["blocking"], bool):
            errors.append(f"{contract_id}: blocking must be boolean")
        for value in contract["changedPaths"]:
            if not isinstance(value, str) or not value:
                errors.append(f"{contract_id}: invalid changed path")
        for value in contract["testFiles"]:
            if not isinstance(value, str) or not value:
                errors.append(f"{contract_id}: invalid test path")
                continue
            path = ROOT / value
            if not path.is_file():
                errors.append(f"{contract_id}: missing test file {value}")
                continue
            marker = f"REGRESSION CONTRACT: {contract_id}"
            if marker not in path.read_text(errors="replace"):
                errors.append(f"{contract_id}: {value} lacks marker {marker}")
    return errors


def current_version() -> str:
    match = PUBSPEC_RE.search((ROOT / "pubspec.yaml").read_text())
    if match is None:
        raise ValueError("pubspec.yaml has no version")
    return match.group("version")


def _doc_status_is_explicit(text: str) -> bool:
    header = "\n".join(text.splitlines()[:18]).lower()
    return any(
        marker in header
        for marker in (
            "文档状态：历史验证草稿",
            "文档状态: 历史验证草稿",
            "文档状态：计划中",
            "文档状态: 计划中",
            "historical draft",
            "planned",
        )
    )


def validate_future_validation_docs(version: str) -> list[str]:
    errors: list[str] = []
    current = _version_key(version)
    docs_dir = ROOT / "docs" / "validation"
    for path in sorted(docs_dir.glob("v*.md")):
        match = DOC_VERSION_RE.search(str(path.relative_to(ROOT)))
        if match is None:
            continue
        doc_version = (
            f"v{match.group('major')}.{match.group('minor')}.{match.group('patch')}."
            f"{match.group('channel')}{match.group('sequence')}"
        )
        if _version_key(doc_version) > current and not _doc_status_is_explicit(path.read_text(errors="replace")):
            errors.append(
                f"future validation document {path.relative_to(ROOT)} must be marked planned or historical draft"
            )
    return errors


def run() -> int:
    try:
        registry = _read_registry()
        errors = validate_contracts(registry)
        errors.extend(validate_future_validation_docs(current_version()))
        if errors:
            print("Regression contract check failed:", file=sys.stderr)
            for error in errors:
                print(f"- {error}", file=sys.stderr)
            return 1
        print(
            f"Regression contract check PASS: {len(registry['contracts'])} contracts; "
            f"current version {current_version()}"
        )
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"Regression contract check failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(run())
