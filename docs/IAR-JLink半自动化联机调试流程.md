# IAR/J-Link 半自动化联机调试流程

本文主要供 AI 和维护人员阅读，描述 IAR/J-Link 后端。操作人员主要看[使用手册](IAR-JLink共享调试面板使用手册.md)。AI 先读 [AGENTS.md](../AGENTS.md)，首次适配先读[迁移说明](IAR-JLink共享调试面板迁移说明.md)，按“工程目录＋版本类型”识别配置；获准联机后才按本文操作。

本文中的硬件与路径示例来自原 IAR 工程，未指定新目标；不能把来源记录、状态文字或下载成功视为持续调试稳定性已经通过。

## 1. 参与者和职责

- 现场人员负责手控器、输入信号、机构观察、急停、限位和供电安全。
- AI 负责读取工程配置、检查日志、提交共享命令、读取变量和结合源码分析。
- 共享后台负责唯一的 J-Link GDB Server、唯一的 GDB/MI 调试进程和命令执行顺序。

AI 不根据变量名自行推断设备可以安全运行。涉及下载、复位、暂停、继续、写值或机构动作时，以用户当轮明确授权和现场安全确认作为前提。

## 2. 目标配置与来源示例

目标工程必须分别识别实际 VCS、版本和工作区修改。构建和下载读取本工程 `SharedDebugConfig.ps1`，具体字段说明、四类工程与两类后端关系见迁移说明。

| 项目 | 配置依据 | 来源示例（不是新目标默认答案） |
| --- | --- | --- |
| IAR 工程与构建配置 | `.eww`、`.ewp` 和实际输出设置 | `prj/iar/HC_SXL.ewp` / `Debug` |
| 调试输出 | `Program`，对应本工程构建产物 | `prj/iar/Debug/Exe/HC_SXL.out` |
| 芯片与调试接口 | `.ewd`、driver 参数和实际探针 | `R7S910002` / Cortex-R4 / SWD |
| 下载与初始化 | general/driver 参数实际引用的宏、DDF 和下载配置 | `RZT1_init_boot.mac` |
| 精确器件选择 | `JLinkDevice` 非空时使用其值；`JLinkCpu` 是空值后备 | `R7S910002`，不沿用旧通用模式结论 |
| 持续共享 | J-Link GDB Server＋GDB/MI | 主机 `127.0.0.1`、端口 `2331` |
| 运行记录 | `RuntimeDirectory` | 工程根目录 `Debug/AutoDebug` |

配置中的接口不等于实际接线已经验证。切换工程或分支后重新检查构建产物、链接内存布局和符号；不能沿用上一工程的地址或旧 C-SPY 导出文件中的绝对路径。

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

“IAR 编译下载/BRG”按以下顺序执行；自动运行步骤以 `IarBreakResetGo=true` 为前提，模板示例开启该选项：

1. 调用 `IarBuild.exe <project> -build <configuration> -log all -varfile <project>.custom_argvars`，加载工程自定义变量；当前脚本要求配置的变量文件存在，缺失时构建会失败，应在静态适配时先报告。
2. 编译成功后停止已有共享后台，清理该工程记录的遗留 J-Link Server，并等待端口释放。
3. 调用 IAR `cspybat` 的 `--download_only --leave_target_running`，使用当前 `.xcl` 引用的工程宏进行下载、复位和初始化，并请求退出后保持运行；实际宏行为按目标核对。
4. C-SPY 保持目标运行后退出并释放探针。
5. 启动 J-Link GDB Server，确认配置的 `GdbServerPort`（示例 2331）由本轮 Server 监听后，再启动 GDB/MI 共享会话。
6. 如果后台在达到 RUNNING/HALTED/DISCONNECTED 前退出，立即记录 ERROR 并结束本次启动；启动后尝试恢复先前记录的监视表达式和断点，按配置请求 Go。断点恢复可能单独失败，必须检查 `BREAKPOINT_ERROR`；状态为 DISCONNECTED 不能视为有效联机。

`StartSharedDebug.ps1` 的组合下载路径先调用 C-SPY，并将后台 `LoadProgram` 设为 false，避免持续后台再次执行 GDB 下载。C-SPY 下载和 GDB 实时调试是两个串行阶段，不是两个同时存在的调试会话。当前没有执行编译、下载或硬件验证授权时，AI 不应调用这些入口。

## 5. AI 操作协议

每次继续调试前，必须先读取：

1. `Debug/AutoDebug/current-session.json`；
2. 该文件指向的 `status.txt`；
3. 同目录的 `events.log`。

以下为独立命令示例，按用户指令选择执行，不整段运行；表达式、源码行号和断点 ID 须替换为当前目标实际值：

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

变量、源码行和地址必须属于本工程当前符号。添加或删除断点前也需 CPU 已暂停。目标运行时的 `READ`、`SET` 和 `SNAPSHOT` 会被后台拒绝或标记为跳过，避免为了面板刷新而偷偷暂停运动中的 CPU。需要读取时先由用户确认安全，再发送 `SUSPEND`，读取完成后是否 `RESUME` 仍需明确指令。

## 7. 故障排查

按以下顺序检查，不要直接杀进程抢占 J-Link：

1. 读取当前 session 的 `status.txt` 和 `events.log`。
2. 检查 `backend.stderr.log`、`jlink.log` 和 C-SPY 下载日志。
3. 确认 IAR/C-SPY、其他 GDB 或 J-Link 工具没有占用探针。
4. 核对 `HardwareInterface`、J-Link 速度、器件名和 J-Link 序列号。
5. 核对 GDB Server 版本是否认识配置中的目标器件；由 GDB 解析 IAR 输出的 ELF/DWARF 符号。不要因旧文档的 V6.10g 或 Cortex-A_R 示例而降级器件配置。
6. 如果是外部 SPI Flash 下载失败，检查 IAR/C-SPY 参数中的下载宏和 Flash Loader；需要重新下载验证时另按用户授权执行，不把失败的 GDB 下载当作已下载。
7. 若寄存器出现异常值、停止原因不是预期断点或 Go 后立即异常，应检查目标上下文和日志；当前代码的 RESUME 路径没有完整的寄存器有效性保护，AI 不应把按钮可点击当作可安全运行的依据。

如果后台 PID 消失、日志停止更新或变量连续读取失败，应立即说明共享监视已经失效。重新开始前先结束旧会话并确认 J-Link 已释放。

## 8. 工具文件职责

| 文件 | 职责 |
| --- | --- |
| `SharedDebugConfig.ps1` | 集中保存工程、IAR、GDB、J-Link 和监视配置 |
| `BuildProject.ps1` | 调用 IARBuild 编译集中配置指定的工程和构建配置 |
| `BuildAndDownload.ps1` | 编译后停止旧会话，串行下载并重新建立共享连接 |
| `IarCspyDownload.ps1` | 调用 IAR cspybat 进行一次性下载 |
| `StartSharedDebug.ps1` | 创建会话目录并启动共享后台 |
| `RunSharedDebug.ps1` | 从会话文件启动后台实现 |
| `IarGdbSession.ps1` | 持有唯一 GDB/MI 会话并处理命令队列 |
| `SendSharedDebugCommand.ps1` | AI 的共享命令入口 |
| `SharedDebugPanel.ps1` | 现场图形面板 |
| `AutoDebugHold.js` | 旧 CCS/DSS 入口的停用提示，不是运行依赖 |

## 9. 验证记录要求

静态识别和配置只证明文件、字段及脚本能被正确解析。IAR 编译、C-SPY 下载、J-Link 连接、变量读取、断点命中、断点恢复和持续运行分别记录结果，未做的保持未验证。

`LOADPROGRAM OK` 不证明全部断点恢复，`RUNNING` 不证明控制程序正常，旧工程的成功记录也不证明新目标已经验证。后台退出、状态停止刷新或变量持续失败时立即报告监视失效；未经指令不自动 Resume、复位、写值、清断点、重新烧录或断开。

## 当前面板命令语义

- 下载并调试：StartSharedDebug -AllowHardware -AllowProgramLoad -LoadProgram -NoPanel；只下载现有 OUT，不构建。C-SPY 初始化后共享接管暂停。
- STOP：运行中发送 -target-disconnect；暂停时先 -exec-continue。成功释放后退出子进程；失败保留会话，不误报已断开。不发送 interrupt/reset。关闭后不再监视，独立运行和活动断点的释放需按目标验收。
- RESTART：运行中先暂停，monitor reset、monitor halt，检查线程状态与 PC；成功保持暂停，失败为 UNKNOWN。不会执行 C-SPY 项目宏，不能保证停在 main。
- 状态与日志：补充 RESTARTING、UNKNOWN、GDB_STOP_RECORD、DETACH REQUESTED/OK 和 RESTART START/OK/ERROR。保留完整停止信号以便区分故障。
- Windows PowerShell 5.1：GDB 标准输入采用无 BOM UTF-8；状态替换使用 NullString.Value；空日志与状态文件占用须容错。

本机安装路径、具体探针和验证快照不作为模板默认事实；以目标自己的适配记录为准。
