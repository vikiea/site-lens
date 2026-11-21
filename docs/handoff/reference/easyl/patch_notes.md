# 易幕 1.0.6 改造补丁说明（smali 级）

样本：`com.easyl.app` v1.0.6 (50)
产物：`easyl_patched-debugSigned.apk`（v2+v3 签名，SHA-256 `6dcea985…93d714b6`）

## 一、补丁清单

| # | 目标 | 类/方法 | 改动 |
|---|---|---|---|
| 1 | 绕过完整性 / root / Hook / Frida 检测 | `com.hzhj.libs.u8.g.b(Context)` | 恒返回 `null`。原逻辑串联 `c()`（调试/模拟器/root/Hook/EkSecNative）与签名比对，命中即返回 `HOOK`，调用方（`EasylApp`、`MainActivity`、`core.config.b`）直接把配置通道判死。返回 null 后所有比较都不成立，检测链全部失效 —— **这是重签后能正常联网的前提**。 |
| 2 | 破解 VIP / 权益全开 | `com.easyl.core.storage.AuthStorage.k(Context, SharedPreferences)` | 恒返回 `b(0x7FF)`，即 11 项权益全开的 `EntFlags`：VIP、免广告、解锁全部、发弹幕、云同步、高清、多线程下载、投屏、专属主题、VIP 标识、头像框。 |
| 3 | VIP 判定兜底 | `AuthStorage$AuthState.isVipActive()` | 恒返回 `true`（原为 `isVip && tierUntilOf() > now`，防止 tier 过期导致 UI 回退）。 |
| 4 | 去广告 | `com.easyl.data.source.AdsConfig$a.a(JSONObject)` | 不再解析远端 `ads` 节点，恒返回 `new AdsConfig()`（enabled=false，全部子配置 null）。服务端无论下发什么，客户端广告组件都不启动。 |
| 5 | 去强制更新 | `com.easyl.ui.settings.UpdateChecker.c(UpdateConfig, int)` | 恒返回 `null`。原来是 `latestVersionCode > 当前` 就构造 `UpdateInfo(show=true, force=…)`，现在任何版本都不提示、不强制。 |
| 6 | 运行时配置 dump | 新增 `com.easyl.x.Dump.d(String,String,String)`，注入 `com.easyl.core.config.b$a` | 每次远端配置拉取成功，把 `tag / url / body` 写到 `/sdcard/Download/easyl_cfg.json`。**用来拿服务端真实 API 域名与内容源列表**。 |

## 二、为什么没用 Frida

设备未 root（`/system/bin/su` 不存在），Frida server 起不来；frida-gadget 注入又必须重打包，成本相同。
而这套 App 自己就有 `libeksec.so` 的 `nativeIsCompromised`（socket 探测 27042-27052 等端口，正是 Frida 默认端口）—— 上 Frida 会先撞上它。
所以改用「重打包 + 静态注入 dump」：同样拿到运行时配置，且不触发反调试。补丁 1 顺带把这条检测也废掉了。

## 三、安装注意

1. 签名已变（debug 证书），**必须先卸载原版**，本地数据（登录态/收藏/历史）会清空；`Download/易幕/` 下的视频分片不受影响。
2. 装完首次启动需要在系统里给「所有文件访问」权限（`MANAGE_EXTERNAL_STORAGE`），否则补丁 6 写不进 Download。
3. 首次进首页联网后会生成 `/sdcard/Download/easyl_cfg.json`，把它取出来即可看到真实后端与源。

## 四、回滚

原版样本保留在 `/sdcard/Download/DSHA/easyl.apk`（与官方签名一致，可直接覆盖安装回去）。
