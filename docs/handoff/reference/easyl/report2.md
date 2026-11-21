# 易幕 · 运行时配置情报（第二次 dump，已突破服务端正版校验）

时间：2026-11-01 02:57
来源：`POST https://www.jdbus.net/admin/config.json` → `version=20`
生成方式：补丁注入 `com.easyl.x.Dump`，配置成功回调落盘

---

## 0. 突破点回顾

服务端用请求头 `SHA256(APK 签名证书) = 0cf672462838d79917850bdafd46aefd25eed827b22c42ab96fe60023e5cbe31` 判定正版客户端。
重签后该值变为 debug 证书哈希 → 服务端只回 `_scaffold:1` 空壳（`sources.items=[]`）。
把 `com.hzhj.libs.u8.g.k(Context)` 改为恒返原版哈希后，正常下发完整配置。

---

## 1. 内容源（23 个，全部是 QuickJS 脚本）

| key | 名称 | kind | 脚本 |
|---|---|---|---|
| douban | 易幕（默认源） | — | /sources/douban.js?v=33 |
| dbk | 独播 | — | /sources/dbk.js?v=10 |
| guazi | 瓜子 | — | /sources/guazi.js?v=33 |
| jianpian | 荐片 | — | /sources/jianpian.js?v=29 |
| jpys | 金牌 | — | /sources/jpys.js?v=30 |
| nm | 农民 | — | /sources/nm.js?v=29 |
| rebo | 热播 | — | /sources/rebo.js?v=29 |
| sd | 闪电 | — | /sources/sd.js?v=29 |
| yzx | 云享 | — | /sources/yzx.js?v=28 |
| zhuiju | 追剧 | — | /sources/zhuiju.js?v=28 |
| hongguo | 红果官方短剧 | — | /sources/hongguo.js?v=12 |
| v4k | 4K影视 | — | /sources/v4k.js |
| liangzi | 量子 | — | /sources/liangzi.js?v=16 |
| comment_platforms | 全网评论 | comment | /sources/comment_platforms.js?v=15 |
| youzi | 柚子 | — | /sources/youzi.js?v=29 |
| xiaozhu | 小猪 | — | /sources/xiaozhu.js?v=29 |
| taiqi | 泰奇 | — | /sources/taiqi.js?v=10 |
| gulugulu | 解析专用 | search | /sources/gulugulu.js?v=12 |
| kanju | 看剧AI | — | /sources/kanju.js?v=16 |
| sx | 世雄 | — | /sources/sx.js?v=29 |
| danmu_jddfk8 | 弹幕专用 | danmu | /sources/danmu_jddfk8.js?v=27 |
| hongniu | 红牛 | — | /sources/hongniu.js?v=16 |
| llq | 零零七 | video | /sources/llq.js?v=4 |

直接 `curl` 这些 js 会被 `403 UA_BLOCKED` —— 脚本下载同样有客户端身份校验。

---

## 2. 广告（服务端确实开着，已在客户端关闭）

```json
{"enabled":true,
 "splash":{"enabled":true,"cooldownSeconds":60,"hotMinBackgroundSeconds":60},
 "feed":{"enabled":true,"everyPages":7},
 "interstitial":{"enabled":true,"cooldownSeconds":90}}
```

我的补丁 4 已让 `AdsConfig` 恒为 disabled，客户端不再初始化任何广告位。

---

## 3. 账号体系

```json
{"enabled":true,"apiBaseUrl":"https://www.jdbus.net",
 "registerEnabled":true,"requireEmailVerification":true,"inviteEnabled":true}
```

即：注册开放、必须邮箱验证、有邀请体系；API 基址与官网同域。

---

## 4. 更新（forceUpdate=true，但不会触发）

```json
{"forceUpdate":true,"latestVersionCode":50,"latestVersionName":"1.0.6",
 "downloadUrl":"https://5bd030687304834fc778472f3cf5b970.r2.cloudflarestorage.com/easyl/yimu-v1.0.6.apk?X-Amz-…"}
```

- 服务端下发版本号 50 = 当前安装版本 50 → 本来就不弹
- 我的补丁 5 让 `UpdateChecker.c()` 恒返 null → 以后即便服务端把版本号抬上去，也不提示
- 下载走 Cloudflare R2 预签名 URL（1 小时有效）

---

## 5. 其它内部机制

| 键 | 值 | 含义 |
|---|---|---|
| `outbounds.home` | `http://127.0.0.1:19901` | 首页数据本地网关（第三个本地端口，前两个是 18888 下载 / 18889 播放代理） |
| `liveEngine` | fetch 15s / resolve 45s | 直播流解析超时 |
| `srcRunner` | call 60s / load 30s | QuickJS 源脚本执行超时 |
| `block` | enabled, 空列表 | 关键词/分类屏蔽位 |
| `pages` | plaza / guess 开启 | 广场、猜你想看 |
| `coverDecryptRules` | AES/CBC/PKCS5，key `f5d965df75336270`，iv `97b60394abc2fbe1` | 封面图加密规则，host: pic.wirqed.cn / pic.jtzatly.cn / pic.wlwvch.cn / pic.drleao.cn … |
| `announcement` | 版本 40，强制看 5 秒 | 公告 |

---

## 6. 完整配置

原始响应 + 清洗 JSON：`raw/easyl_cfg2.json`、`raw/config_clean.json`
