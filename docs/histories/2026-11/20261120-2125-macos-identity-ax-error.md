# macOS 元素身份核对：AX 错误按缺失处理

用户在 macOS 27.2 上对 TextEdit 正文调用 `set_value`，每次都返回“element no longer has the identity the snapshot showed”，什么也没写入。

原因：快照记录身份时，任何读取失败的属性都记为 nil；动作前的核对（`ElementIdentity.read`）却只把 `attributeUnsupported` / `noValue` 当作缺失，其余错误一律判为无法核对。macOS 27 的 TextEdit 正文对 `AXDescription` 返回 `kAXErrorFailure`（-25200），两边永远对不上，`set_value` 和按序号点击这类控件都会失败。

改动：新增 `ElementIdentity.reading(_:)`，按快照的读法解读 `AXUIElementCopyMultipleAttributeValues` 的每一项：任何 AX 错误与 `NSNull` 视为缺失，字符串照常读取，其他类型仍判为无法核对（失败即拒绝）。role 依旧必须存在，身份比较本身不变。

验证：`ElementIdentityTests` 新增用例，覆盖 `attributeUnsupported`、`noValue`、`failure`、`cannotComplete` 均为缺失，字符串保留，非文本值仍拒绝；`swift test` 全部通过，`make check-docs` 通过。真机：同一个 TextEdit 文档，修复前 `set_value` 被拒绝且未发送，修复后写入并回读一致。

由 Claude Code（claude-opus-5-5）实现，用户验证。
