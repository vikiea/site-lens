#!/usr/bin/env python3
import subprocess
import unittest
from unittest.mock import patch

import check_emulator


class CheckEmulatorTests(unittest.TestCase):
    def test_parse_devices_and_filter_emulators(self):
        devices = check_emulator.parse_devices(
            "List of devices attached\n"
            "emulator-5554\tdevice product:sdk_gphone\n"
            "R58M123\toffline usb:1-1\n"
        )
        self.assertEqual(
            devices,
            [
                check_emulator.AdbDevice("emulator-5554", "device"),
                check_emulator.AdbDevice("R58M123", "offline"),
            ],
        )
        self.assertEqual(
            check_emulator.emulator_serials("emulator-5554\tdevice\n"),
            {"emulator-5554"},
        )

    def test_build_command_exposes_avd_and_runtime_profile(self):
        command = check_emulator.build_emulator_command(
            "/sdk/emulator",
            "pixel_api_35",
            port=5560,
            memory_mb=3584,
            cores=3,
            gpu="swiftshader_indirect",
        )
        self.assertEqual(command[:3], ["/sdk/emulator", "-avd", "pixel_api_35"])
        self.assertIn("3584", command)
        self.assertIn("3", command)
        self.assertIn("swiftshader_indirect", command)
        self.assertEqual(command[-2:], ["-port", "5560"])

    def test_ready_requested_serial_returns_without_starting(self):
        def runner(command, **_):
            return subprocess.CompletedProcess(
                command, 0, "List of devices attached\nemulator-5560\tdevice\n", ""
            )

        with patch.object(
            check_emulator, "device_state", return_value="device"
        ), patch.object(
            check_emulator, "boot_completed", return_value="1"
        ), patch.object(check_emulator.subprocess, "Popen") as popen:
            code, message = check_emulator.check_emulator(
                adb="adb",
                serial="emulator-5560",
                avd=None,
                emulator=None,
                port=None,
                timeout=45,
                poll_interval=2,
                log_path=None,
                memory_mb=3072,
                cores=2,
                gpu="host",
                runner=runner,
            )
        self.assertEqual(code, 0)
        self.assertIn("serial=emulator-5560", message)
        popen.assert_not_called()

    def test_invalid_timeout_is_configuration_error(self):
        code, message = check_emulator.check_emulator(
            adb="adb",
            serial=None,
            avd=None,
            emulator=None,
            port=None,
            timeout=0,
            poll_interval=2,
            log_path=None,
            memory_mb=3072,
            cores=2,
            gpu="host",
        )
        self.assertEqual(code, 3)
        self.assertIn("greater than zero", message)

    def test_default_timeout_is_45_seconds(self):
        args = check_emulator.parser().parse_args([])
        self.assertEqual(args.timeout, 45.0)


if __name__ == "__main__":
    unittest.main()
