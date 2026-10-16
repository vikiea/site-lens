"""Unit tests for the risk-tier validation planner and strict device guard."""

from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parent))

import run_android_acceptance as acceptance
import validation_runner as runner_module
from validation_runner import (
    DeviceConnectionError,
    StagePlan,
    build_plan,
    cache_key,
    classify_paths,
    execute_plan,
    manual_evidence_template,
    preflight_tcp_device,
)


class ValidationPlannerTests(unittest.TestCase):
    def test_docs_are_l0(self):
        level, reasons = classify_paths(["README.md", "docs/support.md"])
        self.assertEqual(level, "L0")
        self.assertTrue(reasons)

    def test_pigeon_is_l2(self):
        level, _ = classify_paths(["pigeons/web_host.dart"])
        self.assertEqual(level, "L2")

    def test_acceptance_tooling_is_l3(self):
        level, _ = classify_paths(["tool/run_android_acceptance.py"])
        self.assertEqual(level, "L3")

    def test_web_assets_are_l2(self):
        level, _ = classify_paths(["web_assets/userscript_runtime.js"])
        self.assertEqual(level, "L2")

    def test_browser_controller_is_l2(self):
        level, _ = classify_paths(["lib/ui/app_controller.dart"])
        self.assertEqual(level, "L2")

    def test_release_configuration_is_l4(self):
        level, _ = classify_paths(["android/app/build.gradle.kts"])
        self.assertEqual(level, "L4")

    def test_explicit_level_is_preserved(self):
        plan = build_plan(["README.md"], requested_level="L2", device="emulator-5554")
        self.assertEqual(plan.recommended_level, "L0")
        self.assertEqual(plan.requested_level, "L2")
        self.assertTrue(any(stage.requires_device for stage in plan.stages))
        self.assertTrue(
            any(
                stage.command
                and any("run_android_acceptance.py" in token for token in stage.command)
                for stage in plan.stages
            )
        )

    def test_cache_reuses_a_successful_l1_stage(self):
        plan = build_plan(["lib/domain/models.dart"], requested_level="L1")
        calls: list[tuple[str, ...]] = []

        def runner(command):
            calls.append(tuple(command))
            return subprocess.CompletedProcess(command, 0, "pass\n", "")

        with tempfile.TemporaryDirectory() as directory:
            first = execute_plan(plan, Path(directory), runner=runner)
            second = execute_plan(plan, Path(directory), runner=runner)

        self.assertEqual(first.exit_code, 0)
        self.assertEqual(second.exit_code, 0)
        self.assertEqual(len(calls), 1)
        self.assertTrue(second.results[0].cache_hit)

    def test_missing_device_keeps_local_evidence_and_blocks_only_device_stage(self):
        plan = build_plan(["pigeons/web_host.dart"], requested_level="L2")

        def runner(command):
            return subprocess.CompletedProcess(command, 0, "pass\n", "")

        with tempfile.TemporaryDirectory() as directory:
            report = execute_plan(plan, Path(directory), runner=runner)

        self.assertEqual(report.exit_code, 2)
        self.assertEqual(report.results[0].status, "passed")
        self.assertEqual(report.results[1].status, "blocked")

    def test_passed_manual_evidence_replaces_required_device_stage(self):
        with tempfile.TemporaryDirectory() as directory:
            evidence_path = Path(directory) / "manual.json"
            plan = build_plan(
                ["pigeons/web_host.dart"],
                requested_level="L2",
                manual_evidence=evidence_path,
            )
            evidence = manual_evidence_template("L2", None, plan.paths)
            evidence["status"] = "passed"
            for check in evidence["checks"]:
                check["passed"] = True
            evidence_path.write_text(json.dumps(evidence))

            calls: list[tuple[str, ...]] = []

            def runner(command):
                calls.append(tuple(command))
                return subprocess.CompletedProcess(command, 0, "pass\n", "")

            report = execute_plan(plan, Path(directory) / "cache", runner=runner)

        self.assertEqual(report.exit_code, 0)
        self.assertEqual(report.results[0].status, "passed")
        self.assertEqual(report.results[1].status, "passed")
        self.assertIn("manual evidence", report.results[1].detail)
        self.assertEqual(len(calls), 1)

    def test_device_preflight_failure_runs_no_stage(self):
        plan = build_plan(["pigeons/web_host.dart"], requested_level="L2", device="emulator-5554")
        runner = Mock(return_value=subprocess.CompletedProcess(["check"], 0, "pass\n", ""))
        with patch.object(
            runner_module,
            "preflight_device",
            side_effect=DeviceConnectionError("device unavailable"),
        ):
            with tempfile.TemporaryDirectory() as directory:
                report = execute_plan(plan, Path(directory), runner=runner)
        self.assertEqual(report.exit_code, 2)
        self.assertEqual(report.results[0].status, "passed")
        self.assertEqual(report.results[1].status, "blocked")
        runner.assert_called_once()

    def test_missing_adb_is_an_environment_failure(self):
        with patch.object(runner_module.shutil, "which", return_value=None):
            with self.assertRaisesRegex(DeviceConnectionError, "adb is unavailable"):
                preflight_tcp_device("192.0.2.10:5555")

    def test_l2_device_stage_is_never_reused_from_cache(self):
        plan = build_plan(["pigeons/web_host.dart"], requested_level="L2", device="emulator-5554")
        device_stage = next(stage for stage in plan.stages if stage.requires_device)
        self.assertFalse(device_stage.cacheable)

    def test_l3_and_l4_without_device_keep_lower_stages(self):
        l3 = build_plan(["integration_test/acceptance_suite_test.dart"], requested_level="L3")
        self.assertEqual(l3.stages[0].name, "full local check")
        self.assertTrue(l3.stages[-1].requires_device)

        l4 = build_plan(["android/app/build.gradle.kts"], requested_level="L4")
        self.assertEqual([stage.name for stage in l4.stages[:2]], ["full local check", "formal APK verification"])
        self.assertTrue(l4.stages[-1].requires_device)

    def test_preflight_has_a_bounded_timeout(self):
        runner = Mock(
            return_value=subprocess.CompletedProcess(["adb"], 0, "device\n", "")
        )
        preflight_tcp_device("192.0.2.10:5555", adb_path="adb", runner=runner)
        self.assertEqual(runner.call_args.kwargs["timeout"], 30)

    def test_preflight_timeout_becomes_device_error(self):
        runner = Mock(side_effect=subprocess.TimeoutExpired(["adb"], 30))
        with self.assertRaisesRegex(DeviceConnectionError, "not online"):
            preflight_tcp_device("emulator-5554", adb_path="adb", runner=runner)

    def test_device_stage_streams_stdout_and_stderr_before_child_exit(self):
        stdout = io.StringIO()
        stderr = io.StringIO()
        progress_seen = threading.Event()
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / 'release'
            command = [
                sys.executable,
                '-c',
                (
                    'import pathlib, sys, time\n'
                    'print("device-progress", flush=True)\n'
                    'print("device-error", file=sys.stderr, flush=True)\n'
                    'marker=pathlib.Path(sys.argv[1])\n'
                    'while not marker.exists():\n'
                    '    time.sleep(0.01)\n'
                ),
                str(marker),
            ]
            result_holder = {}

            def run():
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    result_holder['result'] = runner_module._run_capture(
                        command,
                        stream_output=True,
                        on_output=lambda text, is_stderr: progress_seen.set()
                        if 'device-progress' in text
                        else None,
                    )

            thread = threading.Thread(target=run)
            thread.start()
            self.assertTrue(progress_seen.wait(2), 'device output was not streamed')
            self.assertTrue(thread.is_alive(), 'child exited before streamed output was observed')
            marker.touch()
            thread.join(2)
            self.assertFalse(thread.is_alive(), 'streaming runner did not finish')

        result = result_holder['result']
        self.assertEqual(result.returncode, 0)
        self.assertIn('device-progress', result.stdout)
        self.assertIn('device-error', result.stderr)
        self.assertIn('device-progress', stdout.getvalue())
        self.assertIn('device-error', stderr.getvalue())

    def test_cache_key_includes_complete_worktree_fingerprint(self):
        plan = build_plan(["lib/domain/models.dart"], requested_level="L1")
        stage = StagePlan("full local check", ("./tool/check.sh",))
        with patch.object(runner_module, "worktree_fingerprint", return_value="before"):
            before = cache_key(plan, stage, {})
        with patch.object(runner_module, "worktree_fingerprint", return_value="after"):
            after = cache_key(plan, stage, {})
        self.assertNotEqual(before, after)


class StrictDeviceTests(unittest.TestCase):
    def test_tcp_preflight_restarts_adb_once_and_retries(self):
        runner = Mock(
            side_effect=[
                subprocess.CompletedProcess(["adb"], 1, "", "failed to connect"),
                subprocess.CompletedProcess(["adb"], 0, "device\n", ""),
            ]
        )
        restart = Mock()
        preflight_tcp_device(
            "192.0.2.10:5555",
            adb_path="adb",
            runner=runner,
            recover_adb_once=True,
            restart_runner=restart,
        )
        self.assertEqual(runner.call_count, 2)
        restart.assert_called_once_with("adb", "192.0.2.10:5555")

    def test_tcp_preflight_stops_after_one_failed_recovery(self):
        runner = Mock(
            return_value=subprocess.CompletedProcess(
                ["adb"], 1, "", "failed to connect"
            )
        )
        restart = Mock()
        with self.assertRaisesRegex(DeviceConnectionError, "after one adb-server recovery"):
            preflight_tcp_device(
                "192.0.2.10:5555",
                adb_path="adb",
                runner=runner,
                recover_adb_once=True,
                restart_runner=restart,
            )
        self.assertEqual(runner.call_count, 2)
        restart.assert_called_once_with("adb", "192.0.2.10:5555")

    def test_acceptance_restarts_adb_once_for_unavailable_tcp_endpoint(self):
        with patch.object(acceptance, "device_online", side_effect=[False, True]), patch.object(
            acceptance, "restart_adb_server"
        ) as restart, patch.object(acceptance, "reconnect") as reconnect:
            acceptance.require_device("192.0.2.10:5555")
        restart.assert_called_once_with("192.0.2.10:5555")
        reconnect.assert_not_called()

    def test_acceptance_main_stops_before_any_work_on_bad_tcp_endpoint(self):
        with patch.object(acceptance, "device_online", return_value=False), patch.object(
            acceptance, "restart_adb_server"
        ) as restart, patch.object(acceptance, "run_flutter") as run_flutter, patch.object(
            acceptance, "backup_database"
        ) as backup:
            with patch.object(
                sys,
                "argv",
                ["run_android_acceptance.py", "192.0.2.10:5555", "--skip-check", "--skip-build"],
            ):
                with self.assertRaises(SystemExit) as raised:
                    acceptance.main()
        self.assertEqual(raised.exception.code, 2)
        run_flutter.assert_not_called()
        backup.assert_not_called()
        restart.assert_called_once_with("192.0.2.10:5555")

    def test_tcp_install_failure_is_not_retried(self):
        with tempfile.NamedTemporaryFile() as apk, patch.object(
            acceptance, "verify_apk_package"
        ), patch.object(
            acceptance.subprocess,
            "run",
            side_effect=subprocess.CalledProcessError(1, ["adb"]),
        ) as run, patch.object(acceptance, "reconnect") as reconnect:
            with self.assertRaisesRegex(RuntimeError, "install failed 1x"):
                acceptance.install("192.0.2.10:5555", Path(apk.name), acceptance.PACKAGE)
        run.assert_called_once()
        reconnect.assert_not_called()

    def test_acceptance_adb_probe_has_a_bounded_timeout(self):
        with patch.object(
            acceptance.subprocess,
            "run",
            return_value=subprocess.CompletedProcess(["adb"], 0, b"device\n", b""),
        ) as run:
            acceptance.adb("emulator-5554", "get-state", check=False)
        self.assertEqual(run.call_args.kwargs["timeout"], acceptance.ADB_COMMAND_TIMEOUT_SECONDS)


if __name__ == "__main__":
    unittest.main()
