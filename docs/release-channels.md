# Release channels

Site Lens publishes two Android update channels:

- **Stable** is the default channel. It uses tags such as `v0.2.0` and GitHub Releases marked as normal releases.
- **Beta** is opt-in from the app settings screen. It uses prerelease tags such as `v0.2.0.alpha1`, `v0.2.0.beta1`, or `v0.2.0.rc1`; GitHub marks these releases as prereleases. The numeric suffix increments for each release (`alpha2`, `alpha3`, and so on).

The release workflow accepts a `channel`, `tag`, and `version_bump` policy when started manually. Tag pushes infer the channel and use `auto` version detection. Stable tags must have the `vMAJOR.MINOR.PATCH` form. Beta tags must add a dotted `alphaN`, `betaN`, or `rcN` prerelease suffix, for example `v0.2.0.alpha1`. Hyphenated prerelease tags are rejected.

每次发布前必须先更新同一提交中的 `pubspec.yaml`：

```yaml
version: 0.4.0-alpha17+95
```

这里的版本名必须对应标签的 dotted 形式（`v0.4.0.alpha17` → `0.4.0-alpha17`），末尾的 build number 必须是本次 Android `versionCode`。`tool/verify_release_pubspec.py` 会在分配阶段拒绝不一致的标签；构建完成后，工作流还会从 APK manifest 回读 `versionName` 和 `versionCode`，两者任意不一致都会失败。冲突时更新 `pubspec.yaml` 并创建新标签，不在工作流里临时改写版本。

`versionCode` 的候选上限仍由已发布版本、不可变 reservation、当前 stable APK 和安装版本下限共同决定；标签中的 pubspec build number 必须严格高于这个上限。`version-code/<code>-<tag>` Git ref 用来防止并发发布重复占用数字，同一个标签重跑时复用它自己的 reservation。稳定版和测试版共用一条递增序列，CI run number 不参与默认版本号。手动输入 `version_code` 仅为兼容重跑保留，并且必须与标签 `pubspec.yaml` 中的 build number 完全相同。

`tool/determine_release_version.py` compares commits since the previous stable tag. A `BREAKING CHANGE` or `!` selects a major bump; `feat` or a detected cross-domain capability selects minor; recognized fix/perf/refactor/chore-style commits select patch. If commit history is not reliable enough, `auto` uses and reports a patch fallback. Manual workflow runs can select `major`, `minor`, or `patch` explicitly. A prerelease sequence must be the next unused number for its base and kind.

Before creating or updating a GitHub Release, the workflow runs `tool/generate_release_notes.py`. The generated body compares the release tag with the newest earlier tag from the same channel and groups first-parent commits into **功能**, **修复**, and **验证与已知限制**. Commit prefixes such as `feat`, `fix`, `perf`, `test`, and `docs` guide the categorization, while touched test or CI paths add verification context and Android/iOS paths add a device acceptance reminder.

If no earlier same-channel tag exists, the generator uses the most recent first-parent commits and labels the body with a fallback notice. Device-specific changes also keep a reminder that final Android/iOS acceptance must be performed on a target device. The generated body is passed to `gh release create` or `gh release edit`, so rerunning the workflow refreshes the release notes without replacing the release assets.
