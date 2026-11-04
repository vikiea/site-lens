# Android IP:PORT endpoint guard

Read this when validating against an `IP:PORT` Android device endpoint, including a direct `make acceptance DEVICE=IP:PORT` run.

For an `IP:PORT` device, the runner performs one `adb -s IP:PORT get-state` preflight before any build, install, backup, or test. If that preflight fails, restart the local ADB server exactly once with `adb kill-server` followed by `adb start-server`, run `adb connect IP:PORT` once to register the TCP transport, then retry `adb -s IP:PORT get-state` once. Do not call `adb disconnect`, repeat `adb connect`, wait for the device, retry installation, or replay the suite during this recovery step. If the second preflight fails, stop immediately and ask for the correct port.

The same one-restart boundary applies when `make acceptance DEVICE=IP:PORT` is invoked directly, and the report must record whether recovery was attempted and whether the retry passed.
