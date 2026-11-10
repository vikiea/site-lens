# Alpha 71 播放标题、任务组与系统透明探测验证

基线：`2b3baa4` (`v0.6.0.alpha70`)。目标版本：`0.6.0-alpha71+204`。

本轮集中处理两个问题：播放页标题没有可靠成为单集任务组名称；站点探测经过 Clash Meta 时超时，而 sing-box 下虽能成功但延迟偏高。修复保持原生媒体传输、系统代理、PAC、VPN/TUN、授权刷新和媒体身份边界不变。

## 播放标题与任务组

- 媒体生命周期只从当前活动播放 owner 的可见 DOM 读取标题，不读取 `epPlaySrcs`、`#videoInitialData` 或其他页面 JSON 标题。
- 单集原生播放和单集下载都必须先取得非空任务组名称，不再使用 `批量媒体` 兜底。
- 部分站点把播放器放在嵌套 frame；候选本身可能没有 `seriesTitle`。播放/下载入口会通过受控 WebView `inspect` 读取活动播放容器的可见标题，作为任务组名称。
- 该读取在请求前后校验 `HostSession` 身份、generation、当前 URL、`PageSnapshot.generation` 和 snapshot URL。same-document SPA 导航发生时不接受旧页面快照。
- 标题只用于 `batchDirectory`、展示和目录组织，不进入媒体授权、`cacheKey`、`resourceKey` 或候选去重身份。
- 已存在的无组任务在跳过重复下载前会补上任务组。
- `01`、`01-第1集`、`01.第1集`、`01·第1集` 等数字前缀不会再成为 MP4 目录；首集显示和导出文件名保持 `第1集`。

真机 `https://db7c0.adihsppe.cc/video/6233/?__view=mobile` 验收：

- 活动播放标题：`母上攻略`。
- 媒体候选：22 个 Apple HLS 候选。
- 首集任务组：`母上攻略`。
- 首集任务名：`第1集`。
- 测试后设备数据库 SHA-256 已恢复到测试前值。

标题/任务组验收与真实下载、MP4 导出验收分开记录。本页候选能够创建任务组，但没有把标题用例提前返回误报为完整下载导出验收。

## 探测与 WebView 网络

- 生产 discovery `HttpProbe` 不再并行使用应用层 `NativeSystemHttpTransport`，回到 Dart `HttpClient`，由 Android 系统、Clash/sing-box VPN、PAC、系统代理和 DNS 统一决定路由。
- 原生媒体传输和原生媒体授权继续使用既有系统路由实现，本变更不移除代理支持，不重新启用应用自选 `DIRECT` 或自定义路由轮换。
- Clash Meta 超时根因是本机同时存在 Chromium/系统路由和第二条应用层原生探测路由，导致相同目标被重复判定、排队，出现探测超时而 WebView 实际可访问。
- sing-box 下同样移除重复探测路由和额外请求队列；但本机未安装 `moe.nb4a`，本轮不能把 sing-box 真机结果声明为通过，后续需单独设备复核。
- WebView 对 `networkError` 采用 500 ms、1 s、2 s 三次有界重试；第四次停止。HTTP、证书和脚本错误不自动重载。
- `ERR_CONNECTION_CLOSED`、`ERR_CONNECTION_REFUSED`、DNS 失败、断网和代理拒绝显示对应用户文案，不再全部落入通用错误。

Clash Meta 真机环境：Xiaomi `M2102K1C`，Android 14，WebView `155.0.8059.43`，无线调试端点 `172.16.73.82:42287`。`dumpsys connectivity` 显示 Clash VPN 已连接，系统代理为 `127.96.59.142:37545` 并使用 PAC。

| 目标 | WebView | 生产 HTTP probe |
| --- | --- | --- |
| `huangguoai.pages.dev` | PASS，9 个链接 | `reachable`，513 ms |
| `huangguadj.cc/dizhi/` | PASS，40 个链接 | `reachable`，645 ms |

同一运行期间应用包列表包含 `com.github.metacubex.clash.meta`，不包含 `moe.nb4a`。

## 本地验证

- `./tool/check.sh`：PASS；863 项 Flutter 测试，以及 analyze、JS 运行时、媒体生命周期、Pigeon、Android 工具链、代理租约、回归矩阵和 UI token 契约全部通过。
- 媒体生命周期 Node 测试：40 项通过。
- Android tools Python 测试：49 项通过。
- `git diff --check HEAD`：PASS。
- 独立只读评审：当前快照 `APPROVE`，无 P0/P1。

## 真机 L3

`python3 tool/verify_level.py --level L3 --device 172.16.73.82:42287`：PASS。Android 集成套件 42 项通过、2 项环境门控跳过，覆盖 WebView host contract、导航租约、代理/PAC、后台媒体授权、Media3 TS/fMP4/AES-128/HEVC、播放租约、冷恢复、数据库备份恢复和 APK 身份。测试结束后用户数据库 SHA-256 恢复一致。

## 发布边界

源码和真机验证不等于 GitHub Verify、Release 工作流或正式 APK 安装验收。发布完成状态由对应 GitHub Actions 运行和 Release 资产记录；sing-box 真机复核仍是独立待验项。
