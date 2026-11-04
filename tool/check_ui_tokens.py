#!/usr/bin/env python3
"""Keep the runtime UI tokens and the agent-facing skill documents aligned.

The project skills are split into a router (``SKILL.md``) plus on-demand
references. This checker enforces both halves of that contract:

- token synchronization: the runtime tokens, the canonical snapshot, and the
  app policy agree, and the router never restates a critical token value;
- routing structure: every reference is linked from its router, every router
  link resolves, and every reference states when it should be read.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = Path("lib/ui/app_theme.dart")
POLICY = Path("lib/settings/app_settings.dart")
SKILLS = Path(".agents/skills")
UI_SKILL = "site-lens-ui"
SKILL_ROUTERS = (UI_SKILL, "site-lens-validation")
TOKENS = Path("references/tokens.md")
REFERENCE_LINK = re.compile(r"references/([A-Za-z0-9._-]+\.md)")


REQUIRED = {
    "pagePadding": ("pagePadding = 16.0", "pagePadding=16"),
    "panelRadius": ("panelRadius = 22.0", "panelRadius=22"),
    "menuRadius": ("menuRadius = 16.0", "menuRadius=16"),
    "menuItemMinHeight": ("menuItemMinHeight = 48.0", "menuItemMinHeight=48"),
    "menuHorizontalPadding": ("menuHorizontalPadding = 12.0", "menuHorizontalPadding=12"),
    "menuItemGap": ("menuItemGap = 10.0", "menuItemGap=10"),
    "menuIconSize": ("menuIconSize = 18.0", "menuIconSize=18"),
    "compactRowMinHeight": ("compactRowMinHeight = 64.0", "compactRowMinHeight=64"),
    "rowTextMaxCharacters": ("rowTextMaxCharacters = 20", "rowTextMaxCharacters=20"),
    "rowTextMinScale": ("rowTextMinScale = 0.88", "rowTextMinScale=0.88"),
    "toolbarHeight": ("toolbarHeight = 48.0", "toolbarHeight=48"),
    "browserDockWidth": ("browserDockWidth = toolbarHeight / 3", "browserDockWidth=toolbarHeight/3=16"),
    "opacityLabelGap": ("opacityLabelGap = 6.0", "opacityLabelGap=6"),
    "opacitySliderGap": ("opacitySliderGap = 8.0", "opacitySliderGap=8"),
}

# The opacity default lives in the settings policy rather than the theme.
DEFAULT_OPACITY = ("defaultGlassOpacity = 55", "default `55`")

# Snapshot-only phrases that carry behavior, not a single token value.
SNAPSHOT_PHRASES = ("n / 100", "slider is trailing-aligned")


def _read(path: Path) -> str:
    return path.read_text(errors="replace") if path.is_file() else ""


def _check_router(root: Path, skill: str) -> list[str]:
    errors: list[str] = []
    skill_dir = root / SKILLS / skill
    router = skill_dir / "SKILL.md"
    if not router.is_file():
        return [f"{skill}: missing router {router.relative_to(root)}"]
    router_text = _read(router)
    linked = set(REFERENCE_LINK.findall(router_text))
    reference_dir = skill_dir / "references"
    references = sorted(reference_dir.glob("*.md")) if reference_dir.is_dir() else []
    for reference in references:
        if reference.name not in linked:
            errors.append(
                f"{skill}: reference not linked from SKILL.md: references/{reference.name}"
            )
        body = _read(reference)
        if not body.lstrip().startswith("# "):
            errors.append(
                f"{skill}: reference must start with a level-1 heading: "
                f"references/{reference.name}"
            )
        if "Read this when" not in body:
            errors.append(
                f"{skill}: reference must state when to read it: references/{reference.name}"
            )
    for target in sorted(linked):
        if not (reference_dir / target).is_file():
            errors.append(f"{skill}: SKILL.md links missing reference: references/{target}")
    return errors


def _check_tokens(root: Path) -> list[str]:
    errors: list[str] = []
    runtime = _read(root / RUNTIME)
    policy = _read(root / POLICY)
    snapshot = _read(root / SKILLS / UI_SKILL / TOKENS)
    router = _read(root / SKILLS / UI_SKILL / "SKILL.md")

    for name, (runtime_token, snapshot_token) in REQUIRED.items():
        if runtime_token not in runtime:
            errors.append(f"runtime token missing: {name} ({runtime_token})")
        if snapshot_token not in snapshot:
            errors.append(f"snapshot token missing: {name} ({snapshot_token})")
        if snapshot and snapshot_token in router:
            errors.append(
                f"token value restated outside the snapshot: {name} ({snapshot_token})"
            )

    if DEFAULT_OPACITY[0] not in policy:
        errors.append("runtime token missing: defaultGlassOpacity=55")
    if DEFAULT_OPACITY[1] not in snapshot:
        errors.append("snapshot token missing: default opacity 55")
    for phrase in SNAPSHOT_PHRASES:
        if phrase not in snapshot:
            errors.append(f"snapshot text missing: {phrase}")
        if snapshot and phrase in router:
            errors.append(f"snapshot text restated outside the snapshot: {phrase}")
    return errors


def validate(root: Path = ROOT) -> list[str]:
    errors: list[str] = []
    for skill in SKILL_ROUTERS:
        errors.extend(_check_router(root, skill))
    errors.extend(_check_tokens(root))
    return errors


def main() -> int:
    errors = validate()
    if errors:
        print("UI token contract check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(
        f"UI token contract check PASS: {len(REQUIRED) + 1} critical tokens, "
        f"{len(SKILL_ROUTERS)} skill routers"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
