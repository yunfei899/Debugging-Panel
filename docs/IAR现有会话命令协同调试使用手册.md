# IAR 现有会话命令协同调试使用手册

本方案让操作人员继续使用已经配置好的 IAR，AI 通过 PowerShell 命令读取现场、设置代码断点和读取日志。首次联机验证使用 IAR Embedded Workbench for ARM 7.80.2.11975，工程为 HC_SXL / Debug。验证日期：2026-09-09。

它复用当前 IAR 的 C-SPY、探针连接、程序和符号。无需共享调试面板、独立 GDB 后端或 Computer Use。命令会操作 IAR 的 Quick Watch 控件，但不移动鼠标、不模拟键盘，也不启动第二个调试连接。

## 1. 已实现的协作方式

```text
操作人员打开工程并在 IAR 进入调试
                 ↓
AI → Invoke-IarSession.ps1 → Windows 菜单/窗口消息 → 当前 IAR Quick Watch
                                                         ↓
                                                 C-SPY 会话内宏
                                                         ↓
AI ← PowerShell 结果 ← Debug/IarSession/唯一请求结果文件

IAR Debug Log → 操作人员在 IAR 指定的日志文件 → AI 读取和分析
```

这是针对已打开 IAR 的 Windows 界面适配器，不是 IAR 官方提供的外部调试 API。它依赖本版本英文菜单、Quick Watch 控件及 C-SPY 宏能力；其它版本需要验证，CCS 尚未实现。

| 文件 | 用途 |
| --- | --- |
| `Tools/Invoke-IarSession.ps1` | 识别目标 IAR、检查状态、发送命令、等待结果 |
| `Tools/IarSession.mac` | 宏模板；由脚本生成并注册，无需手动注册此模板 |
| `Debug/IarSession/bridge-*.mac` | 按模板内容生成的会话宏 |
| `Debug/IarSession/*.txt` | 每条请求的独立结果，包含 error、value、complete |
| `Debug/IarSession/registration-*.json` | 会话宏注册缓存；不能作为连接仍有效的证据 |

脚本的 Windows API 声明会由 PowerShell Add-Type 编译为本机辅助程序集，不会执行 IAR 项目编译。

### AI 执行约定

以下约定适用于本手册的调试操作，用户当次明确指令优先。

- 复用本工程已打开的 IAR 会话与现有工程配置，不使用 Computer Use；需要鼠标键盘操作时交给用户。
- 每次接入先核对工程并执行 Status，读取实际 Debug Log；CPU 已暂停时读取 PC、源位置和关注变量。仅检查状态或读取变量时不自动暂停。
- 用户要求设置断点，即授权必要的暂停和设置成功后的运行状态恢复，无需重复询问。具体命令顺序见下方“接入时工具实际做什么”；原本已暂停则保持暂停，保留已有断点。
- 设置失败或结果不明时不恢复运行；恢复后再次停下时检查现场和日志，不反复继续。用户明确要求不暂停或保持暂停时遵从该限制。
- 未经要求不编译、下载、复位、写值、清除断点、断开连接或执行上述断点流程以外的运行状态变更。回复结束后保留会话。
- 以本次命令结果和日志为准，区分断点设置成功与实际命中；失败或超时如实报告，不盲目重试。没有后台监视时不声称持续监视。

## 2. 首次接入：直接发给 AI 的内容

### 当前工程已经配置好 IAR

用工程 `.eww` 打开 IAR 并进入调试，在当前工程的 AI 聊天中直接发送：

```text
连接本工程已打开的 IAR，按使用手册检查调试状态和日志。
```

关注变量可替换或省略。不需要重复工程路径、IAR 版本和操作限制，AI 按 `AGENTS.md` 与本手册执行：已暂停时读取现场，运行时只报告状态。多个工程同时打开时，再说明目标工程。

### 迁移到另一个已经配好 IAR 的工程

只需带上以下文件，不必复制整个旧面板的 Tools 和 docs：

- `Tools/Invoke-IarSession.ps1`
- `Tools/IarSession.mac`
- `docs/IAR现有会话命令协同调试使用手册.md`

目标工程已有 `AGENTS.md` 时仅补充先阅读并遵循本手册的入口，保留目标工程原有的业务、构建和安全规则，不整份覆盖。`Debug/IarSession` 由脚本生成，不复制旧工程结果或注册缓存。

在目标工程的 AI 聊天中发送，把工具来源换成实际目录：

```text
把 C:\work_file\IAR\HC-SXL-Host-ECAT 的 IAR 现有会话协同调试工具接入本工程，按来源手册完成适配验证。我的 IAR 已配置好并打开。
```

AI 负责检查目标工程规则和版本，复制缺少的工具、合并协作规则并验证会话；已有文件先比较差异，不覆盖本地修改，不复制运行缓存，不改动工程硬件配置。无需你重复填写适配步骤。

这里的“接入”是核对当前工具与 IDE 是否匹配，不是重新配置硬件调试环境。另一版 IAR 或 CCS 不能直接沿用本次成功结论；CCS 当前未实现。

### 平时直接这样说

下面这些话由 AI 转换成脚本命令，不需要你记 PowerShell 参数。源文件和变量换成当前任务内容。

| 目的 | 可以直接发给 AI |
| --- | --- |
| 新一轮继续 | 继续使用本工程已打开的 IAR，先检查当前会话状态和最新 Debug Log。 |
| 允许暂停并采集 | 现在允许暂停 CPU，请暂停后读取 PC、源位置、ipstep 和 slow_zero，保持暂停。 |
| 已经停在断点 | 我已经停在断点，请读取当前现场和 slow_zero、len_zero，不改变运行状态。 |
| 指定断点 | 请在 Easy6/Source/M_P_Zero_HM_onlylongY_seq_new.c 第 1305 行设置断点。 |
| 检查失败原因 | 我刚在 IAR 操作后出现异常，请读取最新 Debug Log 和当前状态，先分析原因，不修改代码。 |
| 暂停协作 | 本轮先到这里，保留 IAR 连接和断点，不再发送调试命令。 |

如果脚本报告 CPU 正在运行，你可以自行在 IAR 暂停后说“已暂停，继续读取”，也可以明确说“允许暂停并读取”。首次话术中的动作限制只约束该次接入检查，后续以你明确下达的任务为准。

### 接入时工具实际做什么

1. 用工程的 `.eww` 打开 IAR，并按原有配置进入 C-SPY 调试。
2. 在工程根目录运行下文命令。本次在 PowerShell 7 / Windows 下验证。
3. 首次 Read、Snapshot 或 AddBreakpoint 会自动打开 Quick Watch，注册宏，并做一次 `__isBatchMode()` 请求/响应验证。
4. 变量读取和设置断点要求 CPU 已暂停。用户要求设置断点时，AI 直接按 Status → 必要时 Pause → 确认 Stopped → AddBreakpoint 执行，无需再次询问；设置成功后，若本次为设置断点暂停了原本运行的 CPU，则调用 Resume 恢复运行；原本已暂停则保持暂停，保留已有断点。设置失败或结果不明时不恢复运行。用户明确要求不暂停时遵从该限制。单独的 AddBreakpoint 命令仍不会隐式暂停，AI 负责先调用 Pause。仅检查状态或读取变量时不自动暂停。

进程选择依据是 IAR 启动命令行中位于 ProjectRoot 下的工程路径，不根据窗口标题中的同名工程猜测。若 IAR 最初空白启动、随后从菜单打开工程，脚本可能拒绝选择；应使用 `.eww` 直接打开。一个实例中切换了另一个工程后，也必须重新核实，不应继续沿用原实例。

多个实例匹配时，可显式加 `-IarProcessId`。目标实例不唯一、出现模态窗口、宏求值失败或响应超时都会报错，不把请求已发送当作操作成功。

## 3. 日常命令

在工程根目录执行。各命令也可由 AI 直接执行，无需操作人员复制到 IAR。

### 检查当前状态

```powershell
.\Tools\Invoke-IarSession.ps1 -Action Status
```

返回进程、窗口标题、`Running` / `Stopped` / `Unknown` 以及观察时间。菜单状态在读取前刷新，避免使用 IAR 缓存的旧菜单状态。

### 明确暂停

```powershell
.\Tools\Invoke-IarSession.ps1 -Action Pause
```

用户明确要求暂停，或要求设置断点而 CPU 正在运行时使用，无需再次询问。已经暂停时不重复发送暂停命令；命令返回前确认 Stopped。需要恢复运行时使用下方 Resume 命令。

### 读取变量

```powershell
.\Tools\Invoke-IarSession.ps1 -Action Read -Expression ipstep,slow_zero,gactQ.overlap
```

支持标量变量、结构体成员、常量数组下标及寄存器，例如 `reqComEu[0]`、`findZero.flagstep1`、`#PC`。返回表达式、格式化值、结果文件和观察时间。数值默认遵循 C-SPY 的格式，PC 返回值可能是十进制。

Read 不接受赋值、函数调用、任意复杂表达式、指针解引用；这避免把普通变量读取变成执行目标函数或写值。符号不存在时返回错误，不能把失败结果当成零值。

### 继续运行

```powershell
.\Tools\Invoke-IarSession.ps1 -Action Resume
```

用户要求继续运行，或设置断点成功后需要恢复本次操作前的运行状态时使用，无需重复询问。已运行时不重复发送 Go；未知状态拒绝执行。发送后验证 Running，未观察到时报告结果不明（也可能立即命中断点），不自动重试，应读取状态和日志确认。此命令已做模拟状态测试，尚未验证本次硬件上的恢复运行。

### 读取暂停现场

```powershell
.\Tools\Invoke-IarSession.ps1 -Action Snapshot -Expression ipstep,slow_zero,findZero.flagstep1
```

依次读取 PC、C-SPY 返回的源位置、关注变量。源码位置可能只返回模块名，例如 `hal:143:2`，不保证完整文件路径。

这是逐项采样，不是硬件原子快照。采集过程中不要在 IAR 中继续运行、单步、切换核心或修改 Quick Watch。如果状态变化，脚本会拒绝后续求值；已输出的项目仍只是各自时间点的样本。

### 设置代码断点

```powershell
.\Tools\Invoke-IarSession.ps1 -Action AddBreakpoint `
  -SourceFile .\Easy6\Source\M_P_Zero_HM_onlylongY_seq_new.c `
  -Line 1305
```

脚本生成源文件位置形式的 `__setCodeBreak(...)`，由现有 C-SPY 执行。返回非零断点 ID 才报告已接受；既有断点不清除。普通代码断点触发后暂停，不使用会自动继续的日志断点。

本次实测返回 ID 5。ID 仅属于当时那次会话，不是固定编号。非零 ID 表示 C-SPY 接受设置，不等于已命中，也不保证优化后指令恰好对应请求行；在 IAR Breakpoints 中可核对实际落点。不要为验证脚本重复执行 AddBreakpoint，以免新增重复断点。

### 读取 IAR Debug Log

IAR 的菜单为 `Debug → Logging → Set Log File`，勾选 Enable Log file，并包含 Errors、Warnings、Info。此设置只负责日志落盘，不负责探针配置。

本次发现当前实际日志是 `prj/iar/LogFile1.log`，并已读到新写入的宏注册、栈警告和断点命中记录；此前建议的 `Debug/IAR-Debug.log` 并未创建。

```powershell
.\Tools\Invoke-IarSession.ps1 -Action ReadLog `
  -LogFile .\prj\iar\LogFile1.log -Tail 30
```

日志位置由实际 IAR 设置决定，不能认为每个工程都使用 LogFile1.log。日志本身可随时用 Get-Content 读取；脚本的 ReadLog 当前仍会核对目标 IAR 实例。

Debug Log 不会自动包含所有 Watch 变量和调用栈。宏结果文件负责本次请求的读数，日志负责事件历史。日志一段时间未变化不必然代表断线；反过来，旧日志也不能证明当前仍连接。

## 4. 操作人员与 AI 的配合

- 操作人员照常在 IAR 中下载、运行和单步，操作硬件复现问题。
- AI 先读取 Status，再按授权设置断点、采集暂停现场和读取日志。
- 用户发出“读取当前现场”即可让 AI 执行 Snapshot，无需手动把每个值抄出。
- 设置断点前记录运行状态：本次为设置断点暂停的 CPU，在设置成功后恢复运行；原本已暂停则保持暂停。用户明确要求保持暂停时优先遵从。恢复后再次暂停时先检查日志和现场，不自动反复继续。
- 脚本执行期间不要同时编辑 Quick Watch。命令之间可正常操作 IAR；不需要让出鼠标给 AI。
- 两个脚本不能同时向同一 IAR 发送命令，进程级互斥锁会拒绝第二个请求。互斥锁不能阻止人工操作 IAR。

没有常驻监视进程：命令完成后立即退出，IAR/C-SPY 会话保留。AI 只对实际读取到的状态负责，不能声称聊天结束后仍在持续自动监视。

## 5. 换工程时的要求

同一 IAR 版本通常只需复用这两个 Tools 文件，打开目标工程 `.eww`，指定 ProjectRoot 或在目标工程根目录执行。芯片、SWD/JTAG、下载算法、启动宏、符号等继续由该 IAR 工程承担，不再填写 SharedDebugConfig.ps1。

需要随任务改变的是目标源文件、行号、关注变量和日志路径。工具未假定固定 IAR 安装路径、固定 PID 或固定芯片。

当前验证的是一个实例打开一个明确工程的情形。多工程 workspace 中切换活动工程、同一实例另开工程、管理员权限不一致、非英文菜单、升级 IAR、CCS 接入尚未验证。不要仅凭同名窗口认为这些场景已支持。

### 旧方案文件怎么处理

`AGENTS.md` 应保留，内容以当前 IAR 会话规则为准；删除它会让后续 AI 缺少入口和操作边界。三份旧共享面板文档已在开头标记为历史方案，并链接到本手册。

| 文件类别 | 当前处理建议 |
| --- | --- |
| 本手册、`Tools/Invoke-IarSession.ps1`、`Tools/IarSession.mac`、`AGENTS.md` | 当前方案保留。 |
| 三份 `IAR-JLink` 共享面板/迁移/半自动化文档 | 当前不作为操作依据；可保留作历史参考，明确放弃旧方案后可归档或删除。 |
| `打开共享调试面板.bat`、`Tools/SharedDebug*.ps1`、`Tools/StartSharedDebug.ps1`、`Tools/RunSharedDebug.ps1`、`Tools/SendSharedDebugCommand.ps1` | 旧面板链路；不运行就不会占用探针。需要清理时按依赖整体核对。 |
| `Tools/BuildProject.ps1`、`Tools/IarCspyDownload.ps1`、`Tools/BuildAndDownload.ps1` | 仍引用 `SharedDebugConfig.ps1`，其中部分还调用共享后端。若继续使用这些编译/下载入口，不能单独删除其配置与依赖。 |
| `.ewp/.eww`、IAR 启动宏、`prj/iar/settings`、符号与下载文件 | 属于工程/IAR 环境，不作为旧面板文件清理。 |
| `Debug/IarSession` 与实际 Debug Log | 当前结果与记录；不与旧 `Debug/AutoDebug` 混淆，不在使用中清理。 |

当前命令工具不引用旧面板脚本。旧文件仅存放在磁盘不会影响本方案，真正需要避免的是 AI 沿用旧规则、误运行旧连接脚本，以及两个后端争用同一探针。本次只更新规则和文档，没有删除旧工具或终止任何进程。

## 6. 本次验证记录及限制

目标工程 Git 分支 `HC-ECAT-EXIO-Only-IOMAP-KEWEI-58`，提交 `b58da29`，含未提交修改。测试使用已由 IAR 加载的 Debug 程序；本轮未运行工程编译或重新烧录。

| 项目 | 结果 |
| --- | --- |
| 识别已打开的 IAR | 成功，测试实例 PID 140116 |
| 发送暂停并确认状态 | 成功，未自动 Resume |
| 注册 C-SPY 宏并接收文件结果 | 成功，GUI 模式查询返回 0 |
| 读取变量和结构体成员 | 成功，样本 ipstep=-1、slow_zero=0、gactQ.overlap=0.0 |
| PC 与源位置回传 | 成功，曾读到 PC=99688（0x00018568）、hal:143:2 |
| 第 1305 行断点 | C-SPY 返回非零 ID 5，尚未确认该断点实际命中 |
| 原生 Debug Log 读取 | 成功，读到栈范围警告与其它位置的断点命中事件 |
| 写入式 Read 表达式 | `ipstep=9` 被拒绝，未执行赋值 |
| 不存在的变量 | 求值失败明确报错 |
| 错误工程根目录 | 拒绝选择无关 IAR 实例 |
| 运行状态下读取 | 拒绝，不隐式停核 |
| 完整调用栈、单步、写值、删除断点 | 本版命令未提供 |

调试过程中另有日志记录 `Code @ 0x00001A8C` 的断点命中，随后采集返回 ComGUI 模块附近的位置；它不属于这次新增的源行验证，不据此宣称第 1305 行已命中。各记录均带独立时间，不把不同时间的 PC 合并为同一现场。

原型阶段曾出现重复宏定义警告；现实现按模板哈希生成函数名并缓存注册，用真实握手校验会话。IAR 重启调试后宏可能丢失，下一次无副作用握手失败时会重新注册；实际设置断点的命令不自动重试。宏注册成功也不会证明目标源码与已加载程序完全一致。

若请求超时，先查看 Quick Watch 和 Debug Log：操作可能已经发生但回传失败，尤其不要盲目重试设置断点。结果文件以唯一名称及 complete 标记区分完成响应，旧结果不会作为新命令结果使用。

## 7. 实现依据

本机 `C:/software/IAR/arm/doc/EWARM_DebuggingGuide.ENU.pdf`：

- 第 88 页：Debug Log 文件设置。
- 第 382–385 页：宏注册、Quick Watch 执行、普通断点 Action。
- 第 389–390 页：`__fmessage` 格式化文件输出。
- 第 403 页：`__evaluate(string, valuePtr)`。
- 第 429 页：`__registerMacroFile`。
- 第 431–432 页：`__setCodeBreak` 参数和返回值。
- 第 441 页：`__sourcePosition`。

Windows 窗口接口通过实际菜单文本发现命令 ID，使用 WM_INITMENUPOPUP 刷新菜单状态、WM_COMMAND 调用菜单、WM_SETTEXT 填写 Quick Watch，以及 BM_CLICK 请求求值。未使用内部 C-SPY RPC、全局 SendKeys 或固定屏幕坐标。
