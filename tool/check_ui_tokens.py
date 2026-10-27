#!/usr/bin/env python3
"""Keep the runtime UI tokens and the agent-facing token snapshot aligned."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "lib/ui/app_theme.dart"
POLICY = ROOT / "lib/settings/app_settings.dart"
SNAPSHOT = ROOT / ".agents/skills/site-lens-ui/references/ui-system.md"


REQUIRED = {
    "pagePadding": ("pagePadding = 16.0", "pagePadding=16"),
    "panelRadius": ("panelRadius = 22.0", "panelRadius=22"),
    "compactRowMinHeight": ("compactRowMinHeight = 64.0", "compactRowMinHeight=64"),
    "rowTextMaxCharacters": ("rowTextMaxCharacters = 20", "rowTextMaxCharacters=20"),
    "rowTextMinScale": ("rowTextMinScale = 0.88", "rowTextMinScale=0.88"),
    "toolbarHeight": ("toolbarHeight = 48.0", "toolbarHeight=48"),
    "browserDockWidth": ("browserDockWidth = toolbarHeight / 3", "browserDockWidth=toolbarHeight/3=16"),
    "opacityLabelGap": ("opacityLabelGap = 6.0", "opacityLabelGap=6"),
    "opacitySliderGap": ("opacitySliderGap = 8.0", "opacitySliderGap=8"),
}


def validate() -> list[str]:
    errors: list[str] = []
    runtime = RUNTIME.read_text(errors="replace")
    policy = POLICY.read_text(errors="replace")
    snapshot = SNAPSHOT.read_text(errors="replace")
    for name, (runtime_token, snapshot_token) in REQUIRED.items():
        source = policy if name == "defaultGlassOpacity" else runtime
        if runtime_token not in source:
            errors.append(f"runtime token missing: {name} ({runtime_token})")
        if snapshot_token not in snapshot:
            errors.append(f"snapshot token missing: {name} ({snapshot_token})")
    if "defaultGlassOpacity = 55" not in policy:
        errors.append("runtime token missing: defaultGlassOpacity=55")
    if "default `55`" not in snapshot:
        errors.append("snapshot token missing: default opacity 55")
    if "n / 100" not in snapshot:
        errors.append("snapshot token missing: opacity format n / 100")
    if "slider is trailing-aligned" not in snapshot:
        errors.append("snapshot token missing: trailing-aligned opacity slider")
    return errors


def main() -> int:
    errors = validate()
    if errors:
        print("UI token contract check failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"UI token contract check PASS: {len(REQUIRED) + 1} critical tokens")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
