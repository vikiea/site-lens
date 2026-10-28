#!/usr/bin/env python3
"""Generate the regression matrix from the validated registry; --check is read-only."""

from __future__ import annotations

import argparse
import html
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

import check_regression_contracts as contracts

ROOT = contracts.ROOT
REGISTRY = ROOT / contracts.REGISTRY_PATH
OUTPUT = ROOT / "docs/validation/regression-matrix.md"
B = chr(96)
STATUS_LABELS = {"active": "生效", "deprecated": "已弃用", "revoked": "已撤销"}


def load_registry(path: Path | None = None) -> dict[str, Any]:
    data = json.loads((path or REGISTRY).read_text())
    errors = contracts.validate_contracts(data)
    if errors:
        raise ValueError("; ".join(errors))
    return data


def cell(value: Any) -> str:
    return html.escape(str(value), quote=False).replace("|", r"\|").replace("\n", "<br>").replace(B, "&#96;")


def code(value: Any) -> str:
    return B + cell(value) + B


def render_matrix(data: dict[str, Any]) -> str:
    lines = [
        "<!-- GENERATED FILE: tool/generate_regression_matrix.py -->",
        "<!-- Do not edit; run python3 tool/generate_regression_matrix.py --write. -->",
        "",
        "# Site Lens 回归契约矩阵",
        "",
        "唯一来源是 [tool/regression_contracts.json](../../tool/regression_contracts.json)。",
        "维护流程见 [回归契约生命周期](regression-contract-lifecycle.md)。",
        "下列测试与命令是验证入口；登记状态与影响提示均不代表用例、设备或发布已经通过。",
        "",
        "| ID | 状态 | 行为 | 责任人 | 引入版本 | 最低验证 | 已登记验证 | 验证入口 | 发布阻断 | 替代契约 |",
        "|---|---|---|---|---|---|---|---|---|---|",
    ]
    for row in data["contracts"]:
        verified = row["lastVerified"]
        verification = "未登记" if verified is None else cell(
            f"{verified['date']} / {verified['level']} / {verified['report']}")
        refs = "<br>".join(code(item["ref"]) for item in row["evidence"])
        values = [
            code(row["id"]), cell(STATUS_LABELS[row["status"]]), cell(row["description"]),
            cell(row["owner"]), cell(row["introducedIn"]), cell(row["validation"]),
            verification, refs, "是" if row["blocking"] else "否", code(row["replacedBy"]) if row["replacedBy"] else "—",
        ]
        lines.append("| " + " | ".join(values) + " |")
    lines.extend([
        "",
        "生命周期规则：",
        "",
        "- 生效与弃用契约必须保留真实测试及双向标记，替代目标必须是另一条生效契约。",
        "- 撤销必须记录原因；撤销条目与历史永久保留，ID 不得删除或复用。",
        "- 修改行为或绑定时清空旧验证记录；验证记录必须注明日期、级别和报告。",
        "- 设备诊断跳过本地检查时只能作为补充证据。",
        "",
        "## 变更记录",
        "",
        "| ID | 修订 | 动作 | 日期 | 版本 | 原因 | 状态摘要 |",
        "|---|---|---|---|---|---|---|",
    ])
    for event in data["history"]:
        lines.append("| " + " | ".join([
            code(event["id"]), str(event["revision"]), cell(event["action"]),
            cell(event["date"]), cell(event["version"]), cell(event["summary"]),
            code(event["stateHash"][:12]),
        ]) + " |")
    return "\n".join([*lines, ""])


def check_output(expected: str, path: Path | None = None) -> list[str]:
    path = path or OUTPUT
    if not path.is_file() or path.read_text() != expected:
        return ["regression matrix is missing or stale; run python3 tool/generate_regression_matrix.py --write"]
    return []


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    actions = parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--check", action="store_true")
    actions.add_argument("--write", action="store_true")
    args = parser.parse_args(argv)
    try:
        expected = render_matrix(load_registry())
        if args.write:
            with tempfile.NamedTemporaryFile(dir=OUTPUT.parent, prefix=".regression-matrix-", delete=False) as stream:
                staged = Path(stream.name)
                try:
                    stream.write(expected.encode())
                    stream.flush()
                    os.chmod(staged, OUTPUT.stat().st_mode & 0o777 if OUTPUT.exists() else 0o644)
                    os.replace(staged, OUTPUT)
                finally:
                    staged.unlink(missing_ok=True)
            print("Generated docs/validation/regression-matrix.md")
        else:
            errors = check_output(expected)
            if errors:
                raise ValueError("; ".join(errors))
            print("Generated regression matrix PASS")
        return 0
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"Regression matrix failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
