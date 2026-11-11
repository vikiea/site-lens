# Alpha 74 可见播放标题与批量任务组验证

基线：`7900dce` (`v0.6.0.alpha73`)。目标版本：`0.6.0-alpha74+207`。

本轮只修正播放页任务组标题读取，不变更系统代理、PAC、VPN/TUN、原生传输和媒体身份边界。

## 根因

黄果页面当前播放标题为 `合欢宗小弟子`，但 DOM 同时保留多个宽高为零的推荐卡片标题，例如 `西游天命西征`、`神雕：重生之杨过`。原实现存在两个问题：

- 多个选择器的逗号查询结果按 DOM 顺序返回，隐藏推荐卡片可能先于当前播放器。
- 多候选批量下载先采用候选 `seriesTitle` 或确定性 `批量媒体-*` 回退，没有先读取当前活动播放页标题。

真机 Alpha72 复现：同一页面单集任务组为 `合欢宗小弟子`，但批量下载其余 12 集进入 `批量媒体-8c107d8a`。

## 修复契约

- `NativeHosts` 通过专用 `@visible-playback-title` 读取标题。
- 标题选择器按声明优先级逐项查询，不再使用逗号选择器组的 DOM 顺序。
- 候选节点必须具有正宽高，并通过 `checkVisibility(checkOpacity, checkVisibilityCSS)`；环境无该 API 时回退到 computed style。
- 普通选择器的 ready 只要求页面非 loading、根节点可见且文本非空；短标题如 `合欢宗小弟子` 不再被 16 字门槛丢弃。
- 发布页 `@latest-addresses` 保留原有文本、结构元素和链接完整性门禁。
- 单集和多集用户操作都优先采用当前可见播放标题；只有真实标题不可用时，才使用一致的候选标题或确定性 `媒体-*` / `批量媒体-*` 临时组。
- invisible selector match 不参与标题；descriptive document title 仍是受 generation、URL 和 candidate boundary 保护的最终回退。

## 本地验证

- `./tool/check.sh`：PASS；894 项 Flutter 测试及 analyze、Pigeon、Node WebView 脚本、媒体生命周期、Android 工具链、回归矩阵和 UI token 契约全部通过。
- 定向 browser/native host 测试：27 项通过。
- `node tool/test_page_inspector.mjs`：通过；新增可见短标题、选择器优先级和 CSS hidden 覆盖。
- 独立只读评审：PASS，无 release-blocking P0/P1/P2。

## 真机验证

设备：`2410DPN6CC`，无线调试端点 `172.16.76.233:39117`。

页面：`https://fdu.adihsppe.cc/video/12608/`，页面标题 `合欢宗小弟子 - 短剧视频在线观看 | 黄果短剧`。

- 修复前：`合欢宗小弟子` 1 项 + `批量媒体-8c107d8a` 12 项。
- 修复后：批量选择 9 集仅生成 `合欢宗小弟子` 1 个任务组，共 9 项；任务名依次为 `第1集` 至 `第9集`。
- 验收后已批量删除本轮测试任务和下载缓存，媒体任务列表恢复为空。

统一 `verify_level --auto --device` 的本地全量阶段通过；debug 包安装被 MIUI USB 安装限制拦截，因此该设备的 debug integration 阶段未通过。正式签名灰度安装和最终 GitHub 正式 APK 复验在发布记录中单独确认。

## 发布边界

本地测试、独立评审和开发签名真机验证不等于 GitHub Verify 或 Release 完成。alpha74 的发布完成状态以正式 Release workflow 和 APK digest 为准。
