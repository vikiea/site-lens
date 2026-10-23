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


def _manifest_value(apk: Path, field: str, env: dict[str, str]) -> str:
    analyzer = _tool("apkanalyzer", env)
    return subprocess.check_output(
        [analyzer, "manifest", field, str(apk)],
        env=env,
        timeout=60,
        stderr=subprocess.PIPE,
    ).decode().strip()


def verify_apk_version(
    apk: Path,
    *,
    expected_name: str | None = None,
    expected_code: int | None = None,
    env: dict[str, str],
) -> None:
    if expected_name is None and expected_code is None:
        return
    actual_name = _manifest_value(apk, "version-name", env)
    actual_code = _manifest_value(apk, "version-code", env)
    if expected_name is not None and actual_name != expected_name:
        raise RuntimeError(
            f"unexpected APK versionName for {apk.name}: {actual_name!r}; "
            f"expected {expected_name!r}"
        )
    if expected_code is not None:
        try:
            parsed_code = int(actual_code)
        except ValueError as error:
            raise RuntimeError(
                f"invalid APK versionCode for {apk.name}: {actual_code!r}"
            ) from error
        if parsed_code != expected_code:
            raise RuntimeError(
                f"unexpected APK versionCode for {apk.name}: {parsed_code}; "
                f"expected {expected_code}"
            )
    print(
        f"APK version verified: {apk.name} = {actual_name} + {actual_code}",
        flush=True,
    )


def verify_formal_apk(
    apk: Path,
    env: dict[str, str],
    *,
    expected_name: str | None = None,
    expected_code: int | None = None,
) -> None:
    verify_apk_package(apk, FORMAL_PACKAGE, env)
    verify_apk_version(
        apk,
        expected_name=expected_name,
        expected_code=expected_code,
        env=env,
    )
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
