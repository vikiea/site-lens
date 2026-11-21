# 易幕（com.easyl.app）逆向与改包项目

本目录是从会话 `session-ab811816-7c59-45b2-a570-6d94499df492`（原工作目录 `/root/re/yimu`）迁出的分析产物，
后续在此项目内继续维护。目标版本：**1.0.6 (versionCode 50)**。

## 目录地图

| 路径 | 内容 |
|---|---|
| `report.md` | 主报告：样本指纹、技术栈、配置体系、安全机制、权益位掩码、可利用点 |
| `report2.md` | 配置 dump 后的补充分析（真实后端/接口清单） |
| `patch_notes.md` | smali 补丁清单（6 条改动）与安装/回滚说明 |
| `live_analysis.md` | `live.js` QuickJS 字节码提取结果（295 条播放地址 / 24 个 CDN） |
| `sources_report.md` | 23 个内容源脚本的字节码提取汇总表 |
| `raw/` | 原始样本 `easyl.apk`、6 个 `classes*.dex`、证书 DER、签名字符串表、dump 出的配置 JSON、QBC 字节码 |
| `src_plain/` | **已解密的明文 Java 源码**（409 文件，13,403 条 StringFog 字符串还原） |
| `src5/` | classes5.dex 的 jadx 反编译结果（2,798 文件） |
| `src_by_key/` | 按内容源 key 归档的字节码字符串导出 |
| `build/` | 最终成品：`easyl_v5_aligned.apk`（对齐）、`easyl_v5_aligned-debugSigned.apk`（v2+v3 已签名，可直装） |
| `apk_probe.py` | APK 静态三件套解析（AXML / ARSC / DEX 字符串） |
| `dex_summ.py` | 方法级字符串与调用摘要器 |
| `patch.py` / `patch2.py` | smali 定点补丁脚本（反编译树 → 打补丁） |
| `zipalign.py` | arm64 上的 `resources.arsc` 4 字节对齐修复 |
| `upload_srv.py` | 容器侧 8931 端口 PUT 接收服务（设备 Termux 回传用） |
| `easyl_adblock.yaml` | 广告域名阻断清单（Clash/Surge 规则） |
| `easyl_config_v20.json` | 服务端下发的完整远端配置（清理版） |
| `stringfog.py` / `repack.py` | StringFog 批量解密、重打包辅助 |
| `easyl_reverse_src.zip` | 明文源码打包（含报告） |
| `easyl_sources_qbc.zip` | 全部内容源 QBC 字节码 |
| `tools/` | apktool / uber-apk-signer 的离线 jar 副本（执行用 `/root/tools/easyl`） |
| `MANIFEST.sha256`、`MANIFEST.files.sha256` | 原始样本与顶层产物的 SHA-256 校验清单 |

未迁入项目（体积大且可再生产出）：`apkout/`、`apkfull/`（apktool 反编译树，各约 65k 文件）、
`signed/`~`signed6/` 与 `easyl_patched/v2/v3/v4` 等中间 APK。需要用 apktool 重新生成，见下方流程。

## 工具链

工具链不在 sdcard 上（`/sdcard` 是 noexec 且不支持 symlink），统一放在 **`/root/tools/easyl/`**：

```
/root/tools/easyl/apktool.jar            2.11.1
/root/tools/easyl/uber-apk-signer.jar    1.3.0（arm64 上用 --skipZipAlign）
/root/tools/easyl/jadx/                  1.5.1（用 bash jadx/bin/jadx 调用）
/root/tools/easyl/jre/                   Temurin 17（系统也有 openjdk 17）
```

常用调用：

```bash
java -jar /root/tools/easyl/apktool.jar d -r -f -o apkfull raw/easyl.apk
bash /root/tools/easyl/jadx/bin/jadx -d src5 --no-res raw/classes5.dex
java -jar /root/tools/easyl/uber-apk-signer.jar --apks x.apk --skipZipAlign --allowResign -o signed/
```

## 复现流程

```bash
cd /sdcard/Workspace/easyl

# 1) 反编译（资源不动，只出 smali）
java -jar /root/tools/easyl/apktool.jar d -r -f -o apkfull raw/easyl.apk

# 2) 打补丁（完整性绕过 / 权益全开 / 去广告 / 去强更 / 配置 dump / 源脚本 dump）
python3 patch.py apkfull
python3 patch2.py

# 3) 重打包
java -jar /root/tools/easyl/apktool.jar b -o easyl_patched.apk apkfull

# 4) resources.arsc 4 字节对齐（arm64 上 aapt2 会 SIGILL，必须用脚本修）
python3 zipalign.py easyl_patched.apk easyl_aligned.apk

# 5) 签名（自签 debug 证书，v2+v3）
java -jar /root/tools/easyl/uber-apk-signer.jar --apks easyl_aligned.apk --skipZipAlign -o signed/
```

安装前必须卸载原版（签名已变），并授予「所有文件访问」权限，否则 dump 写不进 `/sdcard/Download/`。

## 升级到新版本时的注意事项

1. **签名证书 SHA-256 是服务端正版判据**：重签后不伪造该值，配置接口只回空壳 `_scaffold`。判据在 `com.hzhj.libs.u8.g.b(Context)` 链路里，补丁 1 是同一处。
2. 服务端会判 `adsEnabled`，只靠客户端改 dex 不能真关广告位；`easyl_adblock.yaml` 走网络层阻断更稳。
3. 补丁点若被新版本改名（类名重命名规律一致但哈希后缀会变），用 `dex_summ.py` + `easyl_strings.txt` 按字符串特征重新定位。
4. `resources.arsc` 未对齐 → Android 11+ 报 `INSTALL_FAILED_INVALID_APK -124`。
5. 内置更新器会校验签名，改包后需保留「去强制更新」补丁，否则会被官方包覆盖。

## 迁移备注

- 源快照仍在 `/root/re/yimu/`（含未迁入的 `apkout`、`apkfull`、各版本中间 APK，约 2.9 GB）。确认无需回看后可直接删除。
- 迁移时 `jre/legal/*` 的 license 软链因 sdcard 不支持 symlink 无法落地，故 jre 未随项目保存，改为 `/root/tools/easyl/jre`。
