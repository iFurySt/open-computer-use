# Linux 桌面会话发现

OCU 在缺少 DISPLAY、XAUTHORITY、会话总线等环境时，会从当前用户的桌面进程补齐。带有 `FLATPAK_ID` 或 `container` 标记的进程不作为宿主环境来源。识别桌面进程只看进程名和 argv[0]，不匹配参数中的文件路径。

`AT_SPI_BUS_ADDRESS` 不从其他进程复制。它可能指向只在沙盒里存在的 socket，即使某个地址在宿主可见，也不代表属于当前桌面。未显式指定时，libatspi 通过当前会话总线的 `org.a11y.Bus.GetAddress` 查找辅助功能服务。

调用者设置的 `AT_SPI_BUS_ADDRESS` 原样保留，包括自定义 socket 或其他 D-Bus 地址格式。若调用者自身继承了错误地址，应取消该变量或设置正确地址；自动发现不会覆盖调用者的选择。

## 回归

在带 GTK 3、AT-SPI、Python GI、Xvfb 与 D-Bus 的 Linux 环境构建修复前后两个 binary，然后运行：

```sh
GTK_A11Y=atspi NO_AT_BRIDGE=0 xvfb-run -a dbus-run-session -- \
  python3 scripts/tests/linux-session-discovery-smoke.py \
  --baseline /path/to/baseline --native /path/to/patched
```

脚本创建私有 GTK 窗口和一个带沙盒环境标记的测试进程。它通过真实 `/proc` 发现路径验证：旧版原本正常，加入该进程后无法连接 `/run/flatpak/at-spi-bus`；新版仍可观察、修改控件并回读；显式辅助功能地址也能使用。结束后清理所有测试子进程。

这是沙盒环境污染机制的工程复现，使用真实 GTK/AT-SPI/D-Bus；不等同于完整安装 Flatpak 应用或 GNOME Wayland 桌面的验证。
