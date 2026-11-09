# 系统透明网络收敛验证记录

基线：`82e36ed5757259acc3597ca1a2341b9998e4f52a` (`v0.6.0.alpha64`)

实现目标是让 Android 自有 HTTP 统一遵循系统 `ProxySelector`/PAC、系统 DNS 与可选 DoH；移除应用侧的 Fake-IP、VPN/TUN、私网/回环预判和跨客户端路线重试。WebView 继续由 Chromium 管理网络，DLNA 保留 LAN 直连例外。

## 完成状态

| Gate | Status | Evidence |
| --- | --- | --- |
| 实现 | PASS | worktree `system-transparent-network-alpha` |
| `flutter analyze --no-pub` | PASS | `No issues found!` |
| `make check` | PASS | Flutter 852 项、Node/Python 契约、Pigeon、回归矩阵与 Android 工具链测试全部通过 |
| Android unit tests | PASS | `./gradlew :app:testDebugUnitTest` |
| 聚焦网络/媒体回归 | PASS | 原生先取消、`media_cancelled`、单次 epoch、网络暂停续传、PAC 候选、DoH、过滤源单执行器均覆盖并通过 |
| 独立只读评审 | PASS | 最终 `APPROVE`；无 P0/P1/P2 |
| 模拟器 L3 | BLOCKED | `sl_g37` 可启动并完成大部分验收；7 项失败由 AVD 能力/基线行为阻断，见下节 |
| 真机 `verify_level.py --auto` | BLOCKED | 用户最近提供的无线调试端点在唯一 ADB 恢复后仍不可用；未猜端口 |
| L2/L3 真机代理矩阵 | MANUAL PENDING | 用户选择在 alpha 发布后走人工真机验证 |
| 版本/标签 | READY | `0.6.0-alpha65+198` / `v0.6.0.alpha65` |
| GitHub Verify | PENDING | |
| GitHub Release | PENDING | |
| 正式 APK 身份 | PENDING | |
| 真机候选包验收 | PENDING | |

## 模拟器 L3 证据

- AVD：`sl_g37`，Android API 37，arm64，`3072 MB`，2 cores，`-gpu host`，serial `emulator-5554`。
- WebView：`com.google.android.webview 145.0.7632.218`；Host capabilities 实测 `isolatedScripts=false`（`world=false; navigation=false`）。
- 完整 `acceptance_suite_test.dart` 运行至 35 通过、2 跳过、7 失败。
- 6 项失败集中在依赖隔离脚本的 navigation lease、浏览器菜单和证据包用例；这些用例在能力探测处已经判定当前 AVD 不满足运行前提。
- `Media3 parity` 的 HEVC 用例实际进度为 `0`，H.264 TS/fMP4 与 AES 用例均通过。使用同一 AVD 对 alpha64 基线运行同一用例复现相同 HEVC 失败，因此该项不是本工作树引入的回归。
- `integration_test/network_reliability_test.dart` 在未提供 VPN/HLS fixture 环境时全部跳过，不能当作通过证据。
- `tool/run_android_proxy_acceptance.py emulator-5554` 在修改系统代理前被 AVD 缺少 `curl`（exit 127）阻断；检查回读为 `http_proxy=null`、无测试 reverse，证明失败后未遗留代理状态。该专用代理证据仍需能运行 curl 的真机。

## 独立评审记录

评审共进行四轮。前三轮分别发现并关闭：iOS Pigeon 实现、PAC 多候选/Dart fallback、原生先取消与 Dart 后通知的竞态、重复网络回调产生多次 epoch、以及双恢复协调者问题。最终结构为：

1. Android 合并一次网络切换的回调 burst；
2. 发布单一 native epoch，取消活动传输并通知 Dart；
3. Dart 只由该事件恢复网络暂停任务；
4. 原生先取消以 `media_cancelled` 保留部分文件并转 `paused`，随后由同一事件续传。

最终评审结论：`APPROVE`，无 P0/P1/P2。

## 发布后人工验证

按用户明确要求，alpha 不等待自动 L3 真机门禁，发布成功后执行人工验证。Release notes 必须保留以下清单，发布成功不得推导为设备验收成功：

- [ ] 安装正式 Release APK，核对 `dev.vikiea.site_lens`、`0.6.0-alpha65`、`versionCode 198` 和正式签名。
- [ ] Clash 或其他本机 HTTP 代理 `127.0.0.1:7890`：探测、WebView、Media3、媒体下载和 APK 更新均走系统代理。
- [ ] PAC `HTTP → DIRECT`：请求遵循系统返回顺序，应用日志不出现自造候选。
- [ ] PAC `SOCKS`：目标可连接，或记录真实 SOCKS 传输错误。
- [ ] OpenClash/路由 Fake-IP：解析结果进入连接阶段，无应用级 `fake_ip_policy` 拒绝。
- [ ] DNS 返回 `127.0.0.1`：应用实际尝试连接并报告真实结果。
- [ ] LAN/private HTTP(S)：可达目标成功，不可达目标报告连接失败。
- [ ] DoH 成功与失败回退：DIRECT 使用选定 DoH；失败后一次系统 DNS 回退。
- [ ] Wi-Fi/蜂窝/VPN 切换：活动请求取消，DNS 缓存清除，前台和后台媒体从已写字节续传。
- [ ] Media3 HLS 的 manifest、key、segment 共用系统网络策略。
- [ ] WebView 重复 `NetworkError`/error page 只显示一次失败并最多自动重试一次。
- [ ] DLNA SSDP、SOAP 和本地中继仍使用显式 LAN 直连。

## 真机矩阵

| Case | Status | Evidence |
| --- | --- | --- |
| Clash/local HTTP proxy | PENDING | |
| PAC HTTP/DIRECT | PENDING | |
| PAC SOCKS | PENDING | |
| OpenClash/Fake-IP | PENDING | |
| DNS 返回 `127.0.0.1` | PENDING | |
| LAN/private | PENDING | |
| DoH success | PENDING | |
| DoH fallback | PENDING | |
| Wi-Fi/cellular/VPN change | PENDING | |
| Background media resume | PENDING | |
| Media3 HLS | PENDING | |
| WebView duplicate error normalization | PENDING | |
| DLNA LAN exception | PENDING | |

## 停止条件

- 核心 PAC/HTTP/SOCKS/DNS/媒体测试失败时停止。
- 真机 endpoint 恢复仍失败时停止，不猜端口；新的 `IP:端口` 必须由用户提供。
- 独立评审未返回 `APPROVE` 时不得改变版本或打 tag。
- 发布不得把设备验收标为通过；人工验证完成后单独更新证据。
- Verify、Release、APK digest/package/version/signature 任一不一致时不得发布。
- 代码、评审、本地检查、Verify、Release 和设备验收必须分别报告。
