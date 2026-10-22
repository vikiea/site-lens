"""Read-only regressions for package isolation in Android acceptance tooling."""
import hashlib
import io
import unittest
import subprocess
import sys
from pathlib import Path
from android_artifact import FORMAL_CERT_SHA256
import tempfile
from types import SimpleNamespace
import restore_android_database as standalone
from unittest.mock import patch
import run_android_acceptance as acceptance
from android_media_actions import MediaActionDriver

class AndroidToolsTests(unittest.TestCase):
    def _proof_bundle(self, directory, target=acceptance.DEFAULT_INTEGRATION_TARGET):
        root = Path(directory)
        product = root / 'product-debug.apk'
        test = root / 'integration-debug.apk'
        product.write_bytes(b'product-artifact')
        test.write_bytes(b'test-artifact')
        fingerprint = {'worktree': 'worktree-proof', 'source': 'source-proof'}
        platform = 'android-arm64'
        manifest = {
            'schema': 1,
            'producer': 'prepare_android_acceptance',
            'fingerprint': fingerprint,
            'target_platform': platform,
            'artifacts': {
                'product': {
                    'role': 'product',
                    'entrypoint': acceptance.PRODUCT_ENTRYPOINT,
                    'integration_target': None,
                    'file': product.name,
                    'sha256': acceptance.apk_sha256(product),
                    'command': acceptance.prepared_build_command(
                        acceptance.PRODUCT_ENTRYPOINT, platform, []),
                },
                'test': {
                    'role': 'test',
                    'entrypoint': target,
                    'integration_target': target,
                    'file': test.name,
                    'sha256': acceptance.apk_sha256(test),
                    'command': acceptance.prepared_build_command(
                        target, platform, acceptance.test_defines()),
                },
            },
        }
        manifest_path = root / acceptance.PREBUILT_MANIFEST
        payload = acceptance.manifest_bytes(manifest)
        manifest_path.write_bytes(payload)
        receipts = root / 'receipts'
        receipts.mkdir()
        (receipts / (hashlib.sha256(payload).hexdigest() + '.json')).write_bytes(payload)
        return product, test, manifest_path, receipts, fingerprint

    def _validate_bundle(self, directory, **kwargs):
        product, test, manifest, receipts, fingerprint = self._proof_bundle(directory, **kwargs)
        with patch.object(acceptance, 'prebuilt_receipt_directory', return_value=receipts), \
             patch.object(acceptance, 'prebuilt_source_fingerprint', return_value=fingerprint), \
             patch.object(acceptance, 'verify_apk_package'):
            acceptance.validate_prebuilt_apks(product, test, manifest, kwargs.get('target', acceptance.DEFAULT_INTEGRATION_TARGET))
        return product, test, manifest, receipts, fingerprint

    def test_configured_sites_only_enter_integration_defines(self):
        with patch.dict(acceptance.ENV, {'SITE_LENS_TEST_SITES': 'https://test.example/'}):
            self.assertIn('--dart-define=SITE_LENS_TEST_SITES=https://test.example/',
                          acceptance.test_defines())
        with patch.dict(acceptance.ENV, {'SITE_LENS_TEST_SITES': ''}):
            self.assertEqual(acceptance.test_defines(), [acceptance.NETWORK_DEFINE])

    def test_prebuilt_arguments_require_pair_single_suite_and_no_test_name(self):
        with tempfile.TemporaryDirectory() as directory:
            product = Path(directory) / 'product.apk'
            test = Path(directory) / 'test.apk'
            product.write_bytes(b'product')
            test.write_bytes(b'test')
            cases = [
                ['--prebuilt-product-apk', str(product)],
                [
                    '--prebuilt-product-apk', str(product),
                    '--prebuilt-test-apk', str(test),
                ],
                [
                    '--single-suite',
                    '--prebuilt-product-apk', str(product),
                    '--prebuilt-test-apk', str(test),
                    '--test-name', 'contract',
                ],
            ]
            for options in cases:
                with self.subTest(options=options), \
                     patch.object(acceptance, 'require_device') as require_device, \
                     patch.object(acceptance, 'verify_apk_package') as verify:
                    with patch.object(
                        sys,
                        'argv',
                        ['run_android_acceptance.py', 'emulator-test', *options],
                    ), self.assertRaises(SystemExit):
                        acceptance.main()
                    require_device.assert_not_called()
                    verify.assert_not_called()

    def test_prebuilt_missing_apk_fails_before_device_backup_or_install(self):
        with tempfile.TemporaryDirectory() as directory:
            product = Path(directory) / 'missing-product.apk'
            test = Path(directory) / 'test.apk'
            test.write_bytes(b'test')
            with patch.object(acceptance, 'require_device') as require_device, \
                 patch.object(acceptance, 'backup_database') as backup, \
                 patch.object(acceptance, 'install') as install:
                with patch.object(
                    sys,
                    'argv',
                    [
                        'run_android_acceptance.py', 'emulator-test',
                        '--single-suite',
                        '--prebuilt-product-apk', str(product),
                        '--prebuilt-test-apk', str(test),
                        '--prebuilt-manifest', str(Path(directory) / 'missing-manifest.json'),
                    ],
                ), self.assertRaisesRegex(RuntimeError, 'prebuilt product APK does not exist'):
                    acceptance.main()
            require_device.assert_not_called()
            backup.assert_not_called()
            install.assert_not_called()

    def test_prebuilt_missing_proof_fails_before_device_backup_or_install(self):
        with tempfile.TemporaryDirectory() as directory:
            product = Path(directory) / 'product.apk'
            test = Path(directory) / 'test.apk'
            product.write_bytes(b'product')
            test.write_bytes(b'test')
            with patch.object(acceptance, 'require_device') as require_device, \
                 patch.object(acceptance, 'backup_database') as backup, \
                 patch.object(acceptance, 'install') as install:
                with patch.object(
                    sys,
                    'argv',
                    [
                        'run_android_acceptance.py', 'emulator-test',
                        '--single-suite',
                        '--prebuilt-product-apk', str(product),
                        '--prebuilt-test-apk', str(test),
                        '--prebuilt-manifest', str(Path(directory) / 'missing.json'),
                    ],
                ), self.assertRaisesRegex(RuntimeError, 'missing or invalid prebuilt proof'):
                    acceptance.main()
            require_device.assert_not_called()
            backup.assert_not_called()
            install.assert_not_called()

    def test_prebuilt_proof_rejects_wrong_package_before_any_install(self):
        with tempfile.TemporaryDirectory() as directory:
            product, test, manifest, receipts, fingerprint = self._proof_bundle(directory)
            def verify(path, expected, environment):
                if path == test:
                    raise RuntimeError('unexpected APK package: formal package')

            with patch.object(acceptance, 'prebuilt_receipt_directory', return_value=receipts), \
                 patch.object(acceptance, 'prebuilt_source_fingerprint', return_value=fingerprint), \
                 patch.object(acceptance, 'verify_apk_package', side_effect=verify) as verify_mock, \
                 patch.object(acceptance, 'require_device') as require_device, \
                 patch.object(acceptance, 'backup_database') as backup, \
                 patch.object(acceptance, 'install') as install:
                with self.assertRaisesRegex(RuntimeError, 'prebuilt test APK must be the debug package'):
                    acceptance.validate_prebuilt_apks(product, test, manifest)
            require_device.assert_not_called()
            backup.assert_not_called()
            install.assert_not_called()
            self.assertEqual(verify_mock.call_count, 2)

    def test_prebuilt_proof_rejects_same_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / 'same.apk'
            artifact.write_bytes(b'same-artifact')
            with self.assertRaisesRegex(RuntimeError, 'different artifacts'):
                acceptance.validate_prebuilt_apks(artifact, artifact)

    def test_prebuilt_proof_rejects_role_swap(self):
        with tempfile.TemporaryDirectory() as directory:
            product, test, manifest, receipts, fingerprint = self._proof_bundle(directory)
            product_bytes, test_bytes = product.read_bytes(), test.read_bytes()
            product.write_bytes(test_bytes)
            test.write_bytes(product_bytes)
            with patch.object(acceptance, 'prebuilt_receipt_directory', return_value=receipts), \
                 patch.object(acceptance, 'prebuilt_source_fingerprint', return_value=fingerprint), \
                 patch.object(acceptance, 'verify_apk_package'):
                with self.assertRaisesRegex(RuntimeError, 'prebuilt product SHA-256 mismatch'):
                    acceptance.validate_prebuilt_apks(product, test, manifest)

    def test_prebuilt_proof_rejects_suite_mismatch(self):
        with tempfile.TemporaryDirectory() as directory:
            product, test, manifest, receipts, fingerprint = self._proof_bundle(directory)
            with patch.object(acceptance, 'prebuilt_receipt_directory', return_value=receipts), \
                 patch.object(acceptance, 'prebuilt_source_fingerprint', return_value=fingerprint), \
                 patch.object(acceptance, 'verify_apk_package'):
                with self.assertRaisesRegex(RuntimeError, 'entrypoint/integration suite mismatch'):
                    acceptance.validate_prebuilt_apks(
                        product, test, manifest, 'integration_test/host_contract_test.dart')

    def test_prebuilt_proof_rejects_digest_change(self):
        with tempfile.TemporaryDirectory() as directory:
            product, test, manifest, receipts, fingerprint = self._proof_bundle(directory)
            test.write_bytes(b'altered-test-artifact')
            with patch.object(acceptance, 'prebuilt_receipt_directory', return_value=receipts), \
                 patch.object(acceptance, 'prebuilt_source_fingerprint', return_value=fingerprint), \
                 patch.object(acceptance, 'verify_apk_package'):
                with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
                    acceptance.validate_prebuilt_apks(product, test, manifest)

    def test_prebuilt_proof_rejects_old_source_worktree(self):
        with tempfile.TemporaryDirectory() as directory:
            product, test, manifest, receipts, fingerprint = self._proof_bundle(directory)
            with patch.object(acceptance, 'prebuilt_receipt_directory', return_value=receipts), \
                 patch.object(acceptance, 'prebuilt_source_fingerprint', return_value={'worktree': 'new', 'source': 'new'}), \
                 patch.object(acceptance, 'verify_apk_package'):
                with self.assertRaisesRegex(RuntimeError, 'stale source/worktree fingerprint'):
                    acceptance.validate_prebuilt_apks(product, test, manifest)

    def test_prebuilt_entry_alignment_uses_compiled_target_from_proof(self):
        with tempfile.TemporaryDirectory() as directory:
            product, test, manifest, receipts, fingerprint = self._proof_bundle(
                directory, target='integration_test/host_contract_test.dart')
            with patch.object(acceptance, 'prebuilt_receipt_directory', return_value=receipts), \
                 patch.object(acceptance, 'prebuilt_source_fingerprint', return_value=fingerprint), \
                 patch.object(acceptance, 'verify_apk_package'):
                acceptance.validate_prebuilt_apks(
                    product, test, manifest, 'integration_test/host_contract_test.dart')
            command = acceptance.prebuilt_drive_command('emulator-test', test, Path('/tmp/driver.dart'))
            self.assertNotIn('--target', command)
            self.assertIn('--use-application-binary', command)

    def test_prebuilt_mode_uses_drive_without_build_and_restores_product_copy(self):
        with tempfile.TemporaryDirectory() as directory:
            product = Path(directory) / 'product.apk'
            test = Path(directory) / 'test.apk'
            driver = Path(directory) / 'integration_test.dart'
            product.write_bytes(b'product')
            test.write_bytes(b'test')
            driver.write_text('driver')
            commands = []

            with patch.object(acceptance, 'require_device'), \
                 patch.object(acceptance, 'verify_apk_package'), \
                 patch.object(acceptance, 'integration_driver_path', return_value=driver), \
                 patch.object(acceptance, 'ensure_debug_install', return_value=False) as ensure_debug_install, \
                 patch.object(acceptance, 'backup_database', return_value={}), \
                 patch.object(acceptance, 'adb', return_value=SimpleNamespace(stdout=b'', stderr=b'')), \
                 patch.object(
                     acceptance,
                     'run_single_suite_with_media_driver',
                     side_effect=lambda command, device, timeout=1800: commands.append(command),
                 ), \
                 patch.object(acceptance, 'run_flutter') as run_flutter, \
                 patch.object(acceptance, 'verify_formal_apk') as verify_formal, \
                 patch.object(acceptance, 'install') as install, \
                 patch.object(acceptance, 'restore_database') as restore_database:
                with patch.object(
                    sys,
                    'argv',
                    [
                        'run_android_acceptance.py', 'emulator-test',
                        '--skip-check', '--skip-build', '--single-suite',
                        '--integration-target', 'integration_test/host_contract_test.dart',
                        '--prebuilt-product-apk', str(product),
                        '--prebuilt-test-apk', str(test),
                        '--prebuilt-manifest', str(Path(directory) / 'manifest.json'),
                    ],
                ):
                    with patch.object(acceptance, 'validate_prebuilt_apks', return_value=(product, test)):
                        self.assertEqual(acceptance.main(), 0)
                        self.assertEqual(acceptance.validate_prebuilt_apks.call_count, 2)

            run_flutter.assert_not_called()
            verify_formal.assert_not_called()
            ensure_debug_install.assert_called_once_with('emulator-test', product)
            restore_database.assert_called_once()
            backup_dir = restore_database.call_args.args[1]
            self.assertEqual((backup_dir / 'product-debug.apk').read_bytes(), b'product')
            self.assertEqual(install.call_args.args[1].read_bytes(), b'product')
            self.assertEqual(len(commands), 1)
            command = commands[0]
            self.assertEqual(command[:2], ['flutter', 'drive'])
            for flag in ('--no-pub', '--no-dds', '--keep-app-running'):
                self.assertIn(flag, command)
            self.assertIn('--use-application-binary', command)
            self.assertIn(str(test), command)
            self.assertNotIn('--target', command)

    def test_prebuilt_primary_failure_is_preserved_when_restore_also_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            product = Path(directory) / 'product.apk'
            test = Path(directory) / 'test.apk'
            driver = Path(directory) / 'integration_test.dart'
            product.write_bytes(b'product')
            test.write_bytes(b'test')
            driver.write_text('driver')
            with patch.object(acceptance, 'require_device'), \
                 patch.object(acceptance, 'verify_apk_package'), \
                 patch.object(acceptance, 'integration_driver_path', return_value=driver), \
                 patch.object(acceptance, 'ensure_debug_install', return_value=False), \
                 patch.object(acceptance, 'backup_database', return_value={}), \
                 patch.object(acceptance, 'adb', return_value=SimpleNamespace(stdout=b'', stderr=b'')), \
                 patch.object(
                     acceptance,
                     'run_single_suite_with_media_driver',
                     side_effect=RuntimeError('primary test failure'),
                 ), \
                 patch.object(
                     acceptance,
                     'restore_and_launch_debug',
                     side_effect=RuntimeError('restore failure'),
                 ), \
                 patch.object(acceptance, 'run_flutter') as run_flutter, \
                 patch('sys.stderr', new_callable=io.StringIO) as stderr:
                with patch.object(
                    sys,
                    'argv',
                    [
                        'run_android_acceptance.py', 'emulator-test',
                        '--skip-check', '--skip-build', '--single-suite',
                        '--prebuilt-product-apk', str(product),
                        '--prebuilt-test-apk', str(test),
                        '--prebuilt-manifest', str(Path(directory) / 'manifest.json'),
                    ],
                ):
                    with patch.object(acceptance, 'validate_prebuilt_apks', return_value=(product, test)):
                        self.assertEqual(acceptance.main(), 1)
            run_flutter.assert_not_called()
            self.assertIn('database restore failed: restore failure', stderr.getvalue())
            self.assertIn('Android acceptance FAIL: primary test failure', stderr.getvalue())

    def test_prebuilt_restore_never_rebuilds_when_product_copy_is_missing(self):
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(acceptance, 'adb'), \
                 patch.object(acceptance, 'run_flutter') as run_flutter, \
                 patch.object(acceptance, 'verify_apk_package'), \
                 patch.object(acceptance, 'install'):
                with self.assertRaisesRegex(RuntimeError, 'prebuilt product APK backup is missing'):
                    acceptance.restore_and_launch_debug(
                        'emulator-test',
                        Path(directory),
                        {},
                        [],
                        allow_rebuild=False,
                    )
            run_flutter.assert_not_called()

    def test_restore_footer_only_installs_and_starts_debug(self):
        with patch.object(acceptance, 'adb') as adb, patch.object(acceptance, 'install') as install, \
             patch.object(acceptance, 'ensure_debug_install', return_value=False), \
             patch.object(acceptance, 'restore_database'), patch.object(acceptance, 'run_flutter'), \
             patch.object(acceptance, 'verify_apk_package') as verify:
            acceptance.restore_and_launch_debug('emulator-test', Path('/tmp/fixture'), {}, [])
            verify.assert_called_once_with(acceptance.DEBUG_APK, acceptance.PACKAGE, acceptance.ENV)
            install.assert_called_once_with('emulator-test', acceptance.DEBUG_APK, acceptance.PACKAGE)
            targets = [arg for call in adb.call_args_list for arg in call.args if isinstance(arg,str)]
            self.assertIn('dev.vikiea.site_lens.debug/dev.vikiea.site_lens.MainActivity',targets)
            self.assertNotIn(f'{acceptance.FORMAL_PACKAGE}/{acceptance.ACTIVITY}', targets)
            self.assertNotIn(acceptance.FORMAL_PACKAGE, targets)

    def test_apk_package_verification_accepts_both_product_identities(self):
        self.assertEqual(acceptance.PACKAGE, "dev.vikiea.site_lens.debug")
        self.assertEqual(acceptance.FORMAL_PACKAGE, "dev.vikiea.site_lens")

    def test_restore_path_verifies_debug_artifact_before_install(self):
        with patch.object(acceptance, 'adb'), patch.object(acceptance, 'install'), \
             patch.object(acceptance, 'ensure_debug_install', return_value=False), \
             patch.object(acceptance, 'restore_database'), patch.object(acceptance, 'run_flutter'), \
             patch.object(acceptance, 'verify_apk_package') as verify:
            acceptance.restore_and_launch_debug('emulator-test', Path('/tmp/fixture'), {}, [])
            verify.assert_called_once_with(acceptance.DEBUG_APK, acceptance.PACKAGE, acceptance.ENV)

    def test_apk_package_verification_rejects_mismatched_artifact(self):
        from android_artifact import verify_apk_package
        with tempfile.NamedTemporaryFile() as apk, \
             patch('android_artifact._tool', return_value='/sdk/apkanalyzer'), \
             patch('android_artifact.subprocess.check_output', return_value=b'wrong.package\n'), \
             self.assertRaisesRegex(RuntimeError, 'unexpected APK package'):
            verify_apk_package(Path(apk.name), acceptance.FORMAL_PACKAGE, acceptance.ENV)

    def test_formal_package_foreground_guard_rejects_formal_activity(self):
        with patch.object(acceptance, 'adb', return_value=SimpleNamespace(
            stdout=b'topResumedActivity=dev.vikiea.site_lens/dev.vikiea.site_lens.MainActivity',
        )), self.assertRaisesRegex(RuntimeError, 'formal package became foreground'):
            acceptance.assert_formal_not_foreground('emulator-test')

    def test_formal_package_foreground_guard_allows_debug_activity(self):
        with patch.object(acceptance, 'adb', return_value=SimpleNamespace(
            stdout=b'topResumedActivity=dev.vikiea.site_lens.debug/dev.vikiea.site_lens.MainActivity',
        )):
            acceptance.assert_formal_not_foreground('emulator-test')

    def test_stop_notification_is_scoped_even_when_other_owners_have_stop(self):
        own = '<node resource-id="com.android.systemui:id/expandableNotificationRow"><node text="择站 · 当前标签"/><node text="Site Lens debug media acceptance"/><node package="com.android.systemui" content-desc="停止" bounds="[100,100][200,200]"/></node>'
        other = '<node resource-id="com.android.systemui:id/expandableNotificationRow"><node text="择站 · Site Lens"/><node text="Site Lens media"/><node package="com.android.systemui" content-desc="停止" bounds="[300,300][400,400]"/></node>'
        driver = MediaActionDriver('adb','emulator-test','dev.vikiea.site_lens.debug')
        calls=[]
        def command(*args, **kwargs):
            calls.append(args)
            if args[:3] == ('shell', 'dumpsys', 'notification'):
                return b'NotificationRecord(pkg=dev.vikiea.site_lens.debug)\n  android.title=Site Lens debug media acceptance\n'
            return ('<hierarchy>'+own+other+'</hierarchy>').encode() if args[0]=='exec-out' else b''
        driver.command=command
        with patch('android_media_actions.time.sleep'):
            driver._stop_notification()
        self.assertIn(('shell','input','tap','150','150'),calls)
        self.assertNotIn(('shell','input','tap','350','350'),calls)

    def test_stop_session_targets_the_debug_media_session(self):
        driver = MediaActionDriver('adb', 'emulator-test', 'dev.vikiea.site_lens.debug')
        calls = []

        def command(*args, **kwargs):
            calls.append((args, kwargs))
            if args == ('shell', 'cmd', 'media_session', 'list-sessions'):
                return b'Sessions:\n  tag=site-lens-browser:dev.vikiea.site_lens.debug, package=dev.vikiea.site_lens.debug\n'
            return b''

        driver.command = command
        driver._send_session_action('stop')
        self.assertIn(
            (
                'shell',
                'cmd',
                'media_session',
                'monitor',
                'site-lens-browser:dev.vikiea.site_lens.debug',
            ),
            [args for args, _ in calls],
        )
        self.assertEqual(calls[-1][1]['input'], b'stop\nq\n')

    def test_stop_session_rejects_device_monitor_without_stop_support(self):
        driver = MediaActionDriver('adb', 'emulator-test', 'dev.vikiea.site_lens.debug')
        driver.command = lambda *args, **kwargs: b'Invalid command: stop\n'
        with self.assertRaisesRegex(RuntimeError, 'rejected stop'):
            driver._send_session_action('stop')

    def test_global_media_stop_dispatch_targets_supported_system_command(self):
        driver = MediaActionDriver('adb', 'emulator-test', 'dev.vikiea.site_lens.debug')
        calls = []

        def command(*args, **kwargs):
            calls.append((args, kwargs))
            if args == ('shell', 'cmd', 'media_session', 'list-sessions'):
                return b'Sessions:\n  tag=site-lens-browser:dev.vikiea.site_lens.debug, package=dev.vikiea.site_lens.debug\n'
            return b''

        driver.command = command
        driver._send_global_media_action('stop')
        self.assertIn(
            (
                'shell',
                'cmd',
                'media_session',
                'dispatch',
                'stop',
            ),
            [args for args, _ in calls],
        )

    def test_notification_fallback_accepts_current_service_copy(self):
        own = '<node resource-id="com.android.systemui:id/qs_media_controls"><node content-desc="Site Lens debug media acceptance"/><node text="择站 · 当前标签"/><node package="com.android.systemui" text="停止" bounds="[10,20][110,120]"/></node>'
        driver = MediaActionDriver('adb', 'emulator-test', 'dev.vikiea.site_lens.debug')
        calls = []

        def command(*args, **kwargs):
            calls.append(args)
            if args[:3] == ('shell', 'dumpsys', 'notification'):
                return b'NotificationRecord(pkg=dev.vikiea.site_lens.debug)\n  android.title=Site Lens debug media acceptance\n'
            return ('<hierarchy>' + own + '</hierarchy>').encode() if args[0] == 'exec-out' else b''

        driver.command = command
        with patch('android_media_actions.time.sleep'):
            driver._stop_notification()
        self.assertIn(('shell', 'input', 'tap', '60', '70'), calls)

    def test_missing_owner_notification_refuses_to_tap(self):
        driver = MediaActionDriver('adb','emulator-test','dev.vikiea.site_lens.debug')
        calls=[]
        def command(*args, **kwargs):
            calls.append(args)
            if args[:3] == ('shell', 'dumpsys', 'notification'):
                return b'NotificationRecord(pkg=com.example.other)\n  android.title=Other\n'
            return b'<hierarchy><node content-desc="\xe5\x81\x9c\xe6\xad\xa2" package="com.android.systemui" bounds="[1,1][2,2]"/></hierarchy>' if args[0]=='exec-out' else b''
        driver.command=command
        with patch('android_media_actions.time.sleep'), self.assertRaises(RuntimeError):
            driver._stop_notification()
        self.assertFalse(any(call[:3]==('shell','input','tap') for call in calls))

    def test_media_driver_cleanup_does_not_hide_test_failure(self):
        test_failure = subprocess.CalledProcessError(1, ['flutter', 'test'])
        with patch.object(acceptance, 'MediaActionDriver') as driver_type, \
             patch.object(acceptance, 'run_flutter_test', side_effect=test_failure):
            driver_type.return_value.finish.side_effect = RuntimeError('missing notification')
            with self.assertRaises(subprocess.CalledProcessError) as raised:
                acceptance.run_single_suite_with_media_driver(
                    ['flutter', 'test'], 'emulator-test'
                )
        self.assertTrue(
            any('media driver cleanup also failed' in note for note in raised.exception.__notes__)
        )


    def test_standalone_restore_rebuilds_normal_entry_before_installing(self):
        with tempfile.TemporaryDirectory() as directory:
            source=Path(directory)/'database.sqlite';source.write_bytes(b'fixture')
            apk=Path(directory)/'app-debug.apk';apk.write_bytes(b'integration-entry')
            calls=[]
            def build(*args,**kwargs):
                calls.append('build');apk.write_bytes(b'normal-entry')
            def install(device,path):
                self.assertEqual(path.read_bytes(),b'normal-entry');calls.append('install')
            with patch('sys.argv',['restore','emulator-test',str(source)]), \
                 patch.object(standalone,'DEBUG_APK',apk), \
                 patch.object(standalone,'run_flutter',side_effect=build), \
                 patch.object(standalone,'normal_debug_build',return_value=['flutter','build','apk','--debug','--target=lib/main.dart']), \
                 patch.object(standalone,'install',side_effect=install), \
                 patch.object(standalone,'verify_apk_package'), \
                 patch.object(standalone,'adb',return_value=SimpleNamespace(stdout=b'device',stderr=b'')) as adb, \
                 patch.object(standalone.subprocess,'check_output',return_value=b'fixture'):
                self.assertEqual(standalone.main(),0)
            self.assertEqual(calls,['build','install'])
            targets=[arg for call in adb.call_args_list for arg in call.args if isinstance(arg,str)]
            self.assertIn('dev.vikiea.site_lens.debug/dev.vikiea.site_lens.MainActivity',targets)
            self.assertNotIn(f'{acceptance.FORMAL_PACKAGE}/{acceptance.ACTIVITY}', targets)

if __name__ == '__main__': unittest.main()
