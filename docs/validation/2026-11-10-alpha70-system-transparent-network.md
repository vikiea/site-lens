# Alpha 70 系统透明网络与原生媒体传输验证

基线：`4206b0f` (`v0.6.0.alpha69`)。目标版本：`0.6.0-alpha70+203`。

本轮修复让站点探测和原生媒体传输继续以 Android 系统 `ProxySelector`/PAC 为唯一路由权威，并处理三类实测问题：16 MiB HLS 清单超过旧的 8 MiB 原生缓冲上限；本机代理连接需要 HTTP/1.1 兼容；代理链路验收需要与生产相同的原生媒体传输入口和足够的单请求预算。

## 实现边界

- 系统返回 `PROXY` 或 `SOCKS` 时按原顺序连接该路由；系统返回 `DIRECT` 时直接连接，应用不插入、轮换或改写候选。
- HTTP/SOCKS 代理下的缓冲请求和可续传自有传输使用 HTTP/1.1；DIRECT 保留 OkHttp 的正常协议协商。
- 缓冲响应上限由 8 MiB 提升到 16 MiB，与 HLS 清单预算和 Dart 回退路径一致。
- `HttpProbe` 的单请求预算可显式配置；生产默认仍为 5 秒，代理专用集成测试使用 20 秒，`ProbeCoordinator` 的总门禁不变。
- WebView 继续由 Chromium 管理网络；DLNA 保留 LAN 直连例外。
- 路由诊断只记录 `PROXY`/`SOCKS`/`DIRECT`、稳定失败分类和异常类，不记录 URL、查询参数、请求头、Cookie 或授权值。

## 真机路由证据

设备：Xiaomi `M2102K1C`，Android API 34，WebView `155.0.8059.43`，无线调试端点 `172.16.73.82:42287`。三类测试均使用同一中性公开 AES-128 HLS 样本，覆盖 WorkManager 健康请求、原生 manifest/key/segment 下载和缓存 Media3 播放。

| Case | 系统状态 | App 路由 | 结果 |
| --- | --- | --- | --- |
| Clash 规则模式 | VPN 运行，规则模式 | `media routes=PROXY` | PASS；Clash 将 GitHub 目标按 `DomainKeyword(github)` 送入代理节点 |
| Clash 全局模式 | VPN 运行，全局模式 | `media routes=PROXY` | PASS；Clash 对同一目标标记 `using GLOBAL` |
| 代理关闭 | VPN 停止，`http_proxy=:0` | `media routes=DIRECT` | PASS；四次原生请求均直连并完成 |

三类结果均为 `HEADLESS_HEALTH_PASS reachable=true` 和 `NATIVE_ENCRYPTED_HLS_PASS`：key 为 16 字节、segment 为 2,361,664 字节、Media3 播放进度超过 10 秒。测试结束后 VPN 恢复为“运行中 + 规则模式”，设备数据库恢复到测试前 SHA-256。

补充无 VPN 全局代理矩阵通过：HTTP 重定向与 HLS、HTTPS probe、Dart fetch、原生 TLS、WorkManager 和 HLS 均产生双向字节；结果记录 `fixtureConnects=12`、`forwardedConnect=17`、HLS 2 个 segment 和 1 个 init segment，资源 SHA-256 一致。

## 站点与回归证据

- 配置站点 `huangguoai.pages.dev` 在 App WebView 加载成功并发现 9 个链接；`huangguadj.cc` 加载成功并发现 40 个链接。两站分别以生产默认 5 秒原生 `HttpProbe` 在 389 ms 和 771 ms 内返回 `reachable`。
- 用户提供的真实视频页在规则模式下加载成功，发现 8 个媒体候选；该站点当前返回空的 `epPlaySrcs`，严格的真实剧集资源绑定用例因此不能进入下载阶段。该证据不替代中性 HLS 的路由与传输验收。
- `./tool/check.sh`：856 项 Flutter 测试及 analyze、脚本运行时、Pigeon、Android 工具链、代理租约、回归矩阵和 UI token 契约全部通过。
- `./gradlew :app:testDebugUnitTest`：PASS。
- `python3 tool/verify_level.py --level L3 --device 172.16.73.82:42287`：44 个 Android 集成测试通过，覆盖 WebView host contract、代理 HLS、Media3 TS/fMP4/AES-128/HEVC parity、DLNA、媒体生命周期、数据库备份恢复和正式 APK 身份；设备数据库恢复 SHA-256 一致。

## 评审与发布边界

独立只读评审结论为 `APPROVE`，无 P0/P1。评审保留一项边界：远端 Media3 和 APK 更新客户端继续遵循系统代理，但不强制 HTTP/1.1；代理 HLS、后台 WorkManager、缓存 Media3 和原始 5 秒站点探测已分别通过本轮验证。

源码验证不代表 GitHub Verify、Release 工作流或正式 APK 安装验收。发布完成状态由 GitHub Actions 与 Release 资产记录，正式包安装后的业务验收另行记录。
