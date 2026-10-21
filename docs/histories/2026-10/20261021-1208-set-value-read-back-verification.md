## [2026-10-21 12:08] | Task: set_value 增加 AX 回读校验

### Execution Context

- Agent ID: `lead`
- Base Model: deepseek-flash
- Runtime: DSH web

### User Query

> 实现 #83 P1：`set_value` 在 AX 写入后读回并比对，避免"返回成功但值未变"的静默失败；比较逻辑抽成纯函数并补单测与 fixture 回归；本地分支提交，不 push。

### Changes Overview

- 新增 `SetValueReadBack.swift`：
  - `setValueReadBackResult(requested:before:after:)` 纯函数，返回 `verified` / `unchanged` / `mismatched`；
  - `setValueValuesMatch` 依次做 trim 后精确比较、数值比较（`15` == `15.0`）、布尔字面量比较（`true` == `1`）；
  - `setValueReadBackString(from:)` 支持 `CFString` / `CFNumber` / `CFBoolean`，整数型数值不会读回成 `15.0`；
  - `setValueReadBackErrorMessage` 生成带元素索引与实际值的错误文案。
- `ComputerUseService.setValue` 在写入前记录当前值，AX 写入成功后 0.6 秒内轮询回读并比对；值未变化或不一致时抛出明确错误，不再静默成功。请求值等于元素现值时视为 no-op 成功。
- `ToolDefinitions.swift` 的 `set_value` 描述说明结果会校验实际写入。
- `skills/open-computer-use/references/usage.md` 补充回读语义说明。

### Design Intent

macOS 的 `AXUIElementSetAttributeValue` 对一些控件（select、date stepper 等）会返回成功但实际不写入，agent 无法从 `isError` 判断失败。回读比对把这种失败转成显式错误，并保留"重复写入相同值"的幂等语义。fixture 分支（`OpenComputerUseFixture` 无头 harness）保持原有行为，不进入 AX 回读路径；单测用该 harness 在 smoke 脚本中写入的 Unicode 值做数据级回归。

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/SetValueReadBack.swift`（新增）
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ComputerUseService.swift`
- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/ToolDefinitions.swift`
- `packages/OpenComputerUseKit/Tests/OpenComputerUseKitTests/OpenComputerUseKitTests.swift`
- `skills/open-computer-use/references/usage.md`

### Validation

- `swift build` 成功。
- `swift test`：386 个测试，7 个跳过，0 失败；新增 4 个用例全部通过（字符串/数字/布尔/空白/同值 no-op/不一致/不可读、AX 值转换、错误文案、fixture Unicode 值回归）。
- 变更只在本地分支 `fix/set-value-read-back`，未 push、未开 PR。
