#!/usr/bin/env python3
"""Validate a release tag and infer its next version from repository history."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


STABLE_TAG = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
PRERELEASE_TAG = re.compile(
    r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.((alpha|beta|rc)(0|[1-9][0-9]*))$"
)
CONVENTIONAL = re.compile(
    r"^(?P<type>[a-z]+)(?:\((?P<scope>[^)]*)\))?(?P<breaking>!)?:\s*(?P<subject>.+)$",
    re.IGNORECASE,
)
KNOWN_TYPES = {"feat", "fix", "perf", "refactor", "chore", "test", "ci", "docs", "build", "style", "revert"}
PATCH_TYPES = KNOWN_TYPES - {"feat"}
CAPABILITY_WORDS = re.compile(r"\b(add|support|introduce|generalize|enable|implement|streamline)\b", re.I)


@dataclass(frozen=True)
class ReleaseTag:
    tag: str
    major: int
    minor: int
    patch: int
    kind: str | None = None
    sequence: int | None = None

    @property
    def base(self) -> tuple[int, int, int]:
        return (self.major, self.minor, self.patch)


@dataclass(frozen=True)
class Commit:
    sha: str
    subject: str
    body: str
    files: tuple[str, ...]


def parse_tag(tag: str) -> ReleaseTag:
    stable = STABLE_TAG.fullmatch(tag)
    if stable:
        return ReleaseTag(tag, *(int(stable.group(i)) for i in range(1, 4)))
    prerelease = PRERELEASE_TAG.fullmatch(tag)
    if prerelease:
        return ReleaseTag(
            tag,
            *(int(prerelease.group(i)) for i in range(1, 4)),
            kind=prerelease.group(5),
            sequence=int(prerelease.group(6)),
        )
    raise ValueError(f"unsupported release tag: {tag}")


def _run(root: Path, *args: str) -> str:
    return subprocess.check_output(["git", *args], cwd=root, text=True).strip()


def _commit(root: Path, sha: str) -> Commit:
    raw = _run(root, "show", "-s", "--format=%s%x00%b", sha)
    subject, _, body = raw.partition("\x00")
    files = tuple(
        line
        for line in _run(root, "diff-tree", "--no-commit-id", "--name-only", "-r", sha).splitlines()
        if line
    )
    return Commit(sha=sha, subject=subject, body=body, files=files)


def commits_since(root: Path, base: str | None, target: str) -> list[Commit]:
    if base is None:
        shas = _run(root, "rev-list", "--first-parent", "--max-count", "50", target).splitlines()
    else:
        shas = _run(root, "rev-list", "--first-parent", "--reverse", f"{base}..{target}").splitlines()
    return [_commit(root, sha) for sha in shas]


def _stable_tags(tags: list[str]) -> list[ReleaseTag]:
    return [parse_tag(tag) for tag in tags if STABLE_TAG.fullmatch(tag)]


def previous_stable_tag(tags: list[str], current: ReleaseTag) -> ReleaseTag | None:
    candidates = [tag for tag in _stable_tags(tags) if tag.base < current.base]
    return max(candidates, key=lambda tag: tag.base, default=None)


def infer_bump(commits: list[Commit]) -> tuple[str, str, bool]:
    parsed: list[tuple[Commit, re.Match[str] | None]] = [
        (commit, CONVENTIONAL.match(commit.subject)) for commit in commits
    ]
    if any(
        (match and match.group("breaking")) or "BREAKING CHANGE" in commit.body
        for commit, match in parsed
    ):
        return "major", "检测到 BREAKING CHANGE 或 Conventional Commit 的 ! 标记", False
    if any(match and match.group("type").lower() == "feat" for _, match in parsed):
        return "minor", "检测到 feat 提交", False
    domains = {
        parts[1]
        for commit, _ in parsed
        for path in commit.files
        for parts in [path.split("/")]
        if len(parts) >= 3 and parts[0] == "lib"
    }
    if len(domains) >= 2 and any(CAPABILITY_WORDS.search(commit.subject) for commit, _ in parsed):
        return "minor", "检测到跨 lib 功能域的新能力提交", False
    if commits and all(match and match.group("type").lower() in PATCH_TYPES for _, match in parsed):
        return "patch", "提交均为可识别的 patch 级 Conventional Commits", False
    return "patch", "无法可靠判断版本级别，使用 patch 安全 fallback；可通过 workflow_dispatch 明确指定", True


def next_base(previous: ReleaseTag | None, bump: str) -> tuple[int, int, int] | None:
    if previous is None:
        return None
    major, minor, patch = previous.base
    if bump == "major":
        return (major + 1, 0, 0)
    if bump == "minor":
        return (major, minor + 1, 0)
    if bump == "patch":
        return (major, minor, patch + 1)
    raise ValueError(f"unsupported bump: {bump}")


def validate_sequence(tags: list[str], current: ReleaseTag) -> None:
    if current.kind is None:
        return
    existing = [
        parse_tag(tag)
        for tag in tags
        if tag != current.tag and PRERELEASE_TAG.fullmatch(tag)
    ]
    same_channel = [
        tag.sequence
        for tag in existing
        if tag.base == current.base and tag.kind == current.kind and tag.sequence is not None
    ]
    expected = max(same_channel, default=0) + 1
    if current.sequence != expected:
        raise ValueError(
            f"{current.tag} must be the next {current.kind} release for its base; expected sequence {expected}"
        )


def determine(root: Path, tag: str, channel: str, bump: str) -> dict[str, object]:
    current = parse_tag(tag)
    if channel == "stable" and current.kind is not None:
        raise ValueError(f"stable channel requires a stable tag: {tag}")
    if channel == "beta" and current.kind is None:
        raise ValueError(f"beta channel requires a dotted prerelease tag: {tag}")
    tags = _run(root, "tag", "--list", "v*").splitlines()
    previous = previous_stable_tag(tags, current)
    commits = commits_since(root, previous.tag if previous else None, tag)
    inferred, reason, fallback = infer_bump(commits)
    selected_bump = inferred if bump == "auto" else bump
    if bump != "auto":
        reason = f"workflow_dispatch 明确指定 {bump}"
        fallback = False
    expected = next_base(previous, selected_bump)
    if expected is not None and current.base != expected:
        expected_text = ".".join(map(str, expected))
        raise ValueError(
            f"{tag} does not match the {selected_bump} bump from {previous.tag}; expected base v{expected_text}"
        )
    validate_sequence(tags, current)
    return {
        "tag": tag,
        "channel": channel,
        "bump": selected_bump,
        "reason": reason,
        "fallback": fallback,
        "previous_stable": previous.tag if previous else None,
        "expected_base": f"v{'.'.join(map(str, expected))}" if expected else None,
        "sequence": current.sequence,
        "commit_count": len(commits),
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--tag", required=True)
    parser.add_argument("--channel", choices=("stable", "beta"), required=True)
    parser.add_argument("--bump", choices=("auto", "major", "minor", "patch"), default="auto")
    args = parser.parse_args()
    print(json.dumps(determine(args.root, args.tag, args.channel, args.bump), ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
