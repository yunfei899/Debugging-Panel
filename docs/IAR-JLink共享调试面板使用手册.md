# IAR/J-Link 共享调试面板使用手册

本文主要给操作人员看，说明首次交给 AI 配置的方法、面板操作和状态判断。本分支是 IAR/J-Link 模板，复制到目标工程后仍需首次适配，文中的来源示例不代表目标已配置或已完成联机验证。

| 文件 | 主要读者 | 用途 |
| --- | --- | --- |
| [使用手册](IAR-JLink共享调试面板使用手册.md)（本文） | 操作人员 | 首次适配示例、日常操作、查看日志和结束调试。 |
| [迁移说明](IAR-JLink共享调试面板迁移说明.md) | 首次适配时的 AI，操作人员参考 | 识别工程和后端，填写配置，执行静态检查。 |
| [半自动化联机调试流程](IAR-JLink半自动化联机调试流程.md) | AI 和维护人员 | 理解后台链路、共享命令和故障处理。 |
| [AGENTS.md](../AGENTS.md) | AI | 在工程中工作时先读取协作规则。 |

## 首次适配：提供目录和版本类型

把本分支的 `Tools`、`docs` 和 `打开共享调试面板.bat` 合并到目标工程根目录，已有 `AGENTS.md` 合并规则，不整份覆盖。不要把整个“共享调试面板”目录嵌套进工程。然后提供两项信息即可，下面以 SXL 工程为输入以下表达式仅为来源示例，使用前确认目标符号中存在：

```text
请适配本工程内的共享调试面板。

1. 工程目录：C:\work_file\IAR\HC-SXL
2. 版本类型：SXL 核心 IAR 工程

请读取工程内的 docs/IAR-JLink共享调试面板迁移说明.md，
分析实际工程配置，完成面板适配和静态检查。
有影响调试目标的歧义时再问我。
本轮不编译、不连接、不烧录。
```

EtherCAT 工程只需替换目录，将类型填写为“EtherCAT 核心 IAR 工程”。AI 从工程文件识别 IAR、J-Link、GDB 路径、构建配置、符号、启动宏、接口和默认变量，有关键歧义才补问。大版本或小版本 CCS 工程应使用 `master` 分支的 CCS 版工具。

继续采用“每个工程放一份面板”的方式，不需要独立工具或三层配置。AI 将差异填入该工程 `Tools/SharedDebugConfig.ps1`；同一工程配置有效时不重复适配。移动目录、切换分支、构建配置或探针后应重新检查。

静态适配、IAR 编译下载、持续共享调试分别记录验证结果。模板包含共享调试代码，但不能把下载成功或旧工程的断点记录视为新工程长期稳定调试已通过。

## 1. 先明确会话关系

本分支实现的持续共享链路为：

```text
J-Link GDB Server ←→ arm-none-eabi-gdb/MI ←→ 面板和 AI 的命令队列
```

面板和 AI 操作的是同一个后台进程。IAR 可以用于编辑和编译，但不要同时在 IAR/C-SPY 中连接同一个 J-Link。下载时会短暂使用 C-SPY，下载结束后 C-SPY 释放探针，再建立 GDB 实时会话。

## 2. 使用前检查

1. 设备处于急停、限位和人员安全可控状态。
2. IAR/C-SPY 没有连接同一个 J-Link。
3. 检查 `Tools/SharedDebugConfig.ps1` 的 `HardwareInterface`。
4. 核对目标工程 driver 参数、集中配置与现场接口。来源示例为 SWD，不意味着所有目标都使用 SWD；描述为 JTAG 而配置为 SWD 时应先确认。
5. 确认 `Program` 对应所选工程和构建配置，且符号与现板程序一致。模板示例为 `R7S910002`，`JLinkDevice` 非空时使用精确器件名；`Cortex-A_R` 只在器件名为空时作为代码后备，不应因旧文档而改用该模式。

## 3. 启动面板和连接

在工程根目录双击：

```text
打开共享调试面板.bat
```

此操作只打开面板，不连接硬件。点击“连接调试”后，面板会要求确认设备安全并启动一个共享后台。命令行等价操作：

```powershell
.\Tools\StartSharedDebug.ps1 -AllowHardware
```

连接可能导致 CPU 暂停。连接成功后，顶部状态通常为 `HALTED` 或 `RUNNING`；目标失联时为 `DISCONNECTED`。重新连接按钮只会尝试复用当前后台，不会另起第二个 J-Link Server。

## 4. IAR 编译下载/BRG

顶部按钮实际名称为“IAR 编译下载/BRG”。模板的 `IarBreakResetGo` 示例值为 `true`，点击并确认意味着允许下载流程中按工程宏复位、初始化并请求运行，不能套用 CCS 版“下载后保持暂停”的结论。

当前脚本流程为：

1. `BuildProject.ps1` 调用配置的 `IarBuild.exe`，构建 `IarProject` 的 `IarConfiguration`；当前构建脚本要求 `IarCustomArgVars` 文件存在，并通过 `-varfile` 加载。文件或变量缺失时先报告并补齐配置，不应忽略构建错误。
2. 编译成功后记录监视和断点，停止旧共享会话，并等待该工程相关探针资源释放。
3. `IarCspyDownload.ps1` 使用 `CspyGeneralSettings`、`CspyDriverSettings` 和对应程序调用 `cspybat --download_only`。复位及初始化由工程参数引用的宏决定，单独改一个宏路径字段不代表下载参数已同步。
4. `IarBreakResetGo=true` 时附加 `--leave_target_running`；C-SPY 退出并释放探针后，再启动 J-Link GDB Server＋GDB/MI，尝试恢复断点并自动 Go。
5. 编译、C-SPY 下载、共享连接、断点恢复和运行结果分别查看日志。出现 `LOADPROGRAM OK` 或下载成功状态不代表断点全部恢复，也不代表控制程序正常运行。

用户明确允许编译、下载和相应运行行为后，命令行入口为：

```powershell
.\Tools\BuildAndDownload.ps1 -AllowHardware -AllowProgramLoad
```

`-AllowHardware` 允许连接探针，`-AllowProgramLoad` 允许写入目标；组合脚本还会按 `IarBreakResetGo` 设置内部运行参数，因此不能把这条命令理解成“只下载、不运行”。`IarBreakResetGo=false` 时不请求上述自动 Go，但工程下载宏本身仍可能复位或运行，实际行为须验证。

Reset 集成在下载和工程初始化宏链路中，面板没有独立通用 Reset 按钮。首次适配只做静态检查，不执行上述流程。

## 5. 变量监视、读取和写入

面板左侧每行填写一个表达式，点击“应用监视”后点击“刷新变量”。右侧表格可填写表达式和值：

- “读取全部”逐项读取表格中的表达式；
- “写入选中”向选中表达式执行赋值，再读取回显值；
- 读取和写入要求 CPU 已暂停。CPU 运行时，后台会拒绝操作并在事件日志中记录原因；
- 表达式采用 GDB 语法，不保证完全兼容 C-SPY 专用表达式。

以下表达式仅为来源示例，使用前确认目标符号中存在：

```text
errPLC
ipstep
machmode
```

写入示例：在 Expression 填 `ipstep`，Value 填 `90`，选中该行后点击“写入选中”。写值前必须确认变量类型、运行状态和机构安全。

## 6. 运行、暂停和断点

- “运行 Go”发送 `RESUME`；
- “中断 Break”发送 `SUSPEND`；
- “刷新变量”只在 CPU 已暂停时读取监视表达式；
- 添加或删除断点前先由操作人员暂停 CPU；运行中添加会被拒绝，不会为了添加而自动停核；
- 断点格式支持 `source.c:123` 和 `@0x地址`，行号和地址必须取自本工程当前符号；
- 添加断点后，以后台返回的 ID 为准；删除时填写该 ID；
- 命中断点后后台保持暂停，面板显示 PC 和断点信息，不自动 Resume。

下面列出独立命令示例，不是需要整段执行的步骤；变量、源码行号和断点 ID 需替换为目标实际值。AI 或命令行使用同一个队列：

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

点击“断开调试”并确认，或执行：

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
- 所选 J-Link GDB Server 必须支持目标器件，GDB 必须能解析本工程 IAR 输出的符号。外部 Flash 的下载由 IAR 配置和宏承担，不能用共享连接成功代替下载验证。
- `HALTED`/`RUNNING` 是调试器状态，不等同于业务程序正常；若 PC、寄存器异常或通信失效，应先分析日志，不要反复 Go。
- `Tools/AutoDebugHold.js` 已停用，不能再作为 CCS/DSS 入口运行。
