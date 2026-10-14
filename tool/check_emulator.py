#!/usr/bin/env python3
"""Check that an Android emulator is reachable and fully booted.

The command can observe an already-running emulator or start one AVD when
``--avd`` is supplied. It intentionally does not install an APK or run tests.
"""

from __future__ import annotations

import argparse
import os
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

DEFAULT_TIMEOUT = 45.0
DEFAULT_POLL_INTERVAL = 2.0


@dataclass(frozen=True)
class AdbDevice:
    serial: str
    state: str


def parse_devices(output: str) -> list[AdbDevice]:
    devices: list[AdbDevice] = []
    for line in output.splitlines():
        line = line.strip()
        if not line or line.startswith("List of devices attached"):
            continue
        fields = line.split()
        if len(fields) >= 2:
            devices.append(AdbDevice(fields[0], fields[1]))
    return devices


def emulator_serials(output: str) -> set[str]:
    return {device.serial for device in parse_devices(output) if device.serial.startswith("emulator-")}


def resolve_binary(explicit: str | None, env_name: str, candidates: Sequence[str]) -> str:
    if explicit:
        return explicit
    from_env = os.environ.get(env_name)
    if from_env:
        return from_env
    for candidate in candidates:
        if os.path.isabs(candidate) and os.path.isfile(candidate):
            return candidate
        found = shutil.which(candidate)
        if found:
            return found
    raise FileNotFoundError(f"{env_name.lower()} executable is unavailable")


def run_command(
    command: Sequence[str], *, timeout: float, capture: bool = True
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(command),
        check=False,
        text=True,
        capture_output=capture,
        timeout=timeout,
    )


def adb_devices(adb: str, *, timeout: float = 5.0) -> list[AdbDevice]:
    result = run_command([adb, "devices", "-l"], timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "adb devices failed")
    return parse_devices(result.stdout)


def device_state(adb: str, serial: str, *, timeout: float = 5.0) -> str:
    result = run_command([adb, "-s", serial, "get-state"], timeout=timeout)
    return result.stdout.strip() if result.returncode == 0 else ""


def boot_completed(adb: str, serial: str, *, timeout: float = 5.0) -> str:
    result = run_command(
        [adb, "-s", serial, "shell", "getprop", "sys.boot_completed"],
        timeout=timeout,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


def select_serial(
    devices: Sequence[AdbDevice], requested: str | None, known_serials: set[str]
) -> str | None:
    if requested:
        return requested
    current = [device.serial for device in devices if device.serial.startswith("emulator-")]
    new = sorted(set(current) - known_serials)
    if len(new) == 1:
        return new[0]
    if len(current) == 1:
        return current[0]
    return None


def build_emulator_command(
    emulator: str,
    avd: str,
    *,
    port: int | None,
    memory_mb: int,
    cores: int,
    gpu: str,
) -> list[str]:
    command = [
        emulator,
        "-avd",
        avd,
        "-memory",
        str(memory_mb),
        "-cores",
        str(cores),
        "-gpu",
        gpu,
        "-no-snapshot",
        "-no-snapshot-save",
        "-no-boot-anim",
    ]
    if port is not None:
        command.extend(["-port", str(port)])
    return command


def check_emulator(
    *,
    adb: str,
    serial: str | None,
    avd: str | None,
    emulator: str | None,
    port: int | None,
    timeout: float,
    poll_interval: float,
    log_path: Path | None,
    memory_mb: int,
    cores: int,
    gpu: str,
    runner: Callable[..., subprocess.CompletedProcess[str]] = run_command,
    sleeper: Callable[[float], None] = time.sleep,
) -> tuple[int, str]:
    if timeout <= 0 or poll_interval <= 0:
        return 3, "timeout and poll-interval must be greater than zero"

    try:
        existing = runner([adb, "devices", "-l"], timeout=5.0)
    except FileNotFoundError:
        return 2, f"adb is unavailable: {adb}"
    except subprocess.TimeoutExpired:
        return 2, "adb devices timed out"
    if existing.returncode != 0:
        return 2, existing.stderr.strip() or "adb devices failed"

    devices = parse_devices(existing.stdout)
    known_serials = emulator_serials(existing.stdout)
    selected = serial or select_serial(devices, None, known_serials)
    process: subprocess.Popen[bytes] | None = None
    started = False

    if selected:
        state = device_state(adb, selected)
        boot = boot_completed(adb, selected) if state == "device" else ""
        if state == "device" and boot == "1":
            return 0, f"emulator ready: serial={selected}"

    if avd:
        try:
            emulator_path = resolve_binary(
                emulator,
                "EMULATOR",
                [
                    str(Path(os.environ.get("ANDROID_HOME", "")) / "emulator" / "emulator"),
                    "emulator",
                ],
            )
        except FileNotFoundError as error:
            return 2, str(error)
        target_log = log_path or Path(f"/tmp/site-lens-emulator-{avd}.log")
        target_log.parent.mkdir(parents=True, exist_ok=True)
        log_file = target_log.open("ab")
        command = build_emulator_command(
            emulator_path,
            avd,
            port=port,
            memory_mb=memory_mb,
            cores=cores,
            gpu=gpu,
        )
        try:
            process = subprocess.Popen(
                command,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except OSError as error:
            log_file.close()
            return 2, f"could not start AVD {avd}: {error}"
        log_file.close()
        started = True
        if port is not None and not serial:
            selected = f"emulator-{port}"

    deadline = time.monotonic() + timeout
    last_state = "unavailable"
    last_boot = "?"
    while time.monotonic() < deadline:
        if process is not None and process.poll() is not None:
            message = f"AVD {avd} exited before boot completed"
            return 2, message
        try:
            devices = adb_devices(adb)
        except (RuntimeError, subprocess.TimeoutExpired):
            devices = []
        if not selected:
            selected = select_serial(devices, None, known_serials)
        if selected:
            last_state = device_state(adb, selected)
            last_boot = boot_completed(adb, selected) if last_state == "device" else "?"
            if last_state == "device" and last_boot == "1":
                prefix = "started and ready" if started else "ready"
                return 0, f"emulator {prefix}: serial={selected}"
        sleeper(min(poll_interval, max(0.0, deadline - time.monotonic())))

    if process is not None and process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except OSError:
            process.terminate()
    detail = f"serial={selected or 'undetected'} state={last_state} boot={last_boot}"
    if avd:
        detail += f" avd={avd}"
    return 2, f"emulator startup timeout after {timeout:.0f}s ({detail})"


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Check an Android emulator ADB connection and boot completion."
    )
    result.add_argument("--avd", help="AVD name to start when no ready emulator exists")
    result.add_argument("--serial", help="ADB serial to check, such as emulator-5554")
    result.add_argument(
        "--port", type=int, help="Emulator console port when starting an AVD"
    )
    result.add_argument(
        "--timeout",
        type=float,
        default=DEFAULT_TIMEOUT,
        help=f"startup wait in seconds (default: {DEFAULT_TIMEOUT:g})",
    )
    result.add_argument(
        "--poll-interval",
        type=float,
        default=DEFAULT_POLL_INTERVAL,
        help=f"poll interval in seconds (default: {DEFAULT_POLL_INTERVAL:g})",
    )
    result.add_argument("--adb", help="ADB executable; defaults to $ADB or Android SDK")
    result.add_argument(
        "--emulator", help="emulator executable; defaults to $EMULATOR or Android SDK"
    )
    result.add_argument("--log", type=Path, help="AVD log path when starting an emulator")
    result.add_argument(
        "--memory-mb", type=int, default=3072, help="emulator RAM in MB (default: 3072)"
    )
    result.add_argument(
        "--cores", type=int, default=2, help="emulator CPU cores (default: 2)"
    )
    result.add_argument(
        "--gpu", default="host", help="emulator GPU backend (default: host)"
    )
    result.add_argument(
        "--no-start",
        action="store_true",
        help="only inspect an existing emulator; requires no --avd",
    )
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    if args.no_start and args.avd:
        print("--no-start cannot be combined with --avd", file=sys.stderr)
        return 3
    if args.memory_mb <= 0 or args.cores <= 0:
        print("--memory-mb and --cores must be greater than zero", file=sys.stderr)
        return 3
    try:
        adb = resolve_binary(
            args.adb,
            "ADB",
            [
                str(Path(os.environ.get("ANDROID_HOME", "")) / "platform-tools" / "adb"),
                "adb",
            ],
        )
    except FileNotFoundError as error:
        print(str(error), file=sys.stderr)
        return 2
    code, message = check_emulator(
        adb=adb,
        serial=args.serial,
        avd=None if args.no_start else args.avd,
        emulator=args.emulator,
        port=args.port,
        timeout=args.timeout,
        poll_interval=args.poll_interval,
        log_path=args.log,
        memory_mb=args.memory_mb,
        cores=args.cores,
        gpu=args.gpu,
    )
    stream = sys.stdout if code == 0 else sys.stderr
    print(message, file=stream)
    return code


if __name__ == "__main__":
    raise SystemExit(main())
