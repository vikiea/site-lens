#!/usr/bin/env python3
"""Put an exported Drift database back onto an Android device.

`flutter test integration_test/...` uninstalls the app and therefore wipes app
data. When the automatic restore in `run_android_acceptance.py` cannot run (the
device locks, the wireless port changes, MIUI blocks the install), this puts the
bytes back without re-running any test:

  1. install the debug APK (same debug key, so `run-as` works),
  2. push the exported `site_lens.sqlite` into app-private `files/`,
  3. launch the normal debug product build. Formal release installation is separate.

Usage:
    python3 tool/restore_android_database.py DEVICE_ID path/to/site_lens.sqlite
"""

from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
from pathlib import Path
from android_artifact import verify_apk_package
from run_android_acceptance import normal_debug_build, run_flutter

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = "dev.vikiea.site_lens.debug"
ACTIVITY = "dev.vikiea.site_lens.MainActivity"
DEBUG_APK = ROOT / "build/app/outputs/flutter-apk/app-debug.apk"
REMOTE_TMP = "/data/local/tmp/site_lens_restore.sqlite"


def env() -> dict[str, str]:
    import os

    value = os.environ.copy()
    flutter = Path.home() / ".local/share/flutter/bin"
    if flutter.is_dir():
        value["PATH"] = f"{flutter}:{value.get('PATH', '')}"
    value.setdefault(
        "JAVA_HOME",
        "/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home",
    )
    value.setdefault("ANDROID_HOME", "/opt/homebrew/share/android-commandlinetools")
    return value


ENV = env()
ADB = shutil.which("adb", path=ENV["PATH"]) or "adb"


def adb(device: str, *args: str, check: bool = True, capture: bool = True):
    return subprocess.run(
        [ADB, "-s", device, *args],
        check=check,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        env=ENV,
    )


def install(device: str, apk: Path) -> None:
    verify_apk_package(apk, PACKAGE, ENV)
    if not apk.is_file():
        raise SystemExit(f"missing APK: {apk}")
    print(f"install {apk.name}", flush=True)
    subprocess.run(
        [ADB, "-s", device, "install", "--no-streaming", "-r", str(apk)],
        check=True,
        env=ENV,
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("device")
    parser.add_argument("database", type=Path)
    args = parser.parse_args()

    source = args.database
    if not source.is_file():
        raise SystemExit(f"missing database: {source}")
    # Wireless serials (`host:port`) need a connect first; an emulator or a
    # USB serial is already addressed by adb, and `connect emulator-5554` would
    # register a second, offline transport under the same name, which makes
    # every later `-s emulator-5554` ambiguous and fails the run.
    state = adb(args.device, "get-state", check=False)
    if state.stdout.strip() != b"device" and ":" in args.device:
        adb(args.device, "connect", args.device, check=False)
        state = adb(args.device, "get-state", check=False)
    if state.stdout.strip() != b"device":
        raise SystemExit(
            "device is not online (unlock the phone and re-check the wireless "
            f"port): {state.stderr.decode(errors='replace').strip()}"
        )

    run_flutter(normal_debug_build(args.device), timeout=600)
    install(args.device, DEBUG_APK)
    adb(args.device, "push", str(source), REMOTE_TMP)
    # `run-as` writes as the app user; the file must be readable by it first.
    adb(args.device, "shell", "chmod", "644", REMOTE_TMP)
    # Stage inside app-private storage, verify the staged bytes, then swap the
    # live database. A failed push or hash check never touches the active file.
    adb(args.device, "shell", "run-as", PACKAGE, "mkdir", "-p", "files")
    adb(args.device, "shell", "run-as", PACKAGE, "cp", REMOTE_TMP, "files/site_lens.sqlite.restore")
    sha = subprocess.check_output(
        [ADB, "-s", args.device, "exec-out", "run-as", PACKAGE, "cat", "files/site_lens.sqlite.restore"],
        env=ENV,
    )
    import hashlib

    local = hashlib.sha256(source.read_bytes()).hexdigest()
    remote = hashlib.sha256(sha).hexdigest()
    print(f"staged sha256 local={local} device={remote}", flush=True)
    if local != remote:
        adb(args.device, "shell", "run-as", PACKAGE, "rm", "-f", "files/site_lens.sqlite.restore", check=False)
        raise SystemExit("staged database does not match the export; live database was not changed")
    adb(args.device, "shell", "run-as", PACKAGE, "mv", "-f", "files/site_lens.sqlite", "files/site_lens.sqlite.previous", check=False)
    adb(args.device, "shell", "run-as", PACKAGE, "mv", "-f", "files/site_lens.sqlite.restore", "files/site_lens.sqlite")
    adb(args.device, "shell", "run-as", PACKAGE, "rm", "-f", "files/site_lens.sqlite-wal", "files/site_lens.sqlite-shm")
    adb(args.device, "shell", "rm", "-f", REMOTE_TMP, check=False)
    adb(
        args.device,
        "shell",
        "am",
        "start",
        "-n",
        f"{PACKAGE}/{ACTIVITY}",
        check=False,
    )
    print("restore complete; debug database restored; debug build running", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
