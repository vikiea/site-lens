# 媒体 P0 工程前置审计

日期：2026-10-22。代码基线：cf5cd98（v0.4.0.alpha8）。产品选择以 [主计划](streaming-and-settings-plan.md) Q1–Q27 为准。本文件记录源码事实与待证工程条件；没有把静态审计当成原型、设备或发布验收。P0 整体仍未完成，尚不能接入正式资源库。

## 原生部分缓存播放

现有 NativeMediaRuntime.openLocal 先检查本地文件存在且非空；start 对远程来源选择 DefaultHttpDataSource，对本地文件选择 DefaultDataSource，再交给 HlsMediaSource。没有缓存未命中时的统一请求队列、已提交分片等待、取消唤醒或资源授权引用。直接把 .hls.part/index.m3u8 交给这条路径不能证明部分缓存安全。

源码：android/app/src/main/kotlin/dev/vikiea/site_lens/NativeMediaRuntime.kt 的 openLocal、start。NativeExportRuntime.localDataSources 提供了可复用的 canonical 路径与文件白名单校验，但导出要求完整本地输入，不应改成允许回源的播放路径。

需要单独验证的最小原型：

1. 完整、固定 ENDLIST 的 VOD manifest/index 可先发布，其分片引用使用原生内部的不透明资源身份；manifest 完整不等于分片下载完整。
2. CacheDataSource.open 根据 representation/resource/execution epoch 取得同一协调器的已提交文件；未命中只提交/提升共享请求并在加载线程有界等待，不能阻塞主 Looper。
3. 发布分片前完成响应、Range、长度与身份校验；只有原子提交后才能给播放器打开。FileDataSource 必须再次校验 canonical 路径和已登记资源，不接受 Pigeon 传入任意路径。
4. 相同资源请求合并；等待期间的取消、暂停、授权失效、网络禁止和空间不足能唤醒并给出具体原因。close/中断释放播放租约；超时不清理已保存断点。
5. 通过慢速 TS/fMP4/AES-128 fixture 证明首播早于全量完成、seek 未缓存分片、回看不重复下载、EOS 和音画同步。现有完整导出 parity 不能代替这些证据。

## 原 profile 的受限后台授权刷新

现有 NativeWebHostRegistry 和 NativeWebHost 都依赖 Activity；create 和 available 明确检查 Activity 尚未销毁。浏览使用默认 profile，所有非浏览 purpose 则选独立 site-lens-probe- 随机 profile。MainActivity.cleanUpFlutterEngine 会销毁 host registry。现有发现 probe 的隔离语义与“复用原浏览 profile”相反，不能直接改它来完成刷新。

源码：android/app/src/main/kotlin/dev/vikiea/site_lens/NativeWebHost.kt 的 NativeWebHostRegistry.create、NativeWebHost.available、profileName、init 和 finishDispose；MainActivity.cleanUpFlutterEngine。现有媒体手势限制与权限拒绝可以复用策略，但现有浏览弹窗会转新标签的行为不能用于刷新会话。

需要单独验证的最小原型：

1. 专用授权刷新会话，使用原生持有的来源/profile 绑定；不导出 Cookie、Authorization、Storage，不导航现有可见标签，不清理共享 profile。
2. 只允许原始顶层来源与已绑定同剧/同集/同表示形式结果，拒绝跨站顶层导航、弹窗、外部 intent、权限、独立下载与自动播放；必要 CDN 子资源按现有策略校验。
3. 会话并发、总时限、尝试次数、所有者 epoch 和销毁均有界；缺少可执行环境时显示 waitingExecution，实际解析失败或无法证明同身份后才进入 reauthorize。
4. 真机分别证明前台、退后台、无前台 Activity、锁屏与进程恢复后的创建/解析/销毁条件，验证无声音、无候选污染、无登录态清理和无持续 WebView 泄漏。尚无这组证据，不能宣称现有实现支持后台静默授权刷新。

## 单一写入与当前播放身份

### 当前身份链路的确定缺口

只读审计确认：JS 会读取 currentSrc/src，但把实际元素、JSON 映射、DOM 和 Resource Timing 合并成普通候选；playing 是 frame 内媒体/AudioContext 聚合状态。Android 保存 playing 以维护通知，并没有把它与某个候选绑定传给 Dart。episodeNumber 在 Dart 只转成显示标题，结构化剧目、当前集、表示形式和音轨均未进入持久候选。由此不能用“候选出现 + 正在播放”直接创建自动保存。

frame/document/main 到 Dart 后只进入候选旁表；parent 和媒体 epoch 未传出。SPA snapshotSequence 只有 clear 携带，后续 state/candidates 未携带，Dart 不保存；host generation 不能替代 SPA/source/选中标签的代次。现有 cacheKey 还包含 host/generation，不能用作跨页面重建的持久资源身份。

源码：web_assets/media_lifecycle.js 的 report、beginSnapshotIfNeeded；BrowserMediaController.receive；NativeWebHost.media 回调；pigeons/web_host.dart 的 HostEvent；lib/web_host/native_hosts.dart 的 onEvent；lib/domain/models.dart 的 MediaCandidate；lib/media/media_service.dart 的 MediaTaskStore.cacheKey。

最小扩展是独立的类型化 PlaybackEvidence 事件，包含元素/source revision/event sequence、host/frame/顶层 document/SPA/选中标签代次、真实当前源及来源类型、结构化媒体身份和 unknown/conflict 原因。稳定窗使用原生单调时钟，确认前后均重新核对全身份；原生解析固定 VOD manifest 并确认表示形式后才可 confirmed。仅扩充未被当前事件路径使用的 MediaCandidateDto 不足。

反例必须覆盖：推荐元素播放而当前候选只有 timing、AudioContext 单独活动、同剧切集旧元素继续播放、顶层 SPA 变而 iframe URL 不变、source/剧集/标签 A→B→A、两元素并播、同 URL 多集冲突、master 不变时音轨/质量变化、blob 关联多份 manifest、frame 替换、迟到 clear，以及 HLS 校验完成前切走标签。现有候选防串集测试不等价于这些“实际播放身份”确认测试。

这两项必须沿源码逐段确认，而不是直接复用现有 MediaTask 记录作为新的观看保存资源。主计划要求手动/观看 owner 独立、资源和文件共享、Android 单写入；当前媒体候选展示记录也不能当成稳定实际播放证据。

### 当前写入者与迁移阻塞

| 对象 | 现有权威与实际写入 |
|---|---|
| 任务 | Dart MediaTaskStore → Drift media_tasks；任务 ID 与 cache_key 唯一，内存队列串行，无统一持久执行 epoch |
| HLS | Dart _startHls 编排 ControlledHttp；native TLS 回退也可能写同一 .part；media_cache 下的 .hls.part 完成后 rename，resources.json 只保存资源哈希与文件名 |
| 普通下载 | Dart 回退同样写 media_cache；原生 Worker 写 app external Download/site-lens，SharedPreferences repository + WorkManager + 每 task 文件锁维持另一套状态 |
| 导出 | Transformer 写临时输出，Dart rename 并登记 Drift media_artifacts；独立索引已避免任务删除级联；实际目录身份字段为 MediaArtifact.taskId |
| 租约 | MediaTaskStore 内存计数和排他集合；没有跨重启持久 owner/lease；Worker 锁不能保护其他 taskId 的同一文件读者 |

源码：lib/media/media_service.dart 的 MediaTaskStore._saveTask、_startHls、_downloadHlsResource、_stop 和 Mp4ExportService；lib/data/database.dart 的 saveMediaTask、media_artifacts；NativeMediaTaskRepository、NativeMediaDownloadWorker、MediaNetworkRuntime、ResumableMediaTransfer；lib/media/media_library.dart 的 register、rescan、moveArtifact 和 deleteArtifact。

具体阻塞如下，不能通过简单重命名或重新调用旧下载流程绕过：

1. 旧 HLS 半成品没有持久完整 manifest、顺序、Range、MAP/key、表示形式和所有分片校验器。可原样保留，不能离线猜测资源关系后继续拼接；新授权验证前保持未验证。旧 prune/start 会删除不匹配或已有最终目录，迁移不能调用它来顺便恢复。
2. Dart .resume.json 与 native Properties .resume 不兼容，URL 授权归一规则也不同。ResumableMediaTransfer 在身份/校验器缺失时可能截断旧分片；必须先适配并验证断点，不能直接把旧 .part 喂给它。
3. NativeDownloadRuntime.status 仍可能触发旧 DownloadManager 的复制迁移，再 remove 原任务；这与零复制目标冲突。存在此类记录时保留原管理身份并报告接管阻塞，不能查询过程中悄悄复制/删除。
4. 旧停止屏障能取消并等待 Dart Future、native TLS/Worker 和文件锁，但缺少跨 Activity/进程的统一持久 fence。迟到写入、自动导出、删除、扫描必须一并受迁移 epoch 约束。
5. 旧 catalogId 应原样取 MediaArtifact.taskId，并另存可空 originTaskId。共享旧 MP4 的既有删除路径可能复制缓存，新所有权层不能直接复用该分支。下载任务身份与目录身份不能重新挂回级联关系。

### 单写入接管检查点

| 检查点 | 必须成立的条件 |
|---|---|
| C0 prepared | 持久迁移 ID、epoch、原用户暂停/取消意图及命令 fence，禁止新的旧写入请求 |
| C1 drained | Dart Future、TLS、Worker、播放/导出/投屏/目录变更均停稳并 flush，旧 workId 作废，相关文件锁已取得 |
| C2 inventoried | 一致的 Drift/WAL、prefs/WorkInfo、文件长度/校验摘要、两类 sidecar 和孤儿清单；只备份元数据，媒体字节原地保留 |
| C3 validated | native 从受限根推导 canonical 位置与文件身份；完整输入校验；部分输入有可证明的 manifest/Range/校验器/授权关系 |
| C4 imported | native 单事务登记 legacy store + ID 映射、资源、存储对象、owner、artifact；重复导入保持同一身份和引用数量 |
| C5 active | 单事务切换权威与 epoch；新写入前及发布前检查 epoch；所有旧入口、Worker/TLS、迟到回调无法复活 |
| C6 published | Flutter 只读 native 快照/分页/事件；兼容 Drift 投影仅接受 native epoch/revision，不能回写竞争权威 |

C5 之前可从冻结快照恢复旧权威；C5 之后不能仅恢复旧数据库重新启动旧 writer。需要先停新 writer 并证明反向兼容，否则原生保持暂停且保留字节。迁移期间禁止回收。

最小迁移原型为 WriterFence、NativeMediaIndex、LegacyMediaImporter/LegacyResumeAdapter 与 Pigeon 迁移快照。夹具须覆盖完整 HLS、Dart/TLS/Worker 部分文件、任务已删但导出仍在、共享旧 MP4、孤儿提交文件和残留 DownloadManager；逐检查点注入崩溃，证明 ID/owner/文件身份不变、前缀不丢、旧 epoch 不能写删、未知输入保留并阻塞。以上仍是待实现原型，没有运行证据。

P0 退出标准保持主计划原定义：身份契约和反例可测试，并且单写入迁移、受限部分缓存 DataSource、原 profile 后台刷新三项前置都有对应工程证据。以上列出的原型尚未实现，P1–P8 尚未接入。
