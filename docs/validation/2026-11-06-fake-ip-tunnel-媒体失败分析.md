# Fake-IP 隧道下的媒体与更新失败：clash.meta 与 sing-box 的行为差异

## Read this when

需要理解「同一台设备上 clash.meta 下媒体/下载/更新失败、切到 sing-box 后正常」的原因，或需要修改 `SystemMediaNetwork` 的 DNS 与路由策略时。

- 记录日期：2026-11-06
- 设备：`2410DPN6CC`，Android 16（SDK 36）
- 对照客户端：`com.github.metacubex.clash.meta` 2.11.27 / `moe.nb4a`（sing-box）
- 涉及代码：`android/app/src/main/kotlin/dev/vikiea/site_lens/SystemMediaNetwork.kt`

## 1. 现象

alpha34 装到设备后：

- 站点检测、WebView 浏览：正常；
- 媒体下载、媒体播放、更新下载：在 clash.meta 下失败，切到 sing-box 后全部正常。

因此问题不在「应用是否走 VPN」——两种客户端下应用都在 VPN 内。

## 2. 运行时证据

### 2.1 应用侧的路由诊断（`adb logcat`，tag `SiteLensMediaNetwork`）

```
epoch=0 resource=key {elapsedMs=91, phase=response_headers, attempt=4,
  route=vpn_tun_fake_ip, routeKind=vpn_tun_fake_ip,
  targetDnsMode=system_route, host=tp3.drleao.cn, offset=0,
  failureCategory=tls_handshake, networkEpoch=1, httpStatus=0,
  bytesWritten=0, outcome=retry}
```

五次尝试在 `vpn_tun_fake_ip` 与 `http_proxy` 之间交替，全部 `failureCategory=tls_handshake`，
最终抛出 `PlatformException(media_transfer, 媒体连接失败，已保留缓存，可重试)`。

要点：

- `route=vpn_tun_fake_ip` 说明应用**已经识别出 VPN**，并把连接交给了隧道；
- `failureCategory=tls_handshake` 说明失败发生在 TLS 握手，而不是路由选择或 DNS 解析；
- 交替出现的 `http_proxy` 说明 `planFor` 的代理回退分支也在工作。

### 2.2 clash 侧的连接日志

```
[TCP] 172.19.0.1:35414(dev.vikiea.site_lens) --> tp3.drleao.cn:443
      match DomainSuffix(cn) using DIRECT
[TCP] 127.0.0.1:46002(dev.vikiea.site_lens) --> tp6.drleao.cn:443
      match DomainSuffix(cn) using DIRECT
```

- 源地址 `172.19.0.1` 是 tun 侧地址，且 clash 正确识别了 `uid=10715 dev.vikiea.site_lens`；
- clash 把这两个域名判给了 `DomainSuffix(cn)`，结果是 **DIRECT**。

### 2.3 两个客户端对同一域名的解析结果

对 `172.19.0.2`（clash 的隧道内 DNS）直接发 A 查询：

```
tp3.drleao.cn    -> 198.18.0.147
www.baidu.com    -> 198.18.0.148
www.google.com   -> 198.18.0.149
```

clash.meta 对**所有**域名都返回 `198.18.0.0/15` 内的合成地址（Fake-IP）。
sing-box 默认不启用 Fake-IP（或仅对指定域名启用），返回真实地址。

### 2.4 内核路由表

```
/proc/net/route:
  tun0   172.19.0.0/30        ← 只有本地网段
  wlan0  192.168.2.0/24

dumpsys connectivity（VPN 的 LinkProperties 声明）:
  tun0   1.0.0.0/8, 2.0.0.0/7, ... 覆盖全部 IPv4
```

**声明与内核不一致**：VPN 网络向 ConnectivityService 声明了全网段路由，但内核路由表里
`tun0` 只有 `/30`。这正是规则模式 TUN 的形态：只有被 `Network.bindSocket` 绑定的 socket
才会走这些声明路由。应用侧的 `bindToVpn` 确实生效了（源地址 `172.19.0.1` 可证）。

## 3. 失败链

1. 应用通过隧道 DNS 解析媒体域名，得到 `198.18.0.147`；
2. `planFor` 判定「全部地址都是 Fake-IP」，走 `RouteKind.VPN_TUN_FAKE_IP` 分支，
   把 `198.18.0.147` 原样作为连接目标（`Proxy.NO_PROXY`）；
3. socket 经 `bindToVpn` 绑定，源地址落在 `172.19.0.1`，流量进入 tun；
4. clash 收到连接后**用 Fake-IP 反查出域名**，套用规则，命中 `DomainSuffix(cn)` → DIRECT；
5. clash 不再把 Fake-IP 当作自己的地址处理，而是按 DIRECT 出站；
6. 该出站路径无法完成到 `tp3.drleao.cn` 的 TLS 握手，应用侧表现为 `tls_handshake`。

关键点在第 4、5 步：**Fake-IP 只在隧道愿意接管时才是一个可用地址**。
规则一旦判 DIRECT，这个合成地址就指向空处。

sing-box 下同样的应用逻辑之所以正常，是因为它拿到的就是真实地址：
真实地址无论 tunnel 判 DIRECT 还是 PROXY 都能连。

## 4. 结论：clash.meta 与 sing-box 的三个 GAP

| # | 差异 | clash.meta | sing-box |
|---|---|---|---|
| 1 | DNS 策略 | 全量 Fake-IP，所有域名返回 `198.18.x.x` | 默认真实地址（fakeip 需显式开启与过滤） |
| 2 | 规则与 Fake-IP 的交互 | Fake-IP 反查域名后套用规则，可判 DIRECT；此后该地址不可用 | 无此耦合 |
| 3 | 应用侧假设 | 原实现假定「Fake-IP ⇒ 隧道必然接管」 | 不需要该假设 |

应用原实现把「检测到 Fake-IP」当成「路由可用」的充分条件，这在 clash 的规则模式下不成立。

## 5. 修复

原则：**Fake-IP 只是隧道的一种内部表示，不能作为连接目标的唯一来源。**
媒体与更新需要的是「能连上」，不是「按域名分流」；因此在这些链路上优先使用真实地址。

### 5.1 合成地址降级（核心）

`planFor` 新增 `preferRealAddress` 与 `resolveReal`：

- 默认行为不变（继续使用隧道的合成地址）；
- 当调用方要求真实地址时，改用 `resolveReal` 的结果，且要求结果不是 Fake-IP；
- 路由种类仍是 `VPN_TUN_FAKE_IP`，`dnsClass` 变为 `real_address`，便于诊断。

### 5.2 失败驱动降级

新增 `SystemMediaNetwork.FakeIpFallback`：

```
observe(host, routeKind, failureCategory)
  → 仅当 routeKind 含 fake_ip 且失败为 tls_handshake / certificate 时，标记该主机
preferRealAddress(host)
  → 已标记的主机在下一次 openMediaConnection 中使用真实地址
```

接入点：

- `MediaNetworkRuntime`：前台媒体传输，一次任务内累计；
- `NativeMediaDownloadWorker`：后台下载，一次 worker 调用内有效，后续 WorkManager 重试重新探测。

### 5.3 播放与更新直接使用真实地址

Media3 播放（`NativeMediaRuntime`）与 APK 下载（`NativeUpdateService`）的 OkHttp 解析器
在隧道 DNS 返回纯 Fake-IP 时回退到系统解析：

```kotlin
val answer = tunnel.getAllByName(hostname).toList()
if (answer.isEmpty() || answer.any { !fakeIp(it) }) return answer
return runCatching { Dns.SYSTEM.lookup(hostname) }.getOrElse { answer }
```

这样在 clash.meta 下不再依赖规则是否接管，在 sing-box 下行为不变。

## 6. 验证状态

- `dart analyze lib`：通过；
- Kotlin 结构检查（括号平衡、签名一致性）：通过；
- 核心降级逻辑以等价 Java 片段对 `android.jar` 编译并运行，语义正确；
- 新增 `SystemMediaNetworkTest` 用例：合成地址降级、`FakeIpFallback` 标记条件与大小写匹配。

**未完成**：本机为 aarch64，`flutter test` 与 Gradle 单测无法执行；
设备验证（clash.meta 下媒体下载/播放/更新）需在安装本版本后确认。

## 7. 边界与取舍

- 降级只影响**媒体与更新**链路，站点导航与脚本仍使用隧道的解析结果；
- 使用真实地址后，按域名分流对这些流量不再生效——这是有意的取舍，媒体需要的是可达性；
- 私网与回环地址的拒绝逻辑未放宽：降级路径同样要求答案不是本机/私网地址；
- `Network.getSSLSocketFactory()` 自 API 29 起存在，更低版本只绑定明文槽位。
