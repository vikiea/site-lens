"""Read-only regressions for package isolation in Android acceptance tooling."""
import unittest
import subprocess
from pathlib import Path
from android_artifact import FORMAL_CERT_SHA256
import tempfile
from types import SimpleNamespace
import restore_android_database as standalone
from unittest.mock import patch
import run_android_acceptance as acceptance
from android_media_actions import MediaActionDriver

class AndroidToolsTests(unittest.TestCase):
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
