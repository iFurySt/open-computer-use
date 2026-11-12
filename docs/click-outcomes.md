# macOS 点击结果与重试

辅助功能调用超时不代表应用没有执行。按钮处理超过 AX 超时后，原动作可能仍在运行；此时改用另一种点击方式会重复操作。

点击链遇到 `cannotComplete`、`failure` 等不确定结果时停止，不继续尝试 AXConfirm、附近控件或鼠标点击。返回消息说明动作可能已生效，应先重新观察，不直接重试。

明确拒绝的动作仍可继续原有 fallback。多次点击若已经投递一部分，后续即使明确拒绝，也不重发整组。已有 AXOpen / attributeUnsupported 的兼容行为保留，但不会再次打开。

## 复现与回归

```sh
node scripts/tests/macos-click-outcome-smoke.mjs <signed-baseline-executable> --expect-repeat
node scripts/tests/macos-click-outcome-smoke.mjs <signed-patched-executable>
```

脚本只操作独立 AppKit fixture。慢按钮每次执行暂停 2 秒，独立状态文件记录动作次数；另有快速按钮验证正常单击和有意双击。使用真实 native MCP、默认 app_post 路径，不开启全局指针，不改变系统权限。

序列单元测试还覆盖首次拒绝、首次超时、部分成功后拒绝/超时和 AXOpen。常规几何、后代控件选择与文件面板回归继续使用 `macos-hit-test-smoke.mjs`（包括 `--descendant-guards`）和 `macos-sheet-smoke.mjs`。

这不保证任意第三方 provider 如实报告动作结果，也不改变 Windows/Linux 的输入策略。
