---
name: site-lens-validation
description: Choose and run the smallest sufficient Site Lens validation level for code changes, with strict Android endpoint checks and explicit evidence for skipped higher-risk gates.
---

# Site Lens Validation

Use this skill for implementation, bug fixes, UI changes, test changes, tooling changes, and release preparation in this repository.

## Non-negotiables

- Never report the requested level as passed when a required stage was skipped; a successful lower level does not imply that a higher level passed.
- Preserve the runner's nonzero exit code and include the missing evidence in the report.
- A cache hit is not a device or release gate.
- An `IP:PORT` endpoint gets one ADB server restart, one `adb connect`, and one preflight retry; a second failure stops and asks for the correct port.
- An unchecked or stale manual evidence file is never device evidence.
- Do not download release assets during routine validation.
- Do not report a stopped or timed-out run as passed.

## Workflow

1. Inspect the current worktree, including staged, unstaged, and untracked paths.
2. Read the [validation matrix](references/validation-matrix.md) and classify by behavior first, then by path.
3. Select the smallest sufficient level from L0 through L4. Escalate when the change crosses WebView, navigation, scripts, permissions, persistence, Pigeon, native code, media, device lifecycle, or release identity.
4. Run `python3 tool/verify_level.py --auto` unless the user explicitly selects a level, using `--device IP:PORT` for Android validation; flags, exit codes, and `.ci_cache` policy are in [validation commands](references/validation-commands.md).
5. Run `make emulator-check EMULATOR_AVD=<avd-name>` or `python3 tool/check_emulator.py --avd <avd-name>` before emulator acceptance, and use the bounded profile and monitoring in [emulator profile](references/emulator-profile.md).
6. When the app is absent, stuck on Splash, or the process dies in `libflutter.so`, read [emulator diagnosis](references/emulator-diagnosis.md) before restarting the emulator or ADB.
7. Treat a skipped required stage as incomplete and carry the missing evidence into the report.
8. When a developer has manually verified the checklist on a real device, use the contract in [manual evidence](references/manual-evidence.md) instead of replaying the device stage.

## Reporting

Report the selected level, reason, commands, cache hits, failures, emulator configuration, monitoring observations, and remaining gates. Report whether Android endpoint recovery was attempted and whether the retry passed. For a GitHub Release, report the evidence described in [release evidence](references/release-evidence.md).

## Read on demand

| Reference | Read when |
| --- | --- |
| [validation matrix](references/validation-matrix.md) | Classifying a change, escalating by path, or a required device stage cannot run |
| [validation commands](references/validation-commands.md) | Running the entry point, interpreting exit codes, or reusing cached evidence |
| [Android endpoint](references/android-endpoint.md) | Validating an `IP:PORT` device or recovering from a failed preflight |
| [emulator profile](references/emulator-profile.md) | Starting, configuring, or monitoring an emulator |
| [emulator diagnosis](references/emulator-diagnosis.md) | The app is absent, stuck on Splash, or crashing in the Flutter raster thread |
| [manual evidence](references/manual-evidence.md) | A manual checklist must satisfy a required device stage |
| [release evidence](references/release-evidence.md) | Reporting a GitHub Release or deciding whether to download assets |
