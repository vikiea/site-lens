# Site Lens development setup

Site Lens is an Android-first Flutter application. The repository keeps the project setup, system SDK installation, Codex integration, and device acceptance steps separate so a new contributor can choose the scope they need without changing application data or release credentials.

## First setup

From the repository root, optionally create a project-local environment file, then run:

```sh
cp .env.example .env.local
make setup
make doctor
make check
```

`.env.local` is ignored by Git. It is useful when the SDKs are installed in nonstandard locations or the project should use a fixed emulator default. The bootstrap tool also reads it when invoked directly, so `python3 tool/bootstrap_dev.py doctor` and Make targets use the same values. Make receives only the allowlisted toolchain variables; the file is parsed as plain `KEY=value` data and is never sourced as shell code.

`make setup` resolves the Flutter SDK, installs the locked Dart packages with `--enforce-lockfile`, and regenerates the Pigeon host bindings from `pigeons/web_host.dart`. It refuses to overwrite locally edited generated bindings. It does not install an APK, create an emulator, modify the app database, or configure formal release signing.

The expected development baseline is:

- Flutter 3.47.6
- Dart 3.13.5
- JDK 21
- Android SDK Platform 36
- Android Build Tools 36.0.0
- Android NDK 28.2.13676358
- Android Platform Tools and Emulator
- Node.js, Python 3, and OpenSSL

Set `FLUTTER_ROOT`, `FLUTTER_BIN_DIR`, `ANDROID_HOME`/`ANDROID_SDK_ROOT`, or `JAVA_HOME` in `.env.local` when the tools are outside the standard PATH or macOS locations. The precedence is explicit command-line values, then current shell variables, then `.env.local`, then PATH, then known macOS defaults. An SDK override suppresses all file-level aliases for that SDK. Within a single layer, `FLUTTER_BIN_DIR` wins over `FLUTTER_ROOT`, and `ANDROID_HOME` wins over `ANDROID_SDK_ROOT`; configure only one alias where possible. Do not store a full personal `PATH`, credentials, tokens, or signing contents in the file.

## System dependencies

Use the system installer only when the host is macOS and SDK components are missing:

```sh
make setup-system
```

This installs or verifies Homebrew packages for JDK 21, Node.js, OpenSSL, Python 3, and Android command-line tools, then uses `sdkmanager` for the project Android packages. If the fixed Flutter SDK is missing, it clones Flutter at the repository's pinned revision. It does not create an AVD unless `AVD_NAME` is explicitly set:

```sh
AVD_NAME=sl_g37 make setup-system
```

Or put `AVD_NAME=sl_g37` in `.env.local` to use it as the project default.

Use `BOOTSTRAP_ARGS=--dry-run` to inspect commands without executing them:

```sh
make setup-system BOOTSTRAP_ARGS=--dry-run
```

The command does not delete SDK components, AVDs, user data, signing files, or existing project files. Android SDK licenses remain an explicit user action when the SDK tools request them.

Use `ENV_FILE=path/to/another.env make doctor` when a different project environment file is needed. `DEVICE` remains a command-line value because it identifies a personal emulator or device.

## Codex and Dart MCP

Install the official Flutter/Dart Codex plugin once per user account:

```sh
make setup-agent
```

The command configures the `flutter/agent-plugins` marketplace, installs `dart-flutter`, lists the installed plugin, and verifies that the Dart MCP server can start. It is safe to rerun. The plugin is user-level because it owns the MCP server registration and Skills cache; the repository does not commit absolute paths or duplicate the same MCP server in `.codex/config.toml`. If the selected Flutter SDK's `dart` command is not already on the current PATH, the command creates `~/.local/bin/dart` and `~/.local/bin/flutter` only when that directory is already on PATH; otherwise it prints the required PATH export and stops before claiming MCP readiness.

The Dart MCP server is useful for runtime diagnostics, Widget tree inspection, logs, hot reload, and test exploration. Its observations do not replace the project validation gates for WebView behavior, Pigeon contracts, user scripts, persistence, media, or Android device lifecycle.

## Approved Flutter Skills

The official plugin contains general-purpose Skills. Site Lens uses these selectively:

- `flutter-add-widget-test` for focused `WidgetTester` behavior tests.
- `flutter-fix-layout-issues` for diagnosing Flutter constraint and overflow errors.
- `flutter-build-responsive-layout` when a feature explicitly needs different window widths or large-screen behavior. Preserve the browser toolbar's one-row invariant.

These Skills are advisory. The project-specific `site-lens-ui` and `site-lens-validation` Skills, `AGENTS.md`, and the existing Make targets define the final UI and verification rules.

The following workflows are intentionally not automatic:

- `flutter-add-integration-test`: Site Lens already has a combined integration suite and a database-safe Android acceptance runner. Do not add a second Flutter Driver/`flutter drive` entry point.
- `flutter-apply-architecture-best-practices`: do not replace the existing Riverpod, controller, repository, Domain/Data/UI structure with a generic `ChangeNotifier`/MVVM template.
- `flutter-add-widget-preview`: defer until a pure widget surface is selected and its native/runtime dependencies are isolated.
- `dart-collect-coverage`: add only when coverage reporting becomes an explicit CI requirement.

## Validation commands

Use the smallest command that matches the change:

```sh
make doctor
make check
make verify-level ARGS=--auto
make emulator-check EMULATOR_AVD=sl_g37
make acceptance DEVICE=<adb-serial>
make build-release
```

### Manual device evidence

When a developer has manually verified the app on a real device, the manual result can satisfy the required device stage without replaying the emulator or Android acceptance runner. The evidence is bound to the current changed paths and complete worktree fingerprint, so it becomes stale after any source change.

Create the checklist after the local code is ready:

```sh
make manual-evidence-template LEVEL=L2 DEVICE=<adb-serial> \
  EVIDENCE=.ci_cache/site-lens-manual-L2.json
```

Run the app and complete every checklist item. Then approve the checklist interactively:

```sh
make manual-evidence-approve \
  EVIDENCE=.ci_cache/site-lens-manual-L2.json
```

Use the passed evidence with the validation runner:

```sh
python3 tool/verify_level.py --level L2 \
  --manual-evidence .ci_cache/site-lens-manual-L2.json
```

The runner still executes all local checks. It records the Android stage as passed from the auditable manual evidence and skips the automatic device command. Changing tracked or untracked project files invalidates the evidence and requires a new checklist.

`make acceptance` is the canonical Android device flow. It handles the debug package identity, database backup and restore, the combined integration suite, media/system controls, and restoration of the normal debug APK. Do not substitute an ad hoc `flutter test` on a device containing user data.

`make build-release` additionally requires the formal signing properties outside the repository. `make doctor` reports missing signing configuration as a warning because it does not affect debug checks or local widget tests.
