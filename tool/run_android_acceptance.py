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
import atexit
import base64
import hashlib
import json
import os
import re
import shutil
import shlex
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from android_artifact import FORMAL_PACKAGE, verify_apk_package, verify_formal_apk
from android_media_actions import MediaActionDriver
from validation_runner import content_fingerprint, is_tcp_endpoint, worktree_fingerprint

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = "dev.vikiea.site_lens.debug"
ACTIVITY = "dev.vikiea.site_lens.MainActivity"
DEBUG_APK = ROOT / "build/app/outputs/flutter-apk/app-debug.apk"
RELEASE_APK = ROOT / "build/app/outputs/flutter-apk/app-release.apk"
NETWORK_DEFINE = "--dart-define=ALLOW_LOCAL_TEST_PAGES=true"
PRODUCT_ENTRYPOINT = "lib/main.dart"
DEFAULT_INTEGRATION_TARGET = "integration_test/acceptance_suite_test.dart"
INTEGRATION_TARGETS = (
    DEFAULT_INTEGRATION_TARGET,
    'integration_test/app_flow_test.dart',
    'integration_test/browser_tabs_test.dart',
    'integration_test/host_contract_test.dart',
    'integration_test/modernization_test.dart',
    'integration_test/script_import_test.dart',
    'integration_test/media_tasks_test.dart',
    'integration_test/media3_parity_test.dart',
    'integration_test/configured_sites_test.dart',
    'integration_test/real_media_site_test.dart',
    'integration_test/navigation_lease_test.dart',
    'integration_test/hcpp_visual_test.dart',
)
PREBUILT_MANIFEST = "acceptance-manifest.json"
BACKUP_MANIFEST = "backup-manifest.json"
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
    visual_run = ENV.get('SITE_LENS_VISUAL_RUN_ID', '').strip()
    if visual_run:
        if not re.fullmatch(r'[0-9a-f]{32}', visual_run):
            raise ValueError('invalid visual acceptance run id')
        values.append(f'--dart-define=SITE_LENS_VISUAL_RUN_ID={visual_run}')
    sites = ENV.get('SITE_LENS_TEST_SITES', '').strip()
    if sites:
        values.append(f'--dart-define=SITE_LENS_TEST_SITES={sites}')
    media_url = ENV.get('SITE_LENS_MEDIA_TEST_URL', '').strip()
    media_pages = ENV.get('SITE_LENS_MEDIA_TEST_URLS', '').strip()
    if media_url:
        values.append(f'--dart-define=SITE_LENS_MEDIA_TEST_URL={media_url}')
    if media_pages:
        # Flutter test splits multiline define values into positional test
        # arguments. Encode the developer-only list as one safe argument.
        encoded_pages = base64.b64encode(media_pages.encode()).decode('ascii')
        values.append(f'--dart-define=SITE_LENS_MEDIA_TEST_URLS_BASE64={encoded_pages}')
    if media_url or media_pages:
        expected_episodes = ENV.get('SITE_LENS_MEDIA_EXPECT_EPISODES', '').strip()
        if expected_episodes:
            values.append(f'--dart-define=SITE_LENS_MEDIA_EXPECT_EPISODES={expected_episodes}')
        if ENV.get('SITE_LENS_REAL_MEDIA_DOWNLOAD', '').strip().lower() in {
            '1', 'true', 'yes', 'on'
        }:
            values.append('--dart-define=SITE_LENS_REAL_MEDIA_DOWNLOAD=true')
    if ENV.get('SITE_LENS_PROXY_FIXTURE', '').strip().lower() in {
        '1', 'true', 'yes', 'on'
    }:
        values.append('--dart-define=SITE_LENS_PROXY_FIXTURE=true')
    return values


def integration_driver_path() -> Path:
    # Keep the driver inside this project so its package import resolves from
    # this pubspec. The SDK example driver lives in a different package root,
    # so passing it directly to `flutter drive` cannot resolve this project's
    # integration_test dependency.
    directory = ROOT / ".dart_tool/site-lens-acceptance"
    directory.mkdir(parents=True, exist_ok=True)
    fd, raw_path = tempfile.mkstemp(
        prefix=".site-lens-integration-driver-",
        suffix=".dart",
        dir=directory,
    )
    os.close(fd)
    path = Path(raw_path)
    completion = integration_completion_path(path)
    path.write_text(
        "import 'dart:convert';\n"
        "import 'dart:io';\n"
        "import 'package:integration_test/integration_test_driver.dart';\n"
        "\n"
        "Future<void> main() => integrationDriver("
        "writeResponseOnFailure: false, responseDataCallback: (data) async {\n"
        "  await writeResponseData(data);\n"
        f"  await File({json.dumps(str(completion))}).writeAsString(\n"
        "    jsonEncode({'schema': 1, 'passed': true}), flush: true);\n"
        "});\n",
        encoding="utf-8",
    )
    atexit.register(path.unlink, missing_ok=True)
    atexit.register(completion.unlink, missing_ok=True)
    return path


def integration_completion_path(driver: Path) -> Path:
    return driver.with_suffix('.passed.json')


def verify_integration_completion(driver: Path) -> None:
    # `flutter drive` can exit 0 after SIGTERM while leaving the test app
    # running. The unique per-run receipt is emitted only by the SDK's success
    # response callback, after all tests have finished, never from console text.
    try:
        result = json.loads(integration_completion_path(driver).read_text())
    except (OSError, ValueError) as error:
        raise RuntimeError('Integration driver exited without a passed suite completion receipt') from error
    if result != {'schema': 1, 'passed': True}:
        raise RuntimeError('Integration driver completion receipt does not prove a passed suite')


def apk_sha256(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def acceptance_source_paths() -> list[str]:
    output = subprocess.check_output(
        ['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
        cwd=ROOT,
    )
    return sorted(set(os.fsdecode(path) for path in output.split(b'\0') if path))


def prebuilt_source_fingerprint() -> dict[str, str]:
    # Include dirty and untracked contents, rather than certifying HEAD alone.
    return {
        'worktree': worktree_fingerprint(root=ROOT),
        'source': content_fingerprint(acceptance_source_paths(), root=ROOT),
    }


def prebuilt_receipt_directory() -> Path:
    value = subprocess.check_output(
        ['git', 'rev-parse', '--git-path', 'site-lens-android-acceptance'], cwd=ROOT,
    ).decode().strip()
    path = Path(value)
    return path if path.is_absolute() else ROOT / path


def manifest_bytes(manifest: dict) -> bytes:
    return json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()


def prepared_build_command(
    entrypoint: str, target_platform: str, defines: list[str],
) -> list[str]:
    return [
        'flutter', 'build', 'apk', '--debug', '--no-pub',
        f'--target={entrypoint}', f'--target-platform={target_platform}', *defines,
    ]


def validate_prebuilt_apks(
    product_apk: Path | None,
    test_apk: Path | None,
    manifest_path: Path | None = None,
    integration_target: str = DEFAULT_INTEGRATION_TARGET,
) -> tuple[Path, Path] | None:
    if product_apk is None and test_apk is None:
        return None
    if product_apk is None or test_apk is None:
        raise RuntimeError(
            "--prebuilt-product-apk and --prebuilt-test-apk must be supplied together"
        )

    for role, path in (("product", product_apk), ("test", test_apk)):
        if not path.is_file():
            raise RuntimeError(f"prebuilt {role} APK does not exist: {path}")
    product_digest, test_digest = apk_sha256(product_apk), apk_sha256(test_apk)
    if product_digest == test_digest:
        raise RuntimeError('prebuilt product and test must be different artifacts')

    manifest_path = manifest_path or product_apk.parent / PREBUILT_MANIFEST
    try:
        manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
        if not isinstance(manifest, dict):
            raise ValueError('manifest must be an object')
    except (OSError, ValueError) as error:
        raise RuntimeError(
            'missing or invalid prebuilt proof; run tool/prepare_android_acceptance.py '
            '(existing APKs cannot be certified)'
        ) from error
    payload = manifest_bytes(manifest)
    receipt = prebuilt_receipt_directory() / (hashlib.sha256(payload).hexdigest() + '.json')
    # The manifest is descriptive, not an authority. Only prepare writes this
    # Git-local receipt after both controlled builds and drift checks succeed.
    if not receipt.is_file() or receipt.read_bytes() != payload:
        raise RuntimeError('prebuilt proof has no matching controlled-build receipt; rerun prepare')
    if manifest.get('schema') != 1 or manifest.get('producer') != 'prepare_android_acceptance':
        raise RuntimeError('unsupported prebuilt proof')
    if manifest.get('fingerprint') != prebuilt_source_fingerprint():
        raise RuntimeError('prebuilt proof has stale source/worktree fingerprint; rerun prepare')
    platform = manifest.get('target_platform')
    if platform not in ('android-arm', 'android-arm64', 'android-x64'):
        raise RuntimeError('invalid prebuilt target platform')
    records = manifest.get('artifacts')
    if not isinstance(records, dict) or set(records) != {'product', 'test'}:
        raise RuntimeError('invalid prebuilt artifact roles')
    if manifest_path.resolve().parent != product_apk.resolve().parent \
            or manifest_path.resolve().parent != test_apk.resolve().parent:
        raise RuntimeError('prebuilt APKs and proof must come from one prepared bundle')
    for role, path, digest, entrypoint, defines in (
        ('product', product_apk, product_digest, PRODUCT_ENTRYPOINT, []),
        ('test', test_apk, test_digest, integration_target, test_defines()),
    ):
        record = records[role]
        expected_target = None if role == 'product' else integration_target
        if not isinstance(record, dict) or record.get('role') != role:
            raise RuntimeError(f'prebuilt {role} role mismatch')
        if record.get('file') != path.name:
            raise RuntimeError(f'prebuilt {role} file/role mismatch')
        if (record.get('entrypoint') != entrypoint
                or record.get('integration_target') != expected_target):
            raise RuntimeError(f'prebuilt {role} entrypoint/integration suite mismatch')
        if record.get('command') != prepared_build_command(entrypoint, platform, defines):
            raise RuntimeError(f'prebuilt {role} build command/defines mismatch')
        if record.get('sha256') != digest:
            raise RuntimeError(f'prebuilt {role} SHA-256 mismatch (wrong role or altered APK)')
        try:
            verify_apk_package(path, PACKAGE, ENV)
        except Exception as error:
            raise RuntimeError(
                f"prebuilt {role} APK must be the debug package "
                f"{PACKAGE}: {error}"
            ) from error
    return product_apk, test_apk


def prebuilt_drive_command(
    device: str,
    test_apk: Path,
    driver: Path,
) -> list[str]:
    return [
        "flutter",
        "drive",
        "--no-pub",
        "--no-dds",
        "--keep-app-running",
        "--driver",
        str(driver),
        "--use-application-binary",
        str(test_apk),
        "-d",
        device,
    ]

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


def require_device(device: str, *, allow_recovery: bool = True) -> None:
    if is_tcp_endpoint(device):
        if not device_online(device):
            if not allow_recovery:
                raise SystemExit(f"device {device} is unavailable; ADB recovery disabled")
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


def ensure_debug_install(device: str, apk: Path = DEBUG_APK) -> bool:
    """Install the debug APK only when the private data is unreadable.

    Debug and formal installs have separate identities and certificates.
    Restoring debug data never changes the formal app database. Skipping the push when
    `run-as` already works removes one ~168 MB wireless transfer per run.
    """
    if debug_data_readable(device):
        return False
    verify_apk_package(apk, PACKAGE, ENV)
    install(device, apk, PACKAGE)
    return True


def file_exists(device: str, relative: str) -> bool:
    if relative not in {f"files/{name}" for name in DATABASE_FILES}:
        raise ValueError("unexpected backup database path")
    script = (
        "if [ -d files ]; then "
        "[ -r files ] && [ -x files ] || exit 3; "
        f"if [ -f {shlex.quote(relative)} ]; then "
        f"[ -r {shlex.quote(relative)} ] || exit 4; printf PRESENT; "
        f"elif [ -e {shlex.quote(relative)} ]; then exit 5; else printf ABSENT; fi; "
        "elif [ -e files ]; then exit 6; else printf ABSENT; fi"
    )
    result = adb(device, "shell", f"run-as {PACKAGE} sh -c {shlex.quote(script)}")
    result.check_returncode()
    status = result.stdout.strip()
    if status not in (b"PRESENT", b"ABSENT"):
        raise RuntimeError("database existence probe did not return a trustworthy result")
    return status == b"PRESENT"


def read_device_file(device: str, relative: str) -> bytes:
    return subprocess.check_output(
        [ADB, "-s", device, "exec-out", "run-as", PACKAGE, "cat", relative],
        stderr=subprocess.PIPE,
        timeout=ADB_COMMAND_TIMEOUT_SECONDS,
    )


def read_device_identity(device: str) -> dict:
    """Bind user-0 run-as data to a device, independently of its TCP endpoint.

    Keep only hashes of serial/Android ID in the local backup. Model, API and
    build fingerprint are deliberately not restore keys: an OTA is permitted.
    """
    serial = ''
    for prop in ('ro.serialno', 'ro.boot.serialno'):
        value = adb(device, 'shell', 'getprop', prop).stdout.decode().strip()
        if value and value.lower() not in {'unknown', 'null', 'none'}:
            serial = value
            break
    android_id = adb(
        device, 'shell', 'settings', '--user', '0', 'get', 'secure', 'android_id'
    ).stdout.decode().strip().lower()
    if not serial or not re.fullmatch(r'[0-9a-f]{16}', android_id) \
            or android_id == '0000000000000000':
        raise RuntimeError('stable device identity unavailable; no device mutation permitted')
    return {
        'serial_sha256': hashlib.sha256(serial.encode()).hexdigest(),
        'android_id_sha256': hashlib.sha256(android_id.encode()).hexdigest(),
    }


def write_backup_manifest(
    device: str, directory: Path, backup: dict[str, str], identity: dict
) -> None:
    """Publish a complete backup only after a second source identity check."""
    if read_device_identity(device) != identity:
        raise RuntimeError('device identity changed during backup; tests not permitted')
    files = {}
    for name, digest in backup.items():
        if name not in DATABASE_FILES:
            raise RuntimeError('unexpected backup database name')
        source = directory / name
        if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f'backup hash mismatch for {name}')
        files[name] = {'sha256': digest, 'size': source.stat().st_size}
    payload = {
        'schema': 1, 'complete': True, 'package': PACKAGE, 'user': 0,
        'identity': identity, 'files': files,
        'product_sha256': apk_sha256(directory / 'product-debug.apk'),
    }
    pending = directory / (BACKUP_MANIFEST + '.part')
    with pending.open('x', encoding='utf-8') as stream:
        os.chmod(pending, 0o600)
        json.dump(payload, stream, sort_keys=True)
        stream.flush()
        os.fsync(stream.fileno())
    pending.replace(directory / BACKUP_MANIFEST)


def load_backup_manifest(directory: Path, *, allow_missing_product: bool = False) -> dict:
    try:
        manifest = json.loads((directory / BACKUP_MANIFEST).read_text())
        if not isinstance(manifest, dict) or manifest.get('schema') != 1 \
                or manifest.get('complete') is not True \
                or manifest.get('package') != PACKAGE or manifest.get('user') != 0:
            raise ValueError('invalid backup metadata')
        identity = manifest.get('identity')
        if not isinstance(identity, dict) or set(identity) != {
            'serial_sha256', 'android_id_sha256'
        } or not all(isinstance(value, str) and re.fullmatch(r'[0-9a-f]{64}', value)
                     for value in identity.values()):
            raise ValueError('missing stable source identity')
        files = manifest.get('files')
        if not isinstance(files, dict) or not set(files).issubset(DATABASE_FILES):
            raise ValueError('invalid database inventory')
        actual_files = {name for name in DATABASE_FILES if (directory / name).exists()}
        if set(files) != actual_files:
            raise ValueError('database inventory changed')
        for name, record in files.items():
            source = directory / name
            if not isinstance(record, dict) or record.get('size') != source.stat().st_size \
                    or record.get('sha256') != hashlib.sha256(source.read_bytes()).hexdigest():
                raise ValueError(f'backup bytes changed for {name}')
        product_digest = manifest.get('product_sha256')
        if not isinstance(product_digest, str) or not re.fullmatch(r'[0-9a-f]{64}', product_digest):
            raise ValueError('missing backup product APK identity')
        product = directory / 'product-debug.apk'
        if not product.exists():
            if not allow_missing_product:
                raise RuntimeError(f'prebuilt product APK backup is missing: {product}')
        elif product_digest != apk_sha256(product):
            raise ValueError('backup product APK changed')
        return manifest
    except (OSError, ValueError, TypeError) as error:
        raise RuntimeError(
            'backup lacks valid complete source metadata; legacy backups require '
            'separate source verification and are not automatically assigned to this device'
        ) from error


def verify_backup_target(
    device: str, directory: Path, backup: dict[str, str], *, expected_identity: dict | None = None,
    allow_missing_product: bool = False,
) -> dict:
    manifest = load_backup_manifest(directory, allow_missing_product=allow_missing_product)
    if {name: row['sha256'] for name, row in manifest['files'].items()} != backup:
        raise RuntimeError('backup inventory differs from the captured snapshot')
    if expected_identity is not None and manifest['identity'] != expected_identity:
        raise RuntimeError('backup source metadata differs from the captured identity')
    if read_device_identity(device) != manifest['identity']:
        raise RuntimeError('backup belongs to another device; restore blocked before mutation')
    return manifest


def write_device_file(device: str, relative: str, source: Path) -> None:
    # run-as can read the adb shell stdin but not /sdcard under scoped storage.
    with source.open("rb") as stream:
        subprocess.run(
            [ADB, "-s", device, "shell", f"run-as {PACKAGE} sh -c 'cat > {relative}'"],
            check=True,
            stdin=stream,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=ADB_COMMAND_TIMEOUT_SECONDS,
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
    # Database ownership remains mandatory even when the normal product APK
    # had to be rebuilt into DEBUG_APK instead of its old backup location.
    verify_backup_target(device, directory, backup, allow_missing_product=True)
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
    device: str,
    directory: Path,
    backup: dict[str, str],
    installs: list[str],
    *,
    allow_rebuild: bool = True,
    expected_identity: dict | None = None,
) -> None:
    """Restore only the debug test package, then launch the restored debug build."""
    verify_backup_target(
        device, directory, backup, expected_identity=expected_identity,
        allow_missing_product=allow_rebuild,
    )
    adb(device, "shell", "am", "force-stop", PACKAGE, check=False)
    product = directory / "product-debug.apk"
    if not product.is_file():
        if not allow_rebuild:
            raise RuntimeError(
                f"prebuilt product APK backup is missing: {product}"
            )
        run_flutter(normal_debug_build(device), timeout=600)
        product = DEBUG_APK
    # Flutter integration_test overwrites app-debug.apk with its test entrypoint.
    verify_apk_package(product, PACKAGE, ENV)
    install(device, product, PACKAGE)
    installs.append("normal debug for restore")
    restore_database(device, directory, backup)
    print('restore verified: source device identity and database SHA-256 match', flush=True)
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
    try:
        manifest = load_backup_manifest(directory, allow_missing_product=True)
    except RuntimeError as exc:
        print(f'Android restore-only FAIL: {exc}; backup retained at {directory}', file=sys.stderr)
        return 1
    backup = {name: row['sha256'] for name, row in manifest['files'].items()}
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
        "--no-adb-recovery", action="store_true",
        help="stop on an unavailable endpoint without restarting the shared ADB server",
    )
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
        choices=INTEGRATION_TARGETS,
        default=DEFAULT_INTEGRATION_TARGET,
    )
    parser.add_argument('--test-name', help='Optional Flutter test-name regex for a targeted device regression')
    parser.add_argument(
        '--prebuilt-product-apk',
        type=Path,
        help='prebuilt normal debug APK; requires --prebuilt-test-apk and --single-suite',
    )
    parser.add_argument(
        '--prebuilt-test-apk',
        type=Path,
        help='prebuilt integration-test debug APK; requires --prebuilt-product-apk and --single-suite',
    )
    parser.add_argument(
        '--prebuilt-manifest',
        type=Path,
        help='manifest emitted by tool/prepare_android_acceptance.py',
    )
    args = parser.parse_args()

    if not args.single_suite and (
        args.test_name or args.integration_target != DEFAULT_INTEGRATION_TARGET
    ):
        parser.error('--integration-target and --test-name require --single-suite')

    prebuilt_requested = (
        args.prebuilt_product_apk is not None
        or args.prebuilt_test_apk is not None
        or args.prebuilt_manifest is not None
    )
    if prebuilt_requested:
        if args.prebuilt_product_apk is None or args.prebuilt_test_apk is None:
            parser.error(
                '--prebuilt-product-apk and --prebuilt-test-apk must be supplied together'
            )
        if args.prebuilt_manifest is None:
            parser.error('--prebuilt-manifest is required for prebuilt APKs')
        if not args.single_suite:
            parser.error('prebuilt APKs require --single-suite')
        if args.test_name:
            parser.error('--test-name cannot be used with prebuilt APKs')
        if args.restore_from:
            parser.error('--restore-from cannot be used with prebuilt APKs')

    prebuilt_apks = validate_prebuilt_apks(
        args.prebuilt_product_apk,
        args.prebuilt_test_apk,
        args.prebuilt_manifest,
        args.integration_target,
    )
    prebuilt_driver = integration_driver_path() if prebuilt_apks else None

    global RESTART_ADB
    RESTART_ADB = args.restart_adb
    require_device(args.device, allow_recovery=not args.no_adb_recovery)

    if args.restore_from:
        return restore_only(args.device, Path(args.restore_from))

    if not args.skip_check:
        run_flutter(["./tool/check.sh"], timeout=300)
    if prebuilt_apks is None:
        # Always capture a normal product APK; previous integration runs replace the build output.
        run_flutter(normal_debug_build(args.device), timeout=600)
        if not args.skip_build:
            run_flutter(["flutter", "build", "apk", "--release"], timeout=600)

        product_apk = DEBUG_APK
        verify_apk_package(product_apk, PACKAGE, ENV)
        if not args.skip_build:
            verify_formal_apk(RELEASE_APK, ENV)
    else:
        product_apk, test_apk = prebuilt_apks
        # The first proof check happens before the strict device preflight and
        # local checks. Recheck after those steps and immediately before any
        # backup/install so a source or APK change during preparation cannot
        # turn into device evidence for a different worktree.
        prebuilt_apks = validate_prebuilt_apks(
            args.prebuilt_product_apk,
            args.prebuilt_test_apk,
            args.prebuilt_manifest,
            args.integration_target,
        )
        assert prebuilt_apks is not None
        product_apk, test_apk = prebuilt_apks

    backup_dir = Path(tempfile.mkdtemp(prefix="site-lens-android-backup-"))
    shutil.copy2(product_apk, backup_dir / "product-debug.apk")
    backup: dict[str, str] = {}
    backup_completed = False
    backup_identity = None
    installs: list[str] = []
    error: Exception | None = None
    try:
        backup_identity = read_device_identity(args.device)
        adb(args.device, "shell", "am", "force-stop", PACKAGE, check=False)
        adb(args.device, "shell", "am", "force-stop", FORMAL_PACKAGE, check=False)
        if ensure_debug_install(args.device, product_apk):
            installs.append("debug for backup/restore")
        backup = backup_database(args.device, backup_dir)
        write_backup_manifest(args.device, backup_dir, backup, backup_identity)
        backup_completed = True
        print(f"backup: {backup_dir} files={sorted(backup)}", flush=True)

        if prebuilt_apks is not None:
            print("acceptance mode: prebuilt single-suite (one app install)", flush=True)
            integration_completion_path(prebuilt_driver).unlink(missing_ok=True)
            run_single_suite_with_media_driver(
                prebuilt_drive_command(
                    args.device,
                    test_apk,
                    prebuilt_driver,
                ),
                args.device,
                timeout=1800,
            )
            verify_integration_completion(prebuilt_driver)
        elif args.single_suite:
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
        if not backup_completed:
            print(f"backup incomplete; tests, restore installation and app launch not attempted; "
                  f"partial backup retained at {backup_dir}", file=sys.stderr, flush=True)
        else:
            try:
                restore_and_launch_debug(
                    args.device,
                    backup_dir,
                    backup,
                    installs,
                    allow_rebuild=prebuilt_apks is None,
                    expected_identity=backup_identity,
                )
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
        elif not backup_completed:
            print(f"backup was not completed; original device files remain in place; "
                  f"partial files and product APK retained at {backup_dir}", file=sys.stderr)
        else:
            print(f"no user database was present; product APK retained at {backup_dir}", file=sys.stderr)
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
        + (
            " (prebuilt flutter drive installs the test APK itself)"
            if prebuilt_apks is not None
            else " (flutter test installs the debug APK itself)"
        ),
        flush=True,
    )
    print(f"backup retained at {backup_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
