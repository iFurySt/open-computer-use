## Linux session discovery (#66)

用户要求继续处理 Linux Flatpak 环境造成工具不可用的问题。

### 修改

- 不从其他进程复制 AT_SPI_BUS_ADDRESS，保留调用者显式值，默认交给 libatspi 查询当前 session bus。
- 自动发现排除带 FLATPAK_ID/container 标记的进程；进程匹配只读 comm 与 argv[0]，不把参数中的 Xwayland 路径当成桌面进程名。
- 增加环境污染、显式地址、多种地址格式、截断 comm 和 argv 参数误匹配的 Go 回归。
- 增加真实 /proc + 私有 GTK/AT-SPI/D-Bus 的前后对照脚本，不需用户 Linux 桌面。

### 验证

- 基于 main 的原始 binary 可正常观察 GTK；加入测试沙盒进程后，稳定重现缺失 /run/flatpak/at-spi-bus 的失败。
- 修复 binary 在同样环境下通过原生 MCP 观察、set_value 的真实 GTK 状态验证和动作回读；显式 AT_SPI_BUS_ADDRESS 覆盖通过。
- Linux Go 全套测试在容器通过，Python 44 项通过。测试进程模拟沙盒环境，不宣称完成 GNOME Wayland/完整 Flatpak 安装验证。

入口与行为边界见 `docs/linux-session-discovery.md`。
