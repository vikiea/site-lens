<!-- GENERATED FILE: tool/generate_regression_matrix.py -->
<!-- Do not edit; run python3 tool/generate_regression_matrix.py --write. -->

# Site Lens 回归契约矩阵

唯一来源是 [tool/regression_contracts.json](../../tool/regression_contracts.json)。
维护流程见 [回归契约生命周期](regression-contract-lifecycle.md)。
下列测试与命令是验证入口；登记状态与影响提示均不代表用例、设备或发布已经通过。

| ID | 状态 | 行为 | 责任人 | 引入版本 | 最低验证 | 已登记验证 | 验证入口 | 发布阻断 | 替代契约 |
|---|---|---|---|---|---|---|---|---|---|
| `UI-TRANSITION-001` | 生效 | 页面切换不产生白屏、旧页面残留或玻璃层脱离共享背景。 | site-lens-quality | v0.5.0.alpha11 | L1 | 未登记 | `make check`<br>`test/navigation_transition_test.dart` | 是 | — |
| `UI-GLASS-001` | 生效 | 高质量模式保持 Flutter 自有面板、顶栏和菜单的 premium 玻璃策略；纯色背景为深色提供稳定纯黑采样底，并区分 platformView 降级。 | site-lens-quality | v0.5.0.alpha11 | L2 | 未登记 | `make check`<br>`test/glass_quality_strategy_test.dart`<br>`test/glass_surface_test.dart`<br>`test/site_lens_menu_selector_test.dart`<br>`test/ui_primitives_test.dart`<br>`integration_test/hcpp_visual_test.dart`<br>`tool/test_ui_tokens.py` | 是 | — |
| `UI-DOCK-001` | 生效 | 浏览器浮窗贴边几何、六点标记、导航、页面切换和稳定 Overlay 生命周期保持一致，重建 MaterialApp 时不重复挂载 Navigator 或 OverlayEntry；浏览标签菜单的返回、关闭、无障碍展开状态和页面回退行为保持一致。 | site-lens-quality | v0.5.0.alpha11 | L2 | 未登记 | `make check`<br>`test/browser_dock_test.dart`<br>`test/widget_test.dart` | 是 | — |
| `MEDIA-HLS-001` | 生效 | Dart、原生导出和 Media3 对 HLS 共享资源使用相同的路径、key、init 和 segment 语义。 | site-lens-quality | v0.5.0.alpha11 | L3 | 未登记 | `make check`<br>`test/media_download_resume_test.dart`<br>`tool/test_native_media_contract.py`<br>`integration_test/media_tasks_test.dart` | 是 | — |
| `MEDIA-PLAY-001` | 生效 | 边下边播、未缓存 seek、目标分片优先和清单原子发布保持可恢复。 | site-lens-quality | v0.5.0.alpha11 | L3 | 未登记 | `make check`<br>`test/media_download_resume_test.dart`<br>`integration_test/media_tasks_test.dart` | 是 | — |
| `MEDIA-EXPORT-001` | 生效 | MP4 导出、独立索引、媒体库重扫和任务删除保持独立所有权。 | site-lens-quality | v0.5.0.alpha11 | L3 | 未登记 | `make check`<br>`test/media_library_test.dart`<br>`integration_test/media_tasks_test.dart` | 是 | — |
| `MEDIA-UPGRADE-001` | 生效 | 稳定版本升级后数据库、设置、媒体缓存、历史和浏览器会话仍可恢复。 | site-lens-quality | v0.5.0.alpha11 | L2 | 未登记 | `make check`<br>`test/profile_migration_test.dart`<br>`test/backup_service_test.dart`<br>`test/settings_repository_test.dart`<br>`test/media_download_resume_test.dart` | 是 | — |
| `UPDATE-001` | 生效 | 更新渠道、GitHub Token、断点下载和安装状态在异步页面生命周期中保持一致。 | site-lens-quality | v0.5.0.alpha11 | L2 | 未登记 | `make check`<br>`test/software_update_screen_test.dart`<br>`integration_test/update_flow_test.dart`<br>`tool/test_release_pubspec.py` | 是 | — |
| `RELEASE-001` | 生效 | 本地、设备、Verify、Release 使用同一提交、版本、APK 身份和验证证据。 | site-lens-quality | v0.5.0.alpha11 | L4 | 未登记 | `make check`<br>`tool/test_verify_level.py`<br>`tool/test_acceptance_evidence.py`<br>`tool/test_release_pubspec.py`<br>`tool/test_release_identity.py`<br>`tool/test_regression_contracts.py` | 是 | — |

生命周期规则：

- 生效与弃用契约必须保留真实测试及双向标记，替代目标必须是另一条生效契约。
- 撤销必须记录原因；撤销条目与历史永久保留，ID 不得删除或复用。
- 修改行为或绑定时清空旧验证记录；验证记录必须注明日期、级别和报告。
- 设备诊断跳过本地检查时只能作为补充证据。

## 变更记录

| ID | 修订 | 动作 | 日期 | 版本 | 原因 | 状态摘要 |
|---|---|---|---|---|---|---|
| `UI-TRANSITION-001` | 1 | introduced | 2026-10-28 | 0.5.0-alpha11 | 从 schema 1 迁入可审计注册表；沿用既有行为与测试，补充生命周期元数据。 | `e906125f62dd` |
| `UI-GLASS-001` | 1 | introduced | 2026-10-28 | 0.5.0-alpha11 | 从 schema 1 迁入可审计注册表；沿用既有行为与测试，补充生命周期元数据。 | `1406b9caf29e` |
| `UI-DOCK-001` | 1 | introduced | 2026-10-28 | 0.5.0-alpha11 | 从 schema 1 迁入可审计注册表；沿用既有行为与测试，补充生命周期元数据。 | `3bd2d6f110bc` |
| `MEDIA-HLS-001` | 1 | introduced | 2026-10-28 | 0.5.0-alpha11 | 从 schema 1 迁入可审计注册表；沿用既有行为与测试，补充生命周期元数据。 | `c0acff38c8d6` |
| `MEDIA-PLAY-001` | 1 | introduced | 2026-10-28 | 0.5.0-alpha11 | 从 schema 1 迁入可审计注册表；沿用既有行为与测试，补充生命周期元数据。 | `7608a8021278` |
| `MEDIA-EXPORT-001` | 1 | introduced | 2026-10-28 | 0.5.0-alpha11 | 从 schema 1 迁入可审计注册表；沿用既有行为与测试，补充生命周期元数据。 | `0fca65854033` |
| `MEDIA-UPGRADE-001` | 1 | introduced | 2026-10-28 | 0.5.0-alpha11 | 从 schema 1 迁入可审计注册表；沿用既有行为与测试，补充生命周期元数据。 | `5e0035486f63` |
| `UPDATE-001` | 1 | introduced | 2026-10-28 | 0.5.0-alpha11 | 从 schema 1 迁入可审计注册表；沿用既有行为与测试，补充生命周期元数据。 | `6ab49fb6013c` |
| `RELEASE-001` | 1 | introduced | 2026-10-28 | 0.5.0-alpha11 | 从 schema 1 迁入可审计注册表；沿用既有行为与测试，补充生命周期元数据。 | `a4de36bd31b0` |
| `UI-GLASS-001` | 2 | updated | 2026-10-28 | 0.5.0-alpha13 | 将纯色背景、菜单和顶栏 premium 玻璃行为纳入回归契约 | `a390d5d15dbb` |
| `UI-DOCK-001` | 2 | updated | 2026-10-28 | 0.5.0-alpha13 | 记录稳定 Overlay 生命周期，防止 Navigator 和 OverlayEntry 重复挂载 | `4741c49d62ba` |
| `UI-DOCK-001` | 3 | updated | 2026-10-28 | 0.5.0-alpha13 | 补充浏览标签菜单返回关闭回归与 OverlayEntry 生命周期约束 | `56b88d20d6e1` |
| `UI-DOCK-001` | 4 | updated | 2026-10-28 | 0.5.0-alpha13 | 补充菜单无障碍展开状态并登记共享菜单实现路径 | `2f98590f1b7c` |
