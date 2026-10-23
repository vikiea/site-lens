"""Mock-only Android proxy lease tests; no ADB, network, or device mutation."""
from __future__ import annotations

import shlex
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from android_proxy_lease import AndroidProxyLease, ExistingProxyError, ProxyLeaseError, PROXY_KEYS


class FakeAdb:
    """Models adb shell's argv rejoin, request files, and Settings values."""

    def __init__(self, values=None):
        self.values = {key: None for key in PROXY_KEYS}
        if values:
            self.values.update(values)
        self.calls = []
        self.scripts = []
        self.lease = None
        self.fail_release = False

    def _script(self, argv):
        self.assert_adb_shell_quoting(argv)
        # adbd effectively rejoins the shell argv before the remote sh parses it.
        joined = " ".join(argv[4:])
        parsed = shlex.split(joined)
        if parsed[:2] != ["sh", "-c"] or len(parsed) != 3:
            raise AssertionError(f"bad rejoined shell argv: {joined!r}")
        return parsed[2]

    @staticmethod
    def assert_adb_shell_quoting(argv):
        if len(argv) < 7 or argv[3:6] != ["shell", "sh", "-c"]:
            raise AssertionError(f"unexpected adb argv: {argv!r}")
        # The last argument must itself be one shell-quoted SCRIPT.
        shlex.split(" ".join(argv[4:]))

    def __call__(self, argv):
        argv = list(argv)
        self.calls.append(argv)
        script = self._script(argv)
        self.scripts.append(script)

        words = shlex.split(script)
        if words[:3] == ["settings", "get", "global"] and len(words) == 4:
            value = self.values[words[3]]
            return "null\n" if value is None else f"{value}\n"

        if "printf '%s\\n' ARMED" in script:
            return "ARMED\n"

        if "touch " in script and "printf OK" in script:
            return "OK"

        if "touch " in script and "activate" in script and "base/active" in script:
            self.values.update({
                "http_proxy": f"127.0.0.1:{self.lease.proxy_port}",
                "global_http_proxy_host": "127.0.0.1",
                "global_http_proxy_port": str(self.lease.proxy_port),
                "global_http_proxy_exclusion_list": "",
                "global_proxy_pac_url": "",
            })
            return "ACTIVE\n"

        if "touch " in script and "release" in script and "base/result" in script:
            if self.fail_release:
                return "PENDING\n"
            if not self.lease._is_owned(self.values):
                return "EXTERNAL\n"
            self.values["http_proxy"] = ":0"
            self.values.update(self.lease.snapshot)
            return "RESTORED\n"

        raise AssertionError(f"unmodeled remote script: {script[:180]!r}")


class AndroidProxyLeaseTests(unittest.TestCase):
    def make_lease(self, fake, port=39123):
        lease = AndroidProxyLease(
            fake, "emulator-5554", "adb", proxy_port=port
        )
        fake.lease = lease
        return lease

    def test_canonical_residue_is_refused_before_watchdog(self):
        fake = FakeAdb({
            "global_http_proxy_host": "127.0.0.1",
            "global_http_proxy_port": "39091",
            "global_http_proxy_exclusion_list": "",
            "global_proxy_pac_url": None,
        })
        with self.assertRaises(ExistingProxyError):
            self.make_lease(fake).activate()
        self.assertFalse(any("nohup" in script for script in fake.scripts))

    def test_existing_legacy_proxy_is_refused(self):
        fake = FakeAdb({"http_proxy": "proxy.example:8080"})
        with self.assertRaises(ExistingProxyError):
            self.make_lease(fake).activate()

    def test_empty_canonical_fields_are_owned_and_restored(self):
        original = {
            "http_proxy": ":0",
            "global_http_proxy_host": "",
            "global_http_proxy_port": "0",
            "global_http_proxy_exclusion_list": "",
            "global_proxy_pac_url": None,
        }
        fake = FakeAdb(original)
        lease = self.make_lease(fake)
        lease.activate()

        # Real Android can report PAC as either empty string or null.
        self.assertTrue(lease._is_owned({
            "http_proxy": lease.endpoint,
            "global_http_proxy_host": "127.0.0.1",
            "global_http_proxy_port": str(lease.proxy_port),
            "global_http_proxy_exclusion_list": "",
            "global_proxy_pac_url": None,
        }))
        result = lease.release()

        self.assertTrue(result.ok)
        self.assertEqual(fake.values, original)

    def test_watchdog_is_ready_before_activation_and_quoted_for_adbd_rejoin(self):
        fake = FakeAdb()
        lease = self.make_lease(fake)
        lease.activate()
        self.addCleanup(lease.release)

        arm_index = next(i for i, script in enumerate(fake.scripts) if "nohup sh" in script)
        activate_index = next(i for i, script in enumerate(fake.scripts)
                              if "base/activate" in script and "base/active" in script and "nohup" not in script)
        self.assertLess(arm_index, activate_index)
        self.assertIn("global_proxy_pac_url", fake.scripts[arm_index])
        self.assertIn("global_http_proxy_exclusion_list", fake.scripts[arm_index])
        self.assertIn("stat -c %Y", fake.scripts[arm_index])
        watchdog = lease._watchdog_script()
        self.assertIn('last_seen)) -ge 10', watchdog)
        self.assertIn('started)) -ge 180', watchdog)
        self.assertIn('/proc/uptime', watchdog)
        self.assertIn('rm -rf "$base"', watchdog)
        self.assertIn('2>&1 < /dev/null &', fake.scripts[arm_index])

        # Every remote script was passed as one shlex.quote(script) argument.
        for call, script in zip(fake.calls, fake.scripts):
            self.assertEqual(call[-1], shlex.quote(script))

    def test_release_script_puts_http_proxy_zero_before_snapshot_restore(self):
        fake = FakeAdb()
        lease = self.make_lease(fake)
        lease.activate()
        self.addCleanup(lease.release)
        watchdog = lease._watchdog_script()
        reset = "timeout 2 settings put global http_proxy :0"
        self.assertLess(watchdog.index(reset),
                        watchdog.index("settings delete global global_http_proxy_host"))
        self.assertIn("global_http_proxy_exclusion_list", watchdog)
        self.assertIn("global_proxy_pac_url", watchdog)

    def test_restore_failure_is_unverified_and_keeps_watchdog(self):
        fake = FakeAdb()
        lease = self.make_lease(fake)
        lease.activate()
        fake.fail_release = True

        result = lease.release()

        self.assertEqual(result.status, "unverified")
        self.assertFalse(result.restored)
        self.assertTrue(result.watchdog_retained)

    def test_external_proxy_change_is_preserved_without_zero_request(self):
        fake = FakeAdb()
        lease = self.make_lease(fake)
        lease.activate()
        fake.values["http_proxy"] = "10.0.0.2:8888"
        before = dict(fake.values)

        result = lease.release()

        self.assertEqual(result.status, "external_change")
        self.assertFalse(result.restored)
        self.assertFalse(result.watchdog_retained)
        self.assertEqual(fake.values["http_proxy"], "10.0.0.2:8888")
        self.assertEqual(fake.values, before)

    def test_no_adb_reconnect_is_attempted(self):
        fake = FakeAdb()
        lease = self.make_lease(fake)
        lease.activate()
        lease.release()
        self.assertFalse(any("kill-server" in script or "connect " in script
                             for script in fake.scripts))


class ShellRollbackTests(unittest.TestCase):
    """Run generated POSIX shell with an in-memory Settings function, not ADB."""

    def run_rollback(self, changes=None, *, snapshot=None, ignored_key="",
                     fail_zero=False, suffix=""):
        lease = AndroidProxyLease(lambda _: "", "mock", proxy_port=39123)
        lease.snapshot = {key: None for key in PROXY_KEYS}
        if snapshot:
            lease.snapshot.update(snapshot)
        values = dict(zip(PROXY_KEYS, (lease.endpoint, "127.0.0.1", "39123", "", "")))
        if changes:
            values.update(changes)
        initializers = "\n".join(
            f"s{i}={shlex.quote('null' if values[key] is None else values[key])}"
            for i, key in enumerate(PROXY_KEYS))
        cases = "\n".join(
            f'''        get:{key}) printf '%s\\n' "$s{i}" ;;
        put:{key}) [ "$ignored" = "$key" ] || s{i}="$4" ;;
        delete:{key}) [ "$ignored" = "$key" ] || s{i}=null ;;'''
            for i, key in enumerate(PROXY_KEYS))
        script = initializers + f"""
ignored={shlex.quote(ignored_key)}
fail_zero={int(fail_zero)}
runtime=owned
timeout() {{ shift; "$@"; }}
sleep() {{ :; }}
settings() {{
    key=$3
    if [ "$1" != get ]; then
        printf '%s:%s:%s\\n' "$1" "$key" "$4" >&2
        if [ "$1:$key:$4" = put:http_proxy::0 ]; then
            if [ "$fail_zero" = 1 ]; then fail_zero=0; return 1; fi
            runtime=clear
            s1=; s2=0; s3=; s4=
        fi
    fi
    case "$1:$key" in
{cases}
        *) return 1 ;;
    esac
}}
""" + lease._device_functions() + """
reset_sent=0
outcome=
if rollback; then rc=0; else rc=$?; fi
printf 'RC=%s OUTCOME=%s RUNTIME=%s\\n' "$rc" "$outcome" "$runtime"
read_state
printf 'VALUES=<%s>|<%s>|<%s>|<%s>|<%s>\\n' "$v0" "$v1" "$v2" "$v3" "$v4"
""" + suffix
        result = subprocess.run(["sh", "-s"], input=script, text=True,
                                capture_output=True, timeout=5, check=True)
        return result

    def test_empty_exclusion_and_pac_restore_and_notify_before_deleting(self):
        result = self.run_rollback()
        self.assertIn("RC=0 OUTCOME=RESTORED RUNTIME=clear", result.stdout)
        self.assertIn("VALUES=<null>|<null>|<null>|<null>|<null>", result.stdout)
        writes = result.stderr.splitlines()
        self.assertEqual(writes[0], "put:http_proxy::0")
        self.assertIn("delete:global_http_proxy_host:", writes)
        self.assertIn("delete:global_proxy_pac_url:", writes)

    def test_canonical_residue_with_absent_legacy_is_still_rolled_back(self):
        result = self.run_rollback({"http_proxy": None})
        self.assertIn("OUTCOME=RESTORED", result.stdout)
        self.assertEqual(result.stderr.splitlines()[0], "put:http_proxy::0")

    def test_every_external_proxy_field_is_preserved(self):
        changes = {
            "http_proxy": "other:3128",
            "global_http_proxy_host": "other",
            "global_http_proxy_port": "3128",
            "global_http_proxy_exclusion_list": "user.example",
            "global_proxy_pac_url": "https://user.example/proxy.pac",
        }
        for key, value in changes.items():
            with self.subTest(key=key):
                result = self.run_rollback({key: value})
                self.assertIn("OUTCOME=EXTERNAL", result.stdout)
                self.assertEqual(result.stderr, "")

    def test_silent_canonical_restore_failure_cannot_pass_legacy_verification(self):
        result = self.run_rollback(ignored_key="global_http_proxy_host")
        self.assertIn("RC=1 OUTCOME=", result.stdout)
        self.assertNotIn("OUTCOME=RESTORED", result.stdout)

    def test_failed_zero_notification_is_not_reported_restored(self):
        result = self.run_rollback(fail_zero=True)
        self.assertIn("RC=1 OUTCOME= RUNTIME=owned", result.stdout)
        self.assertEqual(result.stderr.splitlines(), ["put:http_proxy::0"])

    def test_exact_empty_null_snapshot_and_single_zero_notification(self):
        snapshot = dict(zip(PROXY_KEYS, (":0", "", "0", "", None)))
        result = self.run_rollback(snapshot=snapshot)
        self.assertIn("VALUES=<:0>|<>|<0>|<>|<null>", result.stdout)
        self.assertEqual(result.stderr.count("put:http_proxy::0"), 1)

    def test_generated_watchdog_and_request_scripts_parse_as_shell(self):
        scripts = []
        lease = AndroidProxyLease(lambda _: "", "mock", proxy_port=39123)
        lease.snapshot = {key: None for key in PROXY_KEYS}
        lease._shell = lambda script: scripts.append(script) or "ARMED"
        lease._arm()
        lease._request("activate")
        lease._request("release")
        scripts.append(lease._watchdog_script())
        for script in scripts:
            result = subprocess.run(["sh", "-n"], input=script, text=True,
                                    capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_actual_adbd_rejoin_executes_entire_script_without_injection(self):
        def local_adbd(argv):
            return subprocess.run(["sh", "-c", " ".join(argv[4:])],
                                  text=True, capture_output=True, timeout=5,
                                  check=True)
        lease = AndroidProxyLease(local_adbd, "mock", proxy_port=39123)
        value = "space ' ; $(exit 99) \n second line"
        self.assertEqual(lease._shell("printf '%s' " + shlex.quote(value)), value)
        with tempfile.TemporaryDirectory(prefix="proxy ' test ") as root:
            lease.remote_dir = root
            Path(root, "ready").touch()
            Path(root, "active").touch()
            self.assertEqual(lease._request("activate"), "ACTIVE")


class FailureTests(unittest.TestCase):
    def test_each_meaningful_setting_refuses_takeover(self):
        values = ("host:8080", "host", "8080", "exclude.example",
                  "https://proxy.example/a.pac")
        for key, value in zip(PROXY_KEYS, values):
            fake = FakeAdb({key: value})
            lease = AndroidProxyLease(fake, "mock", proxy_port=39123)
            with self.subTest(key=key), self.assertRaises(ExistingProxyError):
                lease.activate()
            self.assertFalse(any("nohup" in script for script in fake.scripts))

    def test_dirty_snapshot_is_refused_before_arming(self):
        for dirty in ("null\nwarning", " null", "null\x00", "null\n\n"):
            fake = FakeAdb({"http_proxy": dirty})
            lease = AndroidProxyLease(fake, "mock", proxy_port=39123)
            with self.subTest(dirty=dirty), self.assertRaises(ProxyLeaseError):
                lease.activate()

    def test_transport_failure_on_release_keeps_watchdog_unverified(self):
        fake = FakeAdb()
        lease = AndroidProxyLease(fake, "mock", proxy_port=39123)
        fake.lease = lease
        lease.activate()
        lease.cmd = lambda _: (_ for _ in ()).throw(ConnectionError("offline"))
        result = lease.release()
        self.assertFalse(result.ok)
        self.assertFalse(result.restored)
        self.assertTrue(result.watchdog_retained)

    def test_failed_heartbeat_stops_further_device_calls(self):
        fake = FakeAdb()
        lease = AndroidProxyLease(fake, "mock", proxy_port=39123)
        fake.lease = lease
        lease.activate()
        lease._heartbeat_error = ConnectionError("offline")
        before = len(fake.calls)
        result = lease.release()
        self.assertEqual(len(fake.calls), before)
        self.assertTrue(result.watchdog_retained)

    def test_all_keys_are_independently_verified_after_daemon_receipt(self):
        fake = FakeAdb()
        lease = AndroidProxyLease(fake, "mock", proxy_port=39123)
        fake.lease = lease
        lease.activate()
        original = lease._request

        def request_with_residue(action):
            status = original(action)
            fake.values["global_http_proxy_port"] = "39091"
            return status

        with patch.object(lease, "_request", side_effect=request_with_residue):
            result = lease.release()
        self.assertFalse(result.ok)
        self.assertFalse(result.restored)
        self.assertIn("all-key snapshot verification", result.message)


if __name__ == "__main__":
    unittest.main()
