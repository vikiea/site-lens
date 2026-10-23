"""Restore must reject another phone or incomplete bytes before changing it."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import run_android_acceptance as acceptance


SOURCE = {'serial_sha256': 'a' * 64, 'android_id_sha256': 'b' * 64}
OTHER = {'serial_sha256': 'c' * 64, 'android_id_sha256': 'b' * 64}


class BackupIdentityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        (self.directory / 'product-debug.apk').write_bytes(b'normal product')
        payload = b'user database'
        (self.directory / 'site_lens.sqlite').write_bytes(payload)
        self.backup = {'site_lens.sqlite': hashlib.sha256(payload).hexdigest()}

    def complete(self):
        with patch.object(acceptance, 'read_device_identity', return_value=SOURCE):
            acceptance.write_backup_manifest('old-host:port', self.directory, self.backup, SOURCE)

    def test_serial_fallback_and_user_zero_are_used_without_retaining_raw_ids(self):
        calls = []

        def reply(device, *args):
            calls.append(args)
            value = {
                ('shell', 'getprop', 'ro.serialno'): b'unknown',
                ('shell', 'getprop', 'ro.boot.serialno'): b'physical-serial',
                ('shell', 'settings', '--user', '0', 'get', 'secure', 'android_id'): b'1234567890abcdef',
            }[args]
            return subprocess.CompletedProcess([], 0, value)

        with patch.object(acceptance, 'adb', side_effect=reply):
            actual = acceptance.read_device_identity('new-endpoint')
        self.assertEqual(actual['serial_sha256'], hashlib.sha256(b'physical-serial').hexdigest())
        self.assertEqual(actual['android_id_sha256'], hashlib.sha256(b'1234567890abcdef').hexdigest())
        self.assertNotIn('physical-serial', json.dumps(actual))
        self.assertIn(('shell', 'settings', '--user', '0', 'get', 'secure', 'android_id'), calls)

    def test_empty_unknown_or_failed_identity_is_not_a_model_or_endpoint_match(self):
        for serial, android_id in ((b'', b'1234567890abcdef'), (b'unknown', b'1234567890abcdef'),
                                   (b'serial', b'null'), (b'serial', b'0000000000000000')):
            def reply(device, *args):
                value = serial if 'getprop' in args else android_id
                return subprocess.CompletedProcess([], 0, value)
            with self.subTest(serial=serial, android_id=android_id), \
                    patch.object(acceptance, 'adb', side_effect=reply), \
                    self.assertRaises(RuntimeError):
                acceptance.read_device_identity('device')
        with patch.object(acceptance, 'adb', side_effect=subprocess.TimeoutExpired('adb', 30)), \
                self.assertRaises(subprocess.TimeoutExpired):
            acceptance.read_device_identity('device')

    def test_complete_backup_accepts_a_new_endpoint_and_ota_with_same_identity(self):
        self.complete()
        # No endpoint/model/API/build version is an identity key.
        with patch.object(acceptance, 'read_device_identity', return_value=SOURCE):
            manifest = acceptance.verify_backup_target('new-host:new-port', self.directory, self.backup)
        self.assertTrue(manifest['complete'])
        self.assertEqual(manifest['user'], 0)

    def test_identity_change_during_backup_does_not_publish_completion(self):
        with patch.object(acceptance, 'read_device_identity', return_value=OTHER), \
                self.assertRaisesRegex(RuntimeError, 'changed during backup'):
            acceptance.write_backup_manifest('device', self.directory, self.backup, SOURCE)
        self.assertFalse((self.directory / acceptance.BACKUP_MANIFEST).exists())

    def test_cross_device_restore_is_rejected_before_force_stop_install_or_write(self):
        self.complete()
        with patch.object(acceptance, 'read_device_identity', return_value=OTHER), \
                patch.object(acceptance, 'adb') as adb, \
                patch.object(acceptance, 'install') as install, \
                patch.object(acceptance, 'write_device_file') as write, \
                self.assertRaisesRegex(RuntimeError, 'another device'):
            acceptance.restore_and_launch_debug('device', self.directory, self.backup, [])
        adb.assert_not_called()
        install.assert_not_called()
        write.assert_not_called()

    def test_rebound_endpoint_after_install_cannot_enter_database_mutation(self):
        self.complete()
        with patch.object(acceptance, 'read_device_identity', side_effect=[SOURCE, OTHER]), \
                patch.object(acceptance, 'verify_apk_package'), \
                patch.object(acceptance, 'install') as install, \
                patch.object(acceptance, 'adb') as adb, \
                patch.object(acceptance, 'write_device_file') as write, \
                self.assertRaisesRegex(RuntimeError, 'another device'):
            acceptance.restore_and_launch_debug('device', self.directory, self.backup, [])
        install.assert_called_once()
        write.assert_not_called()
        self.assertEqual(adb.call_count, 1)  # Only the first, verified force-stop.

    def test_direct_database_restore_also_enforces_source_identity(self):
        self.complete()
        with patch.object(acceptance, 'read_device_identity', return_value=OTHER), \
                patch.object(acceptance, 'adb') as adb, \
                self.assertRaisesRegex(RuntimeError, 'another device'):
            acceptance.restore_database('device', self.directory, self.backup)
        adb.assert_not_called()

    def test_restore_only_rejects_legacy_or_partial_metadata_without_device_mutation(self):
        for value in (None, 'broken', '{}', '{"schema":1,"complete":false}'):
            manifest = self.directory / acceptance.BACKUP_MANIFEST
            manifest.unlink(missing_ok=True)
            if value is not None:
                manifest.write_text(value)
            with self.subTest(value=value), patch.object(acceptance, 'adb') as adb, \
                    patch.object(acceptance, 'install') as install:
                self.assertEqual(acceptance.restore_only('device', self.directory), 1)
            adb.assert_not_called()
            install.assert_not_called()
        self.assertEqual((self.directory / 'site_lens.sqlite').read_bytes(), b'user database')

    def test_tampered_bytes_missing_wal_wrong_package_and_incomplete_manifest_are_rejected(self):
        self.complete()
        manifest_path = self.directory / acceptance.BACKUP_MANIFEST
        original = json.loads(manifest_path.read_text())
        for field, value in (('complete', False), ('package', acceptance.FORMAL_PACKAGE), ('user', 10),
                             ('identity', OTHER), ('files', {})):
            manifest_path.write_text(json.dumps({**original, field: value}))
            with self.subTest(field=field), \
                    patch.object(acceptance, 'read_device_identity', return_value=SOURCE), \
                    patch.object(acceptance, 'adb') as adb, \
                    self.assertRaises(RuntimeError):
                acceptance.restore_database('device', self.directory, self.backup)
            adb.assert_not_called()
        manifest_path.write_text(json.dumps(original))
        for name in ('site_lens.sqlite', 'product-debug.apk'):
            source = self.directory / name
            payload = source.read_bytes()
            source.write_bytes(b'tampered')
            with self.subTest(name=name), self.assertRaises(RuntimeError):
                acceptance.load_backup_manifest(self.directory)
            source.write_bytes(payload)
        (self.directory / 'site_lens.sqlite-wal').write_bytes(b'unrecorded WAL')
        with self.assertRaises(RuntimeError):
            acceptance.load_backup_manifest(self.directory)

    def test_finally_captured_identity_cannot_be_replaced_by_new_manifest(self):
        self.complete()
        with patch.object(acceptance, 'read_device_identity', return_value=SOURCE), \
                self.assertRaisesRegex(RuntimeError, 'captured identity'):
            acceptance.verify_backup_target('device', self.directory, self.backup, expected_identity=OTHER)

    def test_runner_retains_original_test_failure_if_finally_detects_another_phone(self):
        product = self.directory / 'input-product.apk'
        product.write_bytes(b'normal product')
        with patch.object(acceptance, 'require_device'), \
                patch.object(acceptance, 'run_flutter'), \
                patch.object(acceptance, 'verify_apk_package'), \
                patch.object(acceptance, 'DEBUG_APK', product), \
                patch.object(acceptance.tempfile, 'mkdtemp', return_value=str(self.directory)), \
                patch.object(acceptance, 'ensure_debug_install', return_value=False), \
                patch.object(acceptance, 'read_device_identity', side_effect=[SOURCE, SOURCE, OTHER]), \
                patch.object(acceptance, 'backup_database', return_value=self.backup), \
                patch.object(acceptance, 'run_single_suite_with_media_driver', side_effect=RuntimeError('test failure')), \
                patch.object(acceptance, 'adb') as adb, \
                patch.object(acceptance, 'install') as install, \
                patch.object(acceptance, 'write_device_file') as write, \
                patch.object(sys, 'argv', ['runner', 'device', '--single-suite', '--skip-check', '--skip-build']), \
                patch('sys.stderr', new_callable=io.StringIO) as stderr:
            self.assertEqual(acceptance.main(), 1)
        self.assertIn('Android acceptance FAIL: test failure', stderr.getvalue())
        self.assertIn('database restore failed: backup belongs to another device', stderr.getvalue())
        self.assertEqual(adb.call_count, 3)  # ABI read, initial stops; no restore mutations.
        install.assert_not_called()
        write.assert_not_called()
        self.assertTrue((self.directory / acceptance.BACKUP_MANIFEST).is_file())

    def test_missing_product_can_rebuild_after_source_validation_and_rechecks_before_writing(self):
        self.complete()
        (self.directory / 'product-debug.apk').unlink()
        rebuilt = self.directory / 'rebuilt.apk'

        def build(command, timeout):
            self.assertIn('--target=lib/main.dart', command)
            rebuilt.write_bytes(b'rebuilt normal product')

        with patch.object(acceptance, 'read_device_identity', return_value=SOURCE) as identity, \
                patch.object(acceptance, 'DEBUG_APK', rebuilt), \
                patch.object(acceptance, 'run_flutter', side_effect=build) as run, \
                patch.object(acceptance, 'verify_apk_package'), \
                patch.object(acceptance, 'adb', return_value=subprocess.CompletedProcess([], 0, b'arm64-v8a')), \
                patch.object(acceptance, 'install') as install, \
                patch.object(acceptance, 'read_device_file', return_value=b'user database'), \
                patch.object(acceptance, 'write_device_file') as write:
            acceptance.restore_and_launch_debug('new-port', self.directory, self.backup, [], allow_rebuild=True)
        run.assert_called_once()
        install.assert_called_once_with('new-port', rebuilt, acceptance.PACKAGE)
        write.assert_called_once()
        self.assertEqual(identity.call_count, 2)

    def test_missing_prebuilt_product_refuses_before_any_device_mutation(self):
        self.complete()
        (self.directory / 'product-debug.apk').unlink()
        with patch.object(acceptance, 'read_device_identity', return_value=SOURCE), \
                patch.object(acceptance, 'adb') as adb, \
                patch.object(acceptance, 'install') as install, \
                patch.object(acceptance, 'run_flutter') as build, \
                self.assertRaisesRegex(RuntimeError, 'prebuilt product APK backup is missing'):
            acceptance.restore_and_launch_debug('device', self.directory, self.backup, [], allow_rebuild=False)
        adb.assert_not_called()
        install.assert_not_called()
        build.assert_not_called()


if __name__ == '__main__':
    unittest.main()
