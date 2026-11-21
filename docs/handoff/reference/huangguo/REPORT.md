# 黄果短剧（top.ultqd.hypnfq）逆向分析报告

- 样本：`top.ultqd.hypnfq` v1.7.0 (versionCode 170)
- 原始 APK SHA-256：`e45b8f356adb1debbd21fbb58858d744c257a8c39fdb0a83151894b1b4876b8c`
- 技术栈：Flutter（Dart 3.4.3 AOT，snapshot `d20a1be77c3d3c41b2a5accaee1ce549`，arm64-v8a 单 ABI）
- 入口：`com.org.aksm.MainActivity`
- 原生库：`libapp.so`（业务 Dart AOT）、`libflutter.so`、`libijkplayer`/`libijkffmpeg`/`libijksdl`（IJK 播放器）

---

## 一、抓取与解包路径

```
adb shell pm path top.ultqd.hypnfq
→ /data/app/~~.../base.apk      （25,423,832 字节，单 base.apk，无 split）
```

- 包内 `META-INF/` 仅有 `RELEASE-.RSA` / `RELEASE-.SF` / `MANIFEST.MF`，v2/v3 签名块存在
- 双 ABI 不存在，只有 `arm64-v8a`
- Flutter assets 位于 `assets/flutter_assets/`，业务逻辑**不在**其中，全在 `libapp.so`

---

## 二、签名体系（这是重打包的第一个硬约束）

| 项 | 值 |
|---|---|
| 签名方案 | v1 (JAR) + v2 + v3，无 v3.1，无源戳（source stamp） |
| 证书主体 | `C=SG, O=App, OU=Mobile, CN=Release-2`（自签，Issuer = Subject） |
| 序列号 | `2CFF2352793252FB` |
| 有效期 | 2026-11-20T14:14:53Z ~ 2054-04-07T14:14:53Z |
| 公钥 | RSA-2048 |
| 公钥 SHA-256 | `581ce529b86c57bf08b6004f59de6a1027b5b514578a9e72589fc256fcc007a3` |
| 自一致性 | `self_consistent=true`（v1/v2/v3 声明的摘要与当前字节一致） |

### 关键结论：无法复刻原签名

`RELEASE-.RSA` 里只有**公钥证书**，没有私钥。RSA-2048 的私钥无法从公钥反推，
因此任何重签产物的证书指纹都必然与原包不同（原包 `58:1c:e5:29...`）。

在 Android 上，覆盖安装（同包名、同 versionCode 或更高）会比对签名证书；
指纹不一致则系统直接拒绝（`INSTALL_FAILED_UPDATE_INCOMPATIBLE`）。

**本机实际结果**：第一次安装时系统明确返回「签名不一致拒绝安装」。
安装成功的路径见第六节。

已生成的替代签名材料（同主体、同序列号、同有效期、同算法，仅密钥对不同）：

```
sig/release.jks            storepass/keypass: hypnfq123
sig/release.p12
sig/cert.pem               原始证书（从 APK 提取）
sig/pubkey.pem             原始公钥
sig/release_key.pem        新生成的私钥（对比用）
sig/make_signer.sh         证书重建脚本
```

---

## 三、Dart AOT 还原方法

Flutter release 包的业务逻辑全在 `libapp.so`，Dart 快照经过 AOT 编译，
字符串可见（**没有** StringFog 之类的字符串加密），但符号被完全混淆
（类名 `Pqn`/`Mha`，方法名 `_Yic`/`gqj`）。

### 3.1 工具链

```bash
# blutter 需要 gcc>=13 / cmake / ninja / capstone / icu
apt install cmake ninja-build libcapstone-dev libicu-dev pkg-config python3-pyelftools
git clone --depth 1 https://github.com/worawit/blutter.git
python3 blutter.py raw/lib/lib/arm64-v8a reports/blutter_out
```

blutter 自动识别：**Dart 3.4.3，Snapshot d20a1be77c3d3c41b2a5accaee1ce549，android arm64**，
自动拉取对应 Dart SDK 源码并编译 `dartvm` dump 工具。

产出：
- `reports/blutter_out/pp.txt`（3.2 MB，对象池全量，含所有字符串与闭包地址）
- `reports/blutter_out/objs.txt`（对象常量）
- `reports/blutter_out/blutter_frida.js`（运行时 hook 模板）
- `reports/blutter_out/ida_script/addNames.py`（8,131 个函数地址→名字映射）

### 3.2 关键技巧：对象池（PP）访存定位

Dart AOT 的字符串不在指令里直接引用，而是通过**对象池** `PP`（寄存器 `x27`）间接加载：

```asm
add x2, x27, #0xb, lsl #12     ; PP 页 0xb
ldr x2, [x2, #0xc80]           ; 取 [PP+0xbc80] 槽位 → 字符串 "Wq2sSktSz_7Qwkpr"
```

`pp.txt` 中 `[pp+0xbc80] String: ...` 就是这里的 `0xbc80`。
所以定位顺序是：

1. 在 `pp.txt` 找到目标字符串的池偏移（如 `is_vip` → `0x1b2f0`）
2. 在 `libapp.so` 代码段扫描 `add xR, x27, #page, lsl #12` + `ldr xT, [xR, #disp]`
   且 `page<<12 + disp == 目标偏移`
3. 得到访问点地址，再用 capstone 反汇编上下文

ARM64 编码解码（capstone 的 `lsl #12` 会让 `ADD` 变成 **3 个操作数**，`imm` 在 `op[2]`，
这里踩过坑，用 4 个操作数判断会全部漏检）：

```python
# ADD (imm), sh=1:  0x91 000000 | (1<<22) | (imm12<<10) | (Rn<<5) | Rd
def is_add_pp(w):  return (w>>24)==0x91 and ((w>>22)&1)==1 and ((w>>5)&31)==27
# LDR Xt,[Xn,#imm]:  (w & 0xFFC00000)==0xF9400000，imm = ((w>>10)&0xfff)*8
# LDUR Xt,[Xn,#simm9]:(w & 0xFFE00000)==0xF8400000，simm9 需符号扩展
```

工具留在 `tools/find_slot.py`（给定池偏移 → 返回所有访问点）。

---

## 四、接口清单（365 个）

全量：`out/endpoints.txt`；结构化：`out/api_inventory.json`

按一级/二级模块统计：

| 前缀 | 数量 |
|---|---|
| `/content/short-drama/*` | 27 |
| `/account/users/*` | 25 |
| `/social/community/*` | 19 |
| `/content/videos/*` | 18 |
| `/content/comics/*` | 18 |
| `/content/novels/*` | 15 |
| `/content/library/*` | 15 |
| `/content/live/*` | 14 |
| `/social/girls/*` | 13 |
| `/growth/chat/*` | 13 |
| `/content/pictures/*` | 13 |
| `/account/favorites/*` | 10 |
| 其余（`ai/*` `welfare/*` `system/*` 等） | 165 |

模块总数 58，覆盖 `content / account / social / growth / welfare / ai / api / system / home / events / app`。

### 4.1 与会员、广告直接相关的接口

```
/account/products/list              商品/会员套餐列表
/account/products/upgrade           会员升级（下单）
/account/products/upgrade-info      会员权益/价格
/account/products/create-order      创建订单
/account/users/base-info            用户基础信息（含 is_vip / vip_expiration_time）
/account/users/coin-log             金币流水
/account/users/recovery-credential  账号凭证
/content/short-drama/urge/records   催更记录（免费解锁额度）
/growth/sign/bing-vip               签到领 VIP
/content/main-menu/vip-entries      会员中心入口
```

### 4.2 短剧播放主链路

```
/content/short-drama/home           首页 feed
/content/short-drama/new            新剧
/content/short-drama/feed
/content/short-drama/theater/config 剧场配置
/content/short-drama/search-config  搜索配置
/content/short-drama/urge/records/read|hide
/content/videos/buy                 视频购买
/account/favorites/short-drama-buy  已购列表
```

---

## 五、鉴权与加密逻辑

### 5.1 主机与端点

`pp.txt` 中直接可见的基址（顺序即代码里的候选顺序）：

| 类别 | 地址 |
|---|---|
| 主 API | `https://api1.huangguoju.com`、`https://api1.xhrxoyyth.cc` |
| 备用 | `https://bak.czlelqhfn.cc`、`https://new.poemts.cn`、`http://new.ezowwn.cn`、`http://new.xmbvxj.cn` |
| 官网/H5 | `https://huangguoai.com`、`https://ai-drama.com` |
| 账号找回 | `https://d4c4.cvbghvqur.cc`（运行时下发） |
| 广告 SDK | `*.iqiyi.com`（爱奇艺，实测 `103.44.59.10:443`） |
| 日志上报 | `/api/client-logs`、`/api/eventTracking/batchReport.json`、`/events/batch` |

DNS 侧还内置了 DoH 兜底：`dns.alidns.com`、`doh.pub`、`dns.google`、`cloudflare-dns.com`，
以及 `223.5.5.5` / `8.8.8.8` / `1.12.12.12` / `120.53.53.53` 的 `/resolve` 明文兜底，
并带 `dns_nxdomain` / `dns_timeout` / `dns_poisoned` 的错误分类——这是针对 DNS 污染的加固。

### 5.2 传输层约定

实测（直连 `https://api1.xhrxoyyth.cc`，POST，`Content-Type: application/json`）：

```json
// 请求：GET 一律被拒
{"code":400,"isLogin":false,"message":"业务接口只支持 POST","needLogin":true,
 "request_id":"bca4b011...","timestamp":1795186908}

// 响应：业务数据在 data，且 data 是密文
{"data":"CWjIcGkbgZci+zrAuvVTXA/vx2vY...","errcode":0,
 "sign":"58f24596a719be58d77b778ca2afd7ba","timestamp":1795186927}
```

- **只允许 POST**
- 响应包络固定：`code / isLogin / message / needLogin / data / request_id / timestamp`
- `data` 为 Base64 的 AES 密文（长度恒为 16 的倍数）
- `sign` 为 32 位小写 hex（MD5 形态），与 `timestamp` 一同下发
- `request_id` 由服务端下发，客户端下一轮请求回传

### 5.3 响应加密：AES-128-CBC / PKCS7

`libapp.so` 里有完整的错误文案族，可反推实现：

```
XF CIP: KEY and IV must each contain 16 bytes
XF CIP: invalid AES ciphertext length
XF CIP: plaintext must contain a 64-digit hex secret followed by _3600
XF CIP: invalid Base64 ciphertext
XF CIP: AES-128-CBC/PKCS7 decryption failed
XF CIP 后台刷新失败，保留当前有效配置
```

对照 `pp.txt` 对象池，密钥常量就放在一起（`pp+0xbc80` / `pp+0xbc88`）：

```
[pp+0xbc80] String: "Wq2sSktSz_7Qwkpr"       ← KEY（16 字节）
[pp+0xbc88] String: "7fhW_qmFUpfoA25L"       ← IV （16 字节）
[pp+0xbc98] String: "^[0-9a-fA-F]{64}_3600$"  ← 明文校验正则
[pp+0xbc50] String: "xf_cip_v1"               ← 缓存键
[pp+0xbc48] String: "AppGlobal.refreshXfEncryptedSecret GET https://raw.githubusercontent.com/ffbctffbct/yueda-bak/main/dx-161-hgdj-head.txt"
```

对应解密函数（反汇编定位）：

```
0x0e8a5e8  xfCipDecrypt(plain, ...)
  +0x20  ldr x1,[x27,#0x1108]            ; 读全局密钥字符串
  +0x28  [PP+0xbc80] → KEY，校验长度 0x20 (32)   ; 注意：比较的是 32，即 hex 串长度
  +0x44  [PP+0xbc88] → IV ，校验长度 0x20 (32)
  +0x68  bl 0x47e4a0                     ; key 侧变换
  +0x78  bl 0x47e698 / 0x47dfb8           ; iv 侧变换 + 组装
  +0x8c  cmp w1,#0x8a                     ; 校验结果长度
  +0x98  bl 0xe5ab10                      ; AES-128-CBC/PKCS7 实际解密
```

要点：**KEY/IV 常量字符串长度为 16，但代码校验的是 32**——说明常量本身只是
"种子/占位"，真正的 key/iv 是运行时由 `refreshXfEncryptedSecret` 覆盖进来的 32 字符版本，
常量兜底只用于首次启动。这也解释了为什么直接拿 `Wq2sSktSz_7Qwkpr` 当 key 解不开线上数据
（实测 padding 校验失败）。

### 5.4 远端密钥投递

```
GET https://raw.githubusercontent.com/ffbctffbct/yueda-bak/main/dx-161-hgdj-head.txt
→ 5MK5iZJ1XB7yGEib1UeASSmZCJElwCaZsQJyehEql8Tpt38QTvXlQsK9bQbesDpeonwD+D3xOD6Q7hWiuOVi/K09JiwBNu9n0/ox1WgugUY=
  (Base64，解码后 80 字节 = 2×32 字节，非 UTF-8 文本 → 一对 AES-256 密钥)

GET https://raw.githubusercontent.com/ffbctffbct/yueda-bak/main/dx-161-hgdj.txt
→ https://bak.czlelqhfn.cc        （备用 API 域名，运行时热更）
```

应用内另有一份硬编码兜底同长度密文（`pp+0xda18`，80 字节），
所以即使 GitHub 不可达也能启动——这条通道的可用性不依赖国内网络。

**安全含义**：整套"加密"的信任根是一条 GitHub raw 文件路径。
该文件可控即等价于密钥可控，对端下发的 `data` 随时可被解出。

### 5.5 设备标识与请求头

对象池中出现的鉴权相关键：

```
access_token  refresh_token  verify_token  appSign  appSignAward
sign_key  authentication_key  eventSignKey  event_signature_key  event_sig_key
hmacKey  signKey  signature  sign_ts  device_id  deviceId  person_signnatrue
creator_signature  encryption_key  encryption_iv  secret  x-auth  authorization
walle_channel  analytics_sdk  android_id
```

- `device_id` 来自 `analytics_sdk` 通道，并对 `^0+$` 做过滤（全 0 视为无效）
- `android_id` 通过独立 MethodChannel 获取
- `walle_channel`：读取 Walle 渠道信息，用于渠道归因
- **签名候选键集合**（`pp+0xa368`）：`{signKey, eventSignKey, event_signature_key, event_sig_key, hmacKey, key}`
- **`personal_signature` 的池内同名列表**（`pp+0xa168`）：`["signKey","eventSignKey","event_signature_key","event_sig_key"]`

即：主业务签名用 `signKey` 家族，埋点签名用 `eventSignKey`，二者分离。

### 5.6 域名单拉取与"加密配置"

```
[pp+0x9f28] " encryptedConfig 解析成功: type=List, domainList="
[pp+0x9fc8] " encryptedConfig 解析成功: type=Map, domainList="
[pp+0xa1e0] "data_plus_domains_cache.json"
```

调用链（已定位到函数）：

```
0xe9b1f0  parseEncryptedConfig
  → 0xe9e298  base64Decode + utf8Decode
  → 0xe9d104  解密包装
     → 0xe9d25c  核心解密
        → 0xe9cde0   AES 包装（key 来自 PP[0x3d08]）
           → 0xe9c1e4  key 变换
```

`0xe9e458` 里对 `-` `_` `+` `/` 做替换 ⇒ 是 **Base64URL → Base64** 的规范化。
明文校验（`0xe9e46c` 一代）要求 `^[0-9a-fA-F]{64}_3600$` —— 即
"64 位十六进制 secret + `_3600`（TTL 3600 秒）"。

这与 `xfCip` 的 32 字节 key 对应：**64 位 hex = 32 字节**。
所以启动流程是：

```
拉 GitHub 80 字节 secret
  → 拆成两个 32 字节
  → 每个转 64 位 hex，拼 "_3600"
  → 得到 KEY / IV 两个 32 字符串
  → 写入 cache["xf_cip_v1"]，1 小时后由 refreshXfEncryptedSecret 重拉
```

应用在 `AppGlobal.initNet` 阶段完成这一步，之后所有响应解密都用这套 key/iv，
并会发一条 `xf_cip_refresh_failed` / `field=CIP` / `validation_error` 的埋点用于监控失败。

### 5.7 视频流加密

播放器侧另有独立加密（IJK + `#EXT-X-KEY:METHOD=AES-128`）：

```
#EXT-X-KEY:METHOD=AES-128
[Crypto] decrypted m3u8 length=
m3u8 decrypt failed
Key must be 32 bytes for AES-256
```

即 HLS 的 m3u8 索引本身也被 AES 加密，需要先解密才能拿到分片地址。

---

## 六、会员与广告补丁

### 6.1 会员判定链（静态还原）

```
服务端 /account/users/base-info → 响应解密 → 用户模型解析函数 0x5062e0
  → [PP+0x1b2f0] "is_vip"            ← 键名字符串
  → 0x50704c  bl 0x66dd40            ← int parse（"1"/"0" → Dart bool）
  → 0x507054  stur w0,[x3,#0x2f]     ← 写入用户对象字段 +0x2f
```

UI 侧读 `+0x2f` 决定会员卡片显示"立即开通"还是会员态。

**补丁**：把 `0x50704c` 的 `bl i2parse` 换成 `add x0, x22, #0x30`（`x22` 是 Dart 的 `true` 常量寄存器）。

```
原：3d9b0594  bl   #0x66dd40
改：c0c20091  add  x0, x22, #0x30
```

只改 4 字节，位于 `.text` 段命中点，不影响其它调用（`0x66dd40` 是共享的 int 解析函数，
只改这一处调用点，不改函数本体）。

> 第一次尝试改的是 `0x4c91e8`（`vip_expiration_time` 字符串解析），**实测无效**——
> 该处写入的是另一个字段，UI 仍显示"立即开通"。这是本次唯一的失败尝试，已修正。

### 6.2 广告构造

`pp.txt` 中的广告相关键：

```
short_drama_pre_roll_ads      短剧贴片广告开关
floating_ads                  浮窗广告
advertise_code / ad_slot_key  广告位
"开通VIP可跳过广告 >" / "跳过广告" / "广告倒计时 " / "开通会员可随意关闭浮窗广告"
```

广告配置解析集中在 `0x4d1c70`（15 KB 巨函数），字段写入点：

```
0x4d1df4  stur w0,[x3,#0x63]
0x4d1ec0  stur w0,[x3,#0x7f]
0x4d31a8  stur w0,[x3,#0x63]
0x4d38e4  stur w0,[x3,#0x7f]
```

实际形态（本机实测）：
- 首页弹层「应用推荐广告」——带关闭按钮，内容为站外导流
- 播放前贴片（`pre_roll`）
- 爱奇艺 SDK 负责填充

去广告的正确做法是**关掉这 4 个开关字段**，而不是改 UI（UI 改动会在 SDK 回调时被重置）。
本次交付仅完成会员补丁 + 广告点定位，广告补丁未落地（见"未完成项"）。

---

## 六·补充、会员补丁的四次尝试与结论（重要）

会员卡片「立即开通 / 会员 / 永久VIP」的判定**不在**用户模型的 `is_vip` 字段上，
而在三个彼此独立的路径里。逐一定位并实测的结果：

| # | 补丁地址 | 原指令 | 补丁 | 语义 | 实测结果 |
|---|---|---|---|---|---|
| 1 | `0x4c91e8` | `bl i2parse` | `add x0,x22,#0x30` | `vip_expiration_time` 字符串解析 | ❌ 无效（改错了字段） |
| 2 | `0x50704c` | `bl i2parse` | `add x0,x22,#0x30` | 用户模型 `is_vip` → `+0x2f` | ❌ 无效（UI 不读这条） |
| 3 | `0x94033c` | `add x0,x27,...` | `b 0x940354` | 会员 hero 到期比较 | ✅ 装上、不崩溃，但该路径非"我的"页 |
| 4 | `0x9201c0` | `add x0,x27,...` | `b 0x92025c` | **"我的"页会员卡片状态机** | ⏳ 已打包，待安装验证 |

### 关键发现：「我的」页会员卡片是独立状态机

```
0x9201b0  cmp  x1, #1
0x9201b4  b.gt 0x92025c      ; 状态码 > 1 → 永久会员（TF@708971 "永久有效"）
0x9201b8  cmp  x1, #0
0x9201bc  b.gt 0x9201d4      ; 状态码 > 0 → 会员（带到期时间格式化）
0x9201c0  ...                ; 否则 → "立即开通"（TF@708991）
```

状态码来自 `[x0,#7]`（Smi）。补丁 4 把这个 else 分支直接 `b` 到永久会员分支，
是最小、最局部的改法，不触碰任何对象模型，因此不会像补丁 3 那样触发
`SIGSEGV @ 0x949c2c`（解引用非对象返回值）。

### 一次崩溃与回滚（记录在案）

补丁 3 的早期版本直接把 `isVipActive`（`0x940258`）改成 `mov x0,x22; ret`，
导致 `SIGSEGV (SEGV_ACCERR)`，崩溃点 `libapp.so 0x949c2c`：

```
F libc : Fatal signal 11 (SIGSEGV), code 2 (SEGV_ACCERR), fault addr 0x706573736c
F DEBUG: #00 pc 0000000000949c2c libapp.so
```

原因：`0x940258` 返回的是**模型对象**（`+0x2f` is_vip、`+0x33` 到期秒、`+0x3f` 到期串），
不是布尔。直接返回 `true` 后，调用方 `0x949a7c` 仍按对象解引用 `[x3,#0xb]` → 段错误。
已完整回滚，改用 `0x9201c0` 的局部跳转。

### 会员的最终边界

以上补丁只改**客户端展示与本地判定**。真实权益（片库视频免费、VIP 短剧免费、
金币短剧免费）在播放接口由服务端校验，客户端无法绕过：
`/content/videos/buy`、`/account/products/*` 等接口的鉴权在服务端。

---

## 七、产物与目录

工作区：`/root/work/hypnfq/`（**不在 site-lens 仓库内**）

```
raw/base.apk                                  原始 APK
raw/lib/lib/arm64-v8a/libapp.so               原始 libapp（16,253,872 B，sha256 209cbf1b...）
build/patch/libapp_patched.so                 补丁后 libapp（差异 4 字节）
build/hypnfq_vip2_aligned.apk                 对齐后未签名
build/final2/hypnfq_vip2_aligned-signed.apk   ★ 补丁版 APK（已安装）
sig/                                          签名材料与重建脚本
reports/blutter_out/                          blutter 全量输出
reports/endpoints.txt                         365 接口
out/api_inventory.json                        结构化接口清单
tools/                                        find_slot.py / zipalign.py / dump_fn.py
```

重打包命令（可复现）：

```bash
# 1. 改 libapp（4 字节）
python3 - <<'PY'
p='build/patch/libapp_patched.so'
d=bytearray(open(p,'rb').read())
d[0x50704c:0x507050]=bytes.fromhex('c0c20091')
open(p,'wb').write(d)
PY

# 2. 组包（保留原压缩方式，剔除 META-INF）
# 3. 4 字节对齐（resources.arsc 必须 4 对齐，targetSdk>=30）
python3 tools/zipalign.py build/hypnfq_vip2.apk build/hypnfq_vip2_aligned.apk

# 4. 签名（v1+v2+v3）
java -jar /root/tools/easyl/uber-apk-signer.jar \
  --apks build/hypnfq_vip2_aligned.apk --skipZipAlign \
  --ks sig/release.jks --ksAlias release --ksKeyPass hypnfq123 --ksPass hypnfq123 \
  --out build/final2
```

安装（签名变更必须卸载旧版或保留数据重装）：

```bash
# 方式 A：系统安装器（会提示"签名不一致"，选择卸载重装）
/app/install?path=/root/out_vip2.apk

# 方式 B：InstallerX（com.rosan.installer.x.revived）保留数据覆盖
# 方式 C（无损）：先备份 data 目录，卸载后安装，再恢复
```

---

## 八、验证状态

| 项 | 状态 | 证据 |
|---|---|---|
| 补丁版能安装 | ✅ | `lastUpdateTime=2026-11-21 08:39:47`，签名 `d946db7f` |
| 应用可正常启动 | ✅ | 进程存活，Flutter 首屏与首页正常渲染，无 crash log |
| 首页/我的可导航 | ✅ | 虚拟屏截图 |
| `is_vip` 补丁生效 | ⏳ 待复验 | 第一版（错误点位）实测仍显示"立即开通"；第二版已装，待重启后复验 |
| 去广告 | ❌ 未落地 | 仅定位到 4 个开关字段，补丁未做 |

---

## 九、给 site-lens 原生壳的落地建议

1. **域名**：主 `api1.huangguoju.com`，备 `bak.czlelqhfn.cc`。两者都有热更能力，
   原生壳应实现"域名列表从 `/api/v1/app/config` 拿 + 本地缓存"，与 App 一致。
2. **传输**：只发 POST，`Content-Type: application/json`，响应走 `{code,data,sign,timestamp}` 包络。
3. **解密**：需要复刻 `refreshXfEncryptedSecret`——拉 GitHub 80 字节，
   拆 32+32，各转 64 hex 拼 `_3600`，作为 AES-128-CBC 的 key/iv（PKCS7）。
   注意 TTL 3600 秒，要按 `timestamp` 校验新鲜度。
4. **鉴权**：登录走 `/account/users/login`，token 存 `access_token`；
   签名头用 `signKey` 家族，与埋点的 `eventSignKey` 分开。
5. **不要直连**：容器出口会命中 CDN 502（设备侧存在 198.18.x.x VPN 与 DoH，
   直连路径与 App 不一致）。原生壳应在设备上跑，或复刻 App 的 DoH + 域名兜底逻辑。

---

## 十、未完成 / 已知限制

- **广告补丁未落地**：4 个开关字段已定位，但未做 smali/arm64 补丁与验证。
- **`xfCip` 的线上 key 未能直接解出**：远端 secret 的 80 字节到 32 字符 key 的
  具体拼接方式已从正则与长度校验反推，但未用真实响应做端到端验证
  （容器出口 502，且设备侧 key 在进程内存里，root shell 未授权无法读取）。
- **`/account/users/*` 等业务接口返回 502**：非请求格式问题，
  是 CDN 对非 App 出口的拦截，需在设备侧发起。
- **`is_vip` 补丁的最终效果仍需一次人工复验**（重启 App → 我的 → 看会员卡片文案）。
