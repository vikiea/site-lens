#!/usr/bin/env python3
"""Bound the whole native test runner, including VM-service startup (not just test body)."""
import os
import signal
import subprocess
import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("Usage: tool/run_host_contract.py DEVICE_ID")
os.chdir(Path(__file__).resolve().parent.parent)
cmd = ["flutter", "test", "integration_test/host_contract_test.dart", "-d", sys.argv[1], "--dart-define=ALLOW_LOCAL_TEST_PAGES=true"]
proc = subprocess.Popen(cmd, start_new_session=True)
try:
    raise SystemExit(proc.wait(timeout=300))
except subprocess.TimeoutExpired:
    print("FAIL: native runner exceeded 300s (including VM-service startup); no acceptance inferred", file=sys.stderr)
    os.killpg(proc.pid, signal.SIGINT)
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGTERM)
    raise SystemExit(124)
