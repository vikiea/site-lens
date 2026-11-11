# 原生播放器后台播放迁移与生命周期修复验收记录

日期：2026-11-11（Asia/Shanghai）。实现基线为 `v0.6.0.alpha72` / `ae6f7ee`，功能提交为
`a036d8e65cc98c05dfb6b32307158772806eae78`，分支为
`codex/native-background-playback`。原始 checkout 的未提交改动未被修改；本记录绑定隔离
worktree 的功能提交和后续发布提交。

## 行为范围

- 设置入口已从设置首页移动到“媒体管理”，标题为“后台播放”。
- 设置字段为 `allowNativeBackgroundPlayback`，旧字段 `allowBackgroundPlayback` 仅作安全兼容读取；新写入只保存新字段。
- 该设置只控制 Android 原生播放器。关闭时应用进入后台会暂停并保留会话、进度、租约和通知；回到前台不自动播放。重新开启也不自动恢复。
- 网页标签继续按既有当前标签、可见性和应用生命周期策略暂停或静音，不再读取该设置。
- Activity/Flutter Engine detach 只处理临时 Surface；显式 stop/close 才释放原生会话。
- generation、Surface binding、release barrier 和串行执行顺序保护旧 Bridge、旧播放器和旧回调不影响新会话。

## 独立评审

首轮独立只读评审发现一个 P1：旧设置字段更新后没有完整触发生命周期同步。该问题已修复并复测。
最终独立评审结论为 `APPROVE`：旧字段和新字段在设置应用后都会触发生命周期同步，旧字段 patch 会在持久化前规范化；评审路径没有遗留 P0/P1/P2。

## 本地验证

| 门禁 | 命令 | 结果 |
| --- | --- | --- |
| 全量本地检查 | `make check` | 通过；Flutter、脚本、Pigeon、Android、回归契约和 UI token 检查通过 |
| Android 原生单测 | `./gradlew :app:testDebugUnitTest` | 通过 |
| 定向媒体/设置/策略测试 | 设置迁移、媒体管理 UI、NativeMediaRuntime、NativeMediaSessionPolicy 及 integration marker | 通过 |
| L3 计划 | `python3 tool/verify_level.py --level L3 --report .ci_cache/native-background-l3-validation.md` | 本地阶段通过；因无 `DEVICE` 阻塞 Android acceptance，退出码 2 |

L3 报告固定记录了 Dart 3.13.5、Flutter 3.47.6、Node 24.18.0、Python 3.14.6 和 macOS arm64 工具链。
“full local check”通过不等于 Android L3 通过；当前设备证据保持待补。

## GitHub 与 Alpha 发布状态

- 远端已确认 `v0.6.0.alpha72` 使用 versionCode 205，`version-code/205-v0.6.0.alpha72` 已存在。
- 下一可用 Alpha 目标为 `v0.6.0.alpha73` / `0.6.0-alpha73+206`；发布前仍需通过 `verify_release_pubspec.py`。
- GitHub Verify、`Release Site Lens`、Release prerelease、APK/SHA-256 资产和 asset digest：已完成，具体证据见下方。
- Release notes 必须分别保留独立评审、本地检查、Verify、Release 和设备验收状态。

Alpha73 发布后的实际证据如下：

- GitHub Verify run `42965378658`：`success`，源码为 `7900dce41e8c0589edbdf09baed1fe49e78df13d`。
- `Release Site Lens` run `42965378668`：`success`；GitHub Release `v0.6.0.alpha73` 为 prerelease，目标提交为 `7900dce41e8c0589edbdf09baed1fe49e78df13d`。
- APK `site-lens-v0.6.0.alpha73.apk` 已上传，GitHub asset digest 为 `sha256:5080758fa224d8c4782a0d4aee88c00dc2e674310756177ea8187fa9f5bc4e71`；对应 `.sha256` 资产存在，常规发布未下载 APK。
- 真机端点 `172.16.73.82:39955` 预检通过，但 L3 退出码为 1。失败项为 WebView 覆盖页面的旧后台播放断言，以及 `native HLS remux plays continuously and task deletion removes cache` 在策略切换处返回 `stopped` 而不是 `paused`。该结果不构成 Alpha73 设备验收通过。
- 失败调查确认前一项是测试断言仍代表旧网页开关语义；后一项暴露出新的 Flutter runtime 使用从 0 开始的 lifecycle epoch 可能被原生服务持久化 epoch 拒绝。修复提交进入后续 patch Alpha，Alpha73 标签本身不修改。

## Alpha 后设备收尾清单

以下项目必须绑定 Alpha 发布对应的源码 commit；没有设备时不得写成通过：

- Home、锁屏、通知栏和锁屏控制；
- Activity/Engine 重建、Surface detach/rebind、旧 Bridge close/detach；
- 任务移除、服务销毁、进程重启后的暂停/需用户操作状态；
- 音频焦点丢失、重新获得焦点和耳机拔出；
- 网络切换、HLS 重试、快速切集以及 stop/close 竞态；
- 原生播放器与网页标签播放互斥；
- 设置迁移、备份恢复、通知状态、租约释放和数据库 SHA-256 恢复；
- `dumpsys media_session`、通知/锁屏截图、完整 logcat 和 tombstone 检查。

任何 P0/P1 原生崩溃、错误自动恢复或数据损坏都会阻止当前 Alpha 的验收结论；若需修复，必须发布新的 patch Alpha，不修改已发布标签。
