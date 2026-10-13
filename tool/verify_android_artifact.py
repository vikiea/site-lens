#!/usr/bin/env python3
"""Verify a built APK's package identity and, for release, certificate."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from android_artifact import FORMAL_PACKAGE, verify_apk_package, verify_formal_apk


def main() -> int:
    parser = argparse.ArgumentParser()
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--debug", action="store_true")
    group.add_argument("--formal", action="store_true")
    parser.add_argument(
        "apk",
        nargs="?",
        type=Path,
        help="APK path; defaults to the Flutter output for the selected build",
    )
    args = parser.parse_args()
    apk = args.apk or Path(
        "build/app/outputs/flutter-apk/app-release.apk"
        if args.formal
        else "build/app/outputs/flutter-apk/app-debug.apk"
    )
    env = os.environ.copy()
    env.setdefault("ANDROID_HOME", "/opt/homebrew/share/android-commandlinetools")
    if args.formal:
        verify_formal_apk(apk, env)
    else:
        verify_apk_package(apk, "dev.vikiea.site_lens.debug", env)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
