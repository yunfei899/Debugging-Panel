# IAR/J-Link 共享调试面板使用手册

文件名保留了原来的 XDS2xx 名称，但当前工程已经改为 IAR/J-Link 方案。

## 1. 先明确会话关系

当前实时共享链路只有一个：

```text
J-Link GDB Server ←→ arm-none-eabi-gdb/MI ←→ 面板和 AI 的命令队列
```

面板和 AI 操作的是同一个后台进程。IAR 可以用于编辑和编译，但不要同时在 IAR/C-SPY 中连接同一个 J-Link。下载时会短暂使用 C-SPY，下载结束后 C-SPY 释放探针，再建立 GDB 实时会话。

## 2. 使用前检查

1. 设备处于急停、限位和人员安全可控状态。
2. IAR/C-SPY 没有连接同一个 J-Link。
3. 检查 `Tools/SharedDebugConfig.ps1` 的 `HardwareInterface`。
4. 当前生成的 IAR driver 文件写的是 `--drv_interface=SWD`；如果实际接线是 JTAG，先同步 IAR driver 和集中配置。
5. 确认 `prj/iar/Debug/Exe/HC_SXL.out` 是本次 Debug 输出；当前 J-Link 实时连接采用通用 Cortex-A/R 模式，IAR 仍使用精确目标 `R7S910002`。

## 3. 启动面板和连接

在工程根目录双击：

```text
打开共享调试面板.bat
```

此操作只打开面板，不连接硬件。点击“连接”后，面板会要求确认设备安全并启动一个共享后台。命令行等价操作：

```powershell
.\Tools\StartSharedDebug.ps1 -AllowHardware
```

连接可能导致 CPU 暂停。连接成功后，顶部状态通常为 `HALTED` 或 `RUNNING`；目标失联时为 `DISCONNECTED`。重新连接按钮只会尝试复用当前后台，不会另起第二个 J-Link Server。

## 4. 编译并下载

点击“编译并下载”，确认后执行：

1. `IarBuild.exe` 使用 `prj/iar/HC_SXL.custom_argvars` 作为 `-varfile`，编译 `prj/iar/HC_SXL.ewp` 的 `Debug` 配置。
2. 停止旧共享会话，并清理该工程运行记录中遗留的 J-Link Server，等待 J-Link 资源释放。
3. 使用 IAR `cspybat --download_only --leave_target_running`、当前 C-SPY driver 参数和 `RZT1_init_boot.mac` 下载程序，执行 Break → Reset → Go。
4. C-SPY 保持目标运行并退出后，重新建立 J-Link GDB Server + GDB/MI 实时会话。
5. 恢复已有的监视表达式和断点，并自动 Go，保持目标运行。

命令行等价操作：

```powershell
.\Tools\BuildAndDownload.ps1 -AllowHardware -AllowProgramLoad
```

`-AllowHardware` 表示允许连接探针，`-AllowProgramLoad` 表示允许写入目标。编译失败、下载失败、端口被外部调试器占用或旧会话无法停止时，不会进入下一步。

## 5. 变量监视、读取和写入

面板左侧每行填写一个表达式，点击“应用监视”后点击“刷新快照”。右侧表格可填写表达式和值：

- “读取全部”逐项读取表格中的表达式；
- “写入选中”向选中表达式执行赋值，再读取回显值；
- 读取和写入要求 CPU 已暂停。CPU 运行时，后台会拒绝操作并在事件日志中记录原因；
- 表达式采用 GDB 语法，不保证完全兼容 C-SPY 专用表达式。

示例：

```text
errPLC
ipstep
machmode
```

写入示例：在 Expression 填 `ipstep`，Value 填 `90`，选中该行后点击“写入选中”。写值前必须确认变量类型、运行状态和机构安全。

## 6. 运行、暂停和断点

- “继续 Resume”发送 `RESUME`；
- “暂停 Suspend”发送 `SUSPEND`；
- “刷新快照”只在 CPU 已暂停时读取监视表达式；
- 断点格式支持 `source.c:123` 和 `@0x00802000`；
- 添加断点后，以后台返回的 ID 为准；删除时填写该 ID；
- 命中断点后后台保持暂停，面板显示 PC 和断点信息，不自动 Resume。

AI 或命令行使用同一个队列：

```powershell
.\Tools\SendSharedDebugCommand.ps1 'SNAPSHOT'
.\Tools\SendSharedDebugCommand.ps1 'READ ipstep'
.\Tools\SendSharedDebugCommand.ps1 'SET ipstep=90'
.\Tools\SendSharedDebugCommand.ps1 'BREAKADD M_PLC.c:123'
.\Tools\SendSharedDebugCommand.ps1 'BREAKREMOVE 1'
.\Tools\SendSharedDebugCommand.ps1 'SUSPEND'
.\Tools\SendSharedDebugCommand.ps1 'RESUME'
```

每条命令都会以临时文件写入后原子改名为 `commands/*.cmd`，避免后台读到半条命令。执行结果必须以 `events.log` 为准。

## 7. 结束调试

点击“断开”并确认，或执行：

```powershell
.\Tools\SendSharedDebugCommand.ps1 'STOP'
```

后台会在释放 J-Link 前尝试暂停正在运行的 CPU，然后退出 GDB 和 J-Link GDB Server。关闭面板窗口本身不会结束后台会话；如果还要继续本轮调试，不要发送 `STOP`。

## 8. 状态和日志

当前会话由 `Debug/AutoDebug/current-session.json` 指向：

| 文件 | 作用 |
| --- | --- |
| `current-session.json` | 当前会话目录、后台 PID、目标和命令队列路径 |
| `status.txt` | `STARTING`、`HALTED`、`RUNNING`、`DISCONNECTED`、`ERROR` 等状态 |
| `events.log` | 连接、断点、读写、停止和错误的时间线 |
| `backend.stdout.log` / `backend.stderr.log` | PowerShell 后台输出 |
| `jlink.log` | J-Link GDB Server 日志 |
| `cspy-download.stdout.log` / `cspy-download.stderr.log` | IAR C-SPY 下载输出 |
| `build.log` | IAR 编译输出 |

发现后台 PID 消失、状态停止更新、GDB/J-Link 日志报错或变量持续读取失败时，应视为共享监视已经失效；不要继续声称 CPU 状态仍在监视。

## 9. 不支持和常见边界

- 不能同时让 IAR/C-SPY GUI 和面板占用同一个 J-Link。
- 当前方案不是 C-SPY GUI 的远程控制接口。
- 目标运行时不做隐式停核读取，因此不能提供 C-SPY Real-time Mode 那样的无扰动实时表达式刷新。
- J-Link GDB Server 旧版本可能不认识 `R7S910002`，或不能处理该工程的外部 SPI Flash；这需要现场硬件验证。
- `Tools/AutoDebugHold.js` 已停用，不能再作为 CCS/DSS 入口运行。
