# 阶段 2 B 批：重复查询参数媒体身份 — 独立审查记录

- 审查对象：分支 `codex/stage2-dupkey`，worktree `/Users/qinfuling/www/github/vikiea/stage2-dupkey`，基点 `bf7d28e`（`docs(plan): reconcile active-work-plan to v0.6.0.alpha22`），审查时为**未提交工作区**。
- 作者：Builder（实现 + 验证记录《2026-11-04-stage2-重复查询参数媒体身份-验证记录.md》）。
- 审查人：Reviewer（独立审查，非作者）。
- 日期：2026-11-04。本记录与修复同批提交。

## 结论：有条件通过

修复方向正确、范围最小、回归测试在替换为偷懒实现时确实会红，我独立复跑的 analyze / 测试 / 探针全部符合预期。

放行条件是下面 §A 的 4 项，全部属于「提交前必须落实」，不需要改实现逻辑：

- A1：按两个 commit 拆开（`docs(plan):` 与 `fix(media):`），A 批 doc 改动单独一个 commit；
- A2：提交前再跑一次 `git status --short -uall`，确认只有既定路径，`lib/web_host/web_host.g.dart` 不在其中；
- A3：push 与 PR 未获批准前不执行；
- A4：本审查记录与验证记录、实现、测试一起进 B 批 commit（审查记录不能被留在 worktree 外）。

§A 落实后即视为通过；任何一处不落实，按不通过处理。

## A. 必须落实项

**A1 两个 commit 各自的路径边界**

| commit | 应包含路径 |
| --- | --- |
| A `docs(plan): make version-code tag lookup remote-authoritative` | `docs/active-work-plan.md` |
| B `fix(media): keep duplicate query parameters in media identity` | `lib/domain/models.dart`、`test/media_service_test.dart`、`docs/validation/2026-11-04-stage2-重复查询参数媒体身份-验证记录.md`、本文件 |

两个 commit 都要是 Conventional Commit 带 scope，主题行用祈使句。不得为了「补齐证据」追加第三个提交改文档。

**A2 提交前的现场检查**

```
git -C /Users/qinfuling/www/github/vikiea/stage2-dupkey status --short -uall
git -C /Users/qinfuling/www/github/vikiea/stage2-dupkey diff -- lib/web_host/web_host.g.dart
```

第二条必须为空。`--auto` 会重新生成 Pigeon 产物，`web_host.g.dart` 出现任何抖动都不许 `git add`。历史上有人在 worktree 里 `git stash` 做「基线必须红」检查，pop 冲突把未提交的 `lib/domain/models.dart` 冲回旧版，出现过 `lib/domain/models.dart:1039:22: Error: Method not found: '_retainedMediaQuery'.`；此后不得再有人在 Builder 的 worktree 里做 stash/checkout 类操作。

**A3 push / PR**：未获批准前不执行。

**A4 记录随代码**：本文件与验证记录进 B 批 commit。

## B. 审查范围逐条

### B1 diff 最小性：通过

`git diff --stat` = 3 files，172+/0−（不含未跟踪的验证记录）。`lib/domain/models.dart` 的改动只落在四处身份函数与其共用辅助函数：

- `mediaCandidateKey`（`lib/domain/models.dart:943`）→ `_mediaIdentityQuery(clean, _volatileMediaQuery)`；
- `mediaCandidateAuthorizationKey`（`:953`）→ `_mediaIdentityQuery(clean, _authorizationVolatileQuery)`；
- `mediaDocumentIdentity`（`:961`）→ `_mediaIdentityQuery(clean, _documentVolatileQuery)`；
- `mediaCandidateLocatorIdentity`（`:972-990` 区间）改为一次性构造，删除原 `_retainedMediaQuery`，新辅助 `_mediaIdentityQuery` 在 `:1015`。

没有顺手改动其它函数，没有格式化噪声（`dart format` 报 `Formatted 176 files (0 changed)`），`lib/domain/models.dart` 与 `test/media_service_test.dart` 内无 `print(` / `debugPrint` / `TODO` / `FIXME` 残留（grep 无输出）。

### B2 AGENTS.md 契约：通过

- **候选去重与授权身份分离**（AGENTS.md「Media & Persistence Contracts」）：三个 volatile 集合保持基线语义——`token` 只从 document 与 authorization 两组剔除，不进入 `mediaCandidateKey` 的折叠集合；授权身份与候选身份仍然由不同函数产出，没有被合并。
- **保留内容选择参数**：`ep` / `quality` / `audio` 这类参数不在 volatile 集合内，重复值时现在逐个保留（`?ep=1&ep=2`），符合「候选显示去重可以去掉已知传输/鉴权参数，但必须保留 episode、quality、audio 选择」的要求。
- **分层**：改动只在 `lib/domain/models.dart` 的纯函数层，未穿透到 data / network / ui。
- 未触及 Pigeon 契约（`pigeons/web_host.dart` 未改），因此不触发三端绑定重生成。
- 未触及 UI token、未触及文件租约 / PTS / ADTS / 时间戳精度相关代码。

### B3 测试能否抓住回归：通过（已用变异实验验证）

新增 3 个用例（`test/media_service_test.dart`，+131/−0）：

1. `repeated query parameters keep every value in media identity`
2. `single-valued media identity keeps its exact byte form`
3. `locator identity keeps repeated selectors but ignores the CDN route`

**变异验证**：我把 `mediaCandidateLocatorIdentity` 临时换成偷懒的 Map 版（`Uri(queryParameters: {...singles, ...repeated})`，即回到折叠语义），执行

```
flutter test test/media_service_test.dart --plain-name "locator identity keeps repeated selectors but ignores the CDN route"
```

结果 `NAIVE_EXIT:1`，失败原文：

```
Expected: not a string ending with '?'
  Actual: 'https:/a.m3u8?'
```

随后还原，`RESTORED_OK`。说明第 3 个用例确实能抓住 locator 退回到 Map 折叠。

用例 1 的断言选取正确：用的是 §C 的「会碰撞」三行（`?ep=1&ep=2` vs `?ep=2`、`?q=1&q=1` vs `?q=1`、`?q=1&q=2&q=3` vs `?q=3`），在基线 `bf7d28e` 上必然红。**没有**用 Builder 候选卡里最初那条错误反例（「720/1080 会撞」），那条在基线上不会红——这一点已在 `stage2-candidates-review.md` 更正，验证记录 §1 也已同步更正。

用例 2 锁「单值 URL 字节不变」和 token 的 volatile 差异，属于防回归的正向保护，不会让将来的合法改动被误判为失败。

用例 3 断言的是语义（重复 selector 不折叠、volatile 重复与位置零影响、`?sig=s1` 与空 query 的 locator 相等且不留裸 `?`、同 CDN 不同 path 仍不同），**没有**钉 `https:/live/index.m3u8?ep=1%2C2` 这类遗留实现字面量。

### B4 修复前必须红：通过（作者执行，我复核断言逻辑）

验证记录 §3 给出两条：

```
flutter test test/media_service_test.dart --plain-name "repeated query parameters keep every value in media identity"
  → exit 1  Expected: not '...?ep=2'  Actual: '...?ep=2'
flutter test test/media_service_test.dart --plain-name "locator identity keeps repeated selectors but ignores the CDN route"
  → exit 1  Expected: not 'https:/live/index.m3u8?ep=2'  Actual: 'https:/live/index.m3u8?ep=2'
```

这是在「stash 掉实现、只留新测试」的状态下得到的。我复核的方式不是复跑 stash（作者 worktree 里禁止 stash，见 A2），而是用**基线行为实测**替代：在 `bf7d28e` 上，`?ep=1&ep=2` 的 key 与 `?ep=2` 相同、`?ep=1&ep=2` 的 locator 与 `?ep=2` 相同，因此上面两条断言在基线上必然 `Expected: not ... Actual: ...` 同值，红是必然结果。两路证据一致。

### B5 验证证据完整性：通过（L1），L2/L3 待补

- `python3 tool/verify_level.py --auto` 第 5 次运行 exit **0**：`Changed paths: 3`、`Recommended level: L1`、`Requested level: L1`、`Device: none`、`Device preflight: not requested`、`Reasons: ordinary Dart, tooling, dependency, or service-layer behavior changed`，`./tool/check.sh` 全过。
- 级别判定与我的判断一致：改的是 Dart 层身份归一化 + 单测，没有 Pigeon / native host / WebView 路径改动，L1 是矩阵里对应「ordinary Dart」的最小充分级别。
- **L2（WebView / Pigeon / native host 相关）与 L3（设备）未执行，记为待补**，不因 L1 通过而视为通过。注意 `lib/web_host/native_hosts.dart:473` 会消费 `mediaCandidateKey`，真机侧「折叠后候选行覆盖」的实际表现属于 L3 范围，本记录不声称已验证。
- 失败运行没有隐藏：5 次运行全量写进验证记录 §5，含 2 次失败原文、失败用例名、行号、单独重跑结果、归因。我认可归因方向（单进程无并发、每次失败用例不同、单独重跑全绿 `flutter test test/dlna_service_test.dart` → `+29`、`flutter test test/media_service_test.dart` → `+97`、全量 → `+841`、与本次改动无路径交集），但**其 flaky 结论按「待另开缺陷卡」处理**，不进本次 commit，也不作为本次修复的健康证据。

## C. 缺陷成立的事实（供回溯）

基线 `bf7d28e` 上 `Uri.queryParameters` 只留同名参数的最后一个值，因此：

| 输入 A | 输入 B | 基线结果 |
| --- | --- | --- |
| `?ep=1&ep=2` | `?ep=2` | 同 key（误合并） |
| `?q=1&q=1` | `?q=1` | 同 key |
| `?q=1&q=2&q=3` | `?q=3` | 同 key |

**不会碰撞**（写在这里防止回归测试选错样本）：`?q=1&q=2` vs `?q=1`、`?a=1&a=2&b=3` vs `?b=3`、顺序互换 `?a=1&a=2&b=3` vs `?a=2&a=1&b=3`。

## D. 已知遗留：locator 丢弃 CDN authority（本次不修）

按四要素记录，供阶段 3 release notes 引用。

1. **现状**：`mediaCandidateLocatorIdentity` 只重建 `scheme` + `path` + query，不保留 host 与 port。`https://x:8443/v.m3u8?ep=2&s=1` 与 `https://y:9443/v.m3u8?ep=2&s=1` 得到相同的 locator `https:/v.m3u8?ep=2`。
2. **为什么不修**：这是基线既有行为，`test/media_service_test.dart` 的 `structured media identity survives a CDN authority change` 明确锁着「结构化媒体身份跨 CDN 权威不变」。修它会推翻一条已发布并有意保留的语义，属于独立的行为变更，不应塞进本缺陷的修复 commit。
3. **实际影响**：不同 CDN 上同路径的资源在 locator 维度不可区分；只在 locator 被用作跨权威比较依据时才有影响。候选 `id` / `mediaCandidateKey` 不含这一缺陷，下载 / 缓存身份的 `cacheKey` 也不以 locator 为首要依据，因此影响面限定在 locator 消费者。
4. **何时重新评估**：若要按 locator 做跨权威去重或分源展示（例如多 CDN 回源策略），必须先把这条语义拆成独立立项，连同 `structured media identity survives a CDN authority change` 一起重写，再回来改 locator。阶段 3 release notes 必须照实写这条遗留，不得写成「已修复」。

## E. 审查执行记录（实际命令与结果）

全部在 `/Users/qinfuling/www/github/vikiea/stage2-dupkey` 下执行。

| 命令 | 结果 |
| --- | --- |
| `git rev-parse --short HEAD` | `bf7d28e` |
| `git status --short -uall` | 三处 `M` + 未跟踪的验证记录（见 A2） |
| `git diff --stat` | `3 files changed, 172 insertions(+), 0 deletions(-)`（不含未跟踪记录） |
| `grep -n 'print(\|debugPrint\|TODO\|FIXME' lib/domain/models.dart test/media_service_test.dart` | 无输出 |
| `dart run --packages=.dart_tool/package_config.json /tmp/dupkeyprobe/probe9.dart` | 最终版行为复测 `P9_EXIT:0`（plain=`https:/live/a.m3u8`；allvolatile 无裸 `?`；`sig12a==sig12b`=`?ep=1`；`ep12`=`?ep=1&ep=2` 且 `!=ep2`、`!=ep23`） |
| `dart run --packages=.dart_tool/package_config.json /tmp/dupkeyprobe/probe10.dart` | volatile/token/编码复测 `P10_EXIT:0`（`?t=1&t=2&v=720` 与基线 `?v=720` 相同；`loc_cn=ep=%E4%B8%AD`、`loc_plus=ep=a+b`） |
| `dart analyze lib/domain/models.dart test/media_service_test.dart` | `No issues found!` `ANALYZE_EXIT:0` |
| `flutter test test/media_service_test.dart` | `+97: All tests passed!` `SUITE_EXIT:0` |
| 变异：locator 换偷懒 Map 版后 `flutter test test/media_service_test.dart --plain-name "locator identity keeps repeated selectors but ignores the CDN route"` | `NAIVE_EXIT:1`，`Expected: not a string ending with '?' / Actual: 'https:/a.m3u8?'`；还原后 `RESTORED_OK` |
| 基线三段对照（`bf7d28e` / Builder 中间版 / 重建版） | 基线 `?ep=2`（折叠）→ 中间版 `?ep=1%2C2` → 重建版 `?ep=1&ep=2`，volatile 重复零影响，空 selector `https:/live/a.m3u8` |

## F. 我自己的更正留痕

- 早期我把 Builder **中间版**（`join(',')` 版）的行为当作最终版汇报过 `?ep=1%2C2`，没写清测的是哪一版，是我的问题；第三节三段对照即为更正。
- 候选卡最初照抄 Builder 的「720/1080 会撞」例子，实测不成立，已在 `stage2-candidates-review.md` 更正为 §C 的三行，并同步要求验证记录更正（已在验证记录 §1 落地）。
