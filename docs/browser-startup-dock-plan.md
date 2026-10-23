# 冷启动与全局浏览快捷入口后续子计划

工作分支：`codex/browser-startup-dock`。本文件记录本批实现与验证状态。

基线：v0.4.0.alpha13 / 41f6cb8。alpha13 的发布证据保留在 GitHub Release；本计划单独实现、验证后再发测试版。

## 已确认源码线索

- ProfilesPanel 在 persistentStateLoaded=false 时仍渲染现有 profiles，并放置280高的循环进度。
- initialize 顺序等待媒体任务恢复、媒体库恢复、native reconcile、load，再恢复标签。
- load 顺序读取多张表并在发布 persistentStateLoaded 前重建过滤 bundle、应用宿主偏好及同步媒体策略。
- 恢复标签仅创建 metadata 对象，不启动原生WebView。此前空调试库的计时不代表用户的一标签/四源数据；按最新要求直接优化，不再等待对照复现。

## 子计划 S0：启动测量与解耦

1. 已保留可选固定schema启动计时；按用户最新要求不再以真机对照采样作为实施前提。
2. 优先发布设置、站点与标签metadata；把规则编译、媒体库/下载恢复等非首屏工作解耦，但保留导航前规则/脚本安全准备与既有恢复互斥。
3. 以受控迟滞依赖、恢复失败、用户抢先打开/关闭标签、关闭恢复开关回归验证；自动化只跑本地，真机改为测试包人工验证。

## 子计划 S1：全局浏览快捷浮条

- 移除首页与档案详情重复的 ResumeBrowserBar，保留“浏览”一级菜单作为完整标签管理页。
- 非WebView Flutter页面有标签时显示吸边竖条；左右边吸附、边缘竖向位置可拖动，点击展开横条。
- 展开后点击标题进入当前明确标签；提供关闭当前标签按钮，不把关闭入口当作关闭全部。
- 不覆盖WebView原生工具栏；键盘、safe area、底部导航、弹窗与系统返回/无障碍触摸均需验证。
- 位置/展示偏好沿集中AppSettings持久化，不新增平行设置库。
- 使用现有玻璃原语和角色；短条紧凑，长标题省略并保留完整语义。

## 子计划 S2：证据与发布

验证启动时序单测、窄屏/深浅/文本缩放widget及跨页面/恢复/多标签/关闭；独立review后通过GitHub workflow发布后续测试版。真机拖动/渲染由人工清单验收，此前未变媒体/代理证据复用。

## 只读审计补充（41f6cb8）

- profiles身份集合未知时不得先恢复tabs并把profileId置空；先取得可靠设置及profile集合，再恢复纯metadata。
- 不可仅提前persistentStateLoaded：拆成首页metadata、tabs metadata、导航准备、媒体恢复readiness，保留错误/降级语义。
- 导航共享准备Future覆盖openUrl、ensureTabLoaded/recreate、检测host入口；准备未完成时不绕过脚本和规则授权。
- 媒体后台恢复前需下沉写入fence，因为UI可直接调用公开service；tasks.restore→library.restore→reconcile保持顺序，失败不在finally标ready。
- 保留tabLifecycle/selection/restorePolicy epoch、pendingCreate、串行sessionWrites和shutdown等待，避免迟到恢复覆写新用户操作。
- 全局浮条不能用!browserVisible作为唯一条件：modal也会把它置false。由root route observer区分browser/loading/failed、普通Flutter、popup/media/fullscreen，隐藏弹窗与转场中的浮条。
- 冷恢复标签应显示待加载，不写“仍在后台运行”。进入/关闭按稳定tabID、复核epoch，关闭一个后只选择邻居，不在非WebView页面偷偷加载下一tab。
- 位置集中AppSettings，独立于WebView controlsX/Y；结束拖动保存一次，界面展开状态不持久化。

## 当前实现

- initialize 幂等；首页设置/站点和保存标签先发布，媒体任务→媒体库→native reconcile
  与浏览器规则准备、日志/通知/联网监听各自异步执行。规则失败不阻止首页，但阻止
  网页宿主创建，下一次打开可重试；修复设置仍可操作。
- 过滤规则编译、摘要、UTF-8/JSON预算和bundle序列化使用纯数据isolate；exact-selection
  缓存绑定源ID、订阅URL、snapshot ID和摘要，命中只恢复一个bundle。
- 任务写入/文件访问有readiness fence；恢复失败不放行同步写入。目录组织等待任务恢复，
  避免先清空旧的名称/文件夹映射；shutdown与备份恢复等待已接纳的异步工作。
- 浮条集中在root navigator外、更新提示层内；普通Flutter页显示，浏览/播放器/弹窗/
  转场/键盘隐藏，拖动结束才持久化位置；移除两处旧ResumeBrowserBar。
- 本批新增更新页紧凑布局、不透明度同行、codec进入自动读取及五分钟app级缓存。
  Android不再叠加一个无限期原生缓存，失败不缓存。
- 真机与跨设备边界为待验，完整操作清单见
  `validation/browser-startup-settings-manual.md`。不宣称量化启动耗时提升或已通过L3。

## 本地检查进度（2026-10-23）

- 更新渠道改用同行选择器并移除描述；当前版本仅保留版本号，合并进检查更新面板。
- 不透明度标签、数值和滑动条在窄屏与放大字体下保持同行；默认55标记与拖动保留。
- codec进入页面自动读取；五分钟内重进直接复用app级缓存，读取不续期，失败可重试。
- 修复独立审查发现的两处启动边界：shutdown/备份恢复等待后续浏览器准备重试；
  媒体恢复失败保留失败状态，监听器不触发无退避重试，显式restore才再次读取。
- `dart analyze`、完整`./tool/check.sh`通过，其中Flutter测试627项通过；
  `:app:testDebugUnitTest`通过。debug及正式APK的包身份/正式证书检查通过。
- `python3 tool/verify_level.py --auto`选择L3，本地阶段通过；未提供本批设备证据，
  以exit 2保留Android验收未完成。无活动DTD应用，未完成热重载；不以widget测试
  或构建产物推断真实渲染效果。测试版尚未提交/发布。
