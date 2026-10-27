# Site Lens 计划 08 验收证据

复制此模板到 `.ci_cache/acceptance/<date>-<revision>.md`，只填写已执行的命令和设备结果。没有真实设备、接收端或正式签名时保留“待验收”，不要把模拟结果写成通过。

使用 `tool/run_android_acceptance.py --skip-check` 的结果必须标记为 `diagnostic-only`；它可以证明设备场景，但不能满足完整 L1/L4 发布证据。

## 构建身份

- Revision：
- 分支：
- 工作区状态：
- Flutter/Dart：
- Android SDK / WebView：
- applicationId：
- versionName：
- versionCode：
- APK SHA-256：
- 签名证书 SHA-256：

## 门禁

| 级别 | 命令/设备 | 结果 | 证据 |
| --- | --- | --- | --- |
| L0 | `dart analyze`、模型/规则单测 | 待执行 | |
| L1 | `make check` | 待执行 | |
| L2 | Pigeon/WebView/脚本过滤保护集 | 待执行 | |
| L3 | `make acceptance DEVICE=<serial>` | 待验收 | |
| L4 | `make build-release`、签名/安装烟测 | 待执行 | |

## 跨模块场景

- 过滤快照更新与当前播放：待验收
- 脚本停用、GM 取消、菜单清理：待验收
- 候选过期、下载恢复、缓存占用删除保护：待验收
- HLS 本地输入、MP4 输出校验与 SAF 交付：待验收
- DLNA 发现、SOAP 播放、Range/HEAD 中继：待验收
- 凭据过期、网络切换、磁盘不足、设备离线：待验收

## 已知限制

- iOS 原生媒体和 DLNA 未声明已验收。
- 没有真实 Android 设备或接收端时，L3/L4 只记录构建证据，保留“待验收”。
- host contract `127.0.0.1:39399` 阻塞时，记录完整错误和命令，不用它替代静态、单测或 APK 构建证据。
