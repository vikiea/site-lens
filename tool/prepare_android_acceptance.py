#!/usr/bin/env python3
"""Build a proven debug product/test pair before starting an emulator.

Usage: python3 tool/prepare_android_acceptance.py --target-platform android-arm64
The output includes the exact acceptance command. Run pub get/setup first;
prepare uses --no-pub and accepts no old APK or caller-supplied metadata.

Proofs are local to this Git checkout: a manifest must match a receipt written
under its Git directory by a successful prepare. This prevents accidental
certification by hand-written metadata, not hostile modification of the tools
or the Git-local receipt store by someone with the same filesystem access.
"""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import time

import run_android_acceptance as acceptance


class SourceGuard:
    """Reject persistent edits and edits reverted before a build finishes."""

    def __init__(self) -> None:
        self.stamps = self.source_stamps()
        self.fingerprint = acceptance.prebuilt_source_fingerprint()
        self.check()

    @staticmethod
    def source_stamps() -> dict[str, tuple[int, ...] | None]:
        stamps = {}
        for relative in acceptance.acceptance_source_paths():
            path = acceptance.ROOT / relative
            try:
                stat = path.stat()
                stamps[relative] = (
                    stat.st_dev, stat.st_ino, stat.st_mode, stat.st_size,
                    stat.st_mtime_ns, stat.st_ctime_ns,
                )
            except FileNotFoundError:
                stamps[relative] = None
        return stamps

    def check(self) -> None:
        if (self.source_stamps() != self.stamps
                or acceptance.prebuilt_source_fingerprint() != self.fingerprint):
            raise RuntimeError('source/worktree changed during prepare; no proof issued')


def run_guarded_build(command: list[str], guard: SourceGuard) -> None:
    guard.check()
    process = subprocess.Popen(
        command, cwd=acceptance.ROOT, env=acceptance.ENV, start_new_session=True,
    )
    deadline = time.monotonic() + 1200
    try:
        while True:
            try:
                code = process.wait(timeout=0.5)
            except subprocess.TimeoutExpired:
                guard.check()
                if time.monotonic() >= deadline:
                    raise subprocess.TimeoutExpired(command, 1200)
                continue
            guard.check()
            if code:
                raise subprocess.CalledProcessError(code, command)
            return
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=10)


def prepare(output: Path, integration_target: str, target_platform: str) -> Path:
    if integration_target not in acceptance.INTEGRATION_TARGETS:
        raise RuntimeError('unsupported integration target')
    if target_platform not in ('android-arm', 'android-arm64', 'android-x64'):
        raise RuntimeError('unsupported target platform')
    output = output.resolve()
    # Build outputs must be ignored so creating them cannot invalidate their
    # own complete-worktree fingerprint. Never overwrite a previous proof.
    build_root = (acceptance.ROOT / 'build').resolve()
    if not output.is_relative_to(build_root) or output == build_root:
        raise RuntimeError('--output-dir must be a new directory under build/')
    receipts = acceptance.prebuilt_receipt_directory()
    receipts.mkdir(parents=True, exist_ok=True)
    with (receipts / 'prepare.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise RuntimeError('another prepare is already running') from error
        guard = SourceGuard()
        output.mkdir(parents=True, exist_ok=False)
        manifest = {
            'schema': 1,
            'producer': 'prepare_android_acceptance',
            'fingerprint': guard.fingerprint,
            'target_platform': target_platform,
            'artifacts': {},
        }
        for role, entrypoint, defines, filename in (
            ('product', acceptance.PRODUCT_ENTRYPOINT, [], 'product-debug.apk'),
            ('test', integration_target, acceptance.test_defines(), 'integration-debug.apk'),
        ):
            if not (acceptance.ROOT / entrypoint).is_file():
                raise RuntimeError(f'missing {role} entrypoint: {entrypoint}')
            command = acceptance.prepared_build_command(entrypoint, target_platform, defines)
            # A successful no-op/mock builder cannot certify the old output.
            acceptance.DEBUG_APK.unlink(missing_ok=True)
            run_guarded_build(command, guard)
            guard.check()
            acceptance.verify_apk_package(acceptance.DEBUG_APK, acceptance.PACKAGE, acceptance.ENV)
            destination = output / filename
            digest = acceptance.apk_sha256(acceptance.DEBUG_APK)
            shutil.copy2(acceptance.DEBUG_APK, destination)
            if (acceptance.apk_sha256(destination) != digest
                    or acceptance.apk_sha256(acceptance.DEBUG_APK) != digest):
                raise RuntimeError('APK changed while copying; no proof issued')
            manifest['artifacts'][role] = {
                'role': role,
                'entrypoint': entrypoint,
                'integration_target': None if role == 'product' else integration_target,
                'file': filename,
                'sha256': digest,
                'command': command,
            }
        if manifest['artifacts']['product']['sha256'] == manifest['artifacts']['test']['sha256']:
            raise RuntimeError('product and test must be different artifacts; no proof issued')
        guard.check()
        payload = acceptance.manifest_bytes(manifest)
        manifest_path = output / acceptance.PREBUILT_MANIFEST
        manifest_path.write_bytes(payload)
        guard.check()
        # This receipt is the authority; it is never created by the runner or
        # by an import/certify command. Unknown old APKs have no such receipt.
        receipt = receipts / (hashlib.sha256(payload).hexdigest() + '.json')
        receipt.write_bytes(payload)
        return manifest_path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--integration-target', choices=acceptance.INTEGRATION_TARGETS,
                        default=acceptance.DEFAULT_INTEGRATION_TARGET)
    parser.add_argument('--target-platform', choices=('android-arm', 'android-arm64', 'android-x64'),
                        default='android-arm64')
    parser.add_argument('--output-dir', type=Path, help='new bundle directory under build/')
    args = parser.parse_args()
    output = args.output_dir
    if output is None:
        directory = acceptance.ROOT / 'build/android-acceptance'
        directory.mkdir(parents=True, exist_ok=True)
        # Reserve a unique name; prepare itself requires a new directory.
        output = Path(tempfile.mkdtemp(prefix='prepared-', dir=directory))
        output.rmdir()
    try:
        manifest = prepare(output, args.integration_target, args.target_platform)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(f'Android prepare FAIL: {error}', file=acceptance.sys.stderr)
        return 1
    print(f'Android prepare PASS: {manifest}')
    print(shlex.join([
        'python3', 'tool/run_android_acceptance.py', 'DEVICE', '--single-suite',
        '--integration-target', args.integration_target,
        '--prebuilt-product-apk', str(output / 'product-debug.apk'),
        '--prebuilt-test-apk', str(output / 'integration-debug.apk'),
        '--prebuilt-manifest', str(manifest),
    ]))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
