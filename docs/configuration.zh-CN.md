# 配置

[English](configuration.md) | [简体中文](configuration.zh-CN.md)

配置文件默认在 `~/.config/ocu/config.json`，可以直接编辑。如果文件还不存在，可以创建一个。下面是默认配置：

```json
{
  "virtualDisplay": {
    "enabled": false
  },
  "image": {
    "format": "png",
    "jpegQuality": 0.8,
    "maxLongEdgePixels": 1280,
    "scaleDownAfterMaxSize": true,
    "discardBelowPixelCount": 64,
    "captureTimeout": 5
  }
}
```

目前这些配置用于 macOS 截图，修改后在下一次截图时生效。也支持环境变量，优先级是 ENV > 配置文件 > 默认值。

## 命令行配置

也可以通过 `ocu config` 来配置，修改会保存到上面的文件里：

```bash
# 查看配置
ocu config

# 改成 JPG
ocu config set image.format jpg

# 查看某一项
ocu config get image.format

# 恢复默认（如果有 ENV，仍优先使用 ENV）
ocu config reset image.format

# 查看配置文件路径
ocu config path
```

`ocu` 也可以换成 `open-computer-use`。

## 配置项

| 配置项 | 默认值 | 说明 | 命令示例 |
| --- | --- | --- | --- |
| `image.format` | `png` | 输出格式，可选 `png`、`jpg`、`webp`。WebP 为无损编码。 | `ocu config set image.format webp` |
| `image.jpegQuality` | `0.8` | JPG 质量，范围 `0–1`，只影响 JPG。 | `ocu config set image.jpegQuality 0.9` |
| `image.maxLongEdgePixels` | `1280` | 图片长边上限，单位像素，范围 `1–16384`，整数。设为 `null` 关闭限制。 | `ocu config set image.maxLongEdgePixels 1920` |
| `image.scaleDownAfterMaxSize` | `true` | 超过长边上限时，`true` 等比例缩小，`false` 丢弃截图。 | `ocu config set image.scaleDownAfterMaxSize false` |
| `image.discardBelowPixelCount` | `64` | 宽 × 高小于此值时丢弃，等于时保留。范围 `0–268435456`，整数；`0` 关闭过滤。比如 `4096` 就是 `64×64` 的面积。缩小后的图片也会检查。 | `ocu config set image.discardBelowPixelCount 4096` |
| `image.captureTimeout` | `5` | ScreenCaptureKit 后备截图的超时，单位秒，范围 `0.01–300`。 | `ocu config set image.captureTimeout 10` |


## 虚拟显示器（macOS，显式启用）

`virtualDisplay.enabled` 默认 `false`。关闭时，`get_app_state` 的 MCP schema 不包含
`window_placement`，JS 使用提示不包含 `windowPlacement`，遮挡窗口提示也不推荐停放。
旧客户端显式传入 `agent_display` 时，在查找应用或创建显示器之前报错。

通过 `ocu config set virtualDisplay.enabled true` 显式启用，或在调用进程设置
`OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED=true`。配置文件只接受 JSON 布尔值；环境变量
只接受字面量 `true`/`false`，非法环境值关闭创建。优先级为环境变量、配置文件、默认值。
Windows/Linux 始终不暴露这个参数。

创建虚拟显示器会增加系统显示器，可能影响已有显示器布局。关闭使用
`ocu config set virtualDisplay.enabled false`，同时移除启用它的环境变量；重新连接 MCP
客户端以刷新缓存的 schema。已停放窗口仍可用显式 `restore` 或 `turn-ended`/连接清理恢复，
关闭配置不会直接销毁仍承载窗口的显示器。升级后需重启旧版常驻进程。
