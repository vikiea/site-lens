# v0.6.0.alpha32 代理路由修复与路由层代理验证记录（L2）

## Read this when

需要追溯 “启用代理后应用不可用” 这一缺陷的修复范围、真机路由取证方式，以及 alpha32 的本地验证边界。

- 记录日期：2026-11-06
- 基线提交：`f3ce852`（`fix(media): bind native direct routes to vpn network`）
- 版本：`pubspec.yaml` 为 `version: 0.6.0-alpha32+165`，对应标签 `v0.6.0.alpha32`
- 设备：`2410DPN6CC`，Android 16（SDK 36），已装 `0.6.0.alpha31 (164)`
- 验证级别：**L2**（跨 Dart 传输层、WebView 导航、原生媒体桥），L3 未执行

## 1. 缺陷与修复

四条独立成因，都在 “系统代理/路由层代理生效” 时才会暴露。

| # | 缺陷 | 修复 |
|---|---|---|
| 1 | `fetchToFile` 重试始终以 attempt 0 重新取路由，死代理被整轮重放 | 引入 `nextRouteAttempt` 与显式 `routeChangesLeft` 预算，失败推进到下一个 PAC 候选 |
| 2 | Media3 播放器走 `DefaultHttpDataSource`，完全不读系统代理 | `NativeMediaRuntime` 通过 `SystemMediaNetwork.mediaProxy` 注入 OkHttp 代理 |
| 3 | `ProxySelector` 报 DIRECT 时 LinkProperties 代理被丢弃，无第二候选 | `visibleProxyEndpoints` 保序追加、按 `host:port` 去重、不臆造 DIRECT |
| 4 | `router_fake_ip` 的网关 Fake-IP 被当作私网拒绝 | `NetworkPolicy.routeOwnsDns` 让网关 Fake-IP 与 VPN/TUN 同等放行；`resolve` 与放行共用同一谓词 |

附带修复：错误归因。`readableError` 增加 `rawDetail`，但**分类只读错误文本**；`net::ERR_*` 在 socket 匹配之前判定；只有 `err_proxy`/`err_tunnel` 改判为代理问题，其余保持既有文案。新增 `activeRoute` 通道（不解析 DNS）用于导航失败的代理诊断。

VPN 选择修正：`vpnNetwork`/`pickVpnNetwork` 不再只看 `activeNetwork`。规则模式下 Android 可以把底层 Wi-Fi 报为 active 而把 VPN 只放在网络列表里，`openMediaConnection` 的复查也改为只比对该 socket 所属的隧道。

## 2. 真机路由取证

`dumpsys` 与 `/proc/net/route` 实读，作为 `pickVpnNetwork` 与网关 Fake-IP 判定的依据。

路由层代理（OpenClash 软路由，clash 未起 TUN）：

```
WiFi CMCC-QMC  192.168.2.103/24
默认路由       0.0.0.0/0 -> 192.168.2.1 wlan0
DNS            192.168.2.1
能力           WIFI ... NOT_VPN&VALIDATED
系统代理       http_proxy=:0
```

对 `192.168.2.1:53` 直接查询：`www.baidu.com` 返回真实公网 A 记录（`36.152.44.93`），`github.com`/`www.google.com` UDP 超时、TCP 返回 0 答案。结论：当前软路由未开 Fake-IP，国内域名直连解析。

clash.meta 启用 TUN 后（`com.github.metacubex.clash.meta` 2.11.27）：

```
VPN 网络       ni{VPN CONNECTED extra: VPN:com.github.metacubex.clash.meta}
               InterfaceName: tun0  172.19.0.1/30  DNS 172.19.0.2
               策略 EVER_VALIDATED&IS_VALIDATED&IS_VPN
Active default 仍为 WIFI（底层 wlan0）
内核路由       tun0 只有 172.19.0.0/30；无 0.0.0.0/0
```

即：VPN 已建立并被验证，但 `activeNetwork` 指向 wlan0。按修复前的实现，`vpn` 判定为 false，媒体不会绑定隧道 socket —— 这正是 `pickVpnNetwork` 要覆盖的形态。

判定逻辑用设备真实状态代入验证：

```
router gateway fake-ip       -> ALLOWED
plain direct + fake-ip       -> BLOCKED(address policy)
router gateway + real ip     -> ALLOWED
router gateway + loopback    -> BLOCKED(address policy)
router gateway + private     -> BLOCKED(address policy)
```

私网/回环的拒绝边界未被放宽。

## 3. 本地验证（实跑）

`flutter test`、`:app:testDebugUnitTest` 与 `make acceptance` 在本机不可用：Flutter 官方 Linux 发行版仅 x86-64，容器为 aarch64，`flutter_tools.snapshot` 在 qemu 下 `SIGSEGV`（见 `/root/work/_env/site-lens-toolchain.md`）。以下为实际执行并通过的项目。

```
dart analyze lib test integration_test          -> No issues found!
dart format --set-exit-if-changed (改动文件)     -> 0 changed
check_regression_contracts.py                    -> PASS 9 contracts
generate_regression_matrix.py --check            -> PASS
check_ui_tokens.py                               -> PASS 15 tokens
test_android_proxy_fixture.py                    -> OK (10)
test_android_proxy_lease.py                      -> OK (21)
test_android_tools.py                            -> OK (48)
test_native_media_contract.py                    -> OK (38)
test_native_crash_contract.py                    -> OK (26)
test_android_backup_identity.py                  -> OK (13)
test_run_android_proxy_acceptance.py             -> OK (15)
test_release_pubspec.py / test_release_version.py-> PASS
node runtime / filter / page_inspector /
     media_lifecycle / media_episode_identity     -> PASS
```

分类逻辑以源码逐字抽取、在 aarch64 Dart 上实跑，未依赖推理：

- 既有契约保持不变：`net::ERR_INTERNET_DISCONNECTED` 仍返回 `页面请求失败，请刷新后重试`（`test/network_test.dart:18`），`network_test.dart` 与 `error_log_test.dart` 的 10 条既有断言全部成立。
- 代理归因正确：`ERR_PROXY_CONNECTION_FAILED`/`ERR_TUNNEL_CONNECTION_FAILED`、`proxy connect failed`、`Failed to authenticate with proxy`、`proxy_refused`、`proxy: connection refused`、`Failed to connect to proxy.example.com:7890` 均落到代理文案。
- 不误判：`Failed host lookup: proxy.example.com` 保持通用网络文案；URL 中出现 `net::ERR_PROXY_CONNECTION_FAILED` 一类片段不改变分类（`looksLikeUrl` 拦截 scheme 与无 scheme 域名两种形态）。

## 4. 独立审查

三轮只读审查，全部基于源码阅读与逻辑实跑，不修改工作区。

- 第一轮：CHANGES_REQUIRED。阻塞项为 DNS 拒绝文案把投毒/回环解析错误归因为代理设置。
- 第二轮：CHANGES_REQUIRED。确认文案已中性；新发现 `test/network_test.dart:18` 会因 `ERR_*` 改判而变红，且存在由 URL 驱动的反向分类通道。
- 第三轮：**两个阻塞项均已关闭，未发现 CI-red**，判词为可提交。

第三轮遗留的三条非阻断建议已在本提交内处理：删除 `_fetchToFile` 中只写不读的 `transportAttempt`；为两处 `currentRouteAttempt` 语义差异补充注释；`looksLikeUrl` 增加无 scheme 地址的兜底。

## 5. 未完成的门禁

- `flutter test` 与 Gradle/JUnit 未在本机执行；新增的 Dart 与 Kotlin 用例需由 CI 与真机确认。
- L3 设备验收（`make acceptance DEVICE=...`）未执行，手工清单保持待办。
- alpha32 的正式签名包由 `Release Site Lens` 工作流产出，本记录不涉及产物校验。

发布成功只说明 CI 构建与打包通过，不构成设备验收证据。

## 6. alpha32 装包后补充：媒体与更新未走 VPN

alpha32 装到设备后，站点检测与 WebView 正常，但媒体下载、媒体播放和更新链路仍从底层网络出行。根因与上一节不同：这三条链路不是"没找到 VPN"，而是**找到了却没有把 TLS 绑定上去**。

| 链路 | 缺陷 | 修复 |
|---|---|---|
| 媒体下载 | `openOkHttpConnection` 只设置 `socketFactory`，没有设置 `sslSocketFactory` | 两个槽位都由同一 `Network` 提供 |
| 媒体播放 | Media3 的 OkHttp 数据源只挂了 `proxy`，完全没有绑定隧道 | 有隧道时调用 `bindToVpn` |
| 更新下载 | `NativeUpdateService` 用独立 OkHttp 客户端，未绑定任何路由 | 每次传输按当前隧道重建客户端 |

OkHttp 的两处 socket 槽位相互独立：`socketFactory` 只覆盖明文和 TLS 的 TCP 段，TLS 握手由 `sslSocketFactory` 建。只设前者会让一个 HTTPS 请求横跨两个网络——TCP 进隧道、握手从底层出去，表现为"看着走了代理，实际 TLS 没走"。

其它约束：

- `Network.getSSLSocketFactory()` 自 API 29 起存在，minSdk 为 26，因此在更低版本只绑定明文槽位。
- 证书校验保持系统默认信任管理器，不引入自定义校验。
- `openConnection` 的 `context` 为可空参数，既有单测传 `open=` 注入时行为不变；`ResumableMediaTransfer` 同样以可空 `context` 传递。
- 代理跳同样需要绑定：CONNECT 本身就是一个 socket。

本地证据：`dart analyze` 干净，`SystemMediaNetworkTest` 现有 37 个用例（新增 1 个隧道优先用例）。`flutter test` 与 Gradle 单测仍需 CI 与真机确认。
