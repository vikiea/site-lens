#!/usr/bin/env python3
"""Explicit system-proxy acceptance with prebuilt APKs and device-side rollback.

Ordinary acceptance never invokes this script. It refuses an existing proxy,
keeps unrelated HTTP/HTTPS working, never reconnects ADB, and leaves app backup
and restoration to run_android_acceptance.py. Receipts contain fixture paths
and restoration facts, not unrelated destinations or credentials.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import select
import shlex
import subprocess
import sys
import tempfile
import time

from android_proxy_fixture import FIXTURE_HOST, HTTPS_PHASES, ProxyFixture
from android_proxy_lease import AndroidProxyLease, ExistingProxyError
import run_android_acceptance as acceptance


ROOT = Path(__file__).resolve().parent.parent
MARKER = "PROXY_SYSTEM_DISCOVERY_DOWNLOAD_PASS redirect=landing exactPlaylist=true segmentSha256=true"
NATIVE_MARKER = "PROXY_NATIVE_DIRECT_DOWNLOAD_PASS bytes=115175"
HTTPS_MARKER = ("PROXY_HTTPS_APP_PASS probe=true dartBytes=true nativeTls=true "
                "worker=true bytes=1878")
HTTPS_HLS_MARKER = "PROXY_HTTPS_HLS_PASS segments=2 init=1 keys=0 resourcesSha256=true"
HTTPS_PHASE_MARKERS = tuple(f'PROXY_HTTPS_PHASE_PASS phase={phase} wireBytes=true'
                           for phase in HTTPS_PHASES)


def contract_complete(text):
    return all(marker in text for marker in (MARKER, NATIVE_MARKER, HTTPS_MARKER, HTTPS_HLS_MARKER, *HTTPS_PHASE_MARKERS))
TARGET = "integration_test/modernization_test.dart"


def verify_fixture_contract(fixture):
    required = {"/redirect", "/landing", "/contract.m3u8", "/segment.ts", "/direct.mp4"}
    if not required.issubset(fixture.hits):
        raise RuntimeError("fixture request log incomplete")
    if fixture.https_fixture_connect < 1:
        raise RuntimeError('application HTTPS fixture CONNECT evidence incomplete')
    expected = [(phase, edge) for phase in HTTPS_PHASES for edge in ('before', 'after')]
    records = fixture.https_checkpoints
    if [(row['phase'], row['edge']) for row in records] != expected:
        raise RuntimeError('application HTTPS phase checkpoints incomplete')
    phases = {}
    for before, after in zip(records[::2], records[1::2]):
        sent = after['sentBytes'] - before['sentBytes']
        received = after['receivedBytes'] - before['receivedBytes']
        if sent <= 0 or received <= 0:
            raise RuntimeError(f'application HTTPS {before["phase"]} has no bidirectional proxy traffic')
        phases[before['phase']] = {'sentBytes': sent, 'receivedBytes': received}
    return {
        'probe': True, 'dartFetch': True, 'nativeTlsTransfer': True,
        'nativeWorker': True, 'fixtureConnects': fixture.https_fixture_connect,
        'bytes': 1878, 'phaseTraffic': phases,
        'hls': {'segments': 2, 'initSegments': 1, 'keys': 0, 'resourcesSha256': True,
                'upstreamBytes': 427536},
    }


def adb_command(argv):
    return subprocess.run(argv, check=True, capture_output=True, text=True,
                          timeout=20, env=acceptance.ENV).stdout


def adb(device, *args):
    return adb_command([acceptance.ADB, "-s", device, *args])


def new_lease(device, port):
    return AndroidProxyLease(adb_command, device, acceptance.ADB, proxy_port=port)


def clear_snapshot(device, port):
    lease = new_lease(device, port)
    snapshot = lease._read_snapshot()
    if lease._occupied_keys(snapshot):
        raise ExistingProxyError("existing proxy configuration; refusing test takeover")
    return snapshot


def network_check(device, log):
    with log.open("w") as stream:
        result = subprocess.run(
            ["sh", "tool/fix_android_system_proxy.sh", device, "--check-only",
             "--adb", acceptance.ADB, "--wait", "10"],
            cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
            timeout=120, env=acceptance.ENV,
        )
    if result.returncode:
        raise RuntimeError(f"read-only Internet check failed: {log}")


def wait_for_parent(fd):
    while True:
        ready, _, _ = select.select((fd,), (), (), 1)
        if ready and os.read(fd, 1) == b"":
            return


def lease_child(device, port, parent_fd):
    lease = new_lease(device, port)
    try:
        lease.activate()
        print(json.dumps({"remote_dir": lease.remote_dir}), flush=True)
        wait_for_parent(parent_fd)
    finally:
        lease.release()
        os.close(parent_fd)


def verify_watchdog(device, port, original, *, verify_active=None):
    """Kill only our host child, never adb/adbd or a device process."""
    parent_fd, lifetime_fd = os.pipe()
    try:
        child = subprocess.Popen(
            [sys.executable, "-u", str(Path(__file__).resolve()), device,
             "--lease-child", str(port), "--parent-fd", str(parent_fd)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            cwd=ROOT, env=acceptance.ENV, pass_fds=(parent_fd,),
        )
    except BaseException:
        os.close(lifetime_fd)
        raise
    finally:
        os.close(parent_fd)
    started = time.monotonic()
    remote_dir = None
    try:
        ready, _, _ = select.select([child.stdout], [], [], 35)
        if not ready:
            raise RuntimeError("lease child did not acknowledge activation")
        message = child.stdout.readline()
        if not message:
            raise RuntimeError("lease child exited before activation")
        remote_dir = json.loads(message)["remote_dir"]
        if verify_active is not None:
            verify_active()
        child.kill()
        child.wait(timeout=5)
        print("PROXY_HOST_CHILD_KILLED; awaiting device rollback", flush=True)
        reader = new_lease(device, port)
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            unchanged = reader._read_snapshot() == original
            script = f"if [ -d {shlex.quote(remote_dir)} ]; then printf PRESENT; else printf ABSENT; fi"
            cleaned = adb(device, "shell", "sh", "-c", shlex.quote(script)) == "ABSENT"
            if unchanged and cleaned:
                return {"hostTerminationRollback": True, "allFieldsRestored": True,
                        "deviceWatchdogCleaned": True,
                        "seconds": round(time.monotonic() - started, 2)}
            time.sleep(1)
        raise RuntimeError("device watchdog restoration not verified after host termination")

    finally:
        os.close(lifetime_fd)
        if child.poll() is None:
            try:
                child.wait(timeout=20)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        if child.stdout:
            child.stdout.close()
        if child.stderr:
            child.stderr.close()


def run_suite(device, bundle, output, fixture):
    command = [sys.executable, "-u", "tool/run_android_acceptance.py", device,
               "--single-suite", "--skip-check", "--skip-build", "--no-adb-recovery",
               "--integration-target", TARGET,
               "--prebuilt-product-apk", str(bundle / "product-debug.apk"),
               "--prebuilt-test-apk", str(bundle / "integration-debug.apk"),
               "--prebuilt-manifest", str(bundle / acceptance.PREBUILT_MANIFEST)]
    lease = new_lease(device, fixture.port)
    log = output / "acceptance.log"
    process = None
    receipt = None
    marker_seen = False
    try:
        lease.activate()
        print("PROXY_DEVICE_FIXTURE_ACTIVE", flush=True)
        with log.open("w") as stream:
            process = subprocess.Popen(command, cwd=ROOT, env=acceptance.ENV,
                                       stdout=stream, stderr=subprocess.STDOUT)
            while process.poll() is None:
                text = log.read_text(errors="replace")
                if not marker_seen and contract_complete(text):
                    marker_seen = True
                    receipt = lease.release()
                    print(f"PROXY_RELEASE_AFTER_CONTRACT {receipt.status}", flush=True)
                    if not receipt.ok:
                        raise RuntimeError("proxy restoration unverified; retain backup and inspect device")
                time.sleep(0.5)
            code = process.wait()
        marker_seen = marker_seen or contract_complete(log.read_text(errors="replace"))
        if not marker_seen or code:
            raise RuntimeError(f"proxy acceptance failed (exit={code}, contract={marker_seen}); see {log}")
    finally:
        if receipt is None:
            receipt = lease.release()
        # The canonical runner owns app-data restoration. Let its finally run;
        # don't kill it merely because proxy verification failed.
        if process is not None and process.poll() is None:
            try:
                process.wait(timeout=180)
            except subprocess.TimeoutExpired:
                raise RuntimeError("acceptance remains running; inspect process and retained backup")
        if not receipt.ok:
            raise RuntimeError(f"proxy lease is {receipt.status}; restoration not verified")
    return {"proxyContract": marker_seen, "acceptance": True, "allFieldsRestored": receipt.ok}


def check_tunnel(device, port):
    for scheme in ("http", "https"):
        code = adb(device, "shell", "curl", "--silent", "--show-error", "--location",
                   "--output", "/dev/null", "--write-out", "%{http_code}",
                   "--connect-timeout", "5", "--max-time", "10",
                   "--proxy", f"http://127.0.0.1:{port}",
                   f"{scheme}://connect.rom.miui.com/generate_204").strip()
        if code not in ("200", "204"):
            raise RuntimeError(f"ordinary {scheme.upper()} did not pass through the test proxy")


def restored_or_external(device, port, original, *, timeout=35):
    """Do not tear down a working relay while our proxy is still selected."""
    reader = new_lease(device, port)
    deadline = time.monotonic() + timeout
    query_failed = False
    while True:
        try:
            current = reader._read_snapshot()
        except (OSError, RuntimeError, subprocess.SubprocessError):
            if not query_failed:
                print("PROXY_STATE_UNVERIFIED; relay retained; awaiting endpoint", flush=True)
            query_failed = True
            time.sleep(1)
            continue
        if current == original:
            return True
        if not reader._is_owned(current):
            # A user's new proxy takes precedence; never clear it to match our snapshot.
            return False
        if time.monotonic() >= deadline:
            # Do not repeat the old failure mode: closing the listener while
            # Android still selects it makes all ordinary HTTP/HTTPS fail.
            # The host remains live until the device watchdog (or the user)
            # releases ownership. This is a wait, never a success receipt.
            print("PROXY_RESTORATION_PENDING; relay retained; inspect device", flush=True)
            deadline = time.monotonic() + timeout
        time.sleep(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("device")
    parser.add_argument("--watchdog-only", action="store_true")
    parser.add_argument("--skip-watchdog-check", action="store_true")
    parser.add_argument("--bundle", type=Path)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--lease-child", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--parent-fd", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.lease_child:
        if args.parent_fd is None:
            raise ValueError("lease child requires a parent lifetime pipe")
        lease_child(args.device, args.lease_child, args.parent_fd)
        return 0
    acceptance.require_device(args.device, allow_recovery=False)
    acceptance.ENV.update({"SITE_LENS_PROXY_FIXTURE": "true", "SITE_LENS_TEST_SITES": "",
                           "SITE_LENS_MEDIA_TEST_URL": "", "SITE_LENS_REAL_MEDIA_DOWNLOAD": ""})
    parent = ROOT / "build/android-acceptance"
    parent.mkdir(parents=True, exist_ok=True)
    if args.output_dir:
        output = args.output_dir.resolve()
        if not output.is_relative_to((ROOT / "build").resolve()):
            raise ValueError("output directory must be under build/")
        output.mkdir(parents=True, exist_ok=False)
    else:
        output = Path(tempfile.mkdtemp(prefix="proxy-verified-", dir=parent))
    print(f"PROXY_EVIDENCE {output}", flush=True)
    network_check(args.device, output / "network-before.log")
    bundle = args.bundle.resolve() if args.bundle else output / "apks"
    if not args.watchdog_only:
        if not args.bundle:
            from prepare_android_acceptance import prepare
            prepare(bundle, TARGET, "android-arm64")
        acceptance.validate_prebuilt_apks(bundle / "product-debug.apk", bundle / "integration-debug.apk",
                                          bundle / acceptance.PREBUILT_MANIFEST, TARGET)
    acceptance.require_device(args.device, allow_recovery=False)
    evidence = {"schema": 1}
    with ProxyFixture.from_repository(ROOT) as fixture:
        original = clear_snapshot(args.device, fixture.port)
        port_name = f"tcp:{fixture.port}"
        if any(port_name in line.split() for line in adb(args.device, "reverse", "--list").splitlines()):
            raise RuntimeError("reverse port already owned; refusing replacement")
        adb(args.device, "reverse", "--no-rebind", port_name, port_name)
        try:
            # Confirm the device can reach the reverse listener before changing system policy.
            body = adb(args.device, "shell", "curl", "--silent", "--show-error", "--fail",
                       "--max-time", "10", "--proxy", f"http://127.0.0.1:{fixture.port}",
                       f"http://{FIXTURE_HOST}/landing")
            if body != "proxy-contract-landing":
                raise RuntimeError("device reverse proxy did not return the fixture")
            if not args.skip_watchdog_check:
                evidence["watchdog"] = verify_watchdog(
                    args.device, fixture.port, original,
                    verify_active=lambda: check_tunnel(args.device, fixture.port))
                evidence["httpsTunnelWhileActive"] = True
                evidence["ordinaryHttpWhileActive"] = True
                network_check(args.device, output / "network-after-watchdog.log")
                print("PROXY_WATCHDOG_HOST_TERMINATION_PASS", flush=True)
            if not args.watchdog_only:
                evidence["suite"] = run_suite(args.device, bundle, output, fixture)
                evidence['httpsApp'] = verify_fixture_contract(fixture)
            if new_lease(args.device, fixture.port)._read_snapshot() != original:
                raise RuntimeError("original proxy fields not restored")
            evidence["fixtureHits"] = fixture.hits
            evidence["forwardedHttp"] = fixture.forwarded_http
            evidence["forwardedConnect"] = fixture.forwarded_connect
            network_check(args.device, output / "network-after.log")
            evidence["networkAfter"] = True
            (output / "result.json").write_text(json.dumps(evidence, indent=2) + "\n")
        finally:
            released = restored_or_external(args.device, fixture.port, original)
            if not released:
                print("PROXY_EXTERNAL_CHANGE_PRESERVED", flush=True)
            current = adb(args.device, "reverse", "--list")
            if any(line.split()[-2:] == [port_name, port_name] for line in current.splitlines()):
                adb(args.device, "reverse", "--remove", port_name)
    print(f"PROXY_VERIFICATION_PASS {output / 'result.json'}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"PROXY_VERIFICATION_FAIL: {error}", file=sys.stderr, flush=True)
        raise SystemExit(1)
