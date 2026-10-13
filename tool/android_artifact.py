"""Validate Android APK identity before any repository automation installs it."""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from pathlib import Path

FORMAL_PACKAGE = "dev.vikiea.site_lens"
FORMAL_CERT_SHA256 = "9db2d0302374a13f915382c06dbbcee315cca82e04d073eaa10a5de9e752947d"


def _tool(name: str, env: dict[str, str]) -> str:
    found = shutil.which(name, path=env.get("PATH"))
    if found:
        return found
    sdk = Path(env.get("ANDROID_HOME", ""))
    if name == "apkanalyzer":
        candidates = [sdk / "cmdline-tools/latest/bin/apkanalyzer"]
    else:
        build_tools = sdk / "build-tools"
        candidates = []
        if build_tools.is_dir():
            for directory in sorted(build_tools.iterdir(), reverse=True):
                candidates.append(directory / name)
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    raise RuntimeError(f"{name} missing; install the Android SDK tools")


def verify_apk_package(apk: Path, expected: str, env: dict[str, str]) -> None:
    if not apk.is_file():
        raise RuntimeError(f"missing APK: {apk}")
    analyzer = _tool("apkanalyzer", env)
    package = subprocess.check_output(
        [analyzer, "manifest", "application-id", str(apk)],
        env=env,
        timeout=60,
        stderr=subprocess.PIPE,
    ).decode().strip()
    if package != expected:
        raise RuntimeError(
            f"unexpected APK package for {apk.name}: {package!r}; expected {expected!r}"
        )
    print(f"APK package verified: {apk.name} = {package}", flush=True)


def verify_formal_apk(apk: Path, env: dict[str, str]) -> None:
    verify_apk_package(apk, FORMAL_PACKAGE, env)
    signer = _tool("apksigner", env)
    output = subprocess.check_output(
        [signer, "verify", "--print-certs", str(apk)],
        env=env,
        timeout=60,
        stderr=subprocess.PIPE,
    ).decode()
    match = re.search(r"SHA-256 digest: ([0-9a-fA-F:]+)", output)
    actual = match.group(1).replace(":", "").lower() if match else None
    if actual != FORMAL_CERT_SHA256:
        raise RuntimeError(
            f"unexpected formal certificate for {apk.name}: {actual!r}; "
            f"expected {FORMAL_CERT_SHA256!r}"
        )
    print(f"Formal certificate verified: {apk.name} = {actual}", flush=True)
