# Android emulator operating profile

Use this profile for Site Lens L2/L3/L4 validation when an Android emulator is available. Treat it as an operating procedure, not a permanent AVD mutation.

## Recommended profile for a 16 GiB macOS host

- Prefer `sl_g37`: Pixel 6, Android 37, Google APIs, arm64.
- Request `3072` MB with `-memory 3072`. Android 37 may raise the effective minimum to `4096` MB; accept that result and do not increase it further.
- Use `-cores 2` when the host is under memory or CPU pressure.
- Prefer `-gpu host` on Apple silicon. Use `-gpu swiftshader_indirect` only when the host backend fails to start; software rendering can produce long frame stalls in WebView and media tests.
- Use `-no-snapshot -no-snapshot-save -no-boot-anim` for reproducible validation and to avoid stale snapshot state.

Example:

```sh
emulator -avd <avd-name> \
  -memory 3072 \
  -cores 2 \
  -gpu host \
  -no-snapshot \
  -no-snapshot-save \
  -no-boot-anim
```

Record the effective RAM, GPU backend, API level, WebView package/version, emulator serial, and host memory state in the validation report. Do not raise emulator RAM above 4096 MB on a 16 GiB host merely to address a test timeout.

## Startup and live monitoring

Before starting validation, run `make emulator-check EMULATOR_AVD=<avd-name>` or `python3 tool/check_emulator.py --avd <avd-name>`. The one-shot check accepts `--serial` when the ADB serial is already known, `--port` when a fixed emulator console port is needed, and runtime overrides such as `--memory-mb`, `--cores`, `--gpu`, `--timeout`, `--adb`, `--emulator`, and `--log`. Its default startup timeout is 45 seconds. It checks ADB state and `sys.boot_completed=1`; it does not install, back up, or run tests. Before starting validation, check `emulator -list-avds`, the selected AVD `config.ini`, host RAM, and existing emulator/ADB processes. After starting, poll every five seconds until both conditions hold:

```sh
adb devices -l                         # selected serial is present and state is device
adb -s <serial> shell getprop sys.boot_completed  # equals 1
```

Use bounded command timeouts for every ADB shell probe. A probe that hangs is a health signal; do not let monitoring itself block the validation indefinitely.

While a device validation is running, sample every 30–60 seconds:

- `adb devices -l` and `getprop sys.boot_completed`;
- the foreground activity and the Flutter/emulator process state;
- host `memory_pressure`, `vm.swapusage`, and emulator RSS;
- recent `adb logcat` errors when test output stops advancing.

Keep the canonical acceptance runner as the owner of test execution, database backup/restore, and its own test timeout. Monitoring observes and records state; it does not restart the emulator or replay a failed suite automatically.

## Stop conditions

Stop the validation and report the evidence when any of these occurs:

- the emulator disappears from ADB or remains `offline` across two consecutive checks;
- `sys.boot_completed` regresses or ADB shell probes repeatedly time out;
- the test runner has no output progress for five minutes and the monitored process is idle;
- the host enters high memory pressure, available memory falls below roughly 20%, or swap free space falls below 1 GiB;
- the canonical runner reaches its timeout or fails its cleanup/restore step.

On stop, capture the runner output, `/tmp` emulator log, recent logcat, AVD/GPU/RAM configuration, and the retained backup path. Stop the emulator after evidence is collected. Do not report a stopped or timed-out run as passed.

In this repository, a long WebView frame stall or a missing `GM_registerMenuCommand` callback is an integration failure to diagnose with WebView/logcat evidence. Increasing emulator memory is not the default response.
