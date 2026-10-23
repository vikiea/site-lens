"""Proxy orchestration failure contracts; no real ADB or network calls."""
from __future__ import annotations

import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from android_proxy_lease import ExistingProxyError, LeaseResult
import run_android_proxy_acceptance as runner


class Child:
    def __init__(self, ready=True):
        self.stdout = io.StringIO('{"remote_dir":"/data/local/tmp/site-lens-proxy-owned"}\n')
        self.stderr = io.StringIO()
        self.ready = ready
        self.killed = False
        self.exited = False

    def kill(self):
        self.killed = True

    def wait(self, timeout=None):
        self.exited = True
        return -9

    def poll(self):
        return -9 if self.killed or self.exited else None


class RunnerContracts(unittest.TestCase):
    def test_existing_proxy_cannot_be_taken_over(self):
        lease = Mock()
        lease._read_snapshot.return_value = {"http_proxy": "user:7890"}
        lease._occupied_keys.return_value = ["http_proxy"]
        with patch.object(runner, "new_lease", return_value=lease):
            with self.assertRaises(ExistingProxyError):
                runner.clear_snapshot("device", 1234)
        lease.activate.assert_not_called()

    def test_active_proxy_must_forward_http_and_verified_https(self):
        with patch.object(runner, 'adb', side_effect=['204', '200']) as adb:
            runner.check_tunnel('device', 1234)
        self.assertEqual(adb.call_count, 2)
        self.assertTrue(any('http://' in str(call) for call in adb.call_args_list))
        self.assertTrue(any('https://' in str(call) for call in adb.call_args_list))
        self.assertNotIn('--insecure', str(adb.call_args_list))
        with patch.object(runner, 'adb', side_effect=['204', '502']):
            with self.assertRaisesRegex(RuntimeError, 'HTTPS'):
                runner.check_tunnel('device', 1234)

    def test_host_death_waits_for_all_fields_and_daemon_cleanup(self):
        child = Child()
        reader = Mock()
        reader._read_snapshot.side_effect = [{"active": True}, {"clear": True}]
        with patch.object(runner.subprocess, "Popen", return_value=child), \
                patch.object(runner.select, "select", return_value=([child.stdout], [], [])), \
                patch.object(runner, "new_lease", return_value=reader), \
                patch.object(runner, "adb", side_effect=["PRESENT", "ABSENT"]) as adb, \
                patch.object(runner.time, "sleep"):
            result = runner.verify_watchdog("device", 1234, {"clear": True})
        self.assertTrue(child.killed)
        self.assertTrue(result["hostTerminationRollback"])
        self.assertEqual(adb.call_count, 2)
        self.assertNotIn("kill-server", str(adb.call_args_list))

    def test_missing_child_activation_ack_is_failure_and_child_is_stopped(self):
        child = Child()
        with patch.object(runner.subprocess, "Popen", return_value=child), \
                patch.object(runner.select, "select", return_value=([], [], [])), \
                patch.object(runner, "adb") as adb:
            with self.assertRaisesRegex(RuntimeError, "acknowledge"):
                runner.verify_watchdog("device", 1234, {})
        self.assertIsNotNone(child.poll())
        adb.assert_not_called()

    def test_lease_child_releases_when_parent_lifetime_pipe_closes(self):
        read_fd, write_fd = os.pipe()
        lease = Mock(remote_dir="/data/local/tmp/owned")
        activated = threading.Event()
        lease.activate.side_effect = activated.set
        with patch.object(runner, "new_lease", return_value=lease), \
                patch("sys.stdout", new_callable=io.StringIO):
            thread = threading.Thread(target=runner.lease_child, args=("device", 1234, read_fd))
            thread.start()
            try:
                self.assertTrue(activated.wait(2))
            finally:
                os.close(write_fd)
                thread.join(timeout=3)
            self.assertFalse(thread.is_alive())
        lease.release.assert_called_once()

    def test_killing_parent_process_closes_lifeline_in_surviving_child(self):
        child_script = '''
import pathlib, signal, sys
from run_android_proxy_acceptance import wait_for_parent
signal.alarm(10)
root = pathlib.Path(sys.argv[2])
(root / "ready").write_text("ready")
try:
    wait_for_parent(int(sys.argv[1]))
finally:
    (root / "released").write_text("released")
'''
        parent_script = '''
import os, subprocess, sys, time
read_fd, write_fd = os.pipe()
subprocess.Popen([sys.executable, "-c", sys.argv[1], str(read_fd), sys.argv[2]],
                 pass_fds=(read_fd,), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
os.close(read_fd)
time.sleep(30)
'''
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            parent = subprocess.Popen([sys.executable, "-c", parent_script, child_script, raw],
                                      cwd=Path(runner.__file__).parent)
            try:
                deadline = time.monotonic() + 5
                while not (root / "ready").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "ready").exists())
                parent.kill()
                parent.wait(timeout=3)
                deadline = time.monotonic() + 3
                while not (root / "released").exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue((root / "released").exists(), "orphan child retained the lifeline")
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait(timeout=3)

    def test_owned_proxy_keeps_relay_live_after_timeout_until_restored(self):
        reader = Mock()
        reader._read_snapshot.side_effect = [{"active": True}, {"clear": True}]
        reader._is_owned.return_value = True
        with patch.object(runner, "new_lease", return_value=reader), \
                patch.object(runner.time, "monotonic", side_effect=[0, 5, 5]), \
                patch.object(runner.time, "sleep"), \
                patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertTrue(runner.restored_or_external("device", 1234, {"clear": True}, timeout=2))
        self.assertIn("relay retained", output.getvalue())

    def test_user_proxy_change_is_preserved(self):
        reader = Mock()
        reader._read_snapshot.return_value = {"userProxy": "new"}
        reader._is_owned.return_value = False
        with patch.object(runner, "new_lease", return_value=reader):
            self.assertFalse(runner.restored_or_external("device", 1234, {"clear": True}))
        reader.release.assert_not_called()

    def test_failed_proxy_queries_keep_relay_until_restoration_can_be_verified(self):
        reader = Mock()
        reader._read_snapshot.side_effect = [
            subprocess.CalledProcessError(1, ['adb'], stderr=b'offline'),
            RuntimeError('unclean settings reply'),
            {"clear": True},
        ]
        with patch.object(runner, "new_lease", return_value=reader), \
                patch.object(runner.time, "sleep") as sleep, \
                patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertTrue(runner.restored_or_external("device", 1234, {"clear": True}))
        self.assertEqual(reader._read_snapshot.call_count, 3)
        self.assertEqual(sleep.call_count, 2)
        self.assertIn('relay retained', output.getvalue())

    def run_contract(self, *, marker, code=0, restored=True):
        with tempfile.TemporaryDirectory() as raw:
            output = Path(raw)
            fixture = Mock(port=1234)
            lease = Mock()
            lease.release.return_value = LeaseResult(
                "restored" if restored else "unverified", restored=restored,
                watchdog_retained=not restored)
            child = Mock()
            child.wait.return_value = code
            polls = 0

            def poll():
                nonlocal polls
                polls += 1
                if polls == 1:
                    (output / "acceptance.log").write_text(
                        '\n'.join((runner.MARKER, runner.NATIVE_MARKER, runner.HTTPS_MARKER, runner.HTTPS_HLS_MARKER,
                                   *runner.HTTPS_PHASE_MARKERS))
                        if marker else "NO CONTRACT\n"
                    )
                    return None
                return code

            child.poll.side_effect = poll
            with patch.object(runner, "new_lease", return_value=lease), \
                    patch.object(runner.subprocess, "Popen", return_value=child), \
                    patch.object(runner.time, "sleep"):
                return runner.run_suite("device", output / "apks", output, fixture)

    def test_exit_zero_without_executed_contract_is_not_pass(self):
        with self.assertRaisesRegex(RuntimeError, "contract=False"):
            self.run_contract(marker=False)

    def test_proxy_release_requires_http_hls_native_and_all_https_app_receipts(self):
        markers = (runner.MARKER, runner.NATIVE_MARKER, runner.HTTPS_MARKER, runner.HTTPS_HLS_MARKER, *runner.HTTPS_PHASE_MARKERS)
        for missing in markers:
            with self.subTest(missing=missing):
                self.assertFalse(runner.contract_complete('\n'.join(x for x in markers if x != missing)))
        self.assertTrue(runner.contract_complete('\n'.join(markers)))

    def test_download_receipts_need_independent_proxy_connection_and_resource_evidence(self):
        hits = ['/redirect', '/landing', '/contract.m3u8', '/segment.ts', '/direct.mp4']
        checkpoints = [
            {'phase': phase, 'edge': edge, 'connects': 1,
             'sentBytes': i * 100 + j * 50, 'receivedBytes': i * 1000 + j * 500}
            for i, phase in enumerate(runner.HTTPS_PHASES)
            for j, edge in enumerate(('before', 'after'))
        ]
        fixture = Mock(hits=hits, https_fixture_connect=0, https_checkpoints=checkpoints)
        with self.assertRaisesRegex(RuntimeError, 'HTTPS fixture CONNECT'):
            runner.verify_fixture_contract(fixture)
        with self.assertRaisesRegex(RuntimeError, 'request log incomplete'):
            runner.verify_fixture_contract(Mock(hits=hits[:-1], https_fixture_connect=1, https_checkpoints=checkpoints))
        for records in (checkpoints[:-1], list(reversed(checkpoints))):
            with self.assertRaisesRegex(RuntimeError, 'phase checkpoints incomplete'):
                runner.verify_fixture_contract(Mock(hits=hits, https_fixture_connect=1, https_checkpoints=records))
        for index, phase in enumerate(runner.HTTPS_PHASES):
            for key in ('sentBytes', 'receivedBytes'):
                stale = [dict(row) for row in checkpoints]
                stale[2 * index + 1][key] = stale[2 * index][key]
                with self.subTest(phase=phase, key=key), self.assertRaisesRegex(RuntimeError, f'{phase} has no bidirectional'):
                    runner.verify_fixture_contract(Mock(hits=hits, https_fixture_connect=1, https_checkpoints=stale))
        # All stages may legitimately share a single persistent tunnel.
        evidence = runner.verify_fixture_contract(Mock(hits=hits, https_fixture_connect=1, https_checkpoints=checkpoints))
        self.assertEqual(evidence, {
            'probe': True, 'dartFetch': True, 'nativeTlsTransfer': True,
            'nativeWorker': True, 'fixtureConnects': 1, 'bytes': 1878,
            'phaseTraffic': {phase: {'sentBytes': 50, 'receivedBytes': 500} for phase in runner.HTTPS_PHASES},
            'hls': {'segments': 2, 'initSegments': 1, 'keys': 0, 'resourcesSha256': True,
                    'upstreamBytes': 427536},
        })

    def test_executed_contract_does_not_hide_suite_failure(self):
        with self.assertRaisesRegex(RuntimeError, "exit=1"):
            self.run_contract(marker=True, code=1)

    def test_restore_failure_can_never_return_pass(self):
        with self.assertRaisesRegex(RuntimeError, "restoration not verified"):
            self.run_contract(marker=True, restored=False)

    def test_pass_requires_contract_suite_and_restoration(self):
        self.assertEqual(self.run_contract(marker=True),
                         {"proxyContract": True, "acceptance": True, "allFieldsRestored": True})


if __name__ == "__main__":
    unittest.main()
