#!/usr/bin/env python3
"""Capture real compositor pixels for the opt-in HCPP visual fixture.

The canonical acceptance runner owns APK installation and database recovery.
This observer only captures a foreground debug fixture and acknowledges its
per-run checkpoints. PNGs and metadata stay in a new ignored build directory.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import struct
import subprocess
import sys
import time
import uuid

import run_android_acceptance as acceptance


TARGET = 'integration_test/hcpp_visual_test.dart'
PHASES = tuple(f'{theme}-{opacity}-{surface}'
               for theme in ('light', 'dark') for opacity in (0, 55, 100)
               for surface in ('browser', 'overlay', 'flutter'))
REQUEST = 'files/visual_acceptance_phase.json'
ACK = 'files/visual_acceptance_ack'
NO_REQUEST = b'SITE_LENS_NO_VISUAL_REQUEST'


def validate_request(raw: bytes, run_id: str, index: int) -> dict | None:
    if len(raw) > 4096:
        raise RuntimeError('oversized visual capture request')
    try:
        request = json.loads(raw)
    except (ValueError, UnicodeDecodeError) as error:
        raise RuntimeError('invalid visual capture request') from error
    if not isinstance(request, dict):
        raise RuntimeError('invalid visual capture request')
    if request.get('runId') != run_id:
        return None  # A request from an earlier install cannot authorize capture.
    if index >= len(PHASES) or request != {
        'runId': run_id, 'id': f'{run_id}_{index}', 'name': PHASES[index],
    }:
        raise RuntimeError('out-of-order or unknown visual capture checkpoint')
    return request


def assert_debug_foreground(device: str) -> None:
    output = acceptance.adb(device, 'shell', 'dumpsys', 'activity', 'activities', timeout=8).stdout.decode()
    resumed = [line for line in output.splitlines()
               if 'topResumedActivity=' in line or 'mResumedActivity=' in line]
    owners = re.findall(r'\b([a-zA-Z0-9_.]+)/[a-zA-Z0-9_.$]+', '\n'.join(resumed))
    if not owners or set(owners) != {acceptance.PACKAGE}:
        raise RuntimeError('visual capture requires the debug fixture as foreground owner')
    # Android 16 omits global focus from the `windows` subcommand. The full
    # window dump includes it; missing or ambiguous focus still fails closed.
    windows = acceptance.adb(device, 'shell', 'dumpsys', 'window', timeout=8).stdout.decode()
    focused = [line for line in windows.splitlines() if 'mCurrentFocus=' in line]
    owners = re.findall(r'\b([a-zA-Z0-9_.]+)/[a-zA-Z0-9_.$]+', '\n'.join(focused))
    if len(focused) != 1 or owners != [acceptance.PACKAGE]:
        raise RuntimeError('visual capture requires the debug window to have focus')


def read_request(device: str) -> bytes | None:
    # exec-out does not reliably communicate a remote cat failure. Probe
    # existence inside a shell-v2 command and use an explicit absence marker.
    script = f'if [ -f {REQUEST} ]; then cat {REQUEST}; else printf {NO_REQUEST.decode()}; fi'
    result = acceptance.adb(device, 'shell',
                            f'run-as {acceptance.PACKAGE} sh -c {shlex.quote(script)}',
                            check=False, timeout=8)
    if result.returncode or not result.stdout.strip() or result.stdout.strip() == NO_REQUEST:
        return None
    return result.stdout


def assert_current_request(device: str, request: dict) -> None:
    raw = read_request(device)
    try:
        current = json.loads(raw) if raw is not None else None
    except (ValueError, UnicodeDecodeError) as error:
        raise RuntimeError('visual checkpoint expired during capture') from error
    if current != request:
        raise RuntimeError('visual checkpoint expired during capture')


def capture(device: str, directory: Path, request: dict) -> dict:
    assert_current_request(device, request)
    assert_debug_foreground(device)
    image = acceptance.adb(device, 'exec-out', 'screencap', '-p', timeout=8).stdout
    if len(image) < 33 or image[:8] != b'\x89PNG\r\n\x1a\n' or image[12:16] != b'IHDR':
        raise RuntimeError('device did not return a PNG compositor screenshot')
    width, height = struct.unpack('>II', image[16:24])
    if not (100 <= width <= 10000 and 100 <= height <= 10000):
        raise RuntimeError('invalid compositor image dimensions')
    # Hold pixels only in memory until both owner and exact live checkpoint
    # still match. An expired fixture or switched foreground leaves no image.
    assert_debug_foreground(device)
    assert_current_request(device, request)
    name = request['name']
    destination = directory / f'{name}.png'
    acknowledgement = directory / 'ack.txt'
    acknowledgement.write_text(request['id'])
    created = False
    try:
        stream = destination.open('xb')
        created = True
        with stream:
            stream.write(image)
        acceptance.write_device_file(device, ACK, acknowledgement)
    except BaseException:
        if created:
            destination.unlink(missing_ok=True)
        raise
    return {'phase': name, 'file': destination.name, 'sha256': hashlib.sha256(image).hexdigest(),
            'width': width, 'height': height, 'capturedAtMs': int(time.time() * 1000),
            'source': 'adb exec-out screencap -p'}


def observe(process, device: str, output: Path, run_id: str) -> list[dict]:
    records = []
    last_id = None
    while process.poll() is None:
        payload = read_request(device)
        if payload is None:
            # The canonical runner may still be installing. It performs the
            # strict preflight and owns any resulting recovery failure.
            time.sleep(0.3)
            continue
        try:
            raw = json.loads(payload)
            if isinstance(raw, dict) and raw.get('id') == last_id:
                time.sleep(0.2)
                continue
        except (ValueError, UnicodeDecodeError):
            pass
        request = validate_request(payload, run_id, len(records))
        if request is not None:
            records.append(capture(device, output, request))
            last_id = request['id']
            (output / 'captures.json').write_text(json.dumps(records, indent=2) + '\n')
            print(f'VISUAL_CAPTURE_PASS phase={request["name"]}', flush=True)
        time.sleep(0.2)
    if process.wait() or len(records) != len(PHASES):
        raise RuntimeError(f'visual suite incomplete: exit={process.returncode}, captures={len(records)}/{len(PHASES)}')
    return records


def observe_with_restore(process, device: str, output: Path, run_id: str) -> list[dict]:
    try:
        return observe(process, device, output, run_id)
    except BaseException:
        print('VISUAL_OBSERVER_FAILED; waiting for canonical test timeout and protected restore', flush=True)
        # Keep this parent and its exec session alive. Abandoning the exec
        # process group after an arbitrary wait can kill the protected runner
        # before its finally restores the database. Its own bounded test,
        # install and ADB timeouts remain authoritative; never reconnect here.
        while process.poll() is None:
            time.sleep(0.5)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('device')
    parser.add_argument('--output-dir', type=Path, required=True)
    args = parser.parse_args()
    output = args.output_dir.resolve()
    build = (acceptance.ROOT / 'build').resolve()
    if not output.is_relative_to(build) or output == build:
        parser.error('output directory must be a new directory under build/')
    acceptance.require_device(args.device, allow_recovery=False)
    output.mkdir(parents=True, exist_ok=False)
    run_id = uuid.uuid4().hex
    acceptance.ENV['SITE_LENS_VISUAL_RUN_ID'] = run_id
    from prepare_android_acceptance import prepare
    bundle = output / 'apks'
    prepare(bundle, TARGET, 'android-arm64')
    acceptance.require_device(args.device, allow_recovery=False)
    command = [sys.executable, '-u', 'tool/run_android_acceptance.py', args.device,
               '--single-suite', '--skip-check', '--no-adb-recovery', '--integration-target', TARGET,
               '--prebuilt-product-apk', str(bundle / 'product-debug.apk'),
               '--prebuilt-test-apk', str(bundle / 'integration-debug.apk'),
               '--prebuilt-manifest', str(bundle / acceptance.PREBUILT_MANIFEST)]
    with (output / 'acceptance.log').open('w') as log:
        process = subprocess.Popen(command, cwd=acceptance.ROOT, env=acceptance.ENV,
                                   stdout=log, stderr=subprocess.STDOUT)
        records = observe_with_restore(process, args.device, output, run_id)
    (output / 'result.json').write_text(json.dumps({
        'schema': 1, 'runId': run_id, 'captureMethod': 'Android compositor',
        'captures': records, 'suiteAndRestorePassed': True,
        'pixelReview': 'pending',
        'fingerprint': acceptance.prebuilt_source_fingerprint(),
    }, indent=2) + '\n')
    print(f'VISUAL_ACCEPTANCE_PASS captures={len(records)} pixelReview=pending {output / "result.json"}')
    return 0


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f'VISUAL_ACCEPTANCE_FAIL: {error}', file=sys.stderr, flush=True)
        raise SystemExit(1)
