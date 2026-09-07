# IAR/J-Link 半自动化联机调试流程

文件名沿用历史名称；内容适用于当前 IAR 工程，不再描述 CCS/DSS/XDS2xx 后端。

## 1. 参与者和职责

- 现场人员负责手控器、输入信号、机构观察、急停、限位和供电安全。
- AI 负责读取工程配置、检查日志、提交共享命令、读取变量和结合源码分析。
- 共享后台负责唯一的 J-Link GDB Server、唯一的 GDB/MI 调试进程和命令执行顺序。

AI 不根据变量名自行推断设备可以安全运行。涉及下载、复位、暂停、继续、写值或机构动作时，以用户当轮明确授权和现场安全确认作为前提。

## 2. 工程依据

| 项目 | 当前值 |
| --- | --- |
| 构建系统 | IAR Embedded Workbench for Arm |
| 工程 | `prj/iar/HC_SXL.ewp` |
| 构建配置 | `Debug` |
| 调试输出 | `prj/iar/Debug/Exe/HC_SXL.out` |
| IAR 目标 | Renesas `R7S910002` / Cortex-R4 |
| J-Link 实时 CPU 模式 | 通用 `Cortex-A_R` |
| C-SPY 下载器 | `prj/iar/settings/HC_SXL.Debug.driver.xcl` |
| 启动宏 | `prj/iar/startup/spi/RZT1_init_boot.mac` |
| 实时后台 | J-Link GDB Server + `arm-none-eabi-gdb`/MI |
| 会话目录 | `Debug/AutoDebug` |

当前 C-SPY driver 文件实际指定 `--drv_interface=SWD`，而现场描述为 JTAG。连接前必须核对这个差异；工具不会自动替换 IAR 配置或猜测物理接口。

## 3. 共享会话生命周期

```text
连接确认
   ↓
StartSharedDebug.ps1
   ↓
J-Link GDB Server 独占探针
   ↓
arm-none-eabi-gdb/MI 连接 remote 端口
   ↓
面板/AI 写入 commands/*.cmd
   ↓
IarGdbSession.ps1 顺序执行并写 events.log
   ↓
断点命中保持 HALTED，等待下一条指令
```

同一项目同时只允许一个后台会话。面板关闭不等于会话结束；只有用户明确要求停止、断开或结束调试时，才发送 `STOP`。

## 4. 编译和下载链路

“编译并下载”按以下顺序执行：

1. 调用 `IarBuild.exe <project> -build <configuration> -log all -varfile <project>.custom_argvars`，加载工程自定义变量。
2. 编译成功后停止已有共享后台，清理该工程记录的遗留 J-Link Server，并等待端口释放。
3. 调用 IAR `cspybat` 的 `--download_only --leave_target_running`，使用当前 `.xcl` 和工程启动宏完成 Break → Reset → Go。
4. C-SPY 保持目标运行后退出并释放探针。
5. 启动 J-Link GDB Server，确认 2331 端口由本轮 Server 监听后，再启动 GDB/MI 共享会话。
6. 如果后台在达到 RUNNING/HALTED/DISCONNECTED 前退出，立即记录 ERROR 并结束本次启动；成功后恢复先前记录的监视表达式和断点，并自动 Go。

C-SPY 下载和 GDB 实时调试是两个串行阶段，不是两个同时存在的调试会话。当前没有执行编译、下载或硬件验证授权时，AI 不应调用这些入口。

## 5. AI 操作协议

每次继续调试前，必须先读取：

1. `Debug/AutoDebug/current-session.json`；
2. 该文件指向的 `status.txt`；
3. 同目录的 `events.log`。

之后使用：

```powershell
.\Tools\SendSharedDebugCommand.ps1 'READ errPLC'
.\Tools\SendSharedDebugCommand.ps1 'SNAPSHOT'
.\Tools\SendSharedDebugCommand.ps1 'BREAKADD M_PLC.c:123'
.\Tools\SendSharedDebugCommand.ps1 'BREAKREMOVE 1'
.\Tools\SendSharedDebugCommand.ps1 'SUSPEND'
.\Tools\SendSharedDebugCommand.ps1 'RESUME'
```

命令文件先写成同目录临时文件，再原子改名为 `.cmd`；后台按文件名顺序执行。AI 不应直接改写运行中的 JSON、status、events 或命令文件，也不应另起 GDB、C-SPY 或 J-Link 会话抢占探针。

## 6. 状态判断和停止事件

状态文件的第一个分号字段是当前状态：

| 状态 | 含义 |
| --- | --- |
| `STARTING` | 后台正在启动调试器 |
| `HALTED` | CPU 已暂停，可进行变量读写和断点操作 |
| `RUNNING` | CPU 正在运行，后台不做隐式停核读取 |
| `DISCONNECTED` | GDB 与目标失去连接，需检查日志后重新连接或重启会话 |
| `ERROR` | 后台失效，禁止继续依赖其状态 |
| `STOPPED` | 会话已结束 |

事件日志记录 `BREAKPOINT_HIT`、`TARGET_SUSPENDED`、`TARGET_HALTED`、`READ`、`SET`、`COMMAND_ERROR` 和 `FATAL`。断点命中后默认保持 `HALTED`，不自动 Resume、写值、清断点、重新下载或断开。

目标运行时的 `READ`、`SET` 和 `SNAPSHOT` 会被后台拒绝或标记为跳过，避免为了面板刷新而偷偷暂停运动中的 CPU。需要读取时先由用户确认安全，再发送 `SUSPEND`，读取完成后是否 `RESUME` 仍需明确指令。

## 7. 故障排查

按以下顺序检查，不要直接杀进程抢占 J-Link：

1. 读取当前 session 的 `status.txt` 和 `events.log`。
2. 检查 `backend.stderr.log`、`jlink.log` 和 C-SPY 下载日志。
3. 确认 IAR/C-SPY、其他 GDB 或 J-Link 工具没有占用探针。
4. 核对 `HardwareInterface`、J-Link 速度、器件名和 J-Link 序列号。
5. 核对 GDB Server 版本是否认识 `R7S910002`，以及能否加载 IAR 的 ELF/DWARF 信息。
6. 如果是外部 SPI Flash 下载失败，优先回到 IAR/C-SPY 单独验证下载宏和 Flash Loader；不要把失败的 GDB `target-download` 当作已下载。

如果后台 PID 消失、日志停止更新或变量连续读取失败，应立即说明共享监视已经失效。重新开始前先结束旧会话并确认 J-Link 已释放。

## 8. 工具文件职责

| 文件 | 职责 |
| --- | --- |
| `SharedDebugConfig.ps1` | 集中保存工程、IAR、GDB、J-Link 和监视配置 |
| `BuildProject.ps1` | 调用 IARBuild 编译 Debug 配置 |
| `IarCspyDownload.ps1` | 调用 IAR cspybat 进行一次性下载 |
| `StartSharedDebug.ps1` | 创建会话目录并启动共享后台 |
| `RunSharedDebug.ps1` | 从会话文件启动后台实现 |
| `IarGdbSession.ps1` | 持有唯一 GDB/MI 会话并处理命令队列 |
| `SendSharedDebugCommand.ps1` | AI 的共享命令入口 |
| `SharedDebugPanel.ps1` | 现场图形面板 |
| `AutoDebugHold.js` | 旧 CCS/DSS 入口的停用提示，不是运行依赖 |
