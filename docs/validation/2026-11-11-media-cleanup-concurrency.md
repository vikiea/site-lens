# 媒体清理与导出并发验证记录

## 范围

- 基于 `origin/main` 的 `9bc6381` 集成；本次不修改版本号、不创建标签、不发布 APK。
- 任务删除走完整缓存清理流程；已导出 MP4 与媒体索引继续独立保留。
- 缩略图仅清理专用目录中的普通 JPG，并检查内存和持久化共享引用。
- Android 清理已删除任务的锁文件、空系列目录及历史孤儿锁；共享资源 GC 可在后续启动重试。
- 终态操作历史有界保留，排序统一 UTC 小数精度；活动操作及其子记录保留。
- 导出并发可设为 1–4，默认 2；队列及时补位，同目标文件互斥，原生低内存时降为 1。

## 独立审查

两轮独立只读审查发现的缩略图路径过宽、输出临时文件竞争和空闲 worker 不补位问题均已修复并复核关闭。新增清理模块、低内存闸门、共享资源 GC 和 UTC 排序也经过独立复核；未发现剩余代码阻断项。

## 本地验证

| 检查 | 结果 |
| --- | --- |
| `./tool/check.sh` | 通过；Flutter 分析无问题，908 项 Flutter 测试通过，Node/Python/生成契约/UI token 检查通过 |
| `android/gradlew :app:testDebugUnitTest --no-daemon` | 通过；并发闸门 2 项、锁文件/目录清理 3 项均零失败 |
| `python3 tool/test_native_media_contract.py` | 38 项通过，同时包含在完整检查中 |
| `git diff --check` | 通过 |

## 设备证据与限制

最终代码在物理 Android 设备执行受保护的 `integration_test/media_tasks_test.dart`：13 项通过，1 项失败。下载任务删除、导出 MP4 与索引保留、临时投屏缓存清理、HLS remux、媒体库恢复均取得通过标记；失败发生在 HLS remux 测试后续的后台生命周期断言（第 908 行，预期 `paused`，实际 `playing`）。该测试及对应原生播放策略代码与上述远端基线一致，不能据此将整套媒体验收记为通过。

在不含本次变更的干净 `origin/main` 基线 `9bc6381` 上使用相同受保护媒体套件对照，也取得 13 项通过、1 项失败，并复现相同第 908 行断言。基线的数据库恢复同样通过身份与 SHA-256 校验。期间同设备出现其他验收进程，因此这份记录不能替代独占设备的完整验收，也不宣称 `main` 整体验收健康。

最终设备命令使用 `--skip-check --skip-build --single-suite --integration-target integration_test/media_tasks_test.dart`；完整本地检查和 Android 单元测试单独执行，正式 APK 验证未完成。此前自动 L2 的完整 acceptance suite 中断，另一次聚焦运行未启动 Dart Development Service；均未计为通过。一次 WAL 恢复校验失败后，已通过 `make restore-device` 修复并验证；最终运行的数据库恢复也通过了源设备身份与 SHA-256 校验。

尚未完成同设备同样本并发 1/2/3/4 的性能与稳定性 profile，不能据当前结果推荐高于 2 的并发。当前日志提供系统可用内存、进程 PSS、Java/native heap 与可用磁盘信息；RSS、Dart heap 和临时磁盘峰值的完整采样仍需补充。
