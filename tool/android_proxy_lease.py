"""Temporary Android global proxy, with a detached device-side rollback owner.

cmd(argv) must return str/bytes stdout (or a checked CompletedProcess), raise on
command failure, impose a finite timeout (20s covers request polling), and never
reconnect ADB. The caller supplies a port already reserved by its proxy; this module does not allocate
ports, change ADB forwards, or start the proxy.

AOSP sources: Settings.Global.GLOBAL_HTTP_PROXY_PAC is "global_proxy_pac_url".
ProxyTracker.loadDeprecatedGlobalHttpProxy/setGlobalProxy explains why deleting
http_proxy does not reset the runtime proxy, and why :0 must precede restoration.
https://android.googlesource.com/platform/frameworks/base/+/refs/heads/main/core/java/android/provider/Settings.java
https://android.googlesource.com/platform/packages/modules/Connectivity/+/refs/heads/main/service/src/com/android/server/connectivity/ProxyTracker.java

The watchdog needs Android sh, nohup, timeout, stat, and /proc/uptime. Activation
fails closed unless it acknowledges readiness. Expiry initiates rollback after
~10s without a heartbeat, or 180s total, even if the host dies. Device shutdown,
denied/stuck Settings services, or concurrent user writes cannot be guaranteed:
Settings has no compare-and-swap, so ownership checks cannot eliminate the final
check/write race. A failed release never claims verified restoration.
"""
from __future__ import annotations

import secrets
import shlex
import subprocess
import threading
from dataclasses import dataclass
from typing import Callable, Sequence


PROXY_KEYS = (
    "http_proxy",
    "global_http_proxy_host",
    "global_http_proxy_port",
    "global_http_proxy_exclusion_list",
    "global_proxy_pac_url",
)
_EMPTY = (None, "")
_CLEAR = (_EMPTY + (":0",), _EMPTY, _EMPTY + ("0",), _EMPTY, _EMPTY)
Command = Callable[[Sequence[str]], str | bytes | subprocess.CompletedProcess]


class ProxyLeaseError(RuntimeError):
    """A failed or refused lease, with any recovery result attached."""

    def __init__(self, message: str, result: LeaseResult | None = None):
        super().__init__(message)
        self.result = result


class ExistingProxyError(ProxyLeaseError):
    """Existing meaningful proxy configuration must be preserved."""


@dataclass(frozen=True)
class LeaseResult:
    status: str
    restored: bool = False
    watchdog_retained: bool = False
    message: str = ""

    @property
    def ok(self) -> bool:
        return self.status == "restored" and self.restored and not self.watchdog_retained


class AndroidProxyLease:
    """Use activate()/release(), or with; errors in __exit__ are not suppressed."""

    HEARTBEAT_INTERVAL = 2
    STALE_AFTER = 10
    MAX_AGE = 180

    def __init__(self, cmd: Command, device: str, adb: str = "adb", *,
                 proxy_port: int):
        if not device or not adb:
            raise ValueError("device and adb are required")
        if type(proxy_port) is not int or not 1 <= proxy_port <= 65535:
            raise ValueError("proxy_port must be an integer in 1..65535")
        self.cmd, self.device, self.adb = cmd, device, adb
        self.proxy_port = proxy_port
        self.endpoint = f"127.0.0.1:{proxy_port}"
        self.remote_dir = "/data/local/tmp/site-lens-proxy-" + secrets.token_hex(16)
        self.snapshot: dict[str, str | None] | None = None
        self.last_result: LeaseResult | None = None
        self._armed = False
        self._used = False
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._heartbeat_error: Exception | None = None

    def _shell(self, script: str) -> str:
        # adbd rejoins argv into a shell command. The whole sh -c argument needs
        # one additional quote layer even though the host callback uses argv.
        result = self.cmd([self.adb, "-s", self.device, "shell", "sh", "-c",
                           shlex.quote(script)])
        if isinstance(result, subprocess.CompletedProcess):
            result.check_returncode()
            result = result.stdout
        if isinstance(result, bytes):
            result = result.decode("utf-8", errors="strict")
        if not isinstance(result, str):
            raise ProxyLeaseError("cmd must return captured stdout, not None")
        return result

    def _read_snapshot(self) -> dict[str, str | None]:
        result = {}
        for key in PROXY_KEYS:
            raw = self._shell(shlex.join(["settings", "get", "global", key]))
            # Remove only transport line endings; reject diagnostics, whitespace,
            # controls and multiline output instead of persisting dirty output.
            value = raw.removesuffix("\n").removesuffix("\r")
            if (len(value) > 2048 or value != value.strip()
                    or any(ord(c) < 32 or ord(c) == 127 for c in value)):
                raise ProxyLeaseError(f"unclean settings output for {key}")
            result[key] = None if value == "null" else value
        return result

    @staticmethod
    def _occupied_keys(values: dict[str, str | None]) -> list[str]:
        return [key for key, clear in zip(PROXY_KEYS, _CLEAR)
                if values[key] not in clear]

    def _is_owned(self, values: dict[str, str | None]) -> bool:
        legacy, host, port, exclusion, pac = (values[k] for k in PROXY_KEYS)
        # Permit the framework's empty strings, absent settings, and a missing
        # legacy key with canonical residue. Refuse every conflicting field.
        return (
            legacy in (*_CLEAR[0], self.endpoint)
            and host in (*_EMPTY, "127.0.0.1")
            and port in (*_CLEAR[2], str(self.proxy_port))
            and exclusion in _EMPTY and pac in _EMPTY
            and (legacy == self.endpoint
                 or (host == "127.0.0.1" and port == str(self.proxy_port)))
        )

    def _device_functions(self) -> str:
        """Shared daemon functions; also executed with mock settings in tests."""
        if self.snapshot is None:
            raise ProxyLeaseError("missing proxy snapshot")
        q = shlex.quote
        reads = "\n".join(
            f"    v{i}=$(timeout 2 settings get global {q(key)}) || return 1"
            for i, key in enumerate(PROXY_KEYS)
        )
        exact = " && ".join(
            f'[ "$v{i}" = {q("null" if self.snapshot[key] is None else self.snapshot[key])} ]'
            for i, key in enumerate(PROXY_KEYS)
        )
        # Restore canonical fields before legacy; don't write a second :0 if the
        # snapshot already had :0, as that could trigger an asynchronous rewrite.
        restores = []
        for i in (*range(1, len(PROXY_KEYS)), 0):
            key, value = PROXY_KEYS[i], self.snapshot[PROXY_KEYS[i]]
            expected = "null" if value is None else value
            args = ["timeout", "2", "settings",
                    "delete" if value is None else "put", "global", key]
            if value is not None:
                args.append(value)
            restores.append(f"""
    read_state || return 1
    if ! clear_state; then outcome=EXTERNAL; return 0; fi
    if [ "$v{i}" != {q(expected)} ]; then
        {shlex.join(args)} >/dev/null || return 1
    fi""")
        return f"""
base={q(self.remote_dir)}
endpoint={q(self.endpoint)}
port={q(str(self.proxy_port))}
read_state() {{
{reads}
    for value in "$v0" "$v1" "$v2" "$v3" "$v4"; do
        case "$value" in *[[:space:]]*) return 1 ;; esac
    done
}}
snapshot_matches() {{ {exact}; }}
empty() {{ [ "$1" = null ] || [ -z "$1" ]; }}
clear_state() {{
    case "$v0" in ''|null|:0) ;; *) return 1 ;; esac
    empty "$v1" && {{ empty "$v2" || [ "$v2" = 0 ]; }} &&
        empty "$v3" && empty "$v4"
}}
owned() {{
    case "$v0" in ''|null|:0|"$endpoint") ;; *) return 1 ;; esac
    case "$v1" in ''|null|127.0.0.1) ;; *) return 1 ;; esac
    case "$v2" in ''|null|0|"$port") ;; *) return 1 ;; esac
    empty "$v3" && empty "$v4" || return 1
    [ "$v0" = "$endpoint" ] ||
        {{ [ "$v1" = 127.0.0.1 ] && [ "$v2" = "$port" ]; }}
}}
active() {{
    [ "$v0" = "$endpoint" ] && [ "$v1" = 127.0.0.1 ] &&
        [ "$v2" = "$port" ] && empty "$v3" && empty "$v4"
}}
rollback() {{
    read_state || return 1
    if [ "$reset_sent" = 0 ]; then
        if ! owned; then outcome=EXTERNAL; return 0; fi
        # The same process owns activation and rollback, including mid-write
        # failures. No host/daemon race or PID-based killing is necessary.
        timeout 2 settings put global http_proxy :0 >/dev/null || return 1
        reset_sent=1
    fi
    i=0
    while [ "$i" -lt 5 ]; do
        read_state || return 1
        clear_state && break
        if ! owned; then outcome=EXTERNAL; return 0; fi
        i=$((i + 1))
        sleep 1
    done
    clear_state || return 1
{''.join(restores)}
    read_state || return 1
    snapshot_matches || return 1
    outcome=RESTORED
}}
uptime_seconds() {{
    read ticks ignored < /proc/uptime || return 1
    printf '%s\\n' "$ticks" | cut -d. -f1
}}
finish() {{
    printf '%s\\n' "$outcome" > "$base/result"
    # Leave a brief receipt for a connected host, then clean up autonomously.
    n=0
    while [ ! -e "$base/ack" ] && [ "$n" -lt 4 ]; do
        sleep 1
        n=$((n + 1))
    done
    rm -rf "$base"
    exit 0
}}
"""

    def _watchdog_script(self) -> str:
        return self._device_functions() + f"""
# A failed prerequisite or changed snapshot must never mutate proxy settings.
trap 'rm -rf "$base"' EXIT
for required in timeout stat cut settings; do
    command -v "$required" >/dev/null || exit 1
done
started=$(uptime_seconds) || exit 1
stamp=$(stat -c %Y "$base/heartbeat") || exit 1
last_seen=$started
read_state || exit 1
snapshot_matches || exit 1
reset_sent=0
engaged=0
releasing=0
printf '%s\\n' READY > "$base/ready"
trap - EXIT
while :; do
    now=$(uptime_seconds) || {{ now=$started; releasing=1; }}
    current_stamp=$(stat -c %Y "$base/heartbeat" 2>/dev/null) || current_stamp=missing
    if [ "$current_stamp" != missing ] && [ "$current_stamp" != "$stamp" ]; then
        stamp=$current_stamp
        last_seen=$now
    fi
    if [ -e "$base/release" ] ||
            [ $((now - last_seen)) -ge {self.STALE_AFTER} ] ||
            [ $((now - started)) -ge {self.MAX_AGE} ]; then
        releasing=1
    fi
    if [ "$releasing" = 1 ]; then
        touch "$base/stopping"
        if [ "$engaged" = 0 ]; then
            outcome=UNTOUCHED
            finish
        fi
        if rollback; then finish; fi
        # A failed Settings call leaves the watchdog alive to retry rollback.
        # No receipt claims success until all five raw values verify.
    elif [ "$engaged" = 0 ] && [ -e "$base/activate" ]; then
        if ! read_state; then releasing=1; continue; fi
        if ! snapshot_matches; then outcome=EXTERNAL; finish; fi
        engaged=1
        if timeout 2 settings put global http_proxy "$endpoint" >/dev/null; then
            i=0
            while [ "$i" -lt 4 ]; do
                read_state || break
                if active; then printf '%s\\n' ACTIVE > "$base/active"; break; fi
                owned || break
                i=$((i + 1))
                sleep 1
            done
        fi
        if [ ! -e "$base/active" ]; then releasing=1; fi
    fi
    sleep 1
done
"""

    def _arm(self) -> None:
        q = shlex.quote
        # Mark before dispatch: a timeout can occur after nohup successfully ran.
        self._armed = True
        script = f"""
umask 077
base={q(self.remote_dir)}
command -v nohup >/dev/null || exit 1
mkdir "$base" || exit 1
trap 'rm -rf "$base"' EXIT
printf '%s\\n' {q(self._watchdog_script())} > "$base/watchdog.sh" || exit 1
touch "$base/heartbeat" || exit 1
nohup sh "$base/watchdog.sh" > "$base/watchdog.log" 2>&1 < /dev/null &
trap - EXIT
i=0
while [ "$i" -lt 5 ]; do
    if [ -e "$base/ready" ]; then printf '%s\\n' ARMED; exit 0; fi
    sleep 1
    i=$((i + 1))
done
printf '%s\\n' ARM_FAILED
"""
        if self._shell(script).strip() != "ARMED":
            raise ProxyLeaseError("device watchdog did not acknowledge readiness")

    def _request(self, action: str) -> str:
        if action not in ("activate", "release"):
            raise ValueError("invalid lease action")
        q = shlex.quote
        # The daemon acknowledges shutdown only after the host reads its receipt.
        # Heartbeat and requests never recreate a removed lease directory.
        return self._shell(f"""
base={q(self.remote_dir)}
[ -e "$base/ready" ] || {{ printf '%s\\n' MISSING; exit 0; }}
touch "$base/{action}" || exit 1
i=0
while [ "$i" -lt 12 ]; do
    if [ -e "$base/result" ]; then
        result=$(cat "$base/result") || exit 1
        touch "$base/ack" || exit 1
        n=0
        while [ -d "$base" ] && [ "$n" -lt 3 ]; do
            sleep 1
            n=$((n + 1))
        done
        [ ! -d "$base" ] || {{ printf '%s\\n' PENDING; exit 0; }}
        printf '%s\\n' "$result"
        exit 0
    fi
    {('[ -e "$base/active" ] && { printf "%s\\\\n" ACTIVE; exit 0; }' if action == "activate" else ':')}
    sleep 1
    i=$((i + 1))
done
printf '%s\\n' PENDING
""").strip()

    def heartbeat(self) -> None:
        """Refresh once; no retry, reconnect, or recreation after expiry."""
        output = self._shell(
            f"[ -e {shlex.quote(self.remote_dir + '/ready')} ] && "
            f"[ ! -e {shlex.quote(self.remote_dir + '/stopping')} ] && "
            f"touch {shlex.quote(self.remote_dir + '/heartbeat')} && printf OK"
        )
        if output != "OK":
            raise ProxyLeaseError("watchdog is no longer ready")

    def _heartbeat_loop(self) -> None:
        while not self._stop.wait(self.HEARTBEAT_INTERVAL):
            try:
                self.heartbeat()
            except Exception as exc:
                self._heartbeat_error = exc
                self._stop.set()
                return

    def _stop_heartbeat(self) -> bool:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=3)
            if self._thread.is_alive():
                return False
        return True

    def activate(self) -> AndroidProxyLease:
        if self._used:
            raise ProxyLeaseError("lease instances are single-use")
        self._used = True
        self.snapshot = self._read_snapshot()
        occupied = self._occupied_keys(self.snapshot)
        if occupied:
            raise ExistingProxyError("refusing existing proxy settings: " + ", ".join(occupied))
        try:
            self._arm()
            self.heartbeat()
            self._thread = threading.Thread(
                target=self._heartbeat_loop, daemon=True,
                name="android-proxy-heartbeat")
            self._thread.start()
            # Only the acknowledged detached daemon mutates settings.
            status = self._request("activate")
            if status != "ACTIVE":
                raise ProxyLeaseError(f"device activation returned {status}")
        except Exception as exc:
            result = self.release()
            raise ProxyLeaseError(f"proxy activation failed: {exc}; {result.message}",
                                  result) from exc
        return self

    def release(self) -> LeaseResult:
        """Request rollback; never return success without all-key verification."""
        if self.last_result is not None:
            return self.last_result
        if not self._armed:
            return LeaseResult("inactive")
        if not self._stop_heartbeat() or self._heartbeat_error is not None:
            self.last_result = LeaseResult(
                "unverified", watchdog_retained=True,
                message="heartbeat failed or is blocked; device watchdog left armed")
            return self.last_result
        try:
            status = self._request("release")
            if status in ("RESTORED", "UNTOUCHED", "EXTERNAL"):
                self._armed = False
                if status == "RESTORED":
                    # A daemon receipt and a fresh independent all-key read.
                    if self._read_snapshot() != self.snapshot:
                        raise ProxyLeaseError("all-key snapshot verification failed")
                    result = LeaseResult("restored", restored=True)
                else:
                    result = LeaseResult("external_change" if status == "EXTERNAL" else "inactive",
                                         message="current proxy preserved" if status == "EXTERNAL" else "")
            else:
                result = LeaseResult("unverified", watchdog_retained=True,
                                     message=f"device rollback returned {status}")
        except Exception as exc:
            result = LeaseResult("unverified", watchdog_retained=self._armed,
                                 message=f"restoration unverified: {exc}")
        self.last_result = result
        return result

    close = release

    def __enter__(self) -> AndroidProxyLease:
        return self.activate()

    def __exit__(self, exc_type, exc_value, traceback) -> bool:
        result = self.release()
        if not result.ok:
            message = f"proxy release {result.status}: {result.message}"
            if exc_value is not None:
                exc_value.add_note(message)
            else:
                raise ProxyLeaseError(message, result)
        return False
