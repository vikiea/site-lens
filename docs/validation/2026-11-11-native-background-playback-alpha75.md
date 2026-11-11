# 原生播放器后台播放迁移与生命周期修复 Alpha75 收尾记录

Alpha74 已由远端发布，但只包含版本提交 `fb222c8`；本记录绑定真正包含 lifecycle owner、local open policy 和 WebView 回归修复的 Alpha75 patch。

## 当前源码与版本

- Alpha75 目标版本：`0.6.0-alpha75+208`。
- Alpha75 tag：`v0.6.0.alpha75`，versionCode 208；远端引用确认在发布前为空。
- 修复提交：rebased lifecycle owner commit 与 local open policy commit，最终发布提交需在独立复审后固定。
- Alpha74 的真机 L3 失败暴露了 WebView 旧断言、跨 Bridge lifecycle owner/sequence、rebind policy propagation 和 local open 继承旧后台策略四条问题；本批均已纳入修复或回归。

## 修复内容

- 设置只控制原生播放器；WebView 覆盖页面仍按既有网页策略暂停，`WEB_TAB_POLICY_INDEPENDENT_PASS` 已在设备上通过。
- 原生 Bridge attach 时 claim owner；服务持久化 owner/sequence，只接受当前 owner 的递增序列，旧 Bridge 迟到调用被拒绝。
- `openLocal` 将 Dart 携带的当前应用前后台和原生后台策略写回 Kotlin runtime，再创建服务请求，避免前一次后台关闭状态污染后续本地播放。
- rebind 回归等待原生策略状态传播后再断言暂停和 `backgroundPolicyPaused`。

## 已完成本地门禁

- `python3 tool/verify_release_pubspec.py --tag v0.6.0.alpha75 --version-code 208`：待版本提交后复核。
- `make check`：通过；892 项 Flutter 测试及脚本、Pigeon、Android、回归契约、UI token 检查通过。
- `./gradlew :app:testDebugUnitTest`：通过。
- 独立复审：Alpha74 之前的时间 epoch 方案被拒绝；owner/sequence 方案及最终提交需取得新的 `APPROVE` 后才能发布。

## 设备门禁

- Android endpoint：`172.16.73.82:39955`。
- Alpha74 绑定旧源码的 L3 已记录失败；本地修复提交必须重新执行完整 L3，不能把 Alpha74 或旧 commit 的失败/通过结果直接复用。
- 必须保留 `NATIVE_BACKGROUND_DISABLED_PAUSE_PASS`、`NATIVE_BACKGROUND_NO_AUTOPLAY_PASS`、`NATIVE_MEDIA_REBIND_POLICY_PASS`、`WEB_TAB_POLICY_INDEPENDENT_PASS`、通知/锁屏、MediaSession rebind、旧 Bridge、数据库恢复和 tombstone 证据。

## 发布门禁

- 独立评审 `APPROVE` 后，推送 rebased feature/main commit 和 `v0.6.0.alpha75`。
- Verify 与 Release 必须分别为 success；Release 必须是 prerelease，并确认 APK、`.sha256` 和 GitHub asset digest。
- 真机 L3 通过前不能把 Alpha75 写成设备验收完成；若发现 P0/P1 或数据损坏，继续发布新的 patch Alpha，不修改已发布标签。
