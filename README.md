# Site Lens

本机优先的 Flutter 站点发现与浏览应用。**当前交付范围：Android-only**；iOS 源码和手动验收入口保留，但不属于本轮交付。**先检测、人工选择、不自动跳站**；可选用户脚本使用原生隔离环境和按脚本授权的 GM 子集，不是完整浏览器或 Tampermonkey。

## 构建与发布

GitHub Actions 的标签发布、正式签名 Secrets 和应用内更新说明见 [发布流程](docs/releasing.md)。

## 使用

1. 在「择站」添加实际发布页或手动候选。没有预置业务站点。
2. 发布页默认用 `@latest-addresses` 定位地址区域。解析器会综合标题、语义 class/id、链接、`data-*` 域名、跳转参数（例如 `/hop?to=example.com`）和纯文本域名，不再依赖某一个站点的 class；无法明确定位时填写该区域的 CSS 选择器（例如 `#latest-addresses`）。备用发布页同样添加为来源，不能当业务站点。来源失败保留候选缓存和上次成功时间。
3. 「刷新并检测」先做最多 4 路 HTTP 初筛，再串行验证前三个不同落点的核心 DOM。「全量首页验证」验证全部已启用候选的不同落点，包括初筛失败项。
4. 只把本轮首页已就绪的结果按耗时推荐。初筛可达、历史成功、未覆盖项均不是“已验证”。用户进入站点、取消或网络变化会使旧推荐失效。自动检测要求直连公共地址；代理/Fake-IP 会被明确提示为网络环境问题，不归因站点证书。
5. 浏览页采用**固定单行工具栏** + **可拖动的半透明把手**：工具栏永远贴在底部，一行七个等宽按钮（后退、前进、刷新、回首页、标签页、退出、更多），不换行、不缩放、不折叠；「更多」向上弹出面板（新建标签页、脚本菜单、关闭当前标签页）——用面板而不是浮层菜单，是因为 Android 的浮层菜单会被原生 WebView 盖住、在页面上不可读。工具栏**覆盖**在网页上而不是挤压网页视口，所以打开它不会让页面跳动。隐藏时屏幕上只留一个半透明把手：**按住可以拖到页面任意位置**（位置持久化，下次进入还在那里），**点一下展开工具栏**（工具栏本身不可拖动）。3 秒无操作自动隐藏并回到把手：**只有工具栏/把手自身的点击与触摸会重置这 3 秒**，网页内的点击、滑动、长按不重置（工具栏隐藏时，网页里的一次点击只是把它唤出来）；打开标签面板或脚本菜单期间计时暂停。下拉刷新默认关闭（下拉手势属于页面和用户脚本，避免与站点/脚本自己的下拉操作混淆）；需要时在「设置 → 浏览页下拉刷新（Android）」打开，页面处于顶部时下拉即刷新当前页。网页视口顶部预留系统状态栏高度，站点自己的顶部工具栏不会被状态栏遮挡、可正常点击。退出后浏览会话保留，可在首页或档案详情页的「切回」行回到同一批 WebView；回到首页只重载站点入口，不退出 WebView。
6. 界面统一为 **iOS 27 液态玻璃**：顶部栏、底部导航、内容面板、标签卡片、菜单、弹窗与提示条共用同一套材质、圆角、间距和状态色，背景是随主题色变化的静态柔和渐变。底部一级导航是**带文字标签**的单行窄液态玻璃胶囊（左右留出更大边距；选中态为浅主题色紧凑胶囊，导航表面继续折射主题背景），浏览工具栏浮在手势条上方；浮在网页上的控件自带明暗匹配的压暗层，因此深色主题下压在浅色网页上也始终可读。材质固定，不再提供「玻璃效果」开关；普通按钮、浮动把手与导航项都没有额外阴影，层次由材质本身表达。明暗模式与十二种主题色在「设置 → 外观」内直接切换（明暗为行内分段选择，主题色默认折叠）。
8. 在「脚本」粘贴或导入完整 `.user.js`（包含 `// ==/UserScript==`、`@match` 和脚本主体）。导入/编辑后关闭，确认范围、权限、网络域名和依赖后才启用。只粘贴元数据头会明确提示不可启用；权限/依赖变更须重新确认。源码上限为 16 MiB，大脚本由应用内部文件承载，不通过 Binder 发送。
9. 站点地址带不带结尾 `/` 都可以：应用按规范化 URL 校验导航授权，不会因为 WebView 把 `https://host` 补成 `https://host/` 而误判为“无法确认的新文档”并关掉特权脚本。同一文档内、同 origin 的 SPA/hash 切换与同 origin 重定向继续持有租约；跨文档、历史恢复或跨 origin 仍保守撤销。镜像站常见的**入口跨域 301/302**（`http://host` 的入口域名跳到另一个域名）默认跟随：只对应用自己发起的导航（进入/回首页/刷新）、只在同一条在途导航的重定向事件上生效，最多 5 跳、落地即止，该行为固定开启，不作为设置项；页面自己发起的跳转（点击、`location=`、`meta refresh`）永远不跟随这条规则。
10. 浏览页支持多标签：网页里的 `target="_blank"` 与用户手势触发的 `window.open` 会变成应用内的新标签（不再被系统弹窗丢弃），工具栏上有「标签页」按钮（缩略图网格，可切换、关闭、新建，新建时填 HTTP(S) 地址）。「退出」保留会话并回到应用页面，可在首页、档案详情页的「切回」行或「浏览」页回到同一批标签；真正销毁 WebView 的是「更多 → 关闭当前标签页」，「浏览」页里还有「全部关闭」。

首页就绪需要指定核心区域可见、DOM 完成且有内容，默认 `main`；没有该区域的站点需要自定义选择器。验证码、需要登录/交互、证书错误不会自动绕过。启用脚本前阅读 `docs/support.md`。

## 开发与验证

本机验证需要 `openssl`（TLS 测试在临时目录生成自签名证书，结束后清理）。

固定工具链基线：Flutter **3.47.6** / Dart **3.13.5**、JDK 21、Android SDK 36（插件可能需要 SDK 37）、NDK 28.2.13676358。最低 Android 26、iOS 15。提交了 `pubspec.lock`、Pigeon 生成文件与 Gradle wrapper。

首次准备开发环境：

```sh
cp .env.example .env.local # 可选：为本项目固定 SDK/AVD 路径
make setup                 # 项目依赖 + Pigeon 生成
make doctor                # 只读检查工具链、SDK、MCP 和工作区
make check                 # analyze + Flutter 测试 + JS/工具契约
```

`.env.local` 只保存本项目的工具链路径和模拟器默认值，已被 Git 忽略。命令行变量和当前 shell 环境变量优先于 `.env.local`；不要把完整 `PATH`、密码、Token 或签名内容写入其中。详见 [开发环境说明](docs/development-setup.md)。

需要补齐 macOS 系统依赖和 Android SDK 时，显式运行：

```sh
make setup-system
make setup-agent           # Codex + 官方 Dart/Flutter MCP/Skills
```

手工执行等价于：

```sh
flutter pub get
dart run pigeon --input pigeons/web_host.dart
flutter analyze
flutter test
node tool/test_runtime.mjs
dart run tool/verify_script.dart path/to/real.user.js   # 用应用自身的解析器预检真实脚本
make build-release
```

Android 正式安装包：`build/app/outputs/flutter-apk/app-release.apk`，包名为 `dev.vikiea.site_lens`，使用仓库外的固定正式签名；调试与验收包名为 `dev.vikiea.site_lens.debug`。release 缺少签名配置时失败。本轮不迁移旧版数据，首次安装从空库开始，需要用户自行添加发布页或候选站点。签名与完整执行说明见 [Android 现代化说明](docs/android-modernization.md)。

常用操作集中在 `Makefile`（`make help` 看全部目标）：

```sh
make check                                   # analyze + Flutter 测试 + JS/工具契约
make build                                   # debug + release APK
make devices                                 # adb devices -l
make acceptance DEVICE=DEVICE_ID   # 真机完整验收（见下）
make install DEVICE=DEVICE_ID      # 只构建并安装 release
```

跨端原生契约测试使用应用进程内的无破解测试页。真机一次完整验收：

```sh
python3 tool/run_android_acceptance.py DEVICE_ID --single-suite
```

它依次执行 `./tool/check.sh`（静态回归）→ 构建 debug/release → 备份 Drift 数据库 → **一次安装、一次运行**全部 18 个集成用例（入口 `integration_test/acceptance_suite_test.dart`：原生契约 + 产品闭环 + 导航租约 + 多标签 + 入口回退 + 侦察 + 存活检查 + 两份证据 + 主题/完整备份/冷标签 + 真实媒体与系统控制）→ 按 SHA-256 校验写回用户库 → 重装预先保留的正常调试 APK 并启动。正式包安装与验收分开执行。日志末尾的 `script-driven installs` 才是脚本自己装了什么；`flutter test` 还会自行安装一次 debug APK，所以「一次验证」指**一次测试运行安装**，不等于全程只安装一次。

- `--single-suite`：不传则退回逐文件模式，Flutter 会为每个测试文件重装约 168 MB 的 debug APK（无线 adb 上每文件数分钟）。
- 组合模式把 18 个用例放进**同一个应用进程**，跨文件状态隔离比逐文件模式弱；需要逐文件隔离证据时用 `make acceptance-per-file`。
- `--skip-check` / `--skip-build`：跳过静态回归或构建，用于快速复跑。
- `--restore-from DIR`：测试已经通过、只有恢复/安装阶段失败时（无线 adb 掉线），直接用上次打印的备份目录收尾，不重放测试：`make restore-device DEVICE=... BACKUP=DIR`。
- `--restart-adb`：每次重连前 `adb kill-server` + `start-server`，即无线 adb 报 `No route to host` / `device offline` 时的已知解法。脚本对每次 `adb install` 默认重连重试 3 次；恢复失败会明确报错并打印备份目录，不会显示成通过。

需要单独隔离运行集成用例时使用受控入口：

```sh
make acceptance-per-file DEVICE=DEVICE_ID
```

验收包装会负责 debug APK 身份检查、数据库备份/恢复，并监控 Flutter runner，防止正式包成为验收前台进程。

`ALLOW_LOCAL_TEST_PAGES` 只在 debug 模式允许检测本地测试页；release/profile 无效，不放宽 GM/依赖网络政策。旧 WebView 的测试仅证明 fail-closed 路径，不算增强脚本契约通过。必须查看日志里的 `HOST_CAPABILITIES` 和未验收提示。

**真机 `flutter test` 可能重装测试宿主并清空应用数据。** 所以要走上面的验收脚本（它先备份 `files/site_lens.sqlite`，测试后再按 SHA-256 写回调试包，并恢复正常调试入口）；绕开脚本自己跑 `flutter test` 时，必须先手动备份。

当前 Android-only 范围不执行 iOS 验收。若后续恢复双端范围，需完整 Xcode 和 Simulator SDK；仅 Apple Command Line Tools 不能编译或运行。补齐后：

```sh
flutter build ios --simulator --no-codesign
flutter test integration_test/host_contract_test.dart -d SIMULATOR_ID \
  --dart-define=ALLOW_LOCAL_TEST_PAGES=true
```

CI 固定 Flutter 提交并检查生成代码；iOS 构建/模拟器测试为手动启用入口，**未运行 CI 不能当作验证通过**。iOS 真机仍需要签名及设备测试。

## 工程结构

- `lib/domain`：候选、来源、阶段性结果，不使用综合最优分。
- `lib/data`：Drift/SQLite，候选缓存、历史、脚本确认、值与固定依赖。
- `lib/network`：超时/取消、公共地址、连接时 IP 固定、真实 TLS、逐跳权限校验。
- `lib/settings` / `lib/browser` / `lib/backup`：集中偏好、稳定标签元数据与完整业务备份。
- `lib/discovery`：发布页渲染提取、初筛、串行 DOM 验证、落点合流与代次失效。
- `pigeons/web_host.dart`：双端类型化宿主契约。
- `android/.../NativeWebHost.kt` / `ios/Runner/NativeWebHost.swift`：原生世界、数据环境与生命周期门禁。
- `web_assets/userscript_runtime.js`：传统/异步 GM、预载快照、有序持久化、菜单与依赖执行。
- `docs/implementation.md`：实际验收账本；`docs/support.md`：支持与已知限制。

没有服务端、遥测、内置代理、破解、脚本市场或自动更新；未归档 Wiki。

## 使用流程（站点档案）

1. 首屏列出每个站点档案：最近可用落点、最近首页就绪耗时、上次检测时间、状态徽章；没有档案时提供快捷添加入口。
2. 「添加站点」建立档案（名称 + 发布页 + 最新地址区域 + 核心 DOM 选择器）；进入档案详情可查看本轮择优、候选、历史，以及默认折叠的「高级：发布页与选择器」（重新侦察 / 回退到上次成功配置）。
3. 进入站点：默认先跑一轮检测再进；有上次落点时走快路径，未就绪会自动回落到本轮更优落点，失败的标签保留可见。
4. 「脚本」按档案分组，另有「未绑定」分组（按 `@match` 全局生效）；可在这里选择脚本归属档案。
   底部还有「浏览」入口：任何未关闭的浏览会话都列在这里，从任意页面返回都能一键切回（「择站」与档案详情页顶部同样保留一行「切回」）。
   浏览页的标签切换器是固定工具栏上的一个按钮（不单独占一行），点开后用缩略图网格选择、切换或关闭标签；工具栏始终是一行七个等宽按钮，不换行、不折叠。
   工具栏 3 秒无操作自动隐藏，屏幕上只留**你放它的位置**上的把手；工具栏或把手的点击/触摸会重置这 3 秒，网页内的点击、滑动、长按不会（工具栏隐藏时，网页里的一次点击只是把它唤回来）。按住把手拖动即可改变位置，工具栏本身固定。
5. 浏览器内的提示条（TLS/证书、跨文档或历史恢复导致的脚本撤销、全局脚本问题等）可以点右侧 × 清除：清除只收起横幅，不会假装页面正常——宿主仍然记录着同一个错误，重新导航后如仍存在会再次出现。真正的恢复入口有两个：「关闭全部脚本并重载」（清除脚本撤销类问题，集成用例已断言状态被清空）和「重新加载脚本并刷新页面」（在「脚本」页改过脚本后让本页生效）。
   浏览导航栏的「代码」按钮是脚本相关的：它列出**当前文档**里脚本通过 `GM_registerMenuCommand` 注册的菜单；脚本没写、没启用、或 `@match` 不覆盖当前页面时这里就是空的。下面那行「本次文档生效脚本」会直接写出空的原因（全局「关闭全部脚本」还开着 / 没有导入脚本 / 已启用但宿主没注册 / `@match` 不覆盖当前地址并点名是哪些脚本），全局关闭时还会给出「重新启用脚本并刷新」。
6. 一个档案可以同时有多个标签页：在档案里选另一个镜像落点（或再次「进入」）是**新开一个标签**，不再替换/销毁你正在看的那个；只有显式关闭标签页才会销毁 WebView，标签总数上限 8。新建标签页时地址的 `http://` / `https://` 前缀可以省略（省略按 `https://` 处理），但显式写的 `http://` 会被保留。
7. 档案包：档案详情右上角导出（单文件 zip，含配置 + 绑定脚本 + 固定资源字节，不含历史/GM 值/确认标记）；面板「导入档案包」导入时一次性展示包内脚本的权限/域名/依赖，确认后脚本默认关闭，需手动确认才能启用。

发布页解析还支持可导入配置的兜底引擎。把下面的 JSON 作为“最新地址区域”填写即可，不需要改代码：

```text
@extract:{"root":".address-list","linkSelector":"a,[data-domain]","urlAttributes":["data-domain","data-url","data-copy-domain"],"includeText":true,"exclude":[".ad"],"limit":40}
```

`root` 指定 CSS 根节点（省略时使用 `body`）；`linkSelector` 限定要检查的子节点；`urlAttributes` 用于读取复制按钮或业务自定义属性；`includeText` 是否从纯文本提取域名；`exclude` 排除广告等节点；`limit` 限制最多导入的地址数。普通 CSS 选择器仍按原方式工作。解析器只输出无账号密码的 HTTP(S) 地址，并由发布页来源的现有安全策略继续过滤自身域名、发布页和重定向结果。

对 `/dizhi`、`/address` 等常见目录型发布页，服务器返回 404 时会自动重试带尾斜杠的地址（例如 `/dizhi/`）。

## 许可证

Copyright (C) 2026 vikiea.

本项目以 GNU General Public License v3.0（GPL-3.0-only）发布，详见 [LICENSE](LICENSE)。第三方依赖保留各自的许可证。
