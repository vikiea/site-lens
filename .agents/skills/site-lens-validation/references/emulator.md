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

## App state and Flutter raster diagnosis

Separate emulator health from application health before restarting anything. A Mac lock screen can hide the emulator window, but it does not by itself prove that the ADB transport or Android guest stopped. Check the guest and foreground state first:

```sh
adb devices -l
adb -s <serial> get-state
adb -s <serial> shell getprop sys.boot_completed
adb -s <serial> shell pidof dev.vikiea.site_lens.debug
adb -s <serial> shell dumpsys activity activities | rg 'mResumedActivity|dev.vikiea.site_lens'
adb -s <serial> shell dumpsys window windows | rg 'mCurrentFocus|mFocusedApp'
adb -s <serial> shell dumpsys package dev.vikiea.site_lens.debug | rg 'stopped|lastUpdateTime'
```

Interpret the results in layers:

- `get-state=device`, `sys.boot_completed=1`, a live `qemu-system-*` process, and `mWakefulness=Awake` prove that the emulator and ADB are available. If the launcher is foreground, the app PID is absent, and the package reports `stopped=true`, the app was stopped or the Flutter runner was detached; relaunch the app instead of restarting ADB or the emulator.
- A package being installed does not prove that it is running. Capture a screenshot and the foreground activity before calling a validation run successful; a native Splash screen or the launcher is incomplete evidence.
- `libflutter.so` with `Fatal signal 11 (SIGSEGV)` on a thread named `1.raster` is a Flutter rendering-engine crash. It is a graphics/backend failure after the process starts, distinct from an ADB failure, a Mac lock screen, a Dart exception, or a missing APK. Preserve the surrounding logcat and the emulator GPU/API/ABI details.

Flutter Impeller is enabled by default on Android API 29 and newer. The Android emulator's host-GPU translation layer, Vulkan/OpenGL backend, and multi-pass glass/WebView surfaces can expose engine or driver defects on the raster thread. This class of failure has been reproduced in Flutter's own Android emulator and Impeller issue reports; it is not evidence that the app's database or ADB server is corrupt. Use the current Flutter diagnostics and the crash signature to confirm the classification before changing application code.

For emulator-only validation, use the software-rendering fallback when the Impeller raster path crashes:

```sh
flutter run -d <serial> \
  --enable-software-rendering \
  --no-enable-impeller \
  --no-pub
```

This is a validation workaround and should not silently become the shipped Android renderer policy. Do not use `adb shell am start` as an equivalent test after selecting this fallback: the Flutter CLI supplies the renderer flags through the launch intent, while a direct `am start` uses the APK's default renderer and can reproduce the Impeller crash. For a product-level decision, first reproduce with a minimal Flutter screen, check the current stable Flutter and liquid-glass package versions, then choose a scoped renderer or glass-quality fallback based on the affected backend. Increasing emulator RAM, restarting ADB, or clearing the database does not fix a raster-engine crash by itself.

After a software-rendering run, record that the evidence is emulator-only and that the default Impeller path failed. Keep the two results separate; a successful software-rendering screenshot proves the UI path can run under the fallback, not that the default renderer is healthy.
