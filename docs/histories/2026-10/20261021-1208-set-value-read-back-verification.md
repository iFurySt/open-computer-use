# set_value 写入验证（PR #111）

原 PR 由 wicgee 提出，修复 AX API 返回成功但控件未应用值的情况。2026-11-02 根据用户要求基于最新 main 完善，扩展检查 Windows / Linux，并保留原 PR 提交和作者贡献。

- macOS 直接读 AXValue，按实际类型比较；文本不 trim、不转数值、不做 Unicode 归一化，数值比较避免大整数转 Double 丢失精度。
- 轮询使用单调时钟，最多 0.6 秒，只读不重写；每次读取和返回前检查会话。关闭完整回读不跳过验证。
- Windows UIA ValuePattern 和 Linux EditableText 同样精确验证；Linux AT-SPI Value 采用数值比较，不在文本写失败后切换数值路径。
- Linux / Windows 入口保留 value 的空白，三平台允许空字符串清空。验证失败不输出整段值，提示重新观察后再决定是否重试。
- 新增 AppKit / GTK / WPF 可控忽略、改写、延迟 fixture，生产函数边界测试和 Windows CI；文档同步到 docs/set-value-verification.md。

## 验证结果

Swift 比较 / 轮询单测、Linux Python 42 项、Linux / Windows Go 测试、PowerShell 生产验证函数测试通过。真实 GTK 的正常、清空、空白/Unicode、忽略、长度限制、延迟、开关完整回读均通过。macOS 正常/清空/忽略/改写/延迟、开关完整回读和 JS 错误传播均通过；旧 main 在忽略写入的真实控件上仍返回 ok，负对照复现。完整 Swift 428 项（9 跳过）、Node 54 项和既有 AppKit 文本输入回归通过。GTK 原生数值控件也验证通过；Windows CI 的真实 WPF / UIA 写入验证、JS / CLI 观察、物理输入和 2000 项列表回归全部通过；验证了忽略、裁空白、去前导零时返回错误，以及延迟生效、清空和重复写入成功。
