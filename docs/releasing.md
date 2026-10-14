# Site Lens 发布流程

Site Lens 通过 GitHub Actions 构建 Android 正式 APK，并把 APK 和 SHA-256 校验文件上传到 `vikiea/site-lens` 的 GitHub Release。

## 自动发布

推送符合 `vMAJOR.MINOR.PATCH` 的稳定标签即可触发发布：

```bash
git tag v0.1.0
git push origin v0.1.0
```

Workflow 会执行 `./tool/check.sh`、正式签名构建、包名与证书校验，然后发布：

- `site-lens-v0.1.0.apk`
- `site-lens-v0.1.0.apk.sha256`

同一个标签重复运行时会覆盖同名资产，不会创建第二个 Release。

## 手动发布

在 GitHub Actions 中运行 `Release Site Lens`，输入 Release tag，例如 `v0.1.0`。手动流程同样要求输入已经存在的稳定标签，并从该标签对应的源码构建。

## GitHub Secrets

正式构建需要以下仓库 Secrets：

- `SITE_LENS_KEYSTORE_BASE64`：正式 keystore 的 Base64 内容
- `SITE_LENS_KEYSTORE_PASSWORD`
- `SITE_LENS_KEY_ALIAS`
- `SITE_LENS_KEY_PASSWORD`

keystore 必须对应 `tool/android_artifact.py` 中记录的正式证书指纹。Workflow 会把密钥恢复到 runner 的临时目录，构建完成后由 runner 清理，不会写入 Git 仓库。

本地正式构建仍使用仓库外的 `SITE_LENS_SIGNING_PROPERTIES`，例如：

```bash
make build-release BUILD_NAME=0.1.0 BUILD_NUMBER=1
```

## 应用内更新

设置 → 软件更新会请求 GitHub Latest Release。Android 正式包下载 APK 后会校验 SHA-256、包名和当前正式签名，再交给系统安装器。debug 包和签名不一致的 APK 会被拒绝。iOS 和其他平台会打开 GitHub Release 页面。
