#!/usr/bin/env python3
"""Generate categorized Markdown notes for a stable or beta GitHub release."""

from __future__ import annotations

import argparse
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


STABLE_TAG = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
BETA_TAG = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.((?:alpha|beta|rc)(?:0|[1-9][0-9]*))$"
)
MAX_FALLBACK_COMMITS = 50


@dataclass(frozen=True)
class Commit:
    sha: str
    subject: str
    files: tuple[str, ...]


def _run(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def tag_channel(tag: str) -> str | None:
    if STABLE_TAG.fullmatch(tag):
        return "stable"
    if BETA_TAG.fullmatch(tag):
        return "beta"
    return None


def version_key(tag: str) -> tuple[int, int, int, int, int, int, str]:
    stable = STABLE_TAG.fullmatch(tag)
    if stable:
        major, minor, patch = (int(stable.group(i)) for i in range(1, 4))
        # Stable releases sort after prereleases for the same numeric version.
        return (major, minor, patch, 1, 0, 0, "")
    beta = BETA_TAG.fullmatch(tag)
    if beta is None:
        raise ValueError(f"unsupported release tag: {tag}")
    major, minor, patch = (int(beta.group(i)) for i in range(1, 4))
    prerelease = beta.group(4)
    kind_match = re.match(r"^(alpha|beta|rc)(?:[.-]?(\d+))?", prerelease)
    if kind_match is None:
        raise ValueError(f"unsupported release tag: {tag}")
    kind, sequence = kind_match.groups()
    # alpha < beta < rc, with numeric suffixes ordered numerically.
    return (major, minor, patch, 0, {"alpha": 0, "beta": 1, "rc": 2}[kind], int(sequence or 0), prerelease)


def previous_tag(tags: list[str], current: str, channel: str) -> str | None:
    candidates = [
        tag
        for tag in tags
        if tag != current and tag_channel(tag) == channel and version_key(tag) < version_key(current)
    ]
    return max(candidates, key=version_key, default=None)


def _commit(root: Path, sha: str) -> Commit:
    subject = _run(root, "show", "-s", "--format=%s", sha)
    files = tuple(
        line
        for line in _run(root, "diff-tree", "--no-commit-id", "--name-only", "-r", sha).splitlines()
        if line
    )
    return Commit(sha=sha, subject=subject, files=files)


def commits_between(root: Path, tag: str, base: str | None) -> tuple[list[Commit], bool]:
    if base is None:
        shas = _run(root, "rev-list", "--first-parent", "--max-count", str(MAX_FALLBACK_COMMITS), tag).splitlines()
        return ([_commit(root, sha) for sha in reversed(shas)], True)
    shas = _run(root, "rev-list", "--first-parent", "--reverse", f"{base}..{tag}").splitlines()
    return ([_commit(root, sha) for sha in shas], False)


def classify(commit: Commit) -> str:
    kind = re.match(r"^(feat|fix|perf|test|ci|docs|build|refactor|chore|style|revert)(?:\([^)]*\))?!?:", commit.subject.lower())
    prefix = kind.group(1) if kind else ""
    if prefix in {"feat"}:
        return "功能"
    if prefix in {"fix", "perf", "revert"}:
        return "修复"
    if prefix in {"test", "ci", "docs", "build", "refactor", "chore", "style"}:
        return "验证与已知限制"
    if any(path.startswith(("test/", "integration_test/", "tool/", ".github/")) for path in commit.files):
        return "验证与已知限制"
    return "功能"


def _friendly_subject(subject: str) -> str:
    cleaned = re.sub(r"^(feat|fix|perf|test|ci|docs|build|refactor|chore|style|revert)(?:\([^)]*\))?!?:\s*", "", subject, flags=re.I)
    return cleaned[:240].rstrip() or subject[:240].rstrip()


def render_notes(
    *,
    tag: str,
    channel: str,
    base: str | None,
    commits: list[Commit],
    fallback: bool,
) -> str:
    heading = "稳定版" if channel == "stable" else "测试版"
    lines = [f"# Site Lens {tag}", "", f"本次发布渠道：**{heading}**。"]
    if fallback:
        lines.extend([
            "",
            "> 未找到同渠道的上一个发布标签；以下内容基于当前标签最近的提交生成。",
        ])
    elif base:
        lines.extend(["", f"> 变更范围：`{base}` → `{tag}`。"])
    sections = {"功能": [], "修复": [], "验证与已知限制": []}
    for commit in commits:
        category = classify(commit)
        sections[category].append(
            f"- {_friendly_subject(commit.subject)} (`{commit.sha[:7]}`)"
        )
    if not commits:
        sections["验证与已知限制"].append("- 当前版本没有可分类的提交记录；请以发布页和安装包实际行为为准。")
    for title in ("功能", "修复", "验证与已知限制"):
        lines.extend(["", f"## {title}"])
        lines.extend(sections[title])
    if any(path.startswith(("integration_test/", "android/", "ios/")) for commit in commits for path in commit.files):
        lines.extend([
            "",
            "> 设备相关改动仍需要在目标 Android/iOS 设备上完成最终人工验收。",
        ])
    lines.extend(["", "---", "由 Site Lens release workflow 根据提交范围生成。"])
    return "\n".join(lines) + "\n"


def generate(root: Path, tag: str, channel: str, eligible_tags: set[str] | None = None) -> str:
    tags = _run(root, "tag", "--list", "v*").splitlines()
    if eligible_tags is not None:
        tags = [candidate for candidate in tags if candidate in eligible_tags or candidate == tag]
    base = previous_tag(tags, tag, channel)
    commits, fallback = commits_between(root, tag, base)
    return render_notes(
        tag=tag,
        channel=channel,
        base=base,
        commits=commits,
        fallback=fallback,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--tag", required=True)
    parser.add_argument("--channel", choices=("stable", "beta"), required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument(
        "--eligible-tags-file",
        type=Path,
        help="Optional newline-delimited GitHub Release tags to use as changelog baselines",
    )
    args = parser.parse_args()
    if tag_channel(args.tag) != args.channel:
        raise SystemExit(f"tag {args.tag!r} does not match channel {args.channel!r}")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    eligible_tags = None
    if args.eligible_tags_file:
        eligible_tags = {
            line.strip()
            for line in args.eligible_tags_file.read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
    args.output.write_text(
        generate(args.root, args.tag, args.channel, eligible_tags),
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
