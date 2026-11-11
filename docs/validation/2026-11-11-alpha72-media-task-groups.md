# Alpha 72 媒体任务组、目录与批量控制验证

基线：`21b2772` (`v0.6.0.alpha71`)。目标版本：`0.6.0-alpha72+205`。

本轮保持 Alpha71 的系统透明网络、代理、PAC、VPN/TUN、原生媒体传输和授权边界不变，集中收敛任务组标题、单目录存储、批量暂停以及已有媒体跳过逻辑。

## 行为契约

- 单集播放或下载始终从当前活动播放 DOM 读取标题；数字、`第N集`、`媒体`、`video`、`media`、`批量媒体` 不作为任务组标题。
- 活动 DOM 不可用时允许从描述性 document title 提取系列名。标题读取继续绑定 candidate frame/document/epoch、Host generation 和当前 URL，拒绝 same-URL 替换或 SPA 导航后的旧快照。
- 单集标题不可用时创建 `媒体-<8 位小写十六进制>`，并在界面提示使用了临时任务组。多集没有共同标题时使用 `批量媒体-<8 位小写十六进制>`。
- 确定性的临时任务组在任务尚未启动或处于可安全重试状态时可以升级为真实标题；downloading、paused、completed、playable 保持当前物理目录。
- 历史裸 `批量媒体` 不自动迁移；用户重命名、手动移动或包含子目录的临时组也不会被自动改写。
- `batchDirectory` 是任务组、下载缓存和最终导出共用的唯一物理目录来源。组名比较区分大小写，并按实际写入文件系统的安全名称比较。
- 任务组暂停同时覆盖 queued 和 downloading 成员。queued 同步进入 paused；原批次 worker 不能在其后重新启动该成员；继续操作从 paused 成员恢复。
- 单集下载前检查同一任务组是否已有同集 MP4。Android 原生媒体库命中要求 `video/mp4` 且时长大于零；direct path 同样检查 MIME 和时长。已有可播放文件时跳过下载，并把仍为 queued/failed/cancelled/reauthorize 的冗余任务安全取消。
- direct path 成功投递后以配置目录中的文件为正式副本，验证成功后才释放应用私有 `media_exports` 暂存文件。投递或清理失败时暂存副本保留用于恢复。

## 本地验证

- `./tool/check.sh`：PASS；889 项 Flutter 测试，以及 analyze、JS 运行时、媒体生命周期、Pigeon、Android 工具链、代理租约、回归矩阵和 UI token 契约全部通过。
- 定向媒体、WebView、组织与任务测试：218 项通过，覆盖标题回退、same-URL stale boundary、目录升级竞态、queued/downloading 暂停、artifact 清理竞态、大小写目录和 invalid MP4。
- 独立只读评审：PASS，无 P0/P1/P2 release-blocking finding。
- `git diff --check`：PASS。

## 真机人工验收

当前 macOS `adb devices -l` 为空，因此本轮没有新的真机证据。发布 alpha72 后需使用新的无线调试端点完成以下检查：

- 单集播放和下载使用真实播放页标题，例如 `妈妈的答案`。
- 单集标题不可用时生成 `媒体-<8hex>`，并出现临时任务组提示。
- 同一任务组内同时存在 running 与 queued 成员时，批量暂停不会继续启动 queued 成员；继续后整组恢复。
- direct path 中已有合法 `第N集.mp4` 时自动跳过；同名但损坏或不可播放的文件不会误跳过。
- 导出成功只保留配置目录中的文件，应用私有 `media_exports` 不残留正式副本。

## 发布边界

本地检查与独立评审不等于 GitHub Verify、Release 工作流、正式 APK 安装或真机业务验收。最终以 alpha72 Release 工作流和发布资产 digest 为发布完成证据，真机结果单独记录。
