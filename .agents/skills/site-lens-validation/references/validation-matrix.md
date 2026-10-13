# Site Lens validation matrix

Use behavior as the primary signal. Use these paths as conservative fallbacks when the behavior cannot be inferred reliably.

| Level | Typical changes | Required evidence |
| --- | --- | --- |
| L0 | Documentation, agent guidance, focused tests, local tooling tests, isolated userscript or contract fixture changes | Targeted `flutter analyze`, selected `flutter test`, Node/Python contract, or userscript validation |
| L1 | Ordinary Dart, UI, network, discovery, script service, database service, dependency, or Makefile changes | `./tool/check.sh` / `make check` |
| L2 | WebView, browser navigation, scripts executing in a page, Pigeon, native host, media bridge, or cross-layer integration | Full local check plus a targeted host contract or protected integration flow when the behavior needs a device |
| L3 | Android lifecycle, database backup/restore, full acceptance, media/system controls, device tooling, or end-to-end user flow | `make acceptance DEVICE=...` on an available emulator or physical device; record target type |
| L4 | Release package identity, signing/certificate, formal build configuration, CI build gate, or release/version behavior | Formal APK verification plus L3 evidence when a device is required |

High-risk fallback paths include:

- L4: `android/app/build.gradle*`, release manifests, signing configuration, `ios/Runner.xcodeproj`, release xcconfig, and CI workflows.
- L3: `integration_test/acceptance_suite_test.dart`, `modernization_test.dart`, `evidence_test.dart`, Android acceptance and restore tooling, media action tooling, backup and device lifecycle code.
- L2: `integration_test/`, `pigeons/`, generated host bindings, `lib/web_host/`, native host code, `web_assets/`, `lib/browser/`, `lib/scripts/`, browser entry and navigation observer code, and background host code.

When no device is available for a required L2/L3/L4 stage, run all possible lower stages and return exit code `2`. Device stages perform a current `adb get-state` preflight before cache lookup; an L2 device result is never accepted from stale cache alone. Do not report the requested level as passed.

For emulator operation, read [emulator.md](emulator.md) before starting. Use a bounded startup wait and live health sampling; stop on ADB loss, repeated shell timeouts, stalled test progress, or host memory pressure instead of repeatedly restarting the emulator or replaying the suite.
