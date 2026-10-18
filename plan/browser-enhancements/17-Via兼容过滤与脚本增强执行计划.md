# Via 兼容过滤与脚本增强执行计划

## 执行基线

- 分支：`feature/browser-enhancement-release-channels`
- 基线提交：`928d4d36c78d7017f900d142766c2c98134fe24b`
- 应用版本：`0.1.16+28`
- Drift schema：v8
- ProfilePack：v2
- 本计划不复制 Via APK/Dex，也不把 Via 仓库当作可复用开源库；只实现经过审查的 ABP/uBlock 规则兼容和用户脚本兼容。
- Android 是本轮主交付平台；iOS 对未实现的过滤能力必须显示明确降级，不得宣称跨平台完成。

## 当前代码事实

已经存在：

1. 规则源元数据、手动刷新、镜像回退、大小限制、SHA-256、原子快照和失败回退。
2. 受限 Adblock/uBlock 编译器、`shouldInterceptRequest`、CSS 元素隐藏、MutationObserver 和两个审计过的 scriptlet。
3. 过滤设置、域名拦截/例外和过滤诊断面板。
4. 用户脚本批准摘要、依赖/资源固定、declared/public 联网模式、generation/origin 校验和 `SiteLens.registerMedia`。
5. Stable/Beta 更新通道、versionCode reservation 和发布说明生成。

主要缺口：

1. 多个规则源刷新后，active store 只保留最后一个源，尚未形成可回滚的合并 bundle。
2. profile 过滤策略表和 resolver 存在，但浏览宿主仍主要使用全局策略。
3. 规则例外优先级、资源类型、`$domain`、`$third-party` 等 ABP 语义不完整。
4. Native 请求计数没有完整回传到 Dart；规则 JSON 通过 Pigeon 传输存在 Binder 大小风险。
5. 页面规则的 document-start 时序、CSS 例外和动态 DOM 仍需真实 WebView 验证。
6. 脚本仍不支持 `@include`、`@exclude-match`、自动更新和完整 Tampermonkey 兼容。

历史计划中的旧基线（`main@ca904c3`、`0.1.9+7`）只作为设计记录，执行以本分支实际代码为准。

## 阶段与依赖

```text
F0 基线冻结
  -> F1 数据/宿主契约
  -> F2 规则编译器与合并 bundle
  -> F3 Native 请求拦截与页面过滤
  -> F4 profile/站点策略与诊断 UI
  -> F5 用户脚本兼容扩展
  -> F6 Beta 灰度与 Stable 发布
  -> F7 集成验收与交付
```

F1 的契约完成后才能修改 F2-F5；F2 的规则语义决定 F3 的 Native matcher；F3/F4 通过后才能把新行为放进 Beta；F7 最后执行。

## F0：基线冻结与证据目录

### 工作项

- 记录 Git revision、工作区状态、Flutter/Dart/Android WebView/AndroidX WebKit 版本。
- 建立 Via/ABP 兼容矩阵，区分“支持、降级、不支持”。
- 固定非目标：不执行远程规则 JavaScript、不做 VPN/DNS 级拦截、不复制 Via 实现、不放开任意 `GM_download`。
- 为每个提交建立审查记录：变更范围、风险、审查结论、验证命令和未通过门禁。

### 验收

- 工作区干净；`python3 tool/verify_level.py --auto` 能生成有效计划。
- 计划中每一个“已完成”都有代码、测试或设备证据。

## F1：数据和宿主契约

### 工作项

- 增加 `FilterBundle` 和 bundle 成员模型，合并多个源快照并保存源顺序、编译器版本、摘要、规则数和降级数量。
- 规则源增加 ETag/Last-Modified、最后成功版本和刷新错误元数据。
- 多源刷新先下载/编译，再一次性发布 bundle；失败时继续使用上一 bundle。
- 将 profile 策略贯通到 `HostSession`、`HostFilterContextDto` 和 Native host。
- 评估 schema v9；只有需要新增持久化字段时才迁移，必须保持 v8 可回滚。
- 保持 ProfilePack v2 和备份边界：规则正文、编译产物、Cookie、Web Storage、运行时 token 不进入业务备份。
- 增加 Pigeon DTO 的字段白名单、摘要校验和敏感字段回归测试。

### 输出

- bundle schema/状态机；profile 策略优先级；迁移/回滚说明；DTO 字段清单。

## F2：ABP 规则编译器与合并 bundle

### 工作项

- 先修复当前子集：`@@` 例外优先、域名限定、路径/通配、`$domain`、`~domain`、`$third-party` 和有限资源类型。
- 为规则建立稳定 rule ID、来源源 ID 和 unsupported reason。
- 对 `Accept`、URL 后缀和主框架状态建立保守资源分类；未知类型默认不应用类型限定。
- 用许可明确的最小 fixture 测试 EasyList/来自 Via 规则示例，不直接把 Via APK 资产打进包。
- 进行完整引擎 spike：评估 Rust/C++ ABP/uBlock 引擎的许可证、FFI、构建、内存和启动成本。
- 只有完整引擎明显改善兼容性且可维护时才接入；否则继续维护安全子集。

### 验收

- 阻止、例外、域名限定、第三方规则和资源类型有单元测试。
- 未支持语法可定位到源和原始摘要，不静默宣称完整兼容。
- 规则顺序变化不会改变例外优先级结果。

## F3：Native 请求拦截与页面过滤

### 工作项

- Native 请求回调只读不可变内存 matcher；禁止等待 Dart、磁盘或网络。
- 对 Pigeon 传输设置预算；大 bundle 采用受摘要保护的应用私有 staging 文件或 Native 编译，不把任意路径暴露给网页。
- 顶层文档默认放行，子资源按 matcher 决定；拦截响应不携带缓存和敏感头。
- 统计按 host/generation/bundle 聚合，周期性回传增量；事件 URL 必须脱敏。
- 页面过滤支持安全 CSS、动态 DOM 和审计 scriptlet；远程 `##+js` 名称不在 allow-list 中时只进入降级诊断。
- 修复 document-start 尚无 `documentElement` 时的重试和 CSS 例外合并。
- 规则更新绑定下一次导航，不打断当前页面、播放、下载或投屏。

### 验收

- 测试服务器证明被阻止的资源没有到达。
- 快照切换不会污染旧 generation。
- WebView 不支持 document-start 时，页面过滤关闭但请求过滤和降级提示正确。

## F4：profile、站点例外和诊断 UI

### 工作项

- 明确全局策略、profile 策略和当前站点例外的合并优先级。
- 从档案进入浏览时绑定对应 profile 策略；发现/验证宿主使用同一 bundle 但不加载用户脚本和浏览 Cookie。
- 在浏览页提供本站启用/例外/刷新入口，刷新后提示“下次加载生效”。
- 诊断面板显示 bundle、源、阻止/放行计数、未支持规则、降级原因和脱敏命中摘要。
- UI 继续使用 Site Lens liquid-glass 原语，不添加页面级阴影、渐变或第二套间距。
- 错误归档只保存脱敏摘要，不写入完整 query、Cookie、Authorization、脚本正文或本地绝对路径。

### 验收

- profile A 的例外不会影响 profile B。
- 跨域重定向不会自动继承站点例外。
- 窄屏、浅色、深色和非默认主题下诊断入口可读。

## F5：用户脚本兼容扩展

### 工作项

- 支持 `@exclude-match` 作为安全别名；评估将有限 `@include` 转成明确 HTTP(S) 匹配规则。
- 保持主框架限定、隔离 world、批准摘要、依赖/资源快照和 public 逐脚本确认。
- GM 网络请求必须同时通过 `@connect`/public 策略和过滤 matcher。
- 任何源码、权限、联网模式、依赖或资源变化都撤销旧批准。
- `GM_download` 仅在有明确用户动作、公共 HTTPS、大小上限和下载任务授权时单独设计；不直接开放任意文件写入。
- 自动更新、脚本市场、特权 `unsafeWindow` 和完整 Tampermonkey 兼容仍保持非目标，除非另立计划。
- 同步更新 `docs/support.md`、脚本预检工具、脚本运行时和三处 URL 匹配实现。

### 验收

- Dart、Android Native 和 JS runtime 的 `@match` 结果一致。
- 编辑、依赖变化、public/declared 切换后旧摘要不可继续使用。
- GM 网络无法绕过过滤、TLS、公共 IP、大小和并发限制。

## F6：Beta 灰度与 Stable 发布

### 工作项

- 新 matcher、bundle 合并和脚本兼容先进入 Beta。
- Stable 只启用已验证子集；新引擎保留关闭/回退路径。
- 发布说明记录编译器版本、规则源摘要、降级数量和未完成设备门禁。
- 继续使用现有 versionCode reservation 和 Stable/Beta tag 规则。
- 不引入遥测；使用本地诊断、错误日志和用户导出证据。

### 验收

- Beta 可以回退上一 bundle；Stable 不会因为规则源失败白屏。
- 正式 APK 的包名、签名、versionCode 和发布渠道符合现有工作流。

## F7：验证、代码审查和交付

### 本地门禁

- L0/L1：`flutter analyze`、`flutter test`、`./tool/check.sh`、规则/runtime fixture。
- L2：Pigeon 生成文件、Android WebView host contract、过滤/脚本/导航集成。
- L3：`make acceptance DEVICE=...`，覆盖真实 WebView、刷新、断网回退、脚本、媒体和数据库恢复。
- L4：`make build-release`、APK identity/signature/version 检查和正式安装烟测。

### 每次提交前审查

1. 检查 `git diff --check`、完整 diff、生成文件和迁移路径。
2. 对照本计划的安全边界，确认没有新增任意网页桥、Cookie/Authorization 传递、远程规则 JS 执行或未审计文件路径。
3. 运行当前阶段最低验证等级，并记录设备/环境缺失。
4. 审查结论为通过后才允许提交；不通过则先修复再提交。

### 最终交付证据

- 每个阶段的提交、审查记录和验证报告。
- v8/新 schema 迁移、ProfilePack/备份兼容和回滚证据。
- 多源 bundle 摘要、规则编译器版本、降级数量和实际拦截证据。
- 脚本批准失效、GM 网络过滤和媒体候选授权证据。
- L0-L4 结果、真实 Android WebView 版本、正式 APK 校验和未完成事项。

## 执行状态

- [x] F0 基线确认和计划落盘
- [x] F1 数据/宿主契约（`db63013`）
- [x] F2 规则编译器与合并 bundle（`805f60b`）
- [x] F3 Native 请求拦截与页面过滤（`0643f85`）
- [x] F4 profile/站点策略与诊断 UI（`69d079d`）
- [x] F5 用户脚本兼容扩展（`7c88da3`）
- [ ] F6 Beta 灰度与 Stable 发布（构建/签名/设备门禁待执行）
- [ ] F7 集成验收与交付

## 执行记录

- 计划提交：`db09b09`。
- F1-F5 每次提交前均完成 `git diff --check`、目标分析/测试和独立 diff 审查。
- 当前干净工作区的统一本地门禁已通过：`python3 tool/verify_level.py --auto` → `./tool/check.sh`。
- Android Gradle 编译曾因 Gradle wrapper 从 `mirrors.cloud.tencent.com` 下载时连接被拒绝而未完成；这不等同于 Kotlin 编译通过，必须在可用网络或缓存 Gradle 的环境重试。
- 真实 Android WebView、后台生命周期、正式签名 APK、Beta/Stable 发布和设备验收仍属于 F6/F7 未完成门禁。

