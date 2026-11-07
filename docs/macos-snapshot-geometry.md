# macOS 截图几何

窗口部分移出屏幕时，硬件截图可能只包含屏内区域。若仍按完整窗口尺寸换算点击坐标，就会点错位置。#154 在这种情况下改用 ScreenCaptureKit 整窗捕获。

完整落在一个显示器内的窗口仍优先使用硬件截图。出屏、跨屏、显示器信息不可用或硬件结果比例异常时才回退；整窗结果比例仍不符时，不返回图片。这里的比例检查只是保护，不能单凭尺寸证明画面完整。

AX 返回 NaN、无穷、负尺寸或计算溢出的 frame 时，保留控件信息，省略几何。快照、查询和点击重读共用校验；文本渲染另有整数转换保护。窗口候选面积及 ScreenCaptureKit 输出尺寸也使用可失败的整数转换。

## 复现与验证

在已授权辅助功能与屏幕录制的 Mac 上，使用签名后的 App 内可执行文件运行：

```sh
node scripts/tests/macos-snapshot-geometry-smoke.mjs \
  'dist/Open Computer Use.app/Contents/MacOS/OpenComputerUse'

# 用旧版作负向对照：正常窗口必须通过，并复现出屏裁剪和非法 AX 崩溃。
node scripts/tests/macos-snapshot-geometry-smoke.mjs \
  '<old-app>/Contents/MacOS/OpenComputerUse' --expect-regression

swift test
```

脚本只操作自己创建的 AppKit 窗口，结束后关闭 fixture 与 MCP；截图、文本和结果留在输出的临时目录。它使用临时配置，测试原尺寸与最大边 300 px 两种输出，不改用户配置。

2026-11-07，本机签名 native MCP 实测：

| 用例 | v1.1.4 | 修复后 |
| --- | --- | --- |
| 正常 600×432 点窗口 | 1200×864；缩小为 300×216，点击通过 | 同样通过 |
| 左右各出屏半个窗口 | 600×864；缩小为 208×300，比例错误 | 1200×864 / 300×216；三个色块完整，屏内按钮按截图坐标点击命中 |
| 带标识控件返回 NaN 位置 | MCP SIGTRAP 退出 | 读取成功，query 省略 bounds，后续读取与点击正常 |
| 带标识控件返回 NaN 尺寸 | MCP SIGTRAP 退出 | 同上 |

Swift 全量 442 项、9 项跳过、0 失败。原有 `macos-hit-test-smoke.mjs --descendant-guards --allow-desktop-activity` 也通过，覆盖 Retina / 缩小图 / AX-only 索引点击、空白处和窗口根索引保护。该选项不验证桌面前台与物理指针稳定性。

这次复现用的是独立测试窗口，没有修改 Contacts 数据。跨屏路径选择、无显示器信息、截图失败及异常几何另有单元测试；没有声称覆盖所有混合 DPI、其他 Space 或 Locked Use 状态。整窗捕获比硬件路径慢，只在需要时使用。
