---
name: site-lens-validation
description: Choose and run the smallest sufficient Site Lens validation level for code changes, with strict Android endpoint checks and explicit evidence for skipped higher-risk gates.
---

# Site Lens Validation

Use this skill for implementation, bug fixes, UI changes, test changes, tooling changes, and release preparation in this repository.

## Workflow

1. Inspect the current worktree, including staged, unstaged, and untracked paths.
2. Read [references/validation-matrix.md](references/validation-matrix.md) and classify the change by behavior first, then by path.
3. Select the smallest sufficient level from L0 through L4. Escalate when the change crosses WebView, navigation, scripts, permissions, persistence, Pigeon, native code, media, device lifecycle, or release identity.
4. Run `python3 tool/verify_level.py --auto` unless a user explicitly selects a level. Use `--device IP:PORT` for Android validation.
5. For emulator validation, read [references/emulator.md](references/emulator.md) before starting it. Use the recommended bounded RAM/GPU profile and monitor ADB, boot state, test progress, emulator process, and host memory while the runner is active.
6. Treat a skipped required stage as incomplete. Preserve the runner's nonzero exit code and include the missing evidence in the report.
7. Report the selected level, reason, commands, cache hits, failures, emulator configuration, monitoring observations, and remaining gates. A successful lower level does not imply that a higher level passed.

## Android endpoint guard

For an `IP:PORT` device, the runner performs one `adb -s IP:PORT get-state` preflight before any build, install, backup, or test. If it fails, stop immediately and ask for the correct port. Do not reconnect, restart adb, wait for the device, retry installation, or run another validation command. The same strict behavior applies when `make acceptance DEVICE=IP:PORT` is invoked directly.

## Commands and reports

The unified entry point supports `--auto`, `--level L0..L4`, `--paths`, `--device`, `--report`, and `--cache-dir`. It prints a Markdown report and returns:

- `0` when the requested level is complete;
- `1` when a validation command fails;
- `2` when required environment or evidence is unavailable;
- `3` for an invalid runner request.

The runner may reuse exact non-device L0-L2 evidence from `.ci_cache/` when the complete worktree, toolchain, command, and relevant environment fingerprints match. Device stages perform a current preflight and rerun their command; L3 and L4 always perform current critical checks. Do not treat cache hits as a substitute for a missing device or release gate.

Keep the existing `make check`, `make acceptance`, and CI gates working. Complete the project's independent review requirement before committing; review does not by itself require the highest validation level.
