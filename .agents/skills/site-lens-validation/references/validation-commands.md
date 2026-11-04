# Site Lens validation commands

Read this when running the unified entry point, interpreting its exit code, or deciding whether cached evidence may be reused.

The unified entry point supports `--auto`, `--level L0..L4`, `--paths`, `--device`, `--report`, and `--cache-dir`. It prints a Markdown report and returns:

- `0` when the requested level is complete;
- `1` when a validation command fails;
- `2` when required environment or evidence is unavailable;
- `3` for an invalid runner request.

The runner may reuse exact non-device L0-L2 evidence from `.ci_cache/` when the complete worktree, toolchain, command, and relevant environment fingerprints match. Device stages perform a current preflight and rerun their command; L3 and L4 always perform current critical checks. Do not treat cache hits as a substitute for a missing device or release gate.

Use `--device IP:PORT` for Android validation. The single-recovery boundary for an unavailable `IP:PORT` endpoint is defined in [android endpoint](android-endpoint.md); the runner never retries beyond it.

Keep the existing `make check`, `make acceptance`, and CI gates working. Complete the project's independent review requirement before committing; review does not by itself require the highest validation level.
