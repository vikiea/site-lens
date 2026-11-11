# 原生播放器后台播放迁移与生命周期修复 Alpha74 收尾记录

本记录针对 Alpha73 真机 L3 暴露的问题，绑定后续修复提交和 `v0.6.0.alpha74` 发布流程。

## Alpha73 失败后的修复

- WebView 验收改为明确断言：即使打开“后台播放”，网页标签被二级页面覆盖时仍按既有网页策略暂停；返回浏览器前台后再验证网页媒体和系统控制。
- `NativeMediaRuntime` 不再自行决定跨 Engine 的生命周期顺序。Android Bridge attach 时向原生服务声明新的 owner，服务持久化当前 owner 和序列；同一 owner 只接受递增序列，旧 Bridge 在新 owner 接管后被拒绝。
- 不改变 Android 原生播放器的产品行为：关闭后台播放时暂停并保留会话，回前台不自动播放；网页标签不读取该设置。

## 当前版本身份

- Alpha73 基线：`v0.6.0.alpha73` / versionCode 206；Alpha73 Verify/Release 均成功，但真机 L3 失败，见 [Alpha73 验收记录](2026-11-11-native-background-playback-alpha73.md)。
- Alpha74 目标：`v0.6.0.alpha74` / versionCode 207；发布前必须通过 `python3 tool/verify_release_pubspec.py --tag v0.6.0.alpha74 --version-code 207`。
- 发布源码 commit、独立评审、Verify、Release 和设备证据必须分别记录；不能复用 Alpha73 的失败设备证据作为 Alpha74 通过证据。

## 待完成门禁

- 独立只读复审修复 diff，确认无 P0/P1/P2。
- `make check`、Android unit tests、定向媒体/设置测试。
- 使用 `172.16.73.82:39955` 重新执行 L3；遵守一次 ADB 恢复边界。
- 重点确认 `WEB_TAB_POLICY_INDEPENDENT_PASS`、`NATIVE_BACKGROUND_DISABLED_PAUSE_PASS`、`NATIVE_BACKGROUND_NO_AUTOPLAY_PASS`、MediaSession rebind、通知/锁屏、旧 Bridge 和数据库恢复证据。
- Alpha74 Verify/Release 成功后，核对 prerelease、APK/SHA-256 资产、GitHub asset digest 和 tag commit。
- 若设备仍发现原生 P0/P1 或数据损坏，停止发布结论并继续新的 patch Alpha；不修改已发布标签。
