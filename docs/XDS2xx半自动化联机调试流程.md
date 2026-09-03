# XDS2xx 半自动化联机调试流程

## 1. 文档目的

本文用于指导后续 AI 与现场操作人员协作调试目标下位机。该模式定义为“半自动化联机调试”：

- 操作人员负责手控器操作、输入信号触发、机构观察、急停和现场安全确认。
- AI 负责检查调试文件、连接 XDS2xx、采样变量、运行中写值、设置断点、Suspend/Resume、保存日志和结合源码分析。
- AI 不根据变量名称自行推断可以安全运行机构；涉及烧录、复位、停核、写变量和 Resume 时，必须以用户当轮明确授权为准。

目标不是代替 CCS 的全部图形界面，而是把重复的调试动作封装成可审计的命令和日志，使操作人员可以专注于设备动作，AI 可以持续取得同一时间线上的软件状态。

## 2. 工程与环境依据

- 目标下位机 VCS：SVN。
- 仓库相对路径：`^/S3-5/KEWEI/Easy6_fastslow-61-IOMAP`。
- 本次记录时工作副本基准：r7122，且包含未提交修改。
- 目标 CPU：TI TMS320F28335 / C28x。
- 调试探针：Texas Instruments XDS2xx USB Onboard Debug Probe。
- 工程目标配置：`targetConfigs/TMS320F28335.ccxml`。
- 当前自动调试入口：`Tools/AutoDebug.ps1` 和 `Tools/AutoDebug.js`，两者目前尚未纳入 SVN。
- 当前工程在 `Easy6_fastslow/Source/Setup.c` 中执行了 `ERTM`，具备使用 C28x Real-time Mode 的程序侧基础。

TI 官方说明 F28x 支持 Real-time Mode，可以在 CPU 运行期间查看和修改内存；Expressions 的 Continuous Refresh 可以周期刷新变量。参考：

- <https://software-dl.ti.com/ccs/esd/documents/users_guide_ccs_20.0.2/ccs_debug-main.html#real-time-mode>
- <https://software-dl.ti.com/dsps/dsps_public_sw/sdo_ccstudio/workshops/CCSv5/C2000/CCSv5-Workshop%28C2000%29.pdf>

## 3. 为什么采用半自动化

CCS 图形调试适合由操作人员直接查看 Expressions、点击 Suspend 和 Resume，但 AI 不一定能稳定读取或控制当前 CCS 窗口。独立 DSS 会话能够稳定执行调试命令并生成日志，但不能把调试上下文自动转移到已经打开的 CCS Expressions 窗口。

因此采用以下分工：

```text
操作人员操作手控器/硬件
          ↓
目标程序保持运行
          ↓
XDS2xx + DSS 持续采样或执行调试命令
          ↓
CSV/XML 日志
          ↓
AI 读取日志并结合源码分析
```

同一时刻只允许一个调试会话占用 XDS2xx。使用自动调试前，应断开 CCS GUI 中现有的 Debug 会话；CCS 可以保持打开用于编辑代码。

## 4. 当前已经实现的模式

`Tools/AutoDebug.ps1` 当前包含以下模式：

| 模式 | 行为 | 是否访问硬件 |
| --- | --- | --- |
| `Validate` | 检查 DSS、`.ccxml`、`.out`、脚本参数和 XDS2xx 枚举 | 否 |
| `Connect` | 连接目标并读取停止状态；连接动作可能使 CPU 停止 | 是 |
| `Set` | 连接、只加载符号、读取变量、写表达式、回读、恢复运行 | 是 |
| `Debug` | 下载 `.out`、设置断点、复位并运行到断点、读取变量 | 是 |

已实现的 `Set` 仍采用“连接后停核、写入、回读、恢复运行”，并不等同于 CCS Real-time Mode 下直接在运行中修改 Expressions。

本地无硬件验证命令：

```powershell
.\Tools\AutoDebug.ps1 -Mode Validate
```

显式写值示例：

```powershell
.\Tools\AutoDebug.ps1 `
    -Mode Set `
    -AllowHardware `
    -AllowMemoryWrite `
    -AllowRun `
    -SetExpression 'ipstep=90' `
    -Watch @('ipstep','machmode','submode','errPLC','PC')
```

## 5. 已实现的常驻共享调试模式

常驻共享调试由 `AutoDebugHold.js`、`StartSharedDebug.ps1`、`SharedDebugPanel.ps1` 和 `SendSharedDebugCommand.ps1` 组成。图形面板和 AI 不分别连接探针，而是向同一个命令队列提交操作，避免多个调试会话抢占 XDS2xx。

### 5.1 目标能力

一个 DSS 进程持续占用同一个调试会话，目前支持：

1. 普通连接会话只加载 `.out` 中的符号，不重复烧录目标板；面板的 Build 成功后会启动单独的下载会话。
2. 以 Polite Real-time Mode 让目标程序保持运行。
3. 每500毫秒更新目标状态和关注表达式，避免对 XDS2xx 进行过密轮询。
4. 在会话运行期间接收运行中写值命令。
5. 动态设置普通源码行断点，并根据断点 ID 清除断点。
6. 查询当前是否停止、停止位置和 PC。
7. 执行 Suspend、Resume、Snapshot 和 Stop。
8. 所有命令、返回值和错误使用同一时间戳记录。

首次连接但不烧录、不复位、不主动运行：

```powershell
.\Tools\StartSharedDebug.ps1 `
    -AllowHardware
```

未传入 `-Watch` 时只默认监视 `errPLC` 和 `ipstep`。`PC`、`actionrun`、`cliprun` 需要时由操作人员或 AI 明确加入，不作为默认监视项。

只打开控制面板可运行 `.\Tools\SharedDebugPanel.ps1`；不使用命令行时，直接在工程根目录双击 `打开共享调试面板.bat`。该入口隐藏 PowerShell 控制台，只保留 `XDS2xx 共享调试面板` 图形窗口。

面板顶部的 `编译并下载` 会先显示安全确认，用户确认后才调用当前工程 `projects/Windows/Debug/makefile` 和 CCS 自带 `gmake.exe`。编译成功后，流程会先检查 DSS、`.ccxml` 和 `.out`，再停止旧共享会话、重新连接 XDS2xx 并以 `LoadProgram=true` 下载当前 `projects/Windows/Debug/Easy6_STD.out`；编译失败、必要文件不存在或旧会话无法释放时不会下载。结果显示在面板中，完整编译日志保存到 `Debug/AutoDebug/build.log`，下载状态保存到 `Debug/AutoDebug/download-status.txt`。下载成功后 CPU 明确保持暂停，需现场确认安全后再 Resume。手动调用组合脚本时必须显式传入 `-AllowHardware -AllowProgramLoad`。

面板中的 `Connect` 只连接并加载符号，不烧录、不复位、不主动运行；关闭面板不会自动断开 DSS，应使用 `Disconnect` 或 `STOP`。目标失联但后台仍存活时，按钮显示为 `Reconnect`；原会话无法恢复时，停止旧后台并新建会话，不自动复位硬件。

面板把变量监视、读取和写入放在同一区域。左侧填写持续监视的变量（每行一个），小型 `应用监视` 按钮位于标题右侧。右侧采用类似 CCS Expressions 的多行表格，只包含 `Expression` 和 `Value` 两列，可连续新增或删除表达式行。`读取全部` 会刷新表格内全部非空表达式；`写入选中` 只把当前选中行按 `Expression=Value` 提交并回填实际回读值，避免将整张表中的旧值误写回控制器。运行状态由面板顶部显示，不再设置单独的“当前状态和值”区域。

面板的断点区域显示当前有效断点列表，包括 DSS 分配的 ID 和断点规格。目标由运行变为暂停时，后台区分人工 `Suspend` 与断点停止；断点命中时记录 `BREAKPOINT_HIT id=... spec=... PC=...`，面板弹出提示，并在顶部 `Last stop` 持续显示最近命中的位置。

面板启动时断点输入框为空，新建共享会话也不自动设置任何断点。断点添加成功后，面板自动清空断点输入框；添加失败时保留原内容，便于修改后重试。事件区保留原有样式和完整记录，刷新时保持用户当前的横向滚动位置。执行 `Disconnect` 或 `STOP` 时，后台先清除当前会话的全部断点并记录 `BREAKPOINTS_CLEARED`，将状态写为 `STOPPED`，再断开 XDS2xx。

普通源码断点只需输入“完整源文件路径:行号”，不需要地址，也不需要附带该行代码，例如：

```text
C:\work_file\CCS\S3-5\KEWEI\Easy6_fastslow-61-IOMAP\Easy6_fastslow\Source\M_P_AUTO.C:1748
```

只有需要区分同一源码行中的多条机器指令时，才使用 `@地址,源码位置,说明` 精确地址格式，例如：

```text
@0x32112e,M_Sub3D.c:1239,ERROR_CHECKINPUT_RUN
```

如果一行同时包含条件判断和赋值，普通源码行断点可能落在条件入口，即使条件不成立也会暂停。若只监视赋值真正执行，应根据当前 `.out` 的 DWARF 行表设置精确地址断点；重新编译后必须重新解析地址，不能沿用旧地址。

### 5.2 会话文件和共享命令

每次会话输出到独立目录：

```text
Debug/AutoDebug/Shared-YYYYMMDD-HHMMSS-fff/
```

其中包含 `commands/`、`status.txt`、`events.log`、`dss.xml` 和 `session.json`。`current-session.json` 指向最新共享会话，后续 AI 必须读取该文件，不得根据文件时间猜测命令路径。

`status.txt` 保存当前状态和关注值，例如：

```text
HALTED;errPLC=0;ipstep=3
```

`events.log` 按时间记录命令、回读、状态变化和错误。单条命令失败只记录 `COMMAND_ERROR`，不得使整个 DSS 会话退出。图形面板和 AI 使用原子改名的 `.cmd` 队列，因此连续提交命令不会互相覆盖。

```powershell
.\Tools\SendSharedDebugCommand.ps1 'SNAPSHOT'
.\Tools\SendSharedDebugCommand.ps1 'SET ipstep=90'
.\Tools\SendSharedDebugCommand.ps1 'READ actionrun'
.\Tools\SendSharedDebugCommand.ps1 'RESUME'
```

### 5.3 运行中写值

用户说“把 `ipstep` 改成 90”时，Monitor 模式应在同一常驻会话中执行等价表达式：

```c
ipstep = 90
```

然后在下一次采样中回读并记录结果。需要注意：

- 写表达式成功不等于该值会一直保持；目标程序可能在下一个周期立即覆盖它。
- AI 必须同时记录写入时刻、写入返回值和后续至少一次采样值。
- 对指针、数组越界、外设寄存器、动作输出和未知表达式，不得仅凭用户口语模糊匹配后直接写入；应先解析到明确目标。
- 如果实时写入被 DBGM 或关键区阻塞，应报告失败，不得自动切换到 Rude Real-time Mode。

## 6. 操作人员与 AI 的约定命令

操作人员不需要记 DSS 语法，可以直接使用以下自然语言。

### 6.1 开始和停止

```text
开始监视 ipstep、actionrun、cliprun、errPLC，每500毫秒读取一次。
停止监视。
保存当前快照。
```

AI 开始后必须明确回复“监视已经开始”，并给出日志路径。停止后必须报告目标最终是运行还是停止状态。

### 6.2 写变量

```text
把 ipstep 改成90。
把 core_mode 改成0，并确认下一次采样值。
```

默认解释为 Real-time Mode 下直接写入，不自动 Suspend。用户明确要求“暂停后修改”时，才执行 Suspend → 写入 → 回读 → Resume。

### 6.3 设置断点

用户可以使用以下任一种描述：

```text
在 M_Sub3D.c 第1238行打断点。
在 if (actionrun||cliprun) 这一句打断点。
在 StartCore 函数入口打断点。
在 M_Sub3D.c:1238 打条件断点，条件是 actionrun != 0 || cliprun != 0。
```

AI 的处理规则：

当前共享面板只实现普通源码行断点；条件断点尚未接入共享命令接口，不能把普通断点描述成条件断点已经生效。

1. 优先接受“工程相对文件路径 + 行号”或函数名。
2. 用户只给代码片段时，先用源码搜索确定唯一位置；存在多个匹配时不能猜测。
3. 设置行断点前比较源码与 `.out` 时间，并确认 `.map`/调试符号存在。
4. 如果源码晚于 `.out`，明确告知调试信息已过期；未得到编译授权时不主动编译。
5. 断点落在注释、宏或不可执行行时，允许调试器移动到附近可执行地址，但必须报告实际位置。
6. 目标程序位于 Flash 时优先使用硬件断点。C28x 可用分析资源有限；本工程当前程序实测同时启用两个断点后，第三个断点会报 `AET resources` 不足。需要先在面板中选中不再使用的断点、删除其 ID，再添加新断点。单个断点添加失败只记录并弹出错误，不应终止整个共享会话。
7. 条件断点命中后记录 PC、调用点以及预先约定的变量快照。

### 6.4 暂停和继续

```text
暂停。
继续运行。
清除刚才的断点后继续。
```

AI 执行 Resume 前应报告当前停止原因和断点位置。断点会暂停控制 CPU，可能导致输出保持、通信超时或机构状态异常；现场安全判断由操作人员负责。

### 6.5 持续监视与等待规则

用户开始一轮联机调试后，只要用户没有明确说“结束调试”“停止监视”或“断开连接”，AI 就应把本轮调试视为持续进行中的会话：

1. 持续保留用户指定的断点以及用户明确要求监视的变量；没有指定变量时，只默认监视 `errPLC` 和 `ipstep`。目标运行或暂停状态由后台状态字段独立报告，不需要把 `PC` 加入默认表达式。
2. 目标运行时持续检查是否命中断点，并刷新指定变量；目标停在断点时立即记录 PC、断点位置、停止原因和变量快照。
3. 报告断点命中或重要变量变化后，保持目标当前状态并等待用户指令。用户没有明确要求时，不擅自 Resume、Suspend、单步、改值、清除断点、重新烧录或断开连接。
4. 用户暂停聊天、暂时操作手控器或硬件时，后台共享调试会话和监视仍应保持；断点命中后 CPU 保持暂停，直到用户或 AI 根据用户的新指令执行 Resume。
5. 用户可以通过共享面板自行 Resume、Suspend、写值或获取快照；AI 下一次继续工作时应先读取 `current-session.json`、`status.txt` 和 `events.log`，以现场实际状态为准，不假定状态与上一次回复相同。
6. 如果共享调试进程退出、XDS2xx 断开、状态文件停止更新或变量读取持续失败，应明确报告监视已经失效，不能继续声称仍在监视。
7. 长时间等待本身不是调试结束条件。只有用户明确结束，或者连接确实失效且已报告，才结束本轮持续监视状态。

## 7. 推荐的一轮调试流程

以 `Easy6_fastslow/Source/M_Sub3D.c` 中以下判断为例：

```c
if (actionrun || cliprun)
    errPLC = ERROR_CHECKINPUT_RUN;
```

建议流程：

1. 操作人员说明复现步骤、预期结果和现场已满足的安全条件。
2. AI 检查 `.out` 是否晚于相关源码，并确认变量和断点符号存在。
3. AI 启动 Monitor，关注：

   ```text
   ipstep
   machmode
   submode
   actionrun
   cliprun
   errPLC
   keyboard
   cyclehold
   ```

4. AI 回复“监视已经开始”。
5. 操作人员执行手控动作，并在聊天中说明关键动作，例如“现在按下启动”“现在触发输入”。
6. AI在日志中写入对应 `USER_MARK`，并观察动作前后的状态变化。
7. 如果500毫秒采样不足以捕获瞬时变化，改用条件断点、硬件 Watchpoint，或者在固件中增加环形调试记录；不要盲目提高 JTAG 轮询频率。
8. 断点命中后，AI报告是 `actionrun`、`cliprun` 还是两者共同导致，并列出相关位值。
9. 用户说“继续运行”后，AI执行 Resume 并确认目标重新运行。
10. 测试结束后停止 Monitor，保存日志并总结判断依据、未确认项和下一步建议。

## 8. 当前已验证事实

2026-09-02 已完成以下验证：

- `Validate` 模式成功识别本机 CCS DSS、TMS320F28335 `.ccxml`、程序文件和 XDS2xx。
- 最新程序成功下载到目标板。
- `StartCore` 断点成功建立，但程序运行30秒未进入该业务路径；这证明下载和断点建立成功，不证明 `StartCore` 功能异常。
- `Set` 模式成功把 `ipstep` 从22写为90；当时 `machmode=34 (MODE_ZERO)`、`submode=0`、`errPLC=0`。
- 写入后目标恢复运行，DSS确认目标处于运行状态后断开。
- 已修复 DSS 内部失败而 PowerShell 外层误报成功的问题，现使用结果文件校验最终状态。
- 已修复共享启动器经 `cmd.exe` 传递分号分隔监视表达式时启动失败的问题，现由 `RunSharedDebug.ps1` 从会话文件读取参数并启动 DSS。
- `StartSharedDebug.ps1 -AllowHardware` 已成功建立不烧录、不复位、不主动运行的共享会话，DSS 进程和图形面板同时保持存活。
- 精确断点 `M_Sub3D.c:1239` 曾成功建立，断点 ID 为7；当前版本已取消启动时自动添加该断点。
- 操作人员在图形面板点击 `Resume` 后，后台事件日志正确记录 `RESUME OK` 和 `RUNNING`；AI随后通过同一队列执行 `SNAPSHOT`、`READ actionrun` 成功，证明双方能够协同控制同一会话。
- CPU运行期间状态文件能约每500毫秒刷新 `PC`、`errPLC`、`actionrun`、`cliprun` 和 `ipstep`，运行中表达式读取已验证可用。

共享面板、命令队列、状态文件、持久命令通道、硬件连接和运行中读取均已验证。尚未验证的是动态删除断点和条件断点；当前共享接口不宣称支持条件断点。

## 9. 常见问题与处理

### 9.1 CCS Expressions 有变量名但没有值

通常表示 CCS GUI 当前没有有效的目标连接、符号或暂停/实时读取上下文。独立 DSS 会话结束后，不会把上下文留给另一个 CCS 会话。

### 9.2 XDS2xx 被占用

检查 CCS GUI 是否仍连接目标，保证只有一个调试会话。不要通过强制结束不明进程来抢占探针。

### 9.3 断点行对不上

先比较源码、`.obj` 和 `.out` 时间。源码有新修改而 `.out` 未重新生成时，不能相信源代码行映射。

如果添加断点时报 `Cannot enable while the target is disconnected`，说明目标已经失联，不是 `文件:行号` 格式错误。先使用面板的 `Reconnect`；若同一 DSS 会话反复出现 `emulation failure`，停止失联后台后重新建立会话。复位仿真器或目标板必须另行获得用户确认。

如果添加第三个断点时报 `This task cannot be accomplished with the existing AET resources`，说明硬件断点资源已满。删除一个现有断点后再添加，不要反复提交同一个断点。

### 9.4 实时采样漏掉瞬时状态

200～500毫秒轮询适合观察普通状态，不适合捕获5毫秒级瞬变。需要使用硬件 Watchpoint、条件断点或目标程序内的环形日志。

### 9.5 实时写入后马上恢复旧值

这通常表示程序逻辑在周期任务或中断中重新赋值。应记录写入后的连续采样，并追踪赋值点，而不是重复高速写入强行覆盖业务逻辑。

## 10. 后续 AI 的执行原则

- 先确认 `.out` 新鲜度、符号、目标配置和 XDS2xx状态，再连接硬件。
- 默认不主动编译；源码和 `.out` 不一致时先提示用户。
- 连接、烧录、复位、停核、写值和运行分别按其实际影响说明，不用“调试”一词笼统覆盖。
- 用户明确要求运行中直接写值时，不擅自改成停核写入。
- 用户明确要求断点时，可以根据行号、函数名或唯一代码片段解析位置。
- 持久 Monitor 会话运行期间持续保存日志，并允许用户随时用聊天消息补充动作标记。
- 调试会话默认持续监视断点和用户指定变量，并等待用户指令；用户未明确结束前，不因一轮聊天回复结束而自行停止监视或断开连接。
- 断点命中后默认保持暂停；除非用户明确要求，否则不自动 Resume、改值或清除断点。
- 任何时候都不替代现场急停、限位和机构安全判断。
- 调试结束必须说明目标最终状态、写过的变量、烧录过的程序、命中过的断点和日志位置。

这种“CLI/日志源 + AI分析”的封装方式也符合 OpenAI Docs 中为 Codex提供可组合命令入口的自动化思路：<https://learn.chatgpt.com/use-cases>。
