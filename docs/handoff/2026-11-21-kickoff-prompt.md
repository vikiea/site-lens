# 新环境开整提示词

把下面整段贴给接手会话的第一条消息。它自包含：不需要你读过上一场会话。

---

我要在**另一台具备完整 Flutter 工具链的机器**上接手一个进行中的改造，仓库是 `vikiea/site-lens`，集成分支 `feat/direct-route`。

## 你要先读的

按顺序，读完再动手：

1. `docs/handoff/2026-11-21-direct-route.md` —— 上一环境写的交接说明，含"为什么交给你"、剩余失败位置、三条已知设计缺陷。
2. `AGENTS.md` —— 仓库规范：构建/验证命令、Pigeon 契约要求、媒体与持久化契约、发布流程。
3. `GLOSSARY.md` —— 领域语言。下面的术语全部以它为准，不要另造同义词。
4. `docs/adr/0002` `0004` `0005` `0006` `0007` `0008` `0009` `0010` —— 这次改造的全部架构决策。

## 这次改造是什么

把 site-lens（本地优先的站点发现与浏览 app）升级成**播放类 app**，核心是新增一条**直连出口**：内容由应用通过站点自己的接口取得，网页只用来拿凭证。

术语（务必按 GLOSSARY 用）：
- **站点档案** 是一等对象，可同时具备**直连出口**与**浏览出口**
- **站点适配器** 是直连出口的唯一入口，站点专有逻辑止步于此
- **线路** 与 **媒体候选** 不同：用户选线路，播放器拿候选
- **站点凭证** 由应用持有，跨进程推给原生，原生只读

已落地的能力：档案出口字段（schema v26）、适配器契约与注册表、登录容器与凭证存储、凭证跨进程推送与失效处置、媒体会话接受远程地址、远程播放带凭证且过期自动重开、缓存层与下载分离、四类远程失败归因、剧场首屏、剧集详情与线路切换、播放器端到端与跳集续播、批量下载。

## 你的第一件事：先拿事实，别急着改代码

```bash
git fetch origin
git checkout feat/direct-route
git pull
flutter pub get
flutter test          # 全量
```

**这一步的意义**：上一环境是 aarch64 + QEMU 跑 x86-64 Flutter，`flutter test` 根本起不来。所以本分支所有 Widget 测试与迁移测试**只经过 CI 验证，没有一个在本机跑过**。你现在跑的这一遍，是这套代码第一次在真人手里执行测试。

把结果如实告诉我，特别是失败数量和失败用例名。**不要急着修，先让我看全貌。**

## 已知的 3 个失败（全在 `test/series_batch_download_test.dart`）

1. `sync and delete 单独删除一集只删这一集，其他集与批次目录都还在`
   - `deleteEpisode(2)` 返回 0（期望 1）。已加兜底查找仍不生效。
   - 该断言上有 `reason:` 诊断，会打印 `app.mediaTasks.tasks` 的真实内容（id/episodeNumber/batchDirectory）。**先看这条输出再动手。**
2. `sheet 面板显示已选计数、整体进度与逐项失败，可单独重试`
   - 曾 10 分钟超时。已把 `tap(batch-start)` 后改用 `runAsync(() => Future.delayed(Duration.zero))` 推进真实异步，需验证。
3. `detail page 没有 app 时详情页仍可用，但不开批量入队`
   - 具体断言尚未取到。

## 接下来最重要的一件事（用户已明确改变口径）

**剧场首屏必须由真适配器供数**，标准是能对接**黄果客户端接口**或其 **H5 镜像**。假适配器只作测试替身，**不进生产路径**。

这推翻了原规格里"首屏用假适配器、真适配器 out of scope"的口径。也就是说：现在首屏在生产路径下是空态，而下一个里程碑就是让它有内容。

参考材料（在**上一台机器**上，路径是 `/root/work/hypnfq/` 与 `/root/work/easyl/`）：
- `hypnfq/out/REPORT.md` —— 黄果短剧逆向总报告
- `hypnfq/out/api_inventory.json` —— 365 个端点
- `hypnfq/out/shell_integration.json` —— 传输层、加密、鉴权、域名、会员字段的结构化摘要
- `easyl/` —— 易幕逆向，参考它"远端配置 + 源脚本"的形态

如果这些资料没有随仓库过来，先问我要，别凭印象造。

## 三条已知设计缺陷（接真适配器前必须处理）

1. `AppRemotePlaybackHost.openRemote` 把 `candidate.hostId` 当 `profileId` 传给 `openRemoteCandidate`。现在同源成立，接真适配器要验证。
2. 批量下载每集解析两次候选（一次命名、一次入队），20 集 = 40 次适配器往返。
3. `Line` 早期不带 `episodeNumber`，导致同 lineId 跨集串号（已修，提交 `f63aff9`）。**真实适配器实现时必须填这个字段。**

## 这一环境下必须遵守的工程约束

这些不是风格偏好，是上一环境用二十多轮 CI 失败换来的：

- **不改 schema 的判断**：DDL 只写一份常量，`onCreate` 与 `onUpgrade` 两处共用；`ALTER` 前先判表存在；迁移步骤里**不能引用之后才创建的列**。
- **不引入新依赖**：原生 JSON 只用 `org.json`（项目没有 `kotlinx.serialization`）；public 类不能暴露 internal 类型；`as? X` 之后显式收窄。
- **测试写法**：惰性列表用 `scrollUntilVisible`；同一文案多处出现用 `find.descendant` 收敛；Tooltip 不是可见文字，用 `find.byTooltip`；真实插件（secure storage、path_provider）要 mock 平台通道；**不留未取消的 Stream 订阅**（曾让四个测试各挂 10 分钟）；纯 `test()` 里用 `TestDefaultBinaryMessengerBinding` 要先 `TestWidgetsFlutterBinding.ensureInitialized()`。
- **异步与假时钟**：widget 测试的假时钟推不动真实数据库/适配器异步，要 `runAsync`。`pumpAndSettle` 在某个用例里挂 10 分钟通常就是这个原因。
- **`RemoteRetryPolicy.plan()` 只给计划，不执行重试**——要用就显式调 `plan.retry!()`。

## 验收门禁

- `make check` 是基础门禁（`tool/check.sh`）。
- `make check-native` 跑原生 Kotlin 单测。
- 真机验收：`make acceptance DEVICE=<serial>`，L3 级。
- **真机验收从第一轮起就一直空着**，是这次改造最大的证据缺口。锁屏继续播放、通知栏控件、媒体键这三条只有真机能验。

## 工作方式

- 一次只跟我说一件事的结论，别替我猜。
- 遇到"这个测试是不是写错了"的判断，先给出证据（失败信息、实现代码、GLOSSARY 的定义），再给结论。
- 改代码前先说打算改什么、为什么。
- 我不会因为你要花时间而催你；我会因为你不说清楚而打断你。

第一件事：拉分支、跑 `flutter test`、把结果贴给我。
