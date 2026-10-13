# Repository Guidelines

## Project Structure & Module Organization

This is a Flutter app for Android-first, local-first site discovery and browsing. Dart code in `lib/` is organized by responsibility: `domain/` models, `data/` Drift/SQLite persistence, `network/` transport, `discovery/` probing and validation, `scripts/` userscript parsing/runtime services, `ui/` screens and controllers, and `web_host/` platform integration. Native implementations are in `android/` and `ios/`; typed host definitions are declared in `pigeons/web_host.dart` and generate platform bindings. Browser assets live in `web_assets/`. Use `test/` for unit/widget tests, `integration_test/` for device flows, `tool/` for verification scripts, and `docs/` for implementation and support notes.

## Build, Test, and Development Commands

Run `flutter pub get` after dependency changes. Use the project `$site-lens-validation` Skill or `python3 tool/verify_level.py --auto` to select the smallest sufficient validation level. L1 uses `make check`, while higher levels add protected integration, device, or release validation. Format Dart with `make format`, build APKs with `make build`, and run `make verify-script SCRIPT=path/to/file.user.js` to validate a userscript. For Android validation, use `make acceptance DEVICE=<adb-serial>`; `make devices` lists available devices. An `IP:port` endpoint is preflighted once and is never automatically reconnected or retried. `make build-release` produces and validates `build/app/outputs/flutter-apk/app-release.apk`.

## Coding Style & Naming Conventions

Follow `flutter_lints` and Dart conventions: two-space indentation, `lower_snake_case.dart` filenames, `UpperCamelCase` types, and `lowerCamelCase` members. Keep layers focused and preserve the app’s fail-closed behavior around navigation, scripts, permissions, and network access. Run `dart format lib test integration_test tool` before submitting. When changing the Pigeon contract, regenerate bindings and include the generated Dart, Kotlin, and Swift files.

## Testing Guidelines

Name Dart tests with descriptive `*_test.dart` suffixes and group cases around one behavior. Put fast unit/widget coverage in `test/`; reserve `integration_test/` for real device or host-contract behavior. Run the validation level selected by `$site-lens-validation` before review. Device acceptance requires an Android serial and may modify or restore the app database; use the documented Make targets rather than ad hoc installs. Keep the independent review requirement before commits.

## Commit & Pull Request Guidelines

Use imperative Conventional Commit-style subjects with a scope, for example `fix(browser): preserve same-origin leases` or `test(ui): cover tab switching`. Keep commits focused. Pull requests should explain the behavior change, list validation commands, link a related issue or milestone when applicable, and include screenshots or device evidence for visible changes. Mention regenerated files and any Android/iOS scope limitations.

## Security & Configuration Tips

Do not commit signing keys, credentials, private URLs, or personal device data. Release builds require the fixed formal signing configuration stored outside the repository; see `docs/android-modernization.md`. Keep user scripts and network permissions fail-closed, and review `docs/support.md` when changing script or browser behavior.
