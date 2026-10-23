#!/usr/bin/env python3
"""Read fixed, non-personal startup timing events from the running debug app.

Does not install, launch, stop, reconnect or change application/device data.
Use the protected acceptance runner to deploy a traced normal product first.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import time

import run_android_acceptance as acceptance


PREFIX = 'SITE_LENS_STARTUP '
enum_source = (acceptance.ROOT / 'lib/diagnostics/startup_trace.dart').read_text()
PHASES = set(re.findall(r'^\s*(\w+),\s*$', enum_source.split('enum StartupPhase {', 1)[1].split('}', 1)[0], re.M))


def is_app_entry(entry) -> bool:
    return (isinstance(entry, dict) and set(entry) == {'phase', 'kind', 'elapsedUs'}
            and entry['phase'] == 'appEntry' and entry['kind'] == 'mark'
            and type(entry['elapsedUs']) is int and entry['elapsedUs'] >= 0)


def parse_events(output: str) -> list[dict]:
    events = []
    payloads = [line.split(PREFIX, 1)[1] for line in output.splitlines() if PREFIX in line]
    start = 0
    # Separate launches before validating their schema. A stale record from an
    # older instrumented binary cannot invalidate a later complete launch.
    for index, payload in enumerate(payloads):
        try:
            entry = json.loads(payload)
        except ValueError:
            continue
        if is_app_entry(entry):
            start = index
    for payload in payloads[start:]:
        try:
            event = json.loads(payload)
        except ValueError as error:
            raise ValueError('malformed startup timing record') from error
        if (not isinstance(event, dict) or type(event.get('phase')) is not str
                or event['phase'] not in PHASES):
            raise ValueError('unknown startup timing phase')
        if event['phase'] == 'appEntry' and not is_app_entry(event):
            raise ValueError('invalid startup boundary')
        kind = event.get('kind')
        if type(kind) is not str:
            raise ValueError('invalid startup timing kind')
        keys = {
            'mark': {'phase', 'kind', 'elapsedUs', 'itemCount'},
            'span': {'phase', 'kind', 'startUs', 'elapsedUs', 'durationUs', 'succeeded'},
            'frameTiming': {'phase', 'kind', 'reportedAtUs', 'buildUs', 'rasterUs', 'totalUs'},
        }.get(kind)
        if keys is None or set(event) - keys:
            raise ValueError('unexpected startup timing fields')
        required = keys - ({'itemCount'} if kind == 'mark' else set())
        if not required.issubset(event):
            raise ValueError('incomplete startup timing record')
        for key, value in event.items():
            if key in ('phase', 'kind', 'succeeded'):
                continue
            if type(value) is not int or value < 0:
                raise ValueError('invalid numeric startup timing field')
        if kind == 'span' and (type(event['succeeded']) is not bool or
                               event['elapsedUs'] - event['startUs'] != event['durationUs']):
            raise ValueError('invalid startup span')
        events.append(event)
    return events


def observation_complete(events: list[dict]) -> bool:
    marks = {row['phase']: row for row in events if row['kind'] == 'mark'}
    needed = {'appEntry', 'firstFrameworkFrame', 'persistentStateReady',
              'savedTabsReady', 'homeMetadataFrameworkFrame', 'controllerReady'}
    if not needed.issubset(marks):
        return False
    if 'itemCount' not in marks['savedTabsReady']:
        return False  # Unknown tab count must not be inferred as zero.
    if not any(row['phase'] == 'firstRasterFrame' and row['kind'] == 'frameTiming' for row in events):
        return False
    if marks['savedTabsReady'].get('itemCount', 0) > 0:
        return 'resumeEntryFrameworkFrame' in marks
    return True


def summarize(events: list[dict]) -> dict:
    return {
        'milestonesMs': {row['phase']: row['elapsedUs'] / 1000 for row in events if row['kind'] == 'mark'},
        'counts': {row['phase']: row['itemCount'] for row in events if 'itemCount' in row},
        'spansByDurationMs': sorted([
            {'phase': row['phase'], 'durationMs': row['durationUs'] / 1000, 'succeeded': row['succeeded']}
            for row in events if row['kind'] == 'span'
        ], key=lambda row: row['durationMs'], reverse=True),
        'firstRaster': next((row for row in events if row['kind'] == 'frameTiming'), None),
    }


def read_pid(device: str) -> str:
    result = acceptance.adb(device, 'shell', 'pidof', '-s', acceptance.PACKAGE, check=False, timeout=8)
    pid = result.stdout.decode().strip()
    if result.returncode or not re.fullmatch(r'[1-9][0-9]*', pid):
        raise RuntimeError('normal debug app is not running; no app launch was attempted')
    return pid


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('device')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=20)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 60:
        parser.error('timeout must be between 1 and 60 seconds')
    output = args.output.resolve()
    if not output.is_relative_to((acceptance.ROOT / 'build').resolve()) or output.exists():
        parser.error('output must be a new file under build/')
    acceptance.require_device(args.device, allow_recovery=False)
    pid = read_pid(args.device)
    deadline = time.monotonic() + args.timeout
    events = []
    while time.monotonic() < deadline:
        raw = acceptance.adb(args.device, 'logcat', '-d', '--pid', pid, '-v', 'raw', '-s', 'flutter:I', timeout=8)
        events = parse_events(raw.stdout.decode(errors='replace'))
        if read_pid(args.device) != pid:
            raise RuntimeError('debug process restarted during timing capture')
        if observation_complete(events):
            result = {
                'schema': 1, 'buildMode': 'instrumented debug',
                'observationComplete': True, 'capturedAtMs': int(time.time() * 1000),
                'events': events, **summarize(events),
                'sourceFingerprint': acceptance.prebuilt_source_fingerprint(),
                'limitations': ['Excludes Android startup before Dart main.',
                                'Framework marks do not prove compositor presentation.',
                                'FrameTiming reportedAtUs is callback time, not raster completion.',
                                'Debug timings do not establish release/profile performance.'],
            }
            output.parent.mkdir(parents=True, exist_ok=True)
            with output.open('x') as stream:
                json.dump(result, stream, indent=2)
                stream.write('\n')
            print(json.dumps({'output': str(output), **summarize(events)}, indent=2))
            return 0
        time.sleep(0.25)
    raise RuntimeError('startup observation incomplete; no complete timing report written')


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        raise SystemExit(f'STARTUP_TRACE_FAIL: {error}')
