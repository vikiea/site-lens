# 易幕（com.easyl.app）逆向分析报告

分析时间：2026-11-01 02:10（Asia/Shanghai）
样本来源：设备实测拉取（Xiaomi 2410DPN6CC / Android 16）

---

## 0. 一句话结论

易幕是一个**远端配置驱动 + JavaScript 源脚本解析 + 本地代理播放**的影视/直播聚合客户端：所有业务接口地址、内容源、广告开关、会员权益全部由服务端下发；代码层用 StringFog XOR 做字符串加密、用 Keystore 位掩码保护会员权益、用原生 so 做反 root/反 Frida；APK 未加壳，字符串可 100% 还原，权益存在可降级的本地伪造路径。

---

## 1. 样本指纹

| 项目 | 值 |
|---|---|
| 包名 | `com.easyl.app` |
| 应用名 | 易幕 |
| 版本 | 1.0.6（versionCode 50） |
| minSdk / targetSdk / compileSdk | 26 / 35 / 35 |
| 文件大小 | 55,512,314 字节（解压后 125,849,947） |
| MD5 | `97146d0e5dd51b6bebd0f89b71709bd5` |
| SHA-256 | `c851c05ca58f4796ff8179e9e6dd8ea9611f511b697ffcb7d41cec997d2779a8` |
| 签名 | v2 自签，`CN=Easyl, O=Easyl, OU=Easyl, L=Beijing, ST=Beijing, C=CN` |
| 证书有效期 | 2026-09-22 → 2056-09-14（30 年） |
| 证书 SHA-1 | `C3:04:DA:04:29:C0:3A:A0:82:1D:D6:07:8D:A0:9B:E4:FB:7A:EB:26` |
| 安装方式 | `com.android.shell` 侧载，首装 2026-10-08，最后更新 2026-10-31 00:39 |
| 加固 | **无壳**（无 jiagu/shella/DexHelper/mobisec 等特征） |
| 字符串保护 | **StringFog（XOR + Base64）**，共 13,403 条密文，已全量还原 |

DEX：6 个，字符串总数 352,063；自有代码 363 类（`com.easyl.*`）。

---

## 2. 技术栈

| 层 | 实现 |
|---|---|
| 语言/UI | Kotlin + Jetpack Compose（无 XML 布局主界面） |
| 网络 | OkHttp3 + 自研 ECC 加密通道 `com.hzhj.libs.n8.d` |
| 播放 | ExoPlayer(media3) + **mpv(libmpv)** + **FFmpeg(libav\*)** + 字节 ijk(ttmplayer/avmdl) 多内核 |
| 脚本 | **QuickJS**（`com.whl.quickjs`）执行源解析脚本 |
| 插件化 | 字节 **Zeus / pangle** 插件框架（广告 SDK 动态加载） |
| 下载 | 迅雷 SDK（`libxl_thunder_sdk.so`）+ 自建下载服务 |
| 图片 | 自研 shader/`libimage_processing_util_jni.so`、`assets/shaders` |
| 本地服务 | `127.0.0.1:18888`（下载分发）、`127.0.0.1:18889`（播放代理/转发） |

---

## 3. 组件与攻击面

- **Activity 212 个**，其中约 190 个是广告 SDK 桩（`com.mobads.vivatb.host.stub.*`、`com.beizi.*`、`com.kwad.*`、`com.qq.e.*`），自有仅 5 个：
  `com.easyl.app.SplashActivity`、`MainActivity`、`ui.live.LivePlayerActivity`、`ui.crash.CrashActivity`、`probe.CencProbeActivity`
- **Service 21 个**（含 `com.easyl.core.download.ThunderService`、`com.easyl.ui.download.DownloadService`、`com.easyl.ui.room.RoomHostService`）
- **Provider 17 个**（各广告 SDK FileProvider + `com.byazt.bsm.MainProcessProviderProxy` 等）
- **导出组件 5 个**：`SplashActivity`、`com.kwad.auth.login.KwadRouteHandlerActivity`、两个抖音直播代理 Activity、`ProfileInstallReceiver`

配置层面弱点：

1. `android:usesCleartextTraffic="true"` —— 允许明文 HTTP，方便中间人。
2. `allowBackup=false`（正常），`debuggable` 未开。
3. `REQUEST_INSTALL_PACKAGES` + 更新器可下载并安装 APK（自带签名校验，见 §7）。
4. `MANAGE_EXTERNAL_STORAGE`（所有文件访问）—— 因此能在 `Download/易幕/` 直接落 `.ts` 分片；实测该目录下有大量 HLS 分片。
5. `QUERY_ALL_PACKAGES` + `GET_TASKS` —— 可枚举已装应用。
6. `CencProbeActivity` 内置一个硬编码的字节 CDN 视频 URL（`v5-ex-reading-video-a.qznovelvod.com/...`），是播放内核的调试/探测页；未导出，可用 `am start -n`（同 uid/调试权限）拉起，属于潜在本地测试面。

---

## 4. 权限与隐私采集

申请 25 项权限，重点：

```
MANAGE_EXTERNAL_STORAGE, READ/WRITE_EXTERNAL_STORAGE
REQUEST_INSTALL_PACKAGES, QUERY_ALL_PACKAGES, GET_TASKS, REORDER_TASKS
ACCESS_FINE_LOCATION, ACCESS_COARSE_LOCATION, ACCESS_WIFI_STATE, CHANGE_WIFI_STATE
CAMERA, FOREGROUND_SERVICE(_DATA_SYNC), POST_NOTIFICATIONS, WAKE_LOCK
com.asus.msa.SupplementaryDID.ACCESS   ← OAID 获取（MSA 联盟 SDK）
com.easyl.app.openadsdk.permission.TT_PANGOLIN  ← 穿山甲私有权限
```

设备指纹采集面（dex 字符串计数）：`oaid` 216 处、`imei` 13、`device_id` 10、`mac_address` 4；配套原生库 `libBZDevInfo.so`、`libdevInfo.so`、`libplt-base.so`、`libsgcore.so`。

> 实际采集由各家广告 SDK 各自完成（穿山甲/优量汇/快手/百度/倍孜/Octopus/Sigmob 各有一套设备信息模块），属于国内聚合广告的常规形态，但对用户而言是 7 份独立画像。

---

## 5. 第三方 SDK 清单

| 类别 | SDK | 特征类/库 |
|---|---|---|
| 广告 | 穿山甲（CSJ/GroMore） | `com.byazt.*`、`libpanglearmor.so`、`libtt_ugen_layout.so`、`com.bytedance.pangle.*` |
| 广告 | 优量汇/广点通 | `com.qq.e.*`、`assets/gdt_plugin` |
| 广告 | 快手 | `com.kwad.*` |
| 广告 | 百度百青藤 | `com.baidu.mobads.*` |
| 广告 | 倍孜 BeiZi | `com.beizi.ad.*`、`libBZDevInfo.so` |
| 广告 | Octopus | `com.octopus.ad.*`、`liboctopus.so` |
| 广告 | Sigmob | `com.mobads.vivask.*`、`com.mobads.vivatb.*` |
| 播放 | 字节 ttmplayer / avmdl | `libttmplayer_lite.so`、`libavmdl_lite.so` |
| 播放 | mpv / FFmpeg | `libmpv.so`、`libavcodec.so` |
| 下载 | 迅雷 | `libxl_thunder_sdk.so`、`com.xunlei.open.dlsdk.*` |
| 脚本 | QuickJS | `libquickjs-android-wrapper.so` |
| 安全 | 自研 | `libeksec.so` |

---

## 6. 业务架构

### 6.1 远端配置（一切的总开关）

`com.easyl.core.config.b`（tag = `RemoteConfig`），**primary / backup 双通道**拉取，通过 ECC 加密通道 `com.hzhj.libs.n8.d.a.B(url, okhttp, authStorage)` 获取，解析为 `RemoteConfigModel`：

```json
{
  "version": ..., "updatedAt": ...,
  "ads":   {"enabled","splash","interstitial","banner","feed","rescue",...},
  "sources": [...], "pages": [...], "web": ..., "video": ..., "search": ...,
  "auth": ..., "barrage": ..., "comments": ..., "room": ..., "feedback": ...,
  "contact": ..., "block": ..., "announcement": ..., "announceBarrage": ...,
  "homeBanners": [...], "adSkipUrls": [...], "fallbackSourceKey": "...", "update": ...
}
```

从反编译出的 Kotlin 属性名可确认真实远端字段（未经混淆）：

```
apiBaseUrl 组：authApiBaseUrl / barrageApiBaseUrl / commentsApiBaseUrl
                / feedbackApiBaseUrl / roomApiBaseUrl
广告组：adsEnabled, adsSplashEnabled, adsSplashColdOnly, adsSplashTimeoutMs,
        adsSplashCooldownSec, adsSplashHotMinBgSec, adsInterstitialEnabled,
        adsInterstitialCooldownSec, adsBannerCooldownSec, adsFeedEnabled,
        adsFeedEveryPages, adsRescueGuestDailyLimit, adsDailyFreeAdCount
功能组：authEnabled, barrageEnabled, barrageSendEnabled, barrageMaxPerPage,
        commentsEnabled, feedbackEnabled, roomEnabled, registerEnabled,
        inviteEnabled, requireEmailVerification, hotSearches, websiteUrl, agreementUrl
```

**推论**：APK 内不含主业务域名（静态搜到的 `easyl.ltd` 只是分享文案里的官网），所有 API 基址、内容源、开关都靠首次配置拉取下发 —— 想拿到完整接口清单必须抓包或攻破配置通道。

### 6.2 内容源与解析引擎

`com.easyl.data.source` 下的数据模型（字段未混淆）：

- `VideoSource`：`sourceKey, apiURL, title, type, mode, enabled, category, logo, searchable, mediaType, reserved, desc, kind, code, **vip**, beta`
- `SourceBundle` / `SourceItem`：`key, code, codeUrl, codeVer, ext, kind, adult, danmuOnly, defaultKey, defaultOff, forceOff, disabled, enabled, order, sources`
- `Episode` / `VideoItem` / `SourceResult` / `SourceImportResult`

`SourceScriptRunner` 用 **QuickJS 执行远端 JavaScrip t源脚本**得到搜索结果/详情/播放地址；脚本缓存用 `easyl_script_keystore_v1` + `SK1:` 前缀的 Keystore 密钥加密落盘。
即：**这是一个"源可插拔"的聚合器**（类似 TVBox/影视仓的形态），`adult` 字段表明存在成人内容源分类开关，`vip` 字段表明源可标记为会员专享。

元数据侧对接豆瓣：`https://m.douban.com/rexxar/api/v2/`、`https://frodo.douban.com/rexxar/api/v2/`，内置 apikey `0ac44ae016490db2204ce0a042db2916`。

### 6.3 播放链路

1. 源脚本返回播放地址 → 2. 本地代理 `http://127.0.0.1:18889/{token}/p/{id}/{url}` 转发（处理 Referer/UA/分片/解密）→ 3. ExoPlayer / mpv 播放。
2. 下载任务由 `http://127.0.0.1:18888/{token}/{taskId}/{fileName}` 暴露给播放器边下边播。
3. 直播：`ui.live.LivePlayerActivity` + `ui.live.a` 拉 EPG：`https://www.jdbus.net/epg/{频道名}.json`。

### 6.4 社交与运营

- 房间：`RoomHostService`、`RoomChat/RoomMember/RoomVideo`，WebSocket `…/room/{roomId}/ws?token=…&caps=rate`
- 弹幕 / 评论 / 反馈 / 邀请（Invitee）/ 福利（WelfareDto、WelfarePlan）
- 分享文案：`我正在用 易幕 看《影片》（演员）…更多资源，官网：https://www.easyl.ltd`
- 更新：下载 `easyl_update.apk`，域名白名单 `jdbus.net` / `*.jdbus.net` / `*.r2.cloudflarestorage.com`，并做签名一致性校验。

---

## 7. 安全机制

| 机制 | 位置 | 说明 |
|---|---|---|
| 字符串加密 | `com.hzhj.libs.j8.y4` → `StringFogImpl` | XOR + Base64，**已全量解密**（13,403 条） |
| 原生反 root | `libeksec.so` → `nativeHasRootArtifacts` | 检查 `/data/adb/magisk`、`/proc/self/mount`，检测 Magisk |
| 反调试/代理探测 | `libeksec.so` → `nativeIsCompromised` | `socket + inet_pton + connect` 探测 `127.0.0.1` 常见 Frida/代理端口 |
| Hook/完整性检测 | `com.easyl.core.config.b` | `g.a.b(context)` 返回 `HOOK` 时直接产出 `INTEGRITY_HOOK`，配置通道拒绝工作 |
| 配置加密传输 | `com.hzhj.libs.n8.d` | 自研 ECC（"ecc config ok"），失败走 backup 通道 |
| 权益防篡改 | `AuthStorage` + Keystore | 权益位掩码加密存 `ent_flags_enc`，解密失败降级全 false |
| 脚本缓存加密 | `SourceScriptRunner` | `easyl_script_keystore_v1` + `SK1:` |
| 更新防替换 | `ui.settings.a` | 校验 `getApkContentsSigners()` 与自身签名 |

---

## 8. 会员与权益体系（含可利用点）

`AuthStorage$AuthState`（30 字段，全部未混淆）：

```
token, userId, username, nickname, email, emailVerified, isGuest, isVip, vipExpireAt,
tier, goldUntil, diamondUntil, supremeUntil, beta,
entAdfree, entUnlockAll, entDanmakuSend, entCloudSync, entHdQuality,
entMultiThreadDownload, entCast, entExclusiveTheme, entVipBadge, entAvatarFrame,
qq, avatarUrl, adfreeRebindBlocked, adfreeRebindWaitDays, nicknameChangedAt
```

档位：`free / gold / diamond / supreme` + `beta`。

### 权益位掩码（`AuthStorage.b(int)`）

| bit | 值 | 权益 |
|---|---|---|
| 0 | 1 | VIP |
| 1 | 2 | 免广告 adfree |
| 2 | 4 | 解锁全部 unlockAll |
| 3 | 8 | 发弹幕 |
| 4 | 16 | 云同步 |
| 5 | 32 | 高清画质 |
| 6 | 64 | 多线程下载 |
| 7 | 128 | 投屏 |
| 8 | 256 | 专属主题 |
| 9 | 512 | VIP 标识 |
| 10 | 1024 | 头像框 |

全开 = `2047`。

### 存储与降级路径（关键）

`SharedPreferences("easyl_auth" / "AuthStore")`：

```
ent_flags_enc   ← Keystore 加密后的位掩码（优先）
token_enc       ← 加密 token
is_vip, ent_*   ← 明文布尔（仅当 ent_flags_enc == null 时使用）
```

读取逻辑（`AuthStorage.k()`）：

```java
String enc = sp.getString("ent_flags_enc", null);
if (enc == null) {
    return new EntFlags(
        sp.getBoolean("is_vip", false),
        sp.getBoolean("ent_adfree", false),
        sp.getBoolean("ent_unlock_all", false), …);
}
Integer v = parseInt(decrypt(ctx, enc));
return v != null ? b(v) : EntFlags(全部 false);
```

**利用点**：`ent_flags_enc` 置空 → 走明文分支。只要能把 `is_vip=true, ent_adfree=true, ent_unlock_all=true, ent_*` 全部写成 `true`，界面层权益立即全亮；再写 `2047` 对应的加密串（需 Keystore 密钥，属于同 App 进程内可行、跨设备不可行）可保持。
局限：内容接口与源 `vip` 标记仍由服务端判定，播放/视频地址仍可能被服务端拒发；但**广告展示、画质选项、投屏、多线程下载、主题、弹幕发送权**这些纯客户端开关会真实放开。

---

## 9. 广告体系

- 7 家 SDK 并存，由远端 `ads.*` 统一调度（开关、冷却、每日次数、冷启动专属、游客救急次数）。
- 客户端 `com.easyl.core.ads.AdsLog`、`com.easyl.data.source.AdsConfig/AdsSplashConfig/AdsInterstitialConfig/AdsFeedConfig/AdsRescueConfig` 完整建模。
- `adSkipUrls` 下发给播放器，用于跳过片头广告位。
- 结论：**关广告不能只靠 patch 客户端**，因为 `adsEnabled` 来自服务端；但断掉广告 SDK 域名 + 伪造 `ent_adfree` 可以在展示层生效。

---

## 10. 可改造 / 可攻击点清单

| # | 点 | 做法 | 难度 |
|---|---|---|---|
| 1 | 本地权益伪造 | 清空 `ent_flags_enc` + 写明文布尔键（需 root/Shizuku 或改包） | 低 |
| 2 | 广告屏蔽 | hosts/防火墙拉黑 7 家广告域名（`*.pangolin-sdk-toutiao.com`、`gdt.qq.com`、`*.adkwai.com`、`sigmob.cn`、`cpro.baidustatic.com` 等）+ 伪造 `ent_adfree` | 低 |
| 3 | 自定义内容源 | 配置通道中 `sources[]` 可注入自有 `apiURL` + JS 脚本（`SourceScriptRunner`），VOD/直播均可 | 中（需绕过 ECC + 完整性检测） |
| 4 | 抓包 | `usesCleartextTraffic=true`，自签证书无 pinning 迹象，设备装 mitmproxy CA + TUN 即可拿下全部 API | 低 |
| 5 | 反 root/Frida 绕过 | Hook `EkSecNative.nativeHasRootArtifacts/nativeIsCompromised` 返回 false；同时屏蔽 `g.a.b()=="HOOK"` | 中 |
| 6 | 调试页 | `CencProbeActivity` 可被 `am start -n` 拉起，验证播放内核能力/任意 URL 播放 | 低 |
| 7 | 更新劫持 | 下载域名白名单仅 `jdbus.net`/R2，若可中间人替换则受签名校验保护，需同时拿到同签名密钥（不可行） | 高 |

---

## 11. 复现工具链（本次实际使用）

```bash
# 1. 设备侧取证（无 root，Shizuku/ADB shell 通道）
pm path com.easyl.app
cp /data/app/~~…/com.easyl.app-…/base.apk /sdcard/Download/DSHA/easyl.apk
# 2. 传输：设备 Termux 走 127.0.0.1 回环上传到容器（本环境已验证可行）
curl -T /sdcard/Download/DSHA/easyl.apk http://127.0.0.1:8931/easyl.apk
# 3. 反编译
java -Xmx3g -cp jadx-1.5.1-all.jar jadx.cli.JadxCLI -d src --no-res classes5.dex
java -jar apktool.jar d -r -f -o apkout easyl.apk     # 取 smali（jadx 反编译失败的方法）
# 4. StringFog 解密（自写 30 行脚本，见 src_plain）
#    明文 = base64decode(cipher) XOR base64decode(key)
```

---

## 12. 产物

| 文件 | 说明 |
|---|---|
| `raw/easyl.apk` | 原始样本 55.5 MB |
| `src5/` | classes5.dex 反编译 Java（2,798 文件） |
| `src_plain/` | **已解密的明文版源码**（409 文件，13,403 条字符串还原） |
| `apkout/smali_classes5/` | smali（补 jadx 反编译失败的方法） |
| `apk_probe.py` | APK 静态三件套解析（AXML/ARSC/DEX） |
| `dex_summ.py` | 方法级字符串/调用摘要器 |
| `easyl_strings.txt` | 35 万条 dex 字符串全量导出 |

---

## 13. 结论与建议

1. **性质**：内容聚合型影音客户端，业务完全"云端化"，APK 只是空壳 + 播放器 + 广告容器。合规风险集中在成人源分类开关（`adult`）、7 家广告 SDK 的设备指纹采集、以及 `MANAGE_EXTERNAL_STORAGE`。
2. **强度评估**：代码混淆只做到"字符串 XOR + 类名重命名"，业务模型（AuthState/VideoSource/RemoteConfigModel）字段全部裸奔，属于**中低强度保护**；真正的防线是服务端配置 + 原生反调试。
3. **若目标是"用得舒服"**：优先做网络层广告域名阻断 + 本地权益降级伪造，成本最低、见效最快。
4. **若目标是"接自己的源"**：核心是拿下配置通道（ECC）+ 通过完整性检测，之后 `sources[]` 注入 JS 源即可，无需改 dex。
5. **若目标是"长期维护"**：该 App 更新会走 `easyl_update.apk` + 签名校验，任何 dex patch 都会被覆盖，改包方案必须自行重签并关闭更新检查。
