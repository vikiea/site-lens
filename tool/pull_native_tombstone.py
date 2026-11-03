#!/usr/bin/env python3
"""Pull private native tombstones and crash-buffer evidence from an Android device.

The command is intentionally read-only on the device. It copies protobuf bytes
without decoding them as text, then writes metadata and logcat evidence beside
the copy for later symbolized analysis.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import re
import tempfile


def adb(serial: str, *args: str, check: bool = True) -> bytes:
    command = ["adb", "-s", serial, *args]
    completed = subprocess.run(
        command,
        check=check,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    return completed.stdout


def run_as(serial: str, package: str, command: str) -> bytes:
    return adb(serial, "exec-out", "run-as", package, "sh", "-c", command)


def dropbox_records(text: str, package: str) -> list[dict[str, str]]:
    records = []
    for raw in text.split("========================================"):
        if f"Process: {package}" not in raw and f"Package: {package} " not in raw:
            continue
        timestamp = re.search(r"^Timestamp: (.+)$", raw, re.MULTILINE)
        pid = re.search(r"^PID: (\d+)$", raw, re.MULTILINE)
        records.append(
            {
                "timestamp": timestamp.group(1).strip() if timestamp else "",
                "pid": pid.group(1) if pid else "",
                "text": raw.strip(),
            }
        )
    return records


def timestamp_prefix(timestamp: str) -> bytes:
    # Tombstone protobuf strings retain the local timestamp through seconds;
    # fractional precision and timezone formatting may differ by provider.
    return timestamp[:19].encode("utf-8") if len(timestamp) >= 19 else b""


def verified_tombstone(
    data: bytes,
    package: str,
    timestamp: str,
) -> bool:
    if len(data) < 128 or package.encode("utf-8") not in data:
        return False
    prefix = timestamp_prefix(timestamp)
    return not prefix or prefix in data


def verified_tombstone_text(
    text: str,
    package: str,
    pid: str,
    timestamp: str,
) -> bool:
    return (
        f"Cmdline: {package}" in text
        and f"pid: {pid}," in text
        and (not timestamp or timestamp[:19] in text)
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--device", required=True, help="ADB serial, including IP:PORT")
    parser.add_argument("--package", default="dev.vikiea.site_lens")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    adb(args.device, "get-state")
    args.output.mkdir(parents=True, exist_ok=True)
    dropbox = adb(
        args.device,
        "shell",
        "dumpsys",
        "dropbox",
        "--print",
        "data_app_native_crash",
        check=False,
    )
    dropbox_text = dropbox.decode("utf-8", "replace")
    records = dropbox_records(dropbox_text, args.package)
    latest_record = records[-1] if records else {"timestamp": "", "pid": ""}

    run_as_error = None
    try:
        listing = run_as(
            args.device,
            args.package,
            "find no_backup/site_lens_exit_traces -maxdepth 1 -type f -name '*.pb' -print",
        ).decode("utf-8", "replace")
    except subprocess.CalledProcessError as error:
        listing = ""
        run_as_error = error.stdout.decode("utf-8", "replace").strip()
    if "package not debuggable" in listing or "run-as:" in listing:
        run_as_error = listing.strip()
        listing = ""
    files = [
        line.strip()
        for line in listing.splitlines()
        if line.strip().endswith(".pb") and "site_lens_exit_traces" in line
    ]
    copied = []
    for remote in files:
        name = Path(remote).name
        target = args.output / name
        target.write_bytes(run_as(args.device, args.package, f"cat '{remote}'"))
        copied.append(
            {
                "file": name,
                "bytes": target.stat().st_size,
                "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
                "source": "run-as no_backup/site_lens_exit_traces",
            }
        )

    if not copied and latest_record.get("timestamp") and latest_record.get("pid"):
        # A non-debuggable release package cannot expose its private
        # no-backup directory through run-as. Try system protobufs, but accept
        # one only when its bytes identify this package and the selected
        # DropBox crash timestamp. Never treat an adb error or an unrelated
        # newest tombstone as evidence for this process.
        device_listing = adb(
            args.device,
            "shell",
            "ls",
            "-1t",
            "/data/tombstones/tombstone_*.pb",
            check=False,
        ).decode("utf-8", "replace")
        device_files = [
            line.strip()
            for line in device_listing.splitlines()
            if line.strip().endswith(".pb")
        ]
        for remote in device_files[:16]:
            with tempfile.NamedTemporaryFile(
                prefix="site-lens-tombstone-candidate-",
                suffix=".pb",
                dir=args.output,
                delete=False,
            ) as temporary:
                temporary_path = Path(temporary.name)
            try:
                pulled = subprocess.run(
                    ["adb", "-s", args.device, "pull", remote, str(temporary_path)],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )
                if pulled.returncode != 0:
                    continue
                data = temporary_path.read_bytes()
                text_remote = remote.removesuffix(".pb")
                with tempfile.NamedTemporaryFile(
                    prefix="site-lens-tombstone-candidate-",
                    suffix=".txt",
                    dir=args.output,
                    delete=False,
                ) as text_temporary:
                    text_path = Path(text_temporary.name)
                text_pulled = subprocess.run(
                    ["adb", "-s", args.device, "pull", text_remote, str(text_path)],
                    check=False,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                )
                text_value = text_path.read_text(encoding="utf-8", errors="replace") if text_pulled.returncode == 0 else ""
                text_path.unlink(missing_ok=True)
                if not verified_tombstone(
                    data, args.package, latest_record.get("timestamp", "")
                ) or not verified_tombstone_text(
                    text_value,
                    args.package,
                    latest_record.get("pid", ""),
                    latest_record.get("timestamp", ""),
                ):
                    continue
                target = args.output / Path(remote).name
                target.write_bytes(data)
                copied.append(
                    {
                        "file": target.name,
                        "bytes": target.stat().st_size,
                        "sha256": hashlib.sha256(data).hexdigest(),
                        "source": remote,
                        "matchedPid": latest_record.get("pid", ""),
                        "matchedTimestamp": latest_record.get("timestamp", ""),
                        "matchedTextSource": text_remote,
                    }
                )
                break
            finally:
                temporary_path.unlink(missing_ok=True)

    dropbox_files = []
    for index, record in enumerate(records):
        target = args.output / f"dropbox-native-crash-{index:02d}.txt"
        target.write_text(record["text"] + "\n", encoding="utf-8")
        dropbox_files.append(
            {
                "file": target.name,
                "bytes": target.stat().st_size,
                "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
            }
        )
    (args.output / "dropbox-native-crash-all.txt").write_text(
        "\n========================================\n".join(
            record["text"] for record in records
        ) + ("\n" if records else ""),
        encoding="utf-8",
    )
    exit_info = adb(
        args.device,
        "shell",
        "dumpsys",
        "activity",
        "exit-info",
        args.package,
        check=False,
    )
    (args.output / "application-exit-info.txt").write_bytes(exit_info)

    crash_log = adb(args.device, "logcat", "-b", "crash", "-d", check=False).decode(
        "utf-8", "replace"
    )
    (args.output / "logcat-crash.txt").write_text(crash_log, encoding="utf-8")
    metadata = {
        "device": args.device,
        "package": args.package,
        "tombstones": copied,
        "dropboxNativeCrashes": dropbox_files,
        "runAsError": run_as_error,
        "source": (
            copied[0]["source"]
            if copied
            else "dumpsys dropbox data_app_native_crash"
        ),
        "matchedDropBoxCrash": {
            "pid": latest_record.get("pid", ""),
            "timestamp": latest_record.get("timestamp", ""),
        },
        "decoded": False,
    }
    (args.output / "metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(metadata, ensure_ascii=False))
    return 0 if copied or dropbox_files else 2


if __name__ == "__main__":
    sys.exit(main())
