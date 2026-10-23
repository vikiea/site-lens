# 原生后台播放与系统控制子计划

日期：2026-10-23。代码基线为 `145ab61` 之后的修复检查点；本计划尚未启用原生后台播放。
网页 `BrowserMediaService` 的通过证据不等于本计划完成。原生后台当前仍未启用。

## 已确认的实现边界

- 当前 `NativeMediaRuntime` 在 Activity 内创建 ExoPlayer、持有 Flutter texture；
  `MainActivity.cleanUpFlutterEngine` 调用 `dispose()`，播放器随之释放。
- `NativeMediaPlayerScreen.dispose` 会 close 会话并释放 task 引用。通知外壳即使
  存活，也无法改变这一所有权关系；不能把转发 Activity 闭包的 Service 当作后台播放器。
- 文件缓存和导出目录仍按既有独立所有权处理，不创建第二份播放缓存，不搬迁媒体字节。
- 当前标签后台开关仍只描述网页策略。原生后台开关/默认值需在真实服务接入时集中到
  AppSettings/SettingsRepository，不能通过修改网页开关语义悄悄影响已有设置。

## B0 原生读租约与文件变更互斥

这部分先保护现有前台播放，也为服务持有文件建立前置。

- [x] 进程内统一 registry：读租约与变更许可互斥，许可覆盖文件操作全程。
- [x] 当前播放携带稳定 task/catalog ID 与 canonical 文件身份；HLS 保护完整目录，
  SAF 保护实际 document URI；暂停、缓冲和已结束但可重播时保留读租约。
- [x] 原生 delete/rename/move、直接投递覆盖、物化目标覆盖在执行前取得变更许可。
  move 在外层拒绝，不能让内部删除异常被吞掉后返回“移动成功”。
- [x] 原生下载 delete 在取消 transport 前取许可，旧 DownloadManager 迁移也受
  task、真实 DownloadManager 源与 Worker/stage 路径共同保护；冻结同一份
  legacy snapshot 后再取许可。命中当前读者时不得删除、移动源文件或顺便改写任务状态。
- [x] JVM 并发、多个读者、幂等释放、异常释放、父子路径、软链、含空格路径、
  SAF direct/tree/编码别名、含 `document` 的 tree ID 与危险来源回归：新增
  11 项租约回归及 3 项移动故障恢复回归；原生累计 99 项通过。解码采用 API 26 兼容重载。
- [x] 真机证明：没有 Dart retain 时，暂停 MP4 仍拒绝删除/重命名/移动/覆盖，
  HLS 子分片拒绝删除，明确停止后操作成功。用例已加入 `media_tasks_test.dart`；
  alpha12 合并后 API 36 / WebView 155 的完整 35 项批次通过本断言，正常包与
  本机来源绑定数据库校验恢复成功。该证据不覆盖下面尚未接入的 Dart writer 握手。
- [x] 当前原生租约与 B0.2 窄修独立复审通过；未完成 B0.1/最终发布和设备证据
  不能以此宣称整个 B0 完成。
- [x] Android 库副本回收、物化副本清理及库文件删除接入 `deleteOwnedSources`：
  一次保护完整集合后删第一项，读取中的后项会拒绝整组且不改副本元数据；
  后续 I/O 失败回报已完成清单，保留可重试进度。
- [x] Android 本地目录交付与移动接入原生校验复制/移动，保护目标和 `.part`；
  SHA-256 回读通过后发布，移动源删除失败回滚新目标；若回滚也失败，结构化回传 target 并持久化
  目标/源恢复记录。重试前确认 target 可读才清理旧副本。共享旧 MP4 先复制并
  `flush` 新缓存引用，再尝试删除旧路径；保存失败的同 Engine 重试也先重新
  持久化当前引用，不能跳过失败。Inspector/投递/校验也持原生读租约。
- [ ] Flutter 其余 File/Directory 变更接入原生一次性操作，尤其任务缓存删除与
  正在执行的 Dart writer 的 stop/flush 握手；不能只查 heldIDs。
- [ ] 原生操作完成但 Engine 未收到结果时的持久恢复记录和设备证明。

当前 registry 是单进程 fence。后台服务保持同进程；若以后引入独立进程，必须先
更换为跨进程权威，不能沿用内存 registry 宣称隔离有效。常见 SAF direct/tree URI 按 authority 和解码一次的 document ID 统一；
不同 provider authority 指向同一物理文件的别名不能推断等价。已有 task/catalog ID
与原始 URI 必须原样保留。

### B0 剩余接口拆分

1. B0.1 下载删除：冻结 Dart/native 缓存与可选导出清单，在原生取得完整许可后
   才停止 writer。Dart writer 需要 stop/flush 握手，不能在取得许可前 `_active.cancel()`；
   不存在 native repository row 的 Dart HLS 同样受保护。
2. B0.2 副本清理已接入，设备验收待补：`deleteOwnedSources` 在删除第一项之前一次保护全部源；被
   当前读者拒绝时保留库/物化副本字段，按已有清理流程稍后重试。
3. B0.3 写入发布：Android 本地 move、校验复制已接入原生，继续把下载缓存
   与导出 `.part` 最终发布及清理接入原生一次性操作。共享旧 MP4 先校验复制，再持久化缓存引用，最后单独取锁删除原件；
   后续取锁失败仍保留原件。移动/改名需要可恢复结果，防止 Engine 消失后索引落后。
4. B0.4 设备与复审：验证暂停/缓冲 reader、多个 Dart runtime 无 retain、拒绝
   删除不改状态不停止 writer、Engine detach、整组副本清理和跨路径别名。只有
   接入后的最终复审和对应设备证据均满足，才进入 B1。

## B1 服务持有播放器与界面重建

- [ ] 使用 Media3 `MediaSessionService` 持有 application-context ExoPlayer 和
  `MediaSession`；Flutter/Activity 只持有 surface 与命令桥，不保留在服务中的 Activity 闭包。
- [ ] 开始播放时原生先取得读租约、验证输入，再返回成功；切换时新输入先取得租约，
  旧输入在播放器确认释放后退租。停止、错误、取消和服务销毁有统一屏障。
- [ ] 页面退出 detach surface，显式停止才关闭会话。重建 Engine 可只读查询当前
  session/epoch/task/catalog/position；DB 未初始化时，原生变更 guard 仍有效。
- [ ] 通知点击回到实际当前会话，重新 attach texture，保留 seek/倍速/位置；旧页面
  的迟到 close/detach 不得停止或解绑新的会话。
- [ ] Media3 管理通知、前台服务和音频焦点。未申请权限、服务启动被系统限制或通知
  渠道被禁用时给出具体有效状态，不假设服务启动成功，也不在后台重复尝试启动。
- [ ] 停止清理通知和租约；暂停不丢会话，但不承诺无限驻留或绕过系统省电限制。

退出条件：Activity/Flutter detach 后仍由服务播放并受系统控制，重接界面准确；
上述变更互斥覆盖原生和 Flutter 所有实际写入入口。

## B2 原生剧集队列与通知控制

- [ ] 原生持有队列及顺序，entryId 使用稳定 task/catalog 身份，标题/显示去重与
  资源授权身份分离。上下集只能选队列明确存在且可读取的输入，不猜测地址。
- [ ] 第一阶段队列使用已完成本地 HLS/MP4/SAF；未完整资源等观看保存 P0–P3
  的共享协调器与受限 DataSource 完成后接入，不另建缓存或下载器。
- [ ] 页面、通知栏、锁屏和耳机统一控制同一 Player：播放、暂停、上下集、seek、
  停止。边界禁用跳转；自动 EOS 接下一集沿同一身份与租约验证。
- [ ] 队列变更与当前索引原子更新；无法读取下一集保持当前状态并解释原因，不能
  先更新标题再播放另一内容。未选队列项不得因过早释放被后台任务清理。
- [ ] 拒绝无授权外部 controller 改写队列、文件路径或媒体 URL；通知仅公开显示
  元数据，敏感 headers/profile/授权内容留在原生。

退出条件：无 Flutter 页面回调参与时，原生队列上下集仍正确，重新打开页面索引一致。

## B3 生命周期、恢复与验收

- [ ] 确定并持久化可恢复的队列引用、位置、倍速和用户暂停/停止意图；进程被杀后
  恢复为可见的暂停/需重授权状态，不因读取诊断、启动 App 或系统重启自动播放。
- [ ] 设备覆盖：退后台、锁屏、Activity/Engine 重建、任务移除、暂停恢复、网络切换、
  耳机断开、焦点丢失、真实通知命令、下一集缺失、停止与文件删除竞态。
- [ ] 观察无 Activity 泄漏、重复播放器、残留纹理、重复通知或停止后仍持有的读租约。
- [ ] 按风险运行本地门禁、原生单测、受保护 L3 和正式 APK 验证；每批记录源码摘要、
  设备、指令、断言与恢复结果。独立 review 后才可提交；发布另需用户授权。

## 证据与当前阻塞

本轮 JVM、静态分析与接线契约已通过；全部日志留在 `build/android-acceptance/`。
B0 复审已修正 legacy source 遗漏与 SAF 别名/API 兼容；停止时 release 异常保留
player/lease 供重试，在读者结束无法确认时不提前退租。Flutter 直接操作仍待接入
原生一次性操作，permit 须覆盖 IO、writer 停止与清理全程，不能只查询 heldIDs
或依靠 Engine detach 时释放 Dart begin/end token。
当前 API 36 / WebView 155 真机完成上述原生读者定向及完整验收，并恢复正常包与
本机备份数据库。已完成证据按源码变化复用；原生读者通过不替代尚未实现的 Dart
writer 停止/flush、Engine detach 恢复记录和服务后台生命周期验收。

Media3 服务参考：<https://developer.android.com/media/media3/session/background-playback>。
当前只把该契约用作实现目标，未把官方能力当成本应用已完成的证据。

B0.2 最终限定复审 APPROVE。媒体库 32 项回归覆盖整组后项 reader 拒绝、部分
I/O 失败回执、连续缓存引用持久化失败后重试/Store 重建、移动双故障/Library
重建，以及恢复 target 消失后保留唯一 source。原生 99 项包括 3 个纯故障完成
用例。当前未取得这些新增接口的设备结果，原全量 L3 不覆盖该增量。

alpha13 发布前复审补充：共享旧 MP4 脱离复制在目标已发布、缓存引用写入失败后
重启的重试曾被同名检查阻断。现仅该路径显式允许原生复用已有副本，在源读租约
及目标变更许可内核验非空长度/SHA-256 后接管，不重写文件；不同内容、取消及
读取失败保留原件并拒绝。媒体库新增失败后立即重建 Store/Library 回归，累计
33 项；新增 6 项 JVM 后累计 105 项通过，窄审 APPROVE。它不替代未发布 `.part`
和完整 Engine detach 回执的持久恢复计划。
