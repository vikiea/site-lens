# Android emulator and Flutter raster diagnosis

Read this when the app is absent, stuck on Splash, or dies in `libflutter.so`, or when emulator health must be separated from app health.

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
