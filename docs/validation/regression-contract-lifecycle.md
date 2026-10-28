# 回归契约生命周期

唯一可编辑来源是 [tool/regression_contracts.json](../../tool/regression_contracts.json)。
使用 [update_regression_contract.py](../../tool/update_regression_contract.py) 记录新增、修改、弃用、撤销和验证元数据；命令验证候选内容及双向测试标记，通过后同步更新 JSON 历史和生成矩阵。

## 状态与审计规则

- `active`：当前生效；`changedPaths`、`testFiles` 必须非空，测试文件及对应标记必须存在。`blocking` 明确记录发布阻断要求。
- `deprecated`：弃用迁移期，保留原测试与阻断要求，`replacedBy` 必须指向另一条 `active` 契约，不允许自引用、悬空、闭环或指向已弃用/撤销条目。
- `revoked`：填写明确原因即可从生效或弃用状态撤销。撤销时清空测试绑定、取消阻断；历史路径与证据可以保留，即使旧文件已删除也不误阻断后续修改。
- 撤销条目和全部历史**永久保留**，禁止删除、复用 ID 或恢复原 ID；重新引入行为时使用新 ID。
- 每次变化增加 `revision` 和历史事件；事件记录动作、日期、版本、原因、状态及完整条目与行为定义的 SHA-256。跨提交检查禁止改写或删除已有历史，`introducedIn` 不可修改。

`owner` 是维护责任人或角色；`introducedIn` 沿用行为进入注册表的版本。
`evidence` 的 `command`/`test` 项是验证入口，不是通过回执。
`lastVerified` 初始为 `null`；登记验证时保存日期、实际等级和报告引用。行为、测试绑定或其他元数据修改后清空旧记录。登记本身不执行测试，也不能替代本地、设备或发布门禁。

## 新增

先编写真实测试，在相应测试文件中加入独立注释行，例如：

```dart
// REGRESSION CONTRACT: MEDIA-HLS-002
```

准备定义 JSON（`introducedIn` 可省略，默认取当前 pubspec 版本；示例文件必须替换成真实路径）：

```json
{
  "id": "MEDIA-HLS-002",
  "description": "新的资源图行为不变量",
  "owner": "Site Lens maintainers",
  "changedPaths": ["lib/media/media_service.dart"],
  "testFiles": ["test/media_download_resume_test.dart"],
  "evidence": [{"kind": "test", "ref": "test/media_download_resume_test.dart"}],
  "validation": "L3",
  "blocking": true
}
```

```bash
python3 tool/update_regression_contract.py add \
  --definition /tmp/new-contract.json \
  --summary "补充资源图所有权不变量及其回归测试"
```

命令自动填写生效状态、修订、空验证记录和引入事件，不会生成断言或自动宣称功能已经验证。

## 修改

将要修改的字段写入局部 JSON，再记录原因。例如 `/tmp/contract-change.json` 可包含 `description`、`owner`、`changedPaths`、`testFiles`、`evidence`、`validation`、`blocking` 的一个或多个字段；弃用条目可以用 `replacedBy` 更新承接关系。

```bash
python3 tool/update_regression_contract.py update \
  --id MEDIA-HLS-001 --definition /tmp/contract-change.json \
  --summary "调整路径归属并补充原生校验入口"
```

直接编辑注册表也必须同步增加修订、历史和状态摘要；没有记录的改动会被门禁拒绝，推荐使用命令维护。

## 弃用、撤销

新契约及其测试必须先登记。弃用旧契约时指定生效的替代契约：

```bash
python3 tool/update_regression_contract.py deprecate \
  --id MEDIA-HLS-001 --replaced-by MEDIA-HLS-002 \
  --summary "迁移到新的资源图契约"
```

撤销前先移除旧 ID 的测试注释（保留仍有价值的断言及新 ID）。命令会核对原因、替代状态和残留标记，失败时不改写注册表或矩阵。功能整体下线时可直接从生效状态撤销，无需创建虚假的替代契约。记录的保留期为永久，不要求等待后才能撤销。

```bash
python3 tool/update_regression_contract.py revoke \
  --id MEDIA-HLS-001 --summary "已由新契约承接并结束迁移期"
```

若替代契约随后也需要弃用，必须在同一批变更中将原条目转向新的生效承接者并记录原因。

## 登记已完成的验证

先运行相应级别的验证并保存真实报告，再登记，不要通过状态变更刷新验证日期：

```bash
python3 tool/update_regression_contract.py verify \
  --id MEDIA-HLS-001 --level L1 \
  --report docs/validation/current-local-check.md \
  --summary "登记已完成的本地检查，设备验收仍待执行"
```

报告路径必须存在且会进入 `evidence`。等级可以低于契约所需等级，矩阵会显式展示实际登记等级；低等级记录不能满足高等级验收。
`--date` 默认使用 Asia/Shanghai 当前日期，不能回填未来日期；`--version` 默认使用当前 pubspec 版本。

## 自动检查与影响提示

```bash
python3 tool/check_regression_contracts.py
python3 tool/check_regression_contracts.py --base origin/main
python3 tool/generate_regression_matrix.py --write
python3 tool/generate_regression_matrix.py --check
make check
```

`make check` 校验注册表、双向测试标记、不可改写的历史、替代目标、撤销记录永久保留和生成矩阵。矩阵缺失或过期会失败；检查过程不写回文件。
标记扫描包含 Dart、Python、JS、shell 和 Android/iOS 原生测试，识别整行注释格式；字符串赋值示例不会被当作标记。测试 fixture 中需要该整行格式时应拼接字符串，避免误识别。

Git 比较策略：

- 本地有改动时比较 `HEAD`，覆盖暂存、未暂存、未跟踪及重命名前后路径；干净提交默认与父提交比较。
- 多提交分支可以显式使用 `--base <commit>` 或 `REGRESSION_CONTRACT_BASE`，比较整个变更范围。
- GitHub push 使用事件的 `before`；PR 使用 base 与当前提交的 merge-base；新分支、新标签和手动运行使用父提交。
- Verify 使用完整 Git 历史，Release 已使用完整历史。比较提交缺失、事件不完整或 Git 出错均返回失败，禁止静默变成空影响集合。

影响提示根据 `changedPaths` 和测试文件映射输出生效/弃用契约，不强迫每次实现修改都改变行为契约。
它不会推断产品需求、证明断言充分或自动批准撤销；这些语义仍需独立评审。文件级标记也不代替真实行为覆盖。
新增修复与重构应检查提示，并按契约要求执行相应验证等级。
