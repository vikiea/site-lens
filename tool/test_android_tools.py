"""Read-only regressions for package isolation in Android acceptance tooling."""
import hashlib
import base64
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
    def setUp(self):
        # These historical tests isolate runner/package behavior. The real
        # identity guard is covered separately by test_android_backup_identity.
        identity = {
            'serial_sha256': 'a' * 64,
            'android_id_sha256': 'b' * 64,
        }
        source = patch.object(acceptance, 'read_device_identity', return_value=identity)
        guard = patch.object(acceptance, 'verify_backup_target')
        source.start()
        guard.start()
        self.addCleanup(source.stop)
        self.addCleanup(guard.stop)

    def test_partial_backup_failure_never_installs_tests_restores_or_launches(self):
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            product = root / 'product.apk'
            product.write_bytes(b'product')
            backup_dir = root / 'backup'
            backup_dir.mkdir()
            def partial_backup(device, directory):
                (directory / 'site_lens.sqlite').write_bytes(b'partial checkpoint')
                raise OSError('transport failed while reading WAL')
            with patch.object(acceptance, 'require_device'), \
                    patch.object(acceptance, 'run_flutter'), \
                    patch.object(acceptance, 'verify_apk_package'), \
                    patch.object(acceptance, 'DEBUG_APK', product), \
                    patch.object(acceptance.tempfile, 'mkdtemp', return_value=str(backup_dir)), \
                    patch.object(acceptance, 'ensure_debug_install', return_value=False), \
                    patch.object(acceptance, 'adb'), \
                    patch.object(acceptance, 'backup_database', side_effect=partial_backup), \
                    patch.object(acceptance, 'run_single_suite_with_media_driver') as tests, \
                    patch.object(acceptance, 'restore_and_launch_debug') as restore, \
                    patch.object(sys, 'argv', ['run_android_acceptance.py', 'emulator-test',
                                              '--single-suite', '--skip-check', '--skip-build']):
                self.assertEqual(acceptance.main(), 1)
            tests.assert_not_called()
            restore.assert_not_called()
            self.assertEqual((backup_dir / 'site_lens.sqlite').read_bytes(), b'partial checkpoint')

    def test_database_absence_is_explicit_and_transport_errors_fail_closed(self):
        relative = 'files/site_lens.sqlite'
        for status, expected in ((b'PRESENT', True), (b'ABSENT', False)):
            with patch.object(acceptance, 'adb', return_value=subprocess.CompletedProcess([], 0, status, b'')):
                self.assertEqual(acceptance.file_exists('device', relative), expected)
        for result in (
            subprocess.CompletedProcess([], 1, b'', b'device offline'),
            subprocess.CompletedProcess([], 1, b'', b'run-as denied'),
            subprocess.CompletedProcess([], 0, b'', b''),
            subprocess.CompletedProcess([], 0, b'ABSENT\nwarning', b''),
        ):
            with self.subTest(result=result), patch.object(acceptance, 'adb', return_value=result):
                with self.assertRaises((subprocess.CalledProcessError, RuntimeError)):
                    acceptance.file_exists('device', relative)

    def test_failed_database_probe_does_not_return_an_empty_backup(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(acceptance, 'adb', return_value=subprocess.CompletedProcess([], 1, b'', b'offline')), \
                patch.object(acceptance, 'read_device_file') as read:
            with self.assertRaises(subprocess.CalledProcessError):
                acceptance.backup_database('device', Path(directory))
            read.assert_not_called()

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
        with patch.dict(
            acceptance.ENV,
            {'SITE_LENS_TEST_SITES': 'https://test.example/', 'SITE_LENS_PROXY_FIXTURE': ''},
            clear=True,
        ):
            self.assertIn('--dart-define=SITE_LENS_TEST_SITES=https://test.example/',
                          acceptance.test_defines())
        with patch.dict(
            acceptance.ENV,
            {'SITE_LENS_TEST_SITES': '', 'SITE_LENS_PROXY_FIXTURE': ''},
            clear=True,
        ):
            self.assertEqual(acceptance.test_defines(), [acceptance.NETWORK_DEFINE])

    def test_multiple_real_media_pages_only_enter_explicit_test_defines(self):
        pages = 'https://example.org/video/1/\nhttps://example.org/video/1/ep-2/'
        with patch.dict(acceptance.ENV, {'SITE_LENS_MEDIA_TEST_URL': pages.splitlines()[0],
                                       'SITE_LENS_MEDIA_TEST_URLS': pages}, clear=True), \
                patch.object(acceptance, 'adb', return_value=subprocess.CompletedProcess([], 0, b'arm64-v8a', b'')):
            defines = acceptance.test_defines()
            encoded = next(value.split('=', 2)[2] for value in defines
                           if value.startswith('--dart-define=SITE_LENS_MEDIA_TEST_URLS_BASE64='))
            self.assertEqual(base64.b64decode(encoded).decode(), pages)
            self.assertTrue(all('\n' not in value for value in defines))
            self.assertFalse(any('SITE_LENS_MEDIA_TEST' in part
                                 for part in acceptance.normal_debug_build('emulator-test')))

    def test_real_media_page_list_works_without_a_single_page(self):
        pages = 'https://example.org/video/1/\nhttps://example.org/video/1/ep-2/'
        with patch.dict(acceptance.ENV, {
            'SITE_LENS_MEDIA_TEST_URLS': pages,
            'SITE_LENS_MEDIA_EXPECT_EPISODES': '1,2',
            'SITE_LENS_REAL_MEDIA_DOWNLOAD': 'true',
        }, clear=True):
            defines = acceptance.test_defines()
        encoded = next(value.split('=', 2)[2] for value in defines
                       if value.startswith('--dart-define=SITE_LENS_MEDIA_TEST_URLS_BASE64='))
        self.assertEqual(base64.b64decode(encoded).decode(), pages)
        self.assertTrue(all('\n' not in value for value in defines))
        self.assertIn('--dart-define=SITE_LENS_MEDIA_EXPECT_EPISODES=1,2', defines)
        self.assertIn('--dart-define=SITE_LENS_REAL_MEDIA_DOWNLOAD=true', defines)
        self.assertFalse(any(value.startswith('--dart-define=SITE_LENS_MEDIA_TEST_URL=')
                             for value in defines))

    def test_real_media_url_is_only_forwarded_when_explicitly_injected(self):
        with patch.dict(
            acceptance.ENV,
            {
                'SITE_LENS_TEST_SITES': '',
                'SITE_LENS_MEDIA_TEST_URL': 'https://test.example/video/1',
                'SITE_LENS_REAL_MEDIA_DOWNLOAD': 'true',
                'SITE_LENS_PROXY_FIXTURE': '',
            },
            clear=True,
        ):
            self.assertEqual(
                acceptance.test_defines(),
                [
                    acceptance.NETWORK_DEFINE,
                    '--dart-define=SITE_LENS_MEDIA_TEST_URL=https://test.example/video/1',
                    '--dart-define=SITE_LENS_REAL_MEDIA_DOWNLOAD=true',
                ],
            )

    def test_proxy_fixture_define_requires_explicit_opt_in(self):
        with patch.dict(acceptance.ENV, {}, clear=True):
            self.assertNotIn('--dart-define=SITE_LENS_PROXY_FIXTURE=true', acceptance.test_defines())
        with patch.dict(acceptance.ENV, {'SITE_LENS_PROXY_FIXTURE': 'true'}):
            self.assertIn('--dart-define=SITE_LENS_PROXY_FIXTURE=true', acceptance.test_defines())

    def test_targeted_arguments_without_single_suite_fail_before_any_device_action(self):
        for options in (
            ['--test-name', 'targeted regression'],
            ['--integration-target', 'integration_test/modernization_test.dart'],
            ['--integration-target', 'integration_test/modernization_test.dart',
             '--test-name', 'targeted regression'],
        ):
            with self.subTest(options=options), \
                    patch.object(sys, 'argv', ['run_android_acceptance.py',
                                               'emulator-test', *options]), \
                    patch.object(sys, 'stderr', new_callable=io.StringIO) as stderr, \
                    patch.object(acceptance, 'require_device') as device, \
                    patch.object(acceptance, 'run_flutter') as build, \
                    patch.object(acceptance, 'backup_database') as backup, \
                    patch.object(acceptance, 'install') as install:
                with self.assertRaises(SystemExit) as failure:
                    acceptance.main()
                self.assertEqual(failure.exception.code, 2)
                self.assertIn('require --single-suite', stderr.getvalue())
                device.assert_not_called()
                build.assert_not_called()
                backup.assert_not_called()
                install.assert_not_called()

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

            def complete(command, device, timeout=1800):
                commands.append(command)
                acceptance.integration_completion_path(driver).write_text(
                    '{"schema": 1, "passed": true}')

            with patch.object(acceptance, 'require_device'), \
                 patch.object(acceptance, 'verify_apk_package'), \
                 patch.object(acceptance, 'integration_driver_path', return_value=driver), \
                 patch.object(acceptance, 'ensure_debug_install', return_value=False) as ensure_debug_install, \
                 patch.object(acceptance, 'backup_database', return_value={}), \
                 patch.object(acceptance, 'adb', return_value=SimpleNamespace(stdout=b'', stderr=b'')), \
                 patch.object(
                     acceptance,
                     'run_single_suite_with_media_driver',
                     side_effect=complete,
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

    def test_zero_exit_without_suite_completion_still_fails_and_restores(self):
        with tempfile.TemporaryDirectory() as directory:
            product, test, driver = (Path(directory) / name for name in ('product.apk', 'test.apk', 'driver.dart'))
            for path in (product, test, driver):
                path.write_bytes(b'fixture')
            # A result from before launch cannot certify an interrupted run.
            acceptance.integration_completion_path(driver).write_text('{"schema": 1, "passed": true}')
            with patch.object(acceptance, 'require_device'), \
                    patch.object(acceptance, 'verify_apk_package'), \
                    patch.object(acceptance, 'integration_driver_path', return_value=driver), \
                    patch.object(acceptance, 'validate_prebuilt_apks', return_value=(product, test)), \
                    patch.object(acceptance, 'ensure_debug_install', return_value=False), \
                    patch.object(acceptance, 'backup_database', return_value={}), \
                    patch.object(acceptance, 'adb'), \
                    patch.object(acceptance, 'run_single_suite_with_media_driver'), \
                    patch.object(acceptance, 'restore_and_launch_debug') as restore, \
                    patch.object(sys, 'argv', ['run_android_acceptance.py', 'device', '--single-suite', '--skip-check',
                        '--prebuilt-product-apk', str(product), '--prebuilt-test-apk', str(test),
                        '--prebuilt-manifest', str(Path(directory) / 'manifest.json')]), \
                    patch('sys.stderr', new_callable=io.StringIO) as stderr:
                self.assertEqual(acceptance.main(), 1)
                self.assertIn('without a passed suite completion receipt', stderr.getvalue())
            restore.assert_called_once()

    def test_completion_receipt_rejects_failure_unknown_and_malformed_results(self):
        with tempfile.TemporaryDirectory() as directory:
            driver = Path(directory) / 'driver.dart'
            result = acceptance.integration_completion_path(driver)
            for payload in ('{}', 'null', 'broken', '{"schema":1,"passed":false}', '{"schema":2,"passed":true}'):
                result.write_text(payload)
                with self.subTest(payload=payload), self.assertRaises(RuntimeError):
                    acceptance.verify_integration_completion(driver)
            result.write_text('{"schema":1,"passed":true}')
            acceptance.verify_integration_completion(driver)

    def test_generated_driver_writes_receipt_only_in_success_callback(self):
        driver = acceptance.integration_driver_path()
        try:
            source = driver.read_text()
            self.assertIn('writeResponseOnFailure: false', source)
            self.assertIn('responseDataCallback: (data) async', source)
            self.assertIn("jsonEncode({'schema': 1, 'passed': true}), flush: true", source)
            self.assertFalse(acceptance.integration_completion_path(driver).exists())
        finally:
            driver.unlink(missing_ok=True)

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

    def test_apk_version_verification_reads_manifest_identity(self):
        from android_artifact import verify_apk_version

        with tempfile.NamedTemporaryFile() as apk, \
                patch('android_artifact._tool', return_value='/sdk/apkanalyzer'), \
                patch(
                    'android_artifact.subprocess.check_output',
                    side_effect=[b'0.4.0.alpha16\n', b'94\n'],
                ):
            verify_apk_version(
                Path(apk.name),
                expected_name='0.4.0.alpha16',
                expected_code=94,
                env=acceptance.ENV,
            )

    def test_apk_version_verification_rejects_mismatched_manifest_identity(self):
        from android_artifact import verify_apk_version

        with tempfile.NamedTemporaryFile() as apk, \
                patch('android_artifact._tool', return_value='/sdk/apkanalyzer'), \
                patch(
                    'android_artifact.subprocess.check_output',
                    side_effect=[b'0.4.0.alpha15\n', b'93\n'],
                ), \
                self.assertRaisesRegex(RuntimeError, 'versionName'):
            verify_apk_version(
                Path(apk.name),
                expected_name='0.4.0.alpha16',
                expected_code=94,
                env=acceptance.ENV,
            )

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
            if args == ('shell', 'cmd', 'media_session', 'list-sessions'):
                return b'Sessions:\n'
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

    def test_episode_phases_use_only_the_debug_session_among_other_sessions(self):
        driver = MediaActionDriver('adb', 'device', 'dev.vikiea.site_lens.debug')
        phases = iter([b'next', b'previous'])
        controls = []

        def command(*args, **kwargs):
            if args[0] == 'exec-out':
                return next(phases)
            if args == ('shell', 'cmd', 'media_session', 'list-sessions'):
                return (b'Sessions:\n  tag=foreign, package=other.app\n'
                        b'  tag=site-lens-browser:dev.vikiea.site_lens.debug, package=dev.vikiea.site_lens.debug\n')
            controls.append((args, kwargs.get('input')))
            return b''

        driver.command = command
        with patch.object(driver.stop_event, 'wait', side_effect=[False, False, True]):
            driver._run()
        expected = ('shell', 'cmd', 'media_session', 'monitor',
                    'site-lens-browser:dev.vikiea.site_lens.debug')
        self.assertEqual(controls, [(expected, b'next\nq\n'), (expected, b'previous\nq\n')])
        self.assertEqual(driver.handled, {'next', 'previous'})
        self.assertEqual(driver.errors, [])

    def test_episode_phase_without_debug_session_never_sends_a_control(self):
        driver = MediaActionDriver('adb', 'device', 'dev.vikiea.site_lens.debug')
        calls = []

        def command(*args, **kwargs):
            calls.append(args)
            return b'next' if args[0] == 'exec-out' else b'Sessions:\n  tag=foreign, package=other.app\n'

        driver.command = command
        with patch.object(driver.stop_event, 'wait', side_effect=[False, True]):
            driver._run()
        self.assertFalse(any('monitor' in call or 'dispatch' in call for call in calls))
        self.assertEqual(driver.handled, set())

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
            if args == ('shell', 'cmd', 'media_session', 'list-sessions'):
                return b'Sessions:\n'
            return ('<hierarchy>' + own + '</hierarchy>').encode() if args[0] == 'exec-out' else b''

        driver.command = command
        with patch('android_media_actions.time.sleep'):
            driver._stop_notification()
        self.assertIn(('shell', 'input', 'tap', '60', '70'), calls)

    def test_xiaomi_media_card_keeps_stop_scoped_to_fixture(self):
        own = '<node package="com.android.systemui" resource-id="com.android.systemui:id/mi_media_controls"><node text="Site Lens debug media acceptance"/><node package="com.android.systemui" content-desc="停止" bounds="[343,779][563,962]"/></node>'
        other = '<node resource-id="com.android.systemui:id/mi_media_controls"><node text="Other media"/><node package="com.android.systemui" content-desc="停止" bounds="[1,1][99,99]"/></node>'
        driver = MediaActionDriver('adb', 'real-test', 'dev.vikiea.site_lens.debug')
        calls = []

        def command(*args, **kwargs):
            calls.append(args)
            if args[:3] == ('shell', 'dumpsys', 'notification'):
                return b'NotificationRecord(pkg=dev.vikiea.site_lens.debug)\n  android.title=Site Lens debug media acceptance\n'
            if args == ('shell', 'cmd', 'media_session', 'list-sessions'):
                return b'Sessions:\n'
            return ('<hierarchy>' + own + other + '</hierarchy>').encode() if args[0] == 'exec-out' else b''

        driver.command = command
        with patch('android_media_actions.time.sleep'):
            driver._stop_notification()
        self.assertIn(('shell', 'input', 'tap', '453', '870'), calls)
        self.assertNotIn(('shell', 'input', 'tap', '50', '50'), calls)

    def test_notification_shade_waits_for_own_session_to_end_before_collapsing(self):
        driver = MediaActionDriver('adb', 'device', 'dev.vikiea.site_lens.debug')
        own = '<node resource-id="com.android.systemui:id/mi_media_controls"><node text="Site Lens debug media acceptance"/><node package="com.android.systemui" content-desc="停止" bounds="[75,779][295,962]"/></node>'
        calls = []
        inventories = iter([
            b'Sessions:\n  tag=site-lens-browser:dev.vikiea.site_lens.debug, package=dev.vikiea.site_lens.debug\n  tag=foreign, package=other.app\n',
            b'Sessions:\n  tag=foreign, package=other.app\n',
        ])

        def command(*args, **kwargs):
            calls.append(args)
            if args[:3] == ('shell', 'dumpsys', 'notification'):
                return b'NotificationRecord(pkg=dev.vikiea.site_lens.debug)\n  android.title=Site Lens debug media acceptance\n'
            if args == ('shell', 'cmd', 'media_session', 'list-sessions'):
                return next(inventories)
            return ('<hierarchy>' + own + '</hierarchy>').encode() if args[0] == 'exec-out' else b''

        driver.command = command
        with patch('android_media_actions.time.sleep'):
            driver._stop_notification()
        tap = calls.index(('shell', 'input', 'tap', '185', '870'))
        self.assertEqual(calls[tap + 1:], [
            ('shell', 'cmd', 'media_session', 'list-sessions'),
            ('shell', 'cmd', 'media_session', 'list-sessions'),
            ('shell', 'cmd', 'statusbar', 'collapse'),
        ])

    def test_stop_confirmation_does_not_treat_unknown_inventory_as_success(self):
        driver = MediaActionDriver('adb', 'device', 'dev.vikiea.site_lens.debug')
        for response in (b'', b'error: transport lost', b'Sessions:\nerror: transport lost',
                         b'Sessions:\n  tag=site-lens-browser:dev.vikiea.site_lens.debug, package=dev.vikiea.site_lens.debug\n' * 2):
            driver.command = lambda *args, **kwargs: response
            with self.subTest(response=response), self.assertRaises(RuntimeError):
                driver._await_stopped_session()

    def test_stop_confirmation_times_out_when_only_foreign_session_disappears(self):
        driver = MediaActionDriver('adb', 'device', 'dev.vikiea.site_lens.debug')
        driver.command = lambda *args, **kwargs: (
            b'Sessions:\n  tag=site-lens-browser:dev.vikiea.site_lens.debug, package=dev.vikiea.site_lens.debug\n'
        )
        with patch('android_media_actions.time.monotonic', side_effect=[0, 0, 7]), \
                patch('android_media_actions.time.sleep'), \
                self.assertRaisesRegex(RuntimeError, 'remained active'):
            driver._await_stopped_session()

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
