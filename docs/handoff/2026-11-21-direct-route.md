# 交接：直连出口改造（feat/direct-route）

日期：2026-11-21
基线：`main` → `b6b7c1a`（含后续若干修复提交）
规格：#11；子票 #12–#25；PR #26

## 一句话状态

14 张票中 12 张已合并且 CI 绿；剩余 **T11（端到端播放）与 T14（批量下载）** 主体已合入，还剩 **3 个测试失败**全部集中在 T14 的批量下载测试组。代码已全部推送。

## 为什么交给你

这台机器是 aarch64，Flutter 官方 Linux 构建只有 x86-64，靠 QEMU 用户态执行，`dart run` / `flutter_tester` / `flutter build` 全部 SIGSEGV（实测）。所以：

- ✅ 能做：`dart analyze`（原生 arm64 dart）、`tool/` 下全部 Python/Node 契约脚本、git 操作
- ❌ 做不了：`flutter test`、`flutter analyze`、`flutter build apk`、真机/模拟器验收

因此本分支的所有 Widget 测试与迁移测试**只经过 CI 验证**，没有一个在本机跑过。

## 你需要做的第一件事

```bash
git fetch origin feat/direct-route
git checkout feat/direct-route
flutter pub get
flutter test   # 全量；先确认基线
```

## 剩余失败（3 个，全在 test/series_batch_download_test.dart）

1. `sync and delete 单独删除一集只删这一集，其他集与批次目录都还在`
   - `deleteEpisode(2)` 返回 0（期望 1）。已加兜底查找（按 batchDirectory + episodeNumber 扫任务表）仍不生效。
   - 已在该断言上加 `reason:` 诊断，下一次运行会打印 `app.mediaTasks.tasks` 的真实内容（id/episodeNumber/batchDirectory），据此定位。
2. `sheet 面板显示已选计数、整体进度与逐项失败，可单独重试`
   - 曾 10 分钟超时。已把 `tap(batch-start)` 之后改用 `runAsync(() => Future.delayed(Duration.zero))` 推进真实异步，需验证是否解决。
3. `detail page 没有 app 时详情页仍可用，但不开批量入队`
   - 尚未取到具体断言。

## 已知设计缺陷（不是测试问题，接真适配器前必须处理）

- `AppRemotePlaybackHost.openRemote` 把 `candidate.hostId` 当 `profileId` 传给 `openRemoteCandidate`。现在同源成立，接真适配器时要验证。
- 批量下载每集解析两次候选（一次命名、一次入队），20 集 = 40 次适配器往返。
- `Line` 早期不带 `episodeNumber` 导致同 lineId 跨集串号，已修（见提交 `f63aff9`），但真实适配器实现时必须填这个字段。

## 下一步优先级（按用户最新指示调整）

**剧场首屏必须由真适配器供数**，标准是能对接黄果客户端接口或其 H5 镜像。假适配器只作测试替身，不进生产路径。这推翻了原规格里"首屏用假适配器、真适配器 out of scope"的口径。

参考材料：
- `/root/work/hypnfq/out/REPORT.md`（黄果逆向：接口、加密、域名、鉴权）
- `/root/work/hypnfq/out/api_inventory.json`（365 个端点）
- `/root/work/easyl/`（易幕逆向：远端配置 + 源脚本的形态）

## 验收门禁

按规格 A15：产品验收 + `make acceptance DEVICE=<serial>` 的 L3 并行。真机验收从第一轮起一直空着，是最大证据缺口。

## 分支与 PR

- 集成分支：`feat/direct-route`
- PR：#26（草稿）
- 未完成：`/code-review` 双轴评审
