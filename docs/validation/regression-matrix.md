# Site Lens 回归契约矩阵

机器可读来源是 [`tool/regression_contracts.json`](../../tool/regression_contracts.json)。
测试文件中的 `REGRESSION CONTRACT:` 标记把契约与实际用例绑定。

| ID | 行为 | 主要验证 | 发布阻断 |
|---|---|---|---|
| `UI-TRANSITION-001` | 页面切换无白屏、旧页面残留和玻璃层脱离 | navigation widget tests | 是 |
| `UI-GLASS-001` | 高质量面板保持 premium，platformView 单独降级 | glass strategy tests、HCPP visual integration | 是 |
| `UI-DOCK-001` | 浏览器浮窗贴边、六点标记和页面生命周期一致 | browser dock tests | 是 |
| `MEDIA-HLS-001` | HLS 共享资源在 Dart、原生和 Media3 中语义一致 | resume tests、native contract、device media suite | 是 |
| `MEDIA-PLAY-001` | 边下边播、未缓存 seek 和目标分片优先 | resume tests、device media suite | 是 |
| `MEDIA-EXPORT-001` | MP4、媒体库索引和任务缓存保持独立所有权 | media library tests、device media suite | 是 |
| `MEDIA-UPGRADE-001` | 数据库、设置、缓存和会话升级后可恢复 | migration、backup、settings tests | 是 |
| `UPDATE-001` | 更新渠道、Token、断点下载和安装状态一致 | update widget/integration tests | 是 |
| `RELEASE-001` | 本地、设备、Verify、Release 使用同一版本证据 | tooling and evidence tests | 是 |

使用 `--skip-check` 的设备诊断只能作为补充证据，不能满足阻断性契约的完整发布要求。
