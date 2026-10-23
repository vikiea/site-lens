# Site Lens 发布流程

Site Lens 通过 GitHub Actions 构建 Android 正式 APK，并把 APK 和 SHA-256 校验文件上传到 `vikiea/site-lens` 的 GitHub Release。

## Version 与 versionCode

发布提交必须同时更新 `pubspec.yaml` 和标签。版本名使用 Flutter 的连字符形式，标签使用 dotted 形式：

```yaml
version: 0.4.0-alpha16+94
```

对应标签是 `v0.4.0.alpha16`，`94` 是本次 APK 的 Android `versionCode`。先运行：

```bash
python3 tool/verify_release_pubspec.py --tag v0.4.0.alpha16
```

校验通过后再创建标签。工作流会在构建前检查不可变 version-code reservation 和安装版本下限，构建后从 APK manifest 回读 `versionName` 与 `versionCode`；任何不一致都会停止发布。需要改版本或数字时，更新 `pubspec.yaml` 并创建新标签。

## VersionCode allocation

Release runs first enter a short `version-code-allocation` concurrency group. That job reads the latest stable APK and existing `version-code/<code>-<tag>` refs, then atomically creates a new immutable reservation ref through the GitHub API. A ref creation conflict is fatal for a new tag: update `pubspec.yaml` and create a new tag instead of silently changing the build number. Rerunning a tag reuses its existing reservation, so failed retries cannot publish the same code under a different allocation. Different tags cannot reserve the same numeric versionCode.

## 自动发布

推送符合 `vMAJOR.MINOR.PATCH` 的稳定标签即可触发发布：

```bash
git tag v0.1.1
git push origin v0.1.1
```

Workflow 会执行 `./tool/check.sh`、正式签名构建、包名/证书/manifest 版本校验，然后发布：

- `site-lens-v0.1.1.apk`
- `site-lens-v0.1.1.apk.sha256`

同一个标签重复运行时会覆盖同名资产，不会创建第二个 Release。

## 手动发布

在 GitHub Actions 中运行 `Release Site Lens`，输入已经存在的标签。稳定版例如 `v0.1.1`；测试版例如 `v0.4.0.alpha16`。测试版必须在同一提交的 `pubspec.yaml` 中使用 `version: 0.4.0-alpha16+94` 这种连字符版本名，工作流的 `version_code` 只允许填写同一个 `94` 以兼容重跑。

## GitHub Secrets

正式构建需要以下仓库 Secrets：

- `SITE_LENS_KEYSTORE_BASE64`：正式 keystore 的 Base64 内容
- `SITE_LENS_KEYSTORE_PASSWORD`
- `SITE_LENS_KEY_ALIAS`
- `SITE_LENS_KEY_PASSWORD`

keystore 必须对应 `tool/android_artifact.py` 中记录的正式证书指纹。Workflow 会把密钥恢复到 runner 的临时目录，构建完成后由 runner 清理，不会写入 Git 仓库。

本地正式构建仍使用仓库外的 `SITE_LENS_SIGNING_PROPERTIES`，例如：

```bash
make build-release BUILD_NAME=0.4.0.alpha16 BUILD_NUMBER=94
```

## 应用内更新

设置 → 软件更新由用户主动触发：点击“检查更新”才会请求网络，成功结果缓存 1 分钟，间隔内重复点击使用缓存。打开更新页时，只有在磁盘上存在未完成分片时才会自动检查一次，用于继续上一次下载。

Android 正式包的下载由 App 级的 `UpdateController` 持有，而不是由更新页持有：

- 断点续传：分片与 sidecar 元数据写在应用私有目录 `site-lens-updates/`，续传请求带 `Range` 与 `If-Range`；服务端返回 `200`（忽略区间或同一 tag 的资产被覆盖）或 `416` 时从 0 重新下载；每次请求都重新校验 GitHub HTTPS 白名单与 302 跳转。
- 暂停与取消：暂停/取消只停止传输并保留分片，界面提供“继续下载”和“删除下载”；网络中断按 2/5/10 秒退避自动重试 3 次，仍失败则转为“已暂停”，分片保留。
- 后台继续：离开更新页后下载继续；进程被杀后分片与 sidecar 留在磁盘上，用户再次进入更新页时自动续传（用户主动暂停的除外）。
- 完成校验与安装：全部字节到达后校验 SHA-256，通过后把 APK 移动到 cache 目录 `site-lens-updates/` 交给安装器，安装时原生侧再校验 SHA-256、包名、版本号与正式签名；debug 包和签名不一致的 APK 会被拒绝。停留在更新页时下载完成会直接进入安装流程。
- 应用内弹幕：下载完成时在任意页面（包括 WebView 之上）弹出可滑动的玻璃胶囊，提供“查看更新”和“安装”两个动作，约 6 秒自动收起；App 在后台完成时回到前台补弹；安装权限未授予时展示引导文案并保持显示。
- 旧版本分片：检测到新版本时旧断点保留并在更新页提示，可一键清理。

iOS 和其他平台不支持 APK 安装，只提供检查更新与打开发布页。
