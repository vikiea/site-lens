# 广告规则引擎评估

日期：2026-10-20。仓库基线：8d92be8871da（v0.3.0.beta7）。本轮仅实现刷新状态等界面调整，以下为引擎评估，尚未接入 Rust 或验证移动端编译。

## 结论与范围

可以引入 Brave 的 adblock-rust。推荐 Android 先接请求匹配，再补页面隐藏和经过审核的 scriptlet 资源。以“全部内置源的所有规则均正确执行”为目标，成本高；引入解析器并不能自动完成 WebView 宿主的执行能力。

当前内置 EasyList、EasyPrivacy、EasyList China、uBlock filters 只保存订阅元数据，实际规则由刷新下载。增加简化编译器的分支可以补少量语法，但长期维护完整 ABP/uBlock 语义和资源库的成本明显高于维护引擎适配层。

以下工期是单人熟悉代码、Android 优先的工程估算，包含定向回归，不是已验证排期：

| 阶段 | 交付范围 | 估算 |
| --- | --- | --- |
| 装载与能力诊断 | 全量源固定样本、快照装载回执、区分解析/宿主执行、源身份校验 | 2–4 个工作日 |
| Android Rust 请求引擎 | Rust wrapper、JNI、Gradle 多 ABI、请求类型/域名语义、原子切换、失败回滚、黄金判定与性能测试 | 5–10 个工作日 |
| 页面过滤 | 按站点提取 CSS、动态 class/id、受控资源包、scriptlet 语义及长页性能 | 另需 1–3 周，依兼容范围变化 |
| iOS | Rust 库/转换器、WKContentRuleList 安装、转换损失诊断与设备回归 | 独立适配，不能复用 Android 工期 |

不应承诺 100% uBlock 兼容。WebView 不具备桌面扩展全部拦截能力；redirect、CSP、removeparam、程序化隐藏和 scriptlet 分别需要宿主支持或明确降级。

## 当前证据

| 层 | 现状 | 本地源码 |
| --- | --- | --- |
| 请求解析 | 支持简化域名、例外、domain/third-party 和正向资源类型；不支持的选项跳过整条规则 | lib/filter/filter_service.dart：FilterCompiler、_parseNetworkRule |
| 匹配语义 | Dart 与 Android 各自匹配；Android 的部分路径模式删去 * 后按子串比较，不能等价表达完整 ABP 锚定和分隔符 | lib/filter/filter_service.dart：FilterRule.matches；android/app/src/main/kotlin/dev/vikiea/site_lens/NativeWebHost.kt：filterAllows |
| 页面规则 | CSS 安全子集；scriptlet 仅识别 abort-on-property-read、set-constant，当前运行语义有限 | lib/filter/filter_service.dart；web_assets/filter_runtime.js |
| 快照装载 | 所有规则编码为 JSON，再受 512 KiB DTO 限额；大订阅即便下载/编译成功，也可能无法装载原生宿主 | lib/web_host/host_dto_codec.dart：maxFilterRulePayloadBytes、filterSnapshot |
| 页面规则规模 | 按全局顺序截取前 128 条 CSS、32 条 scriptlet 后注入；应改为站点筛选后限额 | NativeWebHost.kt：refreshFilterInjection |
| 回退源 | 部分 fallback 是其他项目的列表，uBlock 末级 fallback 还是 AdGuard 2.txt；不是同一原始订阅的镜像 | lib/filter/filter_service.dart：builtInFilterSources |
| iOS | applyFilter 当前仅记录快照 ID，未实现完整请求引擎 | ios/Runner/NativeWebHost.swift：applyFilter |

已有测试以手写小样本为主，不能证明全量真实订阅在原生生效。本次独立只读评估抓取的列表中，仅纯域名规则转成当前 DTO 的大小下界，EasyList/EasyPrivacy/China 已分别约 11.1/9.1/1.2 MB；列表会更新，应以固定样本重新量测，不能把这些数值当作稳定规格。

## 建议接入方式

1. Flutter 继续管理订阅、下载、SHA-256、策略、快照历史和诊断。保留每个原始源文本，不能先用当前编译器过滤后再交给 Rust。
2. Pigeon 传递私有快照文件身份、摘要和策略。Android 在装载时校验文件根目录、摘要和大小；不要把完整规则作为巨型 DTO 传入每个 WebView。
3. shouldInterceptRequest 同步进入 JNI/Rust，返回结构化判定。构建新引擎后原子替换句柄；当前页面绑定的快照保持稳定，旧引擎等请求退出后再释放。避免每次请求跨 Dart isolate。
4. 上游默认 single-thread 特性会使 Engine 不具备 Send/Sync。接入时关闭该特性，明确回调并发和句柄生命周期；域名判断、第三方与资源类型需同步校正。
5. 对页面按 URL 查询隐藏规则，随着 DOM 新 class/id 增量取通用规则。scriptlet 从固定、审核过且记录来源/许可证的资源包装载，不能执行订阅提供的任意 JavaScript。
6. Android 建立可复现 Cargo/NDK 构建及目标 ABI、16 KiB ELF 对齐验证。iOS 单独评估静态库与 Apple content-blocking 转换；转换器不能表达的能力报告为降级。

## 上游核验

本次核验上游提交 6028a6d5735f1e81346eeef73c194c7240035248：crate 版本 0.13.3、edition 2024、MPL-2.0，默认特性包含 single-thread；上游 rust-toolchain.toml 固定 1.98，不能由此推断最低 Rust 版本。本机尚未完成 Rust 移动目标构建。升级引擎时应保留原始规则重建，不能假设二进制快照跨小版本兼容。

官方来源：

- https://github.com/brave/adblock-rust/tree/6028a6d5735f1e81346eeef73c194c7240035248
- https://raw.githubusercontent.com/brave/adblock-rust/6028a6d5735f1e81346eeef73c194c7240035248/Cargo.toml
- https://raw.githubusercontent.com/brave/adblock-rust/6028a6d5735f1e81346eeef73c194c7240035248/rust-toolchain.toml
- https://raw.githubusercontent.com/brave/adblock-rust/6028a6d5735f1e81346eeef73c194c7240035248/src/content_blocking.rs
- https://docs.rs/adblock/0.13.3/adblock/engine/struct.Engine.html
- https://developer.android.com/reference/android/webkit/WebViewClient#shouldInterceptRequest(android.webkit.WebView,%20android.webkit.WebResourceRequest)

## 后续实现验收

全量固定订阅可装载并有宿主回执；跨平台请求黄金集与例外规则一致；并发刷新、旧快照回滚和释放无串扰；记录匹配耗时/内存；网页播放、下载、投屏和导航不回归。解析成功、装载成功和真实站点广告过滤应分别记录。
