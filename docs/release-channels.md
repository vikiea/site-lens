# Release channels

Site Lens publishes two Android update channels:

- **Stable** is the default channel. It uses tags such as `v0.1.6` and GitHub Releases marked as normal releases.
- **Beta** is opt-in from the app settings screen. It uses prerelease tags such as `v0.1.9.alpha1`, `v0.1.9.beta1`, or `v0.1.9.rc1`; GitHub marks these releases as prereleases. The numeric suffix increments for each release (`alpha2`, `alpha3`, and so on).

The release workflow accepts a `channel` and `tag` when started manually. Tag pushes infer the channel from the tag suffix. Stable tags must have the `vMAJOR.MINOR.PATCH` form. Beta tags must add a dotted `alphaN`, `betaN`, or `rcN` prerelease suffix, for example `v0.1.9.alpha1`. Hyphenated prerelease tags are rejected.

Before creating or updating a GitHub Release, the workflow runs `tool/generate_release_notes.py`. The generated body compares the release tag with the newest earlier tag from the same channel and groups first-parent commits into **功能**, **修复**, and **验证与已知限制**. Commit prefixes such as `feat`, `fix`, `perf`, `test`, and `docs` guide the categorization, while touched test or CI paths add verification context and Android/iOS paths add a device acceptance reminder.

If no earlier same-channel tag exists, the generator uses the most recent first-parent commits and labels the body with a fallback notice. Device-specific changes also keep a reminder that final Android/iOS acceptance must be performed on a target device. The generated body is passed to `gh release create` or `gh release edit`, so rerunning the workflow refreshes the release notes without replacing the release assets.
