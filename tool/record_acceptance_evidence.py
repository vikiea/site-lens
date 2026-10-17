#!/usr/bin/env python3
"""Record auditable local/device gate status without claiming device evidence."""

from __future__ import annotations

import argparse
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def run(command: list[str]) -> str:
    try:
        result = subprocess.run(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "unavailable"
    return result.stdout.strip() or result.stderr.strip() or "unavailable"


def render_evidence(
    *,
    revision: str,
    branch: str,
    worktree: str,
    local_status: str,
    device_status: str,
    created_at: str,
) -> str:
    return f"""# Site Lens acceptance evidence

- Recorded at: {created_at}
- Revision: `{revision}`
- Branch: `{branch}`
- Worktree: `{worktree}`
- Local checks: `{local_status}`
- Device preflight: `{device_status}`

## Gates

| Level | Result | Evidence |
| --- | --- | --- |
| L0 | {local_status} | local model, parser and tool checks |
| L1 | {local_status} | `./tool/check.sh` when explicitly recorded |
| L2 | {local_status} | WebView/Pigeon/script/media bridge checks when explicitly recorded |
| L3 | 待验收 | real Android device and lifecycle evidence not inferred from local tests |
| L4 | 待验收 | signed release APK, install smoke test and release identity |

## Cross-module scenarios

- Filter snapshot refresh while current media remains active: {local_status}
- Script disable, GM cancellation and menu cleanup: {local_status}
- Candidate expiry, download recovery and cache reference protection: {local_status}
- Local HLS input, MP4 validation and SAF delivery: {local_status}
- DLNA discovery, SOAP control and Range/HEAD relay: {local_status}
- Credential expiry, network change, disk failure and receiver offline: 待验收

## Limitations

This file records what was checked at the time of creation. It never converts
an absent Android device, DLNA receiver or formal signing environment into a
passing L3/L4 result.
"""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--local-status",
        choices=("通过", "待执行", "blocked"),
        default="待执行",
    )
    args = parser.parse_args()
    status = run(["git", "status", "--porcelain=v1"])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        render_evidence(
            revision=run(["git", "rev-parse", "HEAD"]),
            branch=run(["git", "branch", "--show-current"]),
            worktree="clean" if not status else "uncommitted changes present",
            local_status=args.local_status,
            device_status=run(["adb", "devices"]),
            created_at=datetime.now(timezone.utc).isoformat(),
        )
    )
    print(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
