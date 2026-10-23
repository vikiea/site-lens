"""Visual capture ownership, run isolation and incomplete-flow regressions."""
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

import run_android_visual_acceptance as visual


class VisualTests(unittest.TestCase):
    run_id = 'a' * 32

    def request(self, index=0):
        return {'runId': self.run_id, 'id': f'{self.run_id}_{index}', 'name': visual.PHASES[index]}

    def test_exact_matrix_requires_all_eighteen_ordered_unique_checkpoints(self):
        self.assertEqual(len(visual.PHASES), 18)
        self.assertEqual(len(set(visual.PHASES)), 18)
        for index in range(18):
            raw = json.dumps(self.request(index)).encode()
            self.assertEqual(visual.validate_request(raw, self.run_id, index), self.request(index))
        with self.assertRaises(RuntimeError):
            visual.validate_request(json.dumps(self.request(1)).encode(), self.run_id, 0)

    def test_stale_run_cannot_authorize_capture_and_bad_payload_is_refused(self):
        self.assertIsNone(visual.validate_request(json.dumps(self.request()).encode(), 'b' * 32, 0))
        for raw in (b'broken', b'[]', b'x' * 4097, json.dumps({**self.request(), 'name': '../private'}).encode()):
            with self.subTest(raw=raw[:30]), self.assertRaises(RuntimeError):
                visual.validate_request(raw, self.run_id, 0)

    def test_foreground_must_be_only_the_debug_fixture(self):
        for text in ('', 'topResumedActivity=example.other/.Main',
                     f'topResumedActivity={visual.acceptance.FORMAL_PACKAGE}/dev.vikiea.site_lens.MainActivity'):
            with patch.object(visual.acceptance, 'adb', return_value=Mock(stdout=text.encode())), \
                    self.assertRaises(RuntimeError):
                visual.assert_debug_foreground('device')
        text = f'topResumedActivity={visual.acceptance.PACKAGE}/dev.vikiea.site_lens.MainActivity'
        window = f'mCurrentFocus=Window{{u0 {visual.acceptance.PACKAGE}/dev.vikiea.site_lens.MainActivity}}'
        with patch.object(visual.acceptance, 'adb', side_effect=[Mock(stdout=text.encode()), Mock(stdout=window.encode())]):
            visual.assert_debug_foreground('device')
        with patch.object(visual.acceptance, 'adb', side_effect=[Mock(stdout=text.encode()), Mock(stdout=b'mCurrentFocus=Window{u0 com.android.systemui/.StatusBar}')]), \
                self.assertRaisesRegex(RuntimeError, 'window to have focus'):
            visual.assert_debug_foreground('device')

    def test_window_focus_uses_full_dump_and_rejects_missing_or_ambiguous_owners(self):
        activity = f'topResumedActivity={visual.acceptance.PACKAGE}/dev.vikiea.site_lens.MainActivity'
        focus = f'mCurrentFocus=Window{{u0 {visual.acceptance.PACKAGE}/dev.vikiea.site_lens.MainActivity}}'
        for window in (focus, '', 'mCurrentFocus=null', f'{focus}\n{focus}',
                       focus.replace(visual.acceptance.PACKAGE, f'other.{visual.acceptance.PACKAGE}')):
            with self.subTest(window=window), patch.object(
                visual.acceptance, 'adb',
                side_effect=[Mock(stdout=activity.encode()), Mock(stdout=window.encode())],
            ) as adb:
                if window == focus:
                    visual.assert_debug_foreground('device')
                else:
                    with self.assertRaisesRegex(RuntimeError, 'window to have focus'):
                        visual.assert_debug_foreground('device')
                self.assertEqual(adb.call_args.args, ('device', 'shell', 'dumpsys', 'window'))

    def test_capture_writes_png_before_ack_and_rechecks_foreground(self):
        png = b'\x89PNG\r\n\x1a\n' + b'\0\0\0\x0dIHDR' + struct.pack('>II', 360, 640) + b'\0' * 20
        with tempfile.TemporaryDirectory() as root, \
                patch.object(visual, 'assert_debug_foreground') as foreground, \
                patch.object(visual, 'read_request', return_value=json.dumps(self.request()).encode()) as live_request, \
                patch.object(visual.acceptance, 'adb', return_value=Mock(stdout=png)), \
                patch.object(visual.acceptance, 'write_device_file') as ack:
            record = visual.capture('device', Path(root), self.request())
            self.assertEqual((Path(root) / record['file']).read_bytes(), png)
            self.assertEqual((record['width'], record['height']), (360, 640))
            self.assertEqual(foreground.call_count, 2)
            self.assertEqual(live_request.call_count, 2)
            ack.assert_called_once()
            self.assertEqual(ack.call_args.args[1], visual.ACK)
            self.assertEqual(ack.call_args.args[2].read_text(), self.request()['id'])

    def test_invalid_pixels_never_acknowledge(self):
        for image in (b'', b'not a PNG', b'\x89PNG\r\n\x1a\n' + b'\0' * 30):
            with tempfile.TemporaryDirectory() as root, \
                    patch.object(visual, 'assert_debug_foreground'), \
                    patch.object(visual, 'read_request', return_value=json.dumps(self.request()).encode()), \
                    patch.object(visual.acceptance, 'adb', return_value=Mock(stdout=image)), \
                    patch.object(visual.acceptance, 'write_device_file') as ack, \
                    self.assertRaises(RuntimeError):
                visual.capture('device', Path(root), self.request())
            ack.assert_not_called()

    def test_changed_foreground_or_expired_checkpoint_leaves_no_saved_image_or_ack(self):
        png = b'\x89PNG\r\n\x1a\n' + b'\0\0\0\x0dIHDR' + struct.pack('>II', 360, 640) + b'\0' * 20
        for expired in (False, True):
            with tempfile.TemporaryDirectory() as root:
                with patch.object(visual, 'assert_debug_foreground', side_effect=[None, None if expired else RuntimeError('switched owner')]), \
                        patch.object(visual, 'read_request', side_effect=[json.dumps(self.request()).encode(), None]), \
                        patch.object(visual.acceptance, 'adb', return_value=Mock(stdout=png)), \
                        patch.object(visual.acceptance, 'write_device_file') as ack, \
                        self.subTest(expired=expired), self.assertRaises(RuntimeError):
                    visual.capture('device', Path(root), self.request())
                self.assertEqual(list(Path(root).glob('*.png')), [])
                ack.assert_not_called()

    def test_expired_post_capture_request_discards_pixels_before_publication(self):
        png = b'\x89PNG\r\n\x1a\n' + b'\0\0\0\x0dIHDR' + struct.pack('>II', 360, 640) + b'\0' * 20
        with tempfile.TemporaryDirectory() as root:
            with patch.object(visual, 'assert_debug_foreground'), \
                    patch.object(visual, 'read_request', side_effect=[json.dumps(self.request()).encode(), None]), \
                    patch.object(visual.acceptance, 'adb', return_value=Mock(stdout=png)), \
                    patch.object(visual.acceptance, 'write_device_file') as ack, \
                    self.assertRaisesRegex(RuntimeError, 'checkpoint expired'):
                visual.capture('device', Path(root), self.request())
            self.assertEqual(list(Path(root).glob('*.png')), [])
            ack.assert_not_called()

    def test_observer_failure_waits_for_canonical_exit_and_preserves_original_error(self):
        process = Mock()
        process.poll.side_effect = [None, None, 0]
        with tempfile.TemporaryDirectory() as root, \
                patch.object(visual, 'observe', side_effect=RuntimeError('original capture failure')), \
                patch.object(visual.time, 'sleep') as sleep, \
                self.assertRaisesRegex(RuntimeError, 'original capture failure'):
            visual.observe_with_restore(process, 'device', Path(root), self.run_id)
        self.assertEqual(sleep.call_count, 2)
        process.terminate.assert_not_called()
        process.kill.assert_not_called()

    def test_absent_or_installing_fixture_is_not_malformed_json(self):
        for response in (Mock(returncode=1, stdout=b'run-as denied'),
                         Mock(returncode=0, stdout=b''),
                         Mock(returncode=0, stdout=visual.NO_REQUEST)):
            with patch.object(visual.acceptance, 'adb', return_value=response) as adb:
                self.assertIsNone(visual.read_request('device'))
                self.assertEqual(adb.call_args.args[1], 'shell')

    def test_successful_process_without_complete_matrix_is_failure(self):
        process = Mock(returncode=0)
        process.poll.return_value = 0
        process.wait.return_value = 0
        with tempfile.TemporaryDirectory() as root, self.assertRaisesRegex(RuntimeError, 'captures=0/18'):
            visual.observe(process, 'device', Path(root), self.run_id)

    def test_visual_nonce_is_test_only_and_malformed_values_fail_closed(self):
        with patch.dict(visual.acceptance.ENV, {'SITE_LENS_VISUAL_RUN_ID': self.run_id}, clear=True), \
                patch.object(visual.acceptance, 'adb', return_value=subprocess.CompletedProcess([], 0, b'arm64-v8a')):
            self.assertIn(f'--dart-define=SITE_LENS_VISUAL_RUN_ID={self.run_id}', visual.acceptance.test_defines())
            self.assertFalse(any('VISUAL_RUN' in part for part in visual.acceptance.normal_debug_build('device')))
        for value in ('../private', 'x' * 32, 'a' * 31):
            with patch.dict(visual.acceptance.ENV, {'SITE_LENS_VISUAL_RUN_ID': value}, clear=True), self.assertRaises(ValueError):
                visual.acceptance.test_defines()

    def test_visual_target_is_accepted_by_both_prepare_and_real_cli_parser(self):
        self.assertIn(visual.TARGET, visual.acceptance.INTEGRATION_TARGETS)
        with patch.object(sys, 'argv', ['runner', 'device', '--single-suite',
                                      '--integration-target', visual.TARGET]), \
                patch.object(visual.acceptance, 'require_device', side_effect=RuntimeError('preflight reached')), \
                patch.object(visual.acceptance, 'run_flutter') as build, \
                self.assertRaisesRegex(RuntimeError, 'preflight reached'):
            visual.acceptance.main()
        build.assert_not_called()


if __name__ == '__main__':
    unittest.main()
