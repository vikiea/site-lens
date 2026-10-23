"""Send acceptance controls to the debug app's own MediaSession/notification."""
from __future__ import annotations

import re
import subprocess
import threading
import time
import xml.etree.ElementTree as ET


class MediaActionDriver:
    def __init__(self, adb: str, device: str, package: str):
        self.adb, self.device, self.package = adb, device, package
        self.stop_event = threading.Event()
        self.errors: list[str] = []
        self.handled: set[str] = set()
        self.thread = threading.Thread(target=self._run, daemon=True)

    def command(self, *args: str, input: bytes | None = None) -> bytes:
        result = subprocess.run(
            [self.adb, '-s', self.device, *args],
            input=input,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=15,
        )
        if result.returncode:
            raise RuntimeError(result.stdout.decode(errors='replace'))
        return result.stdout

    def start(self):
        self.thread.start()

    def finish(self):
        self.stop_event.set()
        self.thread.join(timeout=20)
        if self.thread.is_alive():
            raise RuntimeError('Media acceptance driver did not shut down')
        if self.errors:
            raise RuntimeError('; '.join(self.errors))

    def _run(self):
        while not self.stop_event.wait(0.5):
            try:
                phase = self.command(
                    'exec-out',
                    'run-as',
                    self.package,
                    'cat',
                    'files/media_acceptance_phase',
                ).decode().strip()
            except (RuntimeError, subprocess.TimeoutExpired):
                continue  # Fixture has not started, or runner is reinstalling.
            if phase not in {'pause', 'resume', 'stop', 'next', 'previous'} or phase in self.handled:
                continue
            try:
                sessions = self.command(
                    'shell', 'cmd', 'media_session', 'list-sessions'
                ).decode()
                expected = f'tag=site-lens-browser:{self.package}, package={self.package}'
                own_sessions = [
                    row for row in sessions.splitlines() if row.strip() == expected
                ]
                if not own_sessions:
                    continue  # Wait for the foreground service's session registration.
                if len(own_sessions) != 1:
                    raise RuntimeError('Ambiguous debug media session')
                print(f'MEDIA_DRIVER {phase} own session: {sessions.strip()}', flush=True)
                if phase == 'stop':
                    self._stop_media()
                else:
                    self._send_session_action('play' if phase == 'resume' else phase)
                self.handled.add(phase)
            except Exception as exc:
                self.errors.append(f'{phase}: {exc}')
                print(f'MEDIA_DRIVER {phase} failed: {exc}', flush=True)
                self.handled.add(phase)

    def _send_session_action(self, action: str):
        output = self.command(
            'shell',
            'cmd',
            'media_session',
            'monitor',
            f'site-lens-browser:{self.package}',
            input=f'{action}\nq\n'.encode(),
        )
        if b'No session' in output:
            raise RuntimeError('Target media session disappeared')
        if b'Invalid command' in output or b'Unknown command' in output:
            raise RuntimeError(
                f'MediaSession monitor rejected {action}: '
                f'{output.decode(errors="replace").strip()}'
            )
        print(output.decode(errors='replace'), flush=True)

    def _stop_media(self):
        try:
            self._send_session_action('stop')
            return
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            print(f'MEDIA_DRIVER session stop unavailable: {exc}', flush=True)
        try:
            self._send_global_media_action('stop')
            return
        except (RuntimeError, subprocess.TimeoutExpired) as exc:
            print(f'MEDIA_DRIVER global stop unavailable: {exc}', flush=True)
        self._stop_notification()

    def _send_global_media_action(self, action: str):
        # Global dispatch cannot select a tag. Re-read the full session inventory
        # immediately before sending it; any second or unknown row refuses it.
        sessions = self.command(
            'shell', 'cmd', 'media_session', 'list-sessions'
        ).decode()
        expected = f'tag=site-lens-browser:{self.package}, package={self.package}'
        rows = [
            row.strip() for row in sessions.splitlines()
            if row.strip() and row.strip() != 'Sessions:'
        ]
        if rows != [expected]:
            raise RuntimeError('Global stop requires the debug fixture as the only session')
        output = self.command('shell', 'cmd', 'media_session', 'dispatch', action)
        if b'invalid' in output.lower() or b'unknown' in output.lower():
            raise RuntimeError(
                f'MediaSession dispatch rejected {action}: '
                f'{output.decode(errors="replace").strip()}'
            )
        print(f'MEDIA_DRIVER dispatched global media action {action}', flush=True)

    def _notification_rows(self, root: ET.Element) -> list[ET.Element]:
        candidates = [
            node for node in root.iter('node')
            if node.get('resource-id', '').endswith(
                ('/expandableNotificationRow', '/qs_media_controls', '/mi_media_controls')
            )
        ]
        # Some OEMs nest the media card in an ordinary row. Keep the inner card
        # once, and still consider media cards when other ordinary rows exist.
        return [
            row for row in candidates
            if not any(child in candidates for child in row.iter('node') if child is not row)
        ]

    def _verify_notification_owner(self):
        # SystemUI nodes all belong to SystemUI, so a title alone cannot prove
        # application ownership. Match the live notification records first.
        dump = self.command('shell', 'dumpsys', 'notification', '--noredact').decode()
        records = re.split(r'(?m)^\s*(?=NotificationRecord\()', dump)
        owners = []
        for record in records:
            if not record.startswith('NotificationRecord('):
                continue
            header = record.splitlines()[0]
            owner = re.search(r'\bpkg=([^\s,)]+)', header)
            if owner and re.search(
                r'android\.title=.*Site Lens debug media acceptance', record
            ):
                owners.append(owner.group(1))
        if owners != [self.package]:
            raise RuntimeError(
                'Cannot verify unique debug fixture notification ownership; '
                f'matching records={len(owners)}, debug records={owners.count(self.package)}'
            )

    def _stop_notification(self):
        self._verify_notification_owner()
        self.command('shell', 'cmd', 'statusbar', 'expand-notifications')
        try:
            time.sleep(0.8)
            self.command(
                'shell',
                'uiautomator',
                'dump',
                '/data/local/tmp/site-lens-media-notification.xml',
            )
            xml = self.command(
                'exec-out', 'cat', '/data/local/tmp/site-lens-media-notification.xml'
            )
            root = ET.fromstring(xml)
            rows = self._notification_rows(root)

            def texts(row):
                return {
                    value
                    for node in row.iter('node')
                    for value in (node.get('text'), node.get('content-desc'))
                    if value
                }

            own_rows = [
                row
                for row in rows
                if 'Site Lens debug media acceptance' in texts(row)
            ]
            if len(own_rows) != 1:
                raise RuntimeError(
                    'Expected exactly one debug media notification; '
                    f'found {len(own_rows)} among {len(rows)} notification rows'
                )
            actions = [
                node
                for node in own_rows[0].iter('node')
                if node.get('package') == 'com.android.systemui'
                and (node.get('content-desc') == '停止' or node.get('text') == '停止')
            ]
            if len(actions) != 1:
                raise RuntimeError(
                    f'Expected exactly one debug notification stop action; found {len(actions)}'
                )
            bounds = re.fullmatch(
                r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',
                actions[0].get('bounds', ''),
            )
            if bounds is None:
                raise RuntimeError('Invalid stop action bounds')
            x1, y1, x2, y2 = map(int, bounds.groups())
            self.command(
                'shell', 'input', 'tap', str((x1 + x2) // 2), str((y1 + y2) // 2)
            )
            # input tap returning only acknowledges input injection. Keep the
            # shade in place until the app's own session has actually stopped;
            # collapsing immediately can race delivery on OEM media controls.
            self._await_stopped_session()
            print('MEDIA_DRIVER system notification stop confirmed', flush=True)
        finally:
            self.command('shell', 'cmd', 'statusbar', 'collapse')

    def _await_stopped_session(self):
        deadline = time.monotonic() + 6
        expected = f'tag=site-lens-browser:{self.package}, package={self.package}'
        while time.monotonic() < deadline:
            sessions = self.command(
                'shell', 'cmd', 'media_session', 'list-sessions'
            ).decode()
            rows = [row.strip() for row in sessions.splitlines() if row.strip()]
            if (not rows or rows[0] != 'Sessions:' or any(
                    re.fullmatch(r'tag=.+, package=[A-Za-z0-9_.]+', row) is None
                    for row in rows[1:])):
                raise RuntimeError('Cannot verify media session inventory after notification stop')
            own = [row for row in rows[1:] if row == expected]
            if len(own) > 1:
                raise RuntimeError('Ambiguous debug media session after notification stop')
            if not own:
                return
            time.sleep(0.2)
        raise RuntimeError('Notification stop was injected but the debug media session remained active')
