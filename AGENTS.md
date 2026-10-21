# Repository Guidelines

## Project Structure & Module Organization

This is a Flutter app for Android-first, local-first site discovery and browsing. Dart code in `lib/` is organized by responsibility: `domain/` models, `data/` Drift/SQLite persistence, `network/` transport, `discovery/` probing and validation, `scripts/` userscript parsing/runtime services, `ui/` screens and controllers, and `web_host/` platform integration. Native implementations are in `android/` and `ios/`; typed host definitions are declared in `pigeons/web_host.dart` and generate platform bindings. Browser assets live in `web_assets/`. Use `test/` for unit/widget tests, `integration_test/` for device flows, `tool/` for verification scripts, and `docs/` for implementation and support notes.

## Build, Test, and Development Commands

Run `flutter pub get` after dependency changes. Use the project `$site-lens-validation` Skill or `python3 tool/verify_level.py --auto` to select the smallest sufficient validation level. L1 uses `make check`, while higher levels add protected integration, device, or release validation. Format Dart with `make format`, build APKs with `make build`, and run `make verify-script SCRIPT=path/to/file.user.js` to validate a userscript. For Android validation, use `make acceptance DEVICE=<adb-serial>`; `make devices` lists available devices. Use `make emulator-check EMULATOR_AVD=<avd-name>` to start or check a named emulator, or `make emulator-check EMULATOR_SERIAL=<adb-serial>` to check an existing emulator. The command exposes `EMULATOR_TIMEOUT` (45 seconds by default), `EMULATOR_ARGS`, and the underlying `--avd`, `--serial`, `--port`, `--memory-mb`, `--cores`, `--gpu`, `--adb`, `--emulator`, and `--log` options. An `IP:port` endpoint is preflighted once and is never automatically reconnected or retried. `make build-release` produces and validates `build/app/outputs/flutter-apk/app-release.apk`.

## Agent Tooling and Flutter Skills

Run `make setup` for project dependencies and Pigeon generation, `make doctor` for read-only diagnostics, `make setup-system` only when macOS SDK installation is needed, and `make setup-agent` to install the official Codex Dart/Flutter plugin with Dart MCP. Copy `.env.example` to `.env.local` when this checkout needs fixed SDK or emulator defaults. Read `docs/development-setup.md` before changing bootstrap, SDK, MCP, environment-file, or agent setup behavior. Do not add Argent or a second MCP server configuration.

Dart MCP is an aid for runtime logs, Widget inspection, hot reload, and exploratory test work. Its observations do not replace the project validation gates for WebView behavior, Pigeon contracts, user scripts, persistence, media, Android lifecycle, or release identity.

The approved general Flutter Skills are `flutter-add-widget-test`, `flutter-fix-layout-issues`, and `flutter-build-responsive-layout` when the requested behavior needs them. Treat `site-lens-ui`, `site-lens-validation`, this file, and the existing Make targets as authoritative. Do not apply the generic integration-test/Flutter Driver setup, generic MVVM architecture migration, Widget Previewer, or coverage workflow unless a separate task explicitly establishes that scope.

## Coding Style & Naming Conventions

Follow `flutter_lints` and Dart conventions: two-space indentation, `lower_snake_case.dart` filenames, `UpperCamelCase` types, and `lowerCamelCase` members. Keep layers focused and preserve the app’s fail-closed behavior around navigation, scripts, permissions, and network access. Run `dart format lib test integration_test tool` before submitting. When changing the Pigeon contract, regenerate bindings and include the generated Dart, Kotlin, and Swift files.

## Testing Guidelines

Name Dart tests with descriptive `*_test.dart` suffixes and group cases around one behavior. Put fast unit/widget coverage in `test/`; reserve `integration_test/` for real device or host-contract behavior. Run the validation level selected by `$site-lens-validation` before review. Device acceptance requires an Android serial and may modify or restore the app database; use the documented Make targets rather than ad hoc installs. Keep the independent review requirement before commits.

## Commit & Pull Request Guidelines

Use imperative Conventional Commit-style subjects with a scope, for example `fix(browser): preserve same-origin leases` or `test(ui): cover tab switching`. Keep commits focused. Pull requests should explain the behavior change, list validation commands, link a related issue or milestone when applicable, and include screenshots or device evidence for visible changes. Mention regenerated files and any Android/iOS scope limitations.

## Release Completion & Records

- For stable promotion, synchronize the remote branches, merge the reviewed feature branch into `main`, and publish a stable tag from that commit using `docs/releasing.md` and `docs/release-channels.md`. Preserve published tags; subsequent fixes receive a new patch version.
- Treat a successful `Release Site Lens` workflow as release completion. The workflow owns formal signing, package identity, versionCode allocation, and APK/checksum upload. Download published assets again only when investigating a release anomaly or when explicitly requested.
- Keep final release status, workflow links, and the manual acceptance checklist in GitHub Release notes. Repository validation documents hold reusable procedures, regression cases, and checks already completed before the code commit. Avoid post-release placeholders and follow-up commits solely to fill release evidence.
- Report independent review, local checks, GitHub Verify, Release, and device acceptance separately. When device checks are explicitly deferred, retain the manual checklist as pending; publication does not establish device acceptance. Verify's debug APK is an internal Actions artifact; the Release APK is the user-facing download.
- Investigate failed checks before retrying. Turn a confirmed race into a deterministic regression and repair it before claiming that `main` is healthy, even if the same commit passed another workflow run.

## Media & Persistence Contracts

- HLS downloads and exported MP4 documents have independent ownership. Protect both through file leases; preserve exported indexes when task/cache rows disappear, and use persistent source identity to deduplicate rescans. A moved file keeps its catalog ID; a new file at its previous path receives another ID.
- For HLS remuxing, preserve video decode order and B-frame PTS, and write each AAC access unit separately after removing ADTS transport headers. Validate ASC/ADTS/track configuration, timing, EOS, and output sample counts; existing broken MP4 files require regeneration from HLS.
- Parse timestamps or normalize their precision before ordering persisted updates. Dart's UTC ISO output can contain three or six fractional digits, which makes raw SQLite text comparison misorder `.123Z` and `.123001Z`. Preserve the atomic upsert and stale-progress guards.
- Candidate display deduplication may remove known transport/authentication parameters while preserving episode, quality, and audio selection. Keep download/cache authorization identities separate; dropping every HLS query parameter can hide distinct resources.

## Security & Configuration Tips

Do not commit signing keys, credentials, private URLs, or personal device data. Release builds require the fixed formal signing configuration stored outside the repository; see `docs/android-modernization.md`. Keep user scripts and network permissions fail-closed, and review `docs/support.md` when changing script or browser behavior.
