#!/usr/bin/env python3
"""Run Android acceptance while preserving the device local data.

The Flutter integration-test runner may uninstall the app between runs. This
script keeps a byte-for-byte copy of the Drift database, runs the native and
product-flow suites, restores the database when a backup exists, and leaves the
restored debug APK running. Formal release installation is separate.

Pass --single-suite to run every integration suite through one combined
entrypoint; that avoids reinstalling the debug APK once per file on wireless
adb while keeping the same tests and the same database backup/restore flow.

For an IP:port endpoint, connection setup is strict: the endpoint must be
online before the run starts. A failed preflight gets one local ADB-server
recovery (`adb kill-server`, `adb start-server`) and one repeated preflight.
The runner never disconnects/connects the endpoint, waits for it, installs an
APK, or runs a suite before that retry passes. Once a strict endpoint is online,
an install failure is reported immediately instead of triggering a reconnect
retry. When a run fails only while restoring, --restore-from DIR finishes that
run from the retained backup without replaying the suites.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from android_artifact import FORMAL_PACKAGE, verify_apk_package, verify_formal_apk
from android_media_actions import MediaActionDriver
from validation_runner import is_tcp_endpoint

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = "dev.vikiea.site_lens.debug"
ACTIVITY = "dev.vikiea.site_lens.MainActivity"
DEBUG_APK = ROOT / "build/app/outputs/flutter-apk/app-debug.apk"
RELEASE_APK = ROOT / "build/app/outputs/flutter-apk/app-release.apk"
NETWORK_DEFINE = "--dart-define=ALLOW_LOCAL_TEST_PAGES=true"
DATABASE_FILES = (
    "site_lens.sqlite",
    "site_lens.sqlite-wal",
    "site_lens.sqlite-shm",
)


def env() -> dict[str, str]:
    from bootstrap_dev import project_environment
    value = project_environment()
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


def test_defines() -> list[str]:
    values = [NETWORK_DEFINE]
    sites = ENV.get('SITE_LENS_TEST_SITES', '').strip()
    if sites:
        values.append(f'--dart-define=SITE_LENS_TEST_SITES={sites}')
    return values

# Set from --restart-adb: kill and restart the local adb server on every
# reconnect, the workaround for this device answering `No route to host`.
RESTART_ADB = False
INSTALL_ATTEMPTS = 3
INSTALL_TIMEOUT_SECONDS = 600
RECONNECT_WAIT_SECONDS = 90
ADB_COMMAND_TIMEOUT_SECONDS = 30


def adb(
    device: str,
    *args: str,
    check: bool = True,
    timeout: int = ADB_COMMAND_TIMEOUT_SECONDS,
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [ADB, "-s", device, *args],
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
    )


def device_online(device: str) -> bool:
    try:
        result = adb(device, "get-state", check=False, timeout=10)
    except subprocess.TimeoutExpired:
        return False
    return result.returncode == 0 and result.stdout.strip() == b"device"


def restart_adb_server(device: str) -> None:
    subprocess.run([ADB, "kill-server"], check=False, env=ENV, timeout=60)
    subprocess.run([ADB, "start-server"], check=False, env=ENV, timeout=60)
    subprocess.run(
        [ADB, "connect", device], check=False, env=ENV, timeout=60,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )


def require_device(device: str) -> None:
    if is_tcp_endpoint(device):
        if not device_online(device):
            print(
                f"device {device} preflight failed; restarting local adb server once",
                file=sys.stderr,
                flush=True,
            )
            restart_adb_server(device)
            if not device_online(device):
                print(
                    f"device {device} is unavailable after one adb-server recovery; "
                    "provide the correct adb port",
                    file=sys.stderr,
                )
                raise SystemExit(2)
            print(f"device {device} passed after one adb-server recovery", flush=True)
        return
    if not device_online(device):
        raise SystemExit(f"device {device} is not online")


def reconnect(device: str) -> None:
    """Re-establish a wireless adb session; never fatal on its own."""
    if RESTART_ADB:
        subprocess.run([ADB, "kill-server"], check=False, env=ENV, timeout=60)
        subprocess.run([ADB, "start-server"], check=False, env=ENV, timeout=60)
    else:
        subprocess.run(
            [ADB, "disconnect", device], check=False, env=ENV, timeout=60,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    subprocess.run(
        [ADB, "connect", device], check=False, env=ENV, timeout=60,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        subprocess.run(
            [ADB, "-s", device, "wait-for-device"],
            check=False,
            env=ENV,
            timeout=RECONNECT_WAIT_SECONDS,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        print(
            f"reconnect: {device} did not come back within "
            f"{RECONNECT_WAIT_SECONDS}s",
            file=sys.stderr,
        )


def install(device: str, apk: Path, expected_package: str) -> None:
    verify_apk_package(apk, expected_package, ENV)
    if not apk.is_file():
        # RuntimeError, not SystemExit: SystemExit is a BaseException and would
        # escape the `except Exception` that reports the retained backup.
        raise RuntimeError(f"missing APK: {apk}")
    attempts = 1 if is_tcp_endpoint(device) else INSTALL_ATTEMPTS
    for attempt in range(1, attempts + 1):
        try:
            subprocess.run(
                [ADB, "-s", device, "install", "--no-streaming", "-r", str(apk)],
                check=True,
                env=ENV,
                timeout=INSTALL_TIMEOUT_SECONDS,
            )
            return
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            if attempt == attempts:
                raise RuntimeError(
                    f"install failed {attempts}x for {apk.name}: {exc}"
                ) from exc
            print(
                f"install attempt {attempt}/{attempts} failed for "
                f"{apk.name}; reconnecting before the retry",
                file=sys.stderr,
                flush=True,
            )
            reconnect(device)


def debug_data_readable(device: str) -> bool:
    """True when adb can already read the app private files.

    `run-as` only works for a debuggable install, so this is the exact
    precondition for backing up or restoring the Drift database.
    """
    return (
        adb(device, "shell", "run-as", PACKAGE, "true", check=False).returncode == 0
    )


def ensure_debug_install(device: str) -> bool:
    """Install the debug APK only when the private data is unreadable.

    Debug and formal installs have separate identities and certificates.
    Restoring debug data never changes the formal app database. Skipping the push when
    `run-as` already works removes one ~168 MB wireless transfer per run.
    """
    if debug_data_readable(device):
        return False
    verify_apk_package(DEBUG_APK, PACKAGE, ENV)
    install(device, DEBUG_APK, PACKAGE)
    return True


def file_exists(device: str, relative: str) -> bool:
    return adb(
        device,
        "shell",
        "run-as",
        PACKAGE,
        "test",
        "-f",
        relative,
        check=False,
    ).returncode == 0


def read_device_file(device: str, relative: str) -> bytes:
    return subprocess.check_output(
        [ADB, "-s", device, "exec-out", "run-as", PACKAGE, "cat", relative],
        stderr=subprocess.PIPE,
    )


def write_device_file(device: str, relative: str, source: Path) -> None:
    # run-as can read the adb shell stdin but not /sdcard under scoped storage.
    with source.open("rb") as stream:
        subprocess.run(
            [ADB, "-s", device, "shell", f"run-as {PACKAGE} sh -c 'cat > {relative}'"],
            check=True,
            stdin=stream,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )


def backup_database(device: str, directory: Path) -> dict[str, str]:
    backup = {}
    for name in DATABASE_FILES:
        relative = f"files/{name}"
        if not file_exists(device, relative):
            continue
        payload = read_device_file(device, relative)
        path = directory / name
        path.write_bytes(payload)
        backup[name] = hashlib.sha256(payload).hexdigest()
    return backup


def restore_database(device: str, directory: Path, backup: dict[str, str]) -> None:
    if not backup:
        # Nothing was present to back up. Report it loudly instead of claiming a
        # restore: a run that silently leaves the device without the user's data
        # must never read as "user database restored".
        print(
            "WARNING: no app data was present to back up; nothing will be restored",
            file=sys.stderr,
        )
        return
    adb(device, "shell", "run-as", PACKAGE, "mkdir", "-p", "files", check=False)
    # Drop anything an earlier interrupted restore left behind before staging.
    adb(
        device,
        "shell",
        f"run-as {PACKAGE} sh -c 'rm -f files/*.restore'",
        check=False,
    )
    # Stage each file next to its destination and rename only after the
    # readback matches: a connection that drops mid-write then leaves the live
    # database untouched instead of half-written.
    for name, expected in backup.items():
        source = directory / name
        if not source.is_file():
            raise RuntimeError(f"backup file disappeared: {source}")
        staged = f"files/{name}.restore"
        write_device_file(device, staged, source)
        actual = hashlib.sha256(read_device_file(device, staged)).hexdigest()
        if actual != expected:
            raise RuntimeError(f"staged database hash mismatch for {name}")
        adb(device, "shell", "run-as", PACKAGE, "mv", "-f", staged, f"files/{name}")
    # Anything the backup did not contain must not survive beside it: a stale
    # -wal replayed over the restored database would corrupt it.
    for name in DATABASE_FILES:
        if name not in backup:
            # check=True on purpose: leaving a stale -wal next to the restored
            # database is worse than reporting an incomplete restore.
            adb(device, "shell", "run-as", PACKAGE, "rm", "-f", f"files/{name}")


def run_flutter(args: list[str], timeout: int = 300) -> None:
    subprocess.run(args, cwd=ROOT, env=ENV, check=True, timeout=timeout)


def assert_formal_not_foreground(device: str) -> None:
    state = adb(device, "shell", "dumpsys", "activity", "activities", check=False)
    text = state.stdout.decode(errors="replace")
    foreground_lines = "\n".join(
        line for line in text.splitlines()
        if "topResumedActivity=" in line or "mResumedActivity=" in line
    )
    if f"{FORMAL_PACKAGE}/" in foreground_lines:
        raise RuntimeError(
            "formal package became foreground during debug integration acceptance"
        )


def run_flutter_test(args: list[str], device: str, timeout: int = 1800) -> None:
    """Run Flutter's device runner while guarding against a formal-package launch."""
    process = subprocess.Popen(args, cwd=ROOT, env=ENV)
    deadline = time.monotonic() + timeout
    try:
        while process.poll() is None:
            assert_formal_not_foreground(device)
            if time.monotonic() >= deadline:
                process.terminate()
                raise subprocess.TimeoutExpired(args, timeout)
            time.sleep(0.5)
    except Exception:
        if process.poll() is None:
            process.terminate()
        process.wait(timeout=30)
        raise
    if process.returncode:
        raise subprocess.CalledProcessError(process.returncode, args)


def run_single_suite_with_media_driver(
    args: list[str], device: str, timeout: int = 1800
) -> None:
    """Run one suite without allowing driver cleanup to hide its failure."""
    media_driver = MediaActionDriver(ADB, device, PACKAGE)
    media_driver.start()
    test_error = None
    test_traceback = None
    try:
        run_flutter_test(args, device, timeout=timeout)
    except Exception as exc:
        test_error = exc
        test_traceback = exc.__traceback__

    driver_error = None
    try:
        media_driver.finish()
    except Exception as exc:
        driver_error = exc

    if test_error is not None:
        if driver_error is not None:
            print(f'media driver cleanup also failed: {driver_error}', file=sys.stderr)
            test_error.add_note(f'media driver cleanup also failed: {driver_error}')
        raise test_error.with_traceback(test_traceback)
    if driver_error is not None:
        raise driver_error


def backup_hashes(directory: Path) -> dict[str, str]:
    """Hashes the retained database copies, so a restore-only run can verify."""
    return {
        name: hashlib.sha256((directory / name).read_bytes()).hexdigest()
        for name in DATABASE_FILES
        if (directory / name).is_file()
    }


def normal_debug_build(device: str) -> list[str]:
    abi = adb(device, "shell", "getprop", "ro.product.cpu.abi").stdout.decode().strip()
    target = {"arm64-v8a": "android-arm64", "armeabi-v7a": "android-arm", "x86_64": "android-x64"}.get(abi)
    return ["flutter", "build", "apk", "--debug", "--target=lib/main.dart"] + ([f"--target-platform={target}"] if target else [])


def restore_and_launch_debug(
    device: str, directory: Path, backup: dict[str, str], installs: list[str]
) -> None:
    """Restore only the debug test package, then launch the restored debug build."""
    adb(device, "shell", "am", "force-stop", PACKAGE, check=False)
    product = directory / "product-debug.apk"
    if not product.is_file():
        run_flutter(normal_debug_build(device), timeout=600)
        product = DEBUG_APK
    # Flutter integration_test overwrites app-debug.apk with its test entrypoint.
    verify_apk_package(product, PACKAGE, ENV)
    install(device, product, PACKAGE)
    installs.append("normal debug for restore")
    restore_database(device, directory, backup)
    adb(
        device,
        "shell",
        "am",
        "start",
        "-n",
        f"{PACKAGE}/{ACTIVITY}",
        check=False,
    )


def restore_only(device: str, directory: Path) -> int:
    """Finish a failed run from its retained backup, without replaying suites."""
    if not directory.is_dir():
        raise SystemExit(f"not a backup directory: {directory}")
    backup = backup_hashes(directory)
    if not backup:
        raise SystemExit(f"no database files in {directory}")
    installs: list[str] = []
    print(
        f"restore-only from {directory} files={sorted(backup)}", flush=True
    )
    try:
        restore_and_launch_debug(device, directory, backup, installs)
    except Exception as exc:
        print(f"Android restore-only FAIL: {exc}", file=sys.stderr)
        print(f"backup retained at {directory}", file=sys.stderr)
        return 1
    print(
        "Android restore-only PASS; debug database restored with verified "
        f"SHA-256; debug build running. script-driven installs: {installs}"
    )
    print(f"backup retained at {directory}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("device", help="adb device id, for example DEVICE_ID")
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--skip-check", action="store_true")
    parser.add_argument(
        "--single-suite",
        action="store_true",
        help="run all integration suites through one app install",
    )
    parser.add_argument(
        "--restart-adb",
        action="store_true",
        help="restart the local adb server on every reconnect",
    )
    parser.add_argument(
        "--restore-from",
        metavar="DIR",
        help="skip the suites: restore the database from a retained backup "
        "directory, then launch the debug package",
    )
    parser.add_argument(
        '--integration-target',
        choices=[
            'integration_test/acceptance_suite_test.dart',
            'integration_test/app_flow_test.dart',
            'integration_test/browser_tabs_test.dart',
            'integration_test/host_contract_test.dart',
            'integration_test/modernization_test.dart',
            'integration_test/script_import_test.dart',
            'integration_test/media_tasks_test.dart',
            'integration_test/media3_parity_test.dart',
            'integration_test/configured_sites_test.dart',
            'integration_test/navigation_lease_test.dart',
        ],
        default='integration_test/acceptance_suite_test.dart',
    )
    parser.add_argument('--test-name', help='Optional Flutter test-name regex for a targeted device regression')
    args = parser.parse_args()

    global RESTART_ADB
    RESTART_ADB = args.restart_adb
    require_device(args.device)

    if args.restore_from:
        return restore_only(args.device, Path(args.restore_from))

    if not args.skip_check:
        run_flutter(["./tool/check.sh"], timeout=300)
    # Always capture a normal product APK; previous integration runs replace the build output.
    run_flutter(normal_debug_build(args.device), timeout=600)
    if not args.skip_build:
        run_flutter(["flutter", "build", "apk", "--release"], timeout=600)

    verify_apk_package(DEBUG_APK, PACKAGE, ENV)
    if not args.skip_build:
        verify_formal_apk(RELEASE_APK, ENV)

    backup_dir = Path(tempfile.mkdtemp(prefix="site-lens-android-backup-"))
    shutil.copy2(DEBUG_APK, backup_dir / "product-debug.apk")
    backup: dict[str, str] = {}
    installs: list[str] = []
    error: Exception | None = None
    try:
        adb(args.device, "shell", "am", "force-stop", PACKAGE, check=False)
        adb(args.device, "shell", "am", "force-stop", FORMAL_PACKAGE, check=False)
        if ensure_debug_install(args.device):
            installs.append("debug for backup/restore")
        backup = backup_database(args.device, backup_dir)
        print(f"backup: {backup_dir} files={sorted(backup)}", flush=True)

        if args.single_suite:
            print("acceptance mode: single-suite (one app install)", flush=True)
            run_single_suite_with_media_driver(
                [
                    "flutter",
                    "test",
                    args.integration_target,
                    "-d",
                    args.device,
                    *test_defines(),
                    *(['--name', args.test_name] if args.test_name else []),
                ],
                args.device,
                timeout=1800,
            )
        else:
            run_flutter(
                [
                    "python3",
                    "tool/run_host_contract.py",
                    args.device,
                ],
                timeout=330,
            )
            run_flutter_test(
                [
                    "flutter",
                    "test",
                    "integration_test/app_flow_test.dart",
                    "integration_test/navigation_lease_test.dart",
                    "integration_test/browser_tabs_test.dart",
                    "integration_test/entry_fallback_test.dart",
                    "integration_test/recon_test.dart",
                    "integration_test/health_check_test.dart",
                    "integration_test/evidence_test.dart",
                    "-d",
                    args.device,
                    NETWORK_DEFINE,
                ],
                # Flutter reinstalls the ~168 MB debug APK for each file.
                # Over wireless adb that is several minutes per install, so
                # this bound has to cover the installs, not just the tests.
                args.device,
                timeout=1800,
            )
    except Exception as exc:  # Restore before reporting the original failure.
        error = exc
    finally:
        try:
            restore_and_launch_debug(args.device, backup_dir, backup, installs)
        except Exception as restore_error:
            # Never let this read as a clean run: the user database is still
            # only in the retained backup at this point.
            print(f"database restore failed: {restore_error}", file=sys.stderr)
            if backup:
                print(f"backup retained at {backup_dir}", file=sys.stderr)
                print(
                    "the on-device database may be incomplete; finish this run "
                    f"with: make restore-device DEVICE={args.device} "
                    f"BACKUP={backup_dir}",
                    file=sys.stderr,
                )
            else:
                # Nothing was read off the device, so there is nothing to put
                # back and `--restore-from` would refuse the empty directory.
                print(
                    "no user database was backed up, so there is nothing to "
                    "restore (the run failed before the backup, or the app had "
                    "no database yet)",
                    file=sys.stderr,
                )
            if error is None:
                error = restore_error

    if error is not None:
        print(f"Android acceptance FAIL: {error}", file=sys.stderr)
        if backup:
            print(f"backup retained at {backup_dir}", file=sys.stderr)
        else:
            print(
                "no backup was taken (failure before the backup step); the "
                f"product APK remains in {backup_dir}",
                file=sys.stderr,
            )
        return 1
    restored = (
        "user database restored"
        if backup
        else "no user database was present (nothing to restore)"
    )
    print(f"Android acceptance PASS; {restored}; debug build running.")
    print(
        "script-driven installs: "
        + (", ".join(installs) if installs else "none")
        + " (flutter test installs the debug APK itself)",
        flush=True,
    )
    print(f"backup retained at {backup_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
