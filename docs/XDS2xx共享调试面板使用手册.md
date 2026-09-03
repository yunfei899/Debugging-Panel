# XDS2xx 共享调试面板使用手册

## 1. 文档用途

本文面向使用共享调试面板的现场操作人员和后续 AI，说明如何在同一个 XDS2xx/DSS 会话中协同完成编译、连接、变量监视与读写、断点管理、暂停和继续运行。

这套流程属于“半自动化联机调试”：

- 操作人员通过图形面板以及手控器、现场硬件进行操作。
- AI 通过命令脚本操作同一个共享调试会话，并结合事件日志和源码分析问题。
- 双方不会分别创建调试会话，避免同时抢占 XDS2xx。

更详细的实现原理、安全边界和故障排查见 `docs/XDS2xx半自动化联机调试流程.md`。

## 2. 当前适用范围

当前版本已经按照本工程配置，可直接用于：

- 目标 CPU：TI TMS320F28335 / C28x。
- 仿真器：XDS2xx。
- 目标配置：`projects/Windows/targetConfigs/TMS320F28335.ccxml`。
- 程序文件：`projects/Windows/Debug/Easy6_STD.out`。
- 源码目录：`Easy6/Source`。

当前工具不是所有 CCS 工程都能直接使用的通用成品。其他工程需要调整目标配置、程序文件、源码目录、构建目录和默认监视变量，详见文末答疑第3项。

## 3. 使用前准备

1. 连接目标板和 XDS2xx，确认设备处于允许调试的安全状态。
2. CCS 可以保持打开用于编辑源码，但必须断开 CCS 自己的 Debug 会话。
3. 同一时刻只能由一个 DSS/CCS Debug 会话占用 XDS2xx。
4. 点击“编译并下载”会先要求现场确认，再编译、重新建立下载会话并烧录当前 `.out`；连接按钮本身仍只负责连接和加载符号。
5. 涉及机构动作时，由现场操作人员负责急停、限位和人员安全确认。

## 4. 打开共享调试面板

在工程根目录双击：

```text
打开共享调试面板.bat
```

该入口会打开“XDS2xx 共享调试面板”，不会额外显示需要操作的 PowerShell 控制台。

面板会优先读取 `Debug/AutoDebug/current-session.json`：

- 如果已有仍然存活的共享会话，面板接入该会话。
- 如果没有可用会话，点击“连接”后建立新的共享调试会话。
- 不要同时在 CCS 中重新连接同一个 XDS2xx。

## 5. 推荐操作流程

### 5.1 编译

点击顶部的“编译并下载”，确认 CCS Debug 已断开且设备处于安全状态后，在确认框中选择“是”。

该按钮调用当前工程 `projects/Windows/Debug/makefile` 完成编译和链接；编译成功后会自动下载 `projects/Windows/Debug/Easy6_STD.out`：

- 编译失败时不会连接或烧录。
- 编译成功后会停止旧的共享 DSS 会话，重新连接 XDS2xx 并下载目标程序。
- 下载过程不会自动复位或 Resume；下载完成后明确保持 CPU 暂停，按需要点击“继续 Resume”。
- 编译状态显示在面板顶部。
- 下载状态显示在面板顶部，必须看到 `Download: SUCCESS` 才表示下载完成。
- 完整日志写入 `Debug/AutoDebug/build.log`。

如果日志显示 `gmake: Nothing to be done for 'all'.`，表示本次没有重新生成 `.out`，但面板仍会把当前 `.out` 下载到目标板。

### 5.2 连接

点击顶部的“连接”按钮。

正常连接默认加载符号，用于解析变量名和源码行，不代表已经把新程序烧录到目标板。连接成功后按钮显示为“Connected”；目标失联时显示为“Reconnect”。

如果提示 XDS2xx 被占用，先检查 CCS 的 Debug 会话是否仍处于连接状态，不要强制结束不明进程抢占探针。

### 5.3 设置监视变量

面板初始只默认填写 `errPLC` 和 `ipstep`。`PC`、`actionrun`、`cliprun` 不会默认监视，需要时再手动加入。

在“监视变量（每行一个）”区域输入变量或表达式，例如：

```text
errPLC
ipstep
```

然后点击“应用监视”。后台会按当前共享会话的刷新周期读取这些表达式，并把结果写入状态和事件记录。

“刷新快照”只立即读取当前已应用的监视表达式；如果监视列表没有 `PC`，普通快照中不会因为历史默认值而自动增加 `PC`。目标停止时，后台仍可能为了判断停止位置单独记录 PC。

### 5.4 读取表达式

右侧表格仿照 CCS Expressions，只使用两列：

- `Expression`：要读取的变量或表达式。
- `Value`：读取结果，或准备写入的新值。

在空行中填写一个或多个 Expression，然后点击“读取全部”。系统会依次读取全部非空表达式并更新 Value。

读取不会修改目标内存，但目标持续运行时，值可能在两次刷新之间发生变化。

### 5.5 写入变量

在表格中：

1. 在 Expression 列填写明确的目标变量，例如 `ipstep`。
2. 在同一行 Value 列填写目标值，例如 `90`。
3. 选中该行。
4. 点击“写入选中”。
5. 查看回读值和事件记录，确认写入是否成功。

系统只写入当前选中的一行，不会把整张表里的旧值全部写回目标板。

写入成功并不保证变量会一直保持该值，目标程序可能在下一周期或中断中重新赋值。对指针、数组下标、外设寄存器、动作输出和含义不明确的表达式，不应直接尝试写入。

### 5.6 添加断点

普通源码行断点输入完整源码路径和行号即可，例如：

```text
C:\work_file\CCS\S3-5\KEWEI\Easy6_fastslow-61-IOMAP\Easy6_fastslow\Source\M_P_AUTO.C:1748
```

不需要填写源代码内容，也不需要自行查找机器地址。点击“添加”后：

- 成功时，断点出现在当前断点列表中，输入框自动清空。
- 失败时，输入内容保留，便于修改后重试。
- 如果提示目标已断开，应先点击 Reconnect，而不是修改断点格式。

只有需要区分同一源码行中的具体机器指令时，才使用精确地址格式：

```text
@0x32112e,M_Sub3D.c:1239,ERROR_CHECKINPUT_RUN
```

精确地址取自当前 `.out` 的调试信息，重新编译后不能沿用旧地址。

### 5.7 删除断点

在当前断点列表中选中一个断点，面板会取得其 ID；点击“删除ID”删除该断点。

C28x 的硬件断点资源有限。遇到 AET resources 不足时，应先删除不再使用的断点，再添加新断点。

点击“断开”时，后台会先清除当前共享会话中的全部断点，再断开 XDS2xx。

### 5.8 暂停、继续和断点命中

- “暂停 Suspend”：主动暂停 CPU。
- “继续 Resume”：让暂停的 CPU 继续运行。
- “刷新快照”：立即读取当前监视表达式，不等同于暂停。
- “断开”：清除当前断点并结束共享调试连接。

断点命中后，面板会提示 `BREAKPOINT_HIT`，并显示断点 ID、实际位置和 PC。后台默认保持 CPU 暂停，等待操作人员或 AI 的下一条明确指令，不自动继续运行。

暂停 CPU 可能造成通信超时、输出停止刷新或机构状态保持，必须结合现场设备状态判断是否可以操作。

## 6. 人与 AI 联合调试

### 6.1 操作人员负责

- 打开并操作共享调试面板。
- 操作手控器、输入信号和现场机构。
- 确认急停、限位和动作安全条件。
- 决定是否允许编译、烧录、暂停、继续和写变量。
- 告诉 AI 当前复现步骤、关注变量和期望断点。

### 6.2 AI负责

- 首先读取 `Debug/AutoDebug/current-session.json` 指向的 `status.txt` 和 `events.log`。
- 通过 `Tools/SendSharedDebugCommand.ps1` 使用同一个共享命令队列。
- 按用户要求添加或删除断点、读写变量、刷新快照、暂停或继续。
- 每次操作后读取状态和事件记录，确认命令是否真正成功。
- 断点命中后报告停止位置、PC和关注变量，并保持当前状态等待指令。
- 结合源码追踪变量来源和报警条件。

AI不得建立第二个 DSS 或 CCS Debug 会话，也不得在用户未明确要求时自动改变 CPU 状态、写变量、清除断点、重新烧录或断开连接。

### 6.3 推荐对 AI 的说法

没有共享会话时：

```text
开始 XDS2xx 联合调试。按 AGENTS.md 的共享调试规则执行；没有可用会话才启动新会话。监视 errPLC、actionrun 和 ipstep，在 M_Sub3D.c:1973 打断点。未经我的指令不要改变 CPU 状态。
```

面板或后台会话已经运行时：

```text
接管当前 XDS2xx 联合调试。先读取 current-session.json、status.txt 和 events.log，不要新建调试会话。继续监视现有断点和变量，等待我的操作。
```

在本工程中，通常只需要简化为：

```text
开始联合调试，监视 actionrun 和 errPLC，在 M_Sub3D.c:1973 打断点。
```

## 7. 状态与日志位置

每次会话位于：

```text
Debug/AutoDebug/Shared-YYYYMMDD-HHMMSS-fff/
```

主要文件如下：

| 文件 | 作用 |
| --- | --- |
| `Debug/AutoDebug/current-session.json` | 指向当前或最近一次共享会话。 |
| `status.txt` | 当前连接状态、CPU状态和已应用的监视值。 |
| `events.log` | 断点、读写、暂停、继续、错误等带时间戳的记录。 |
| `commands/` | 面板和AI共用的命令队列。 |
| `Debug/AutoDebug/build.log` | 编译完整输出。 |

用户正常使用时不要手工修改这些运行文件；它们用于面板和 AI 同步现场状态及复盘问题。

## 8. 结束调试

1. 确认 CPU 当前是运行还是暂停状态。
2. 确认是否存在为了调试而临时写入的变量。
3. 点击“断开”，让后台清除全部断点并断开 XDS2xx。
4. 检查事件记录中是否出现 `BREAKPOINTS_CLEARED` 和 `STOP`。
5. 如需恢复 CCS 图形调试，等共享 DSS 会话完全退出后再连接。

关闭聊天或暂时不回复不代表结束调试。只有明确说“结束调试”“停止监视”或“断开连接”，才结束本轮持续调试会话。

## 9. 上一轮问题答疑

结论是：目前这套共享调试工具是为 KEWEI-61 + TMS320F28335 配置好的，设计可以移植到其他 CCS 工程，但现在还不是所有工程拿来即用。

### 9.1 每个新加的文件分别是什么作用

| 文件 | 作用 |
| --- | --- |
| `打开共享调试面板.bat` | 双击启动共享调试面板，并隐藏背后的 PowerShell 控制台。 |
| `Tools/SharedDebugPanel.ps1` | 操作人员使用的图形界面，提供编译、连接、暂停/继续、变量读写、断点管理和事件查看。 |
| `Tools/StartSharedDebug.ps1` | 创建共享会话，设置目标芯片配置、`.out`、源码目录和默认监视变量。 |
| `Tools/RunSharedDebug.ps1` | 在后台启动持续运行的 DSS 脚本，并可靠传递会话参数。 |
| `Tools/AutoDebugHold.js` | 共享调试核心，独占 XDS2xx，维护连接、CPU状态、变量监视、断点及命令队列。 |
| `Tools/SendSharedDebugCommand.ps1` | AI 的控制入口，把读写、断点、暂停、继续等命令提交给同一个后台会话。 |
| `Tools/BuildProject.ps1` | 读取集中配置并调用目标工程的 makefile。 |
| `Tools/BuildAndDownload.ps1` | “编译并下载”按钮调用的流程脚本；编译成功后停止旧会话并下载当前 `.out`。手动调用时必须显式传入 `-AllowHardware -AllowProgramLoad`。 |
| `Tools/SharedDebugConfig.ps1` | 当前工程唯一的共享调试配置入口，保存 CCS、构建目录、`.ccxml`、`.out`、源码目录和默认监视变量。 |
| `Tools/AutoDebug.ps1` | 较早的一次性自动调试入口，用于验证、连接、写值或运行到断点。 |
| `Tools/AutoDebug.js` | 配合 `AutoDebug.ps1` 执行一次性 DSS 操作；完成后退出，不是共享面板的持续后台。 |
| `docs/XDS2xx半自动化联机调试流程.md` | 实现原理、命令、安全规则和故障排查说明。 |
| `docs/XDS2xx共享调试面板使用手册.md` | 当前这份面向实际操作的使用手册和答疑。 |
| `AGENTS.md` | 后续 AI 在本工程中必须遵守的持续联机调试规则。 |

截图中的 `Tools/bfe2.exe`、`Tools/link.txt` 和 `Tools/postBuildStep_Debug.bat` 是原工程已有的编译后处理链路，不是本次共享调试新增的核心文件。

共享调试还会在 `Debug/AutoDebug` 下生成会话描述、状态、事件、命令队列和编译日志。这些是运行数据，不是需要人工维护的源码文件。

### 9.2 使用时操作人员可以改动什么

正常使用时，可以通过面板：

- 增删并应用监视表达式。
- 在 Expression/Value 表格中读取多个表达式。
- 选中一行并写入该变量的新值。
- 使用“完整源码路径:行号”添加断点。
- 选中断点并按 ID 删除。
- 暂停、继续和刷新快照。
- 编译当前工程。
- 连接、重连或断开共享会话。
- 在 CPU 运行期间操作手控器和现场硬件。

需要明确区分各操作的影响：

- 读取和监视不主动修改目标内存。
- 写入会真实改变目标内存，且可能被程序立即覆盖。
- 断点和 Suspend 会暂停 CPU，可能影响通信和输出。
- “编译并下载”经用户确认后才会改写目标程序；下载失败必须以面板的 `Download: FAILED` 和事件日志为准。
- Disconnect 会清除共享会话的全部断点。

正常调试不需要直接修改 `AutoDebugHold.js`、其他 PowerShell 脚本或运行中的 JSON、日志和命令文件。只有调整当前工程配置或迁移工具时才修改 `Tools/SharedDebugConfig.ps1`。

### 9.3 共享调试面板能否用于所有 CCS 工程

不能直接用于所有 CCS 工程。当前版本可以直接用于本工程，因为默认配置中包含：

- `targetConfigs/TMS320F28335.ccxml`。
- `Debug/Easy6_fastslow_KEWEI_61_IOMAP.out`。
- `Easy6_fastslow/Source`。
- 当前工程的默认监视变量。
- 当前工程的 `Debug/makefile` 和 CCS 工具位置。

共享命令队列、面板和 DSS 常驻会话的整体架构可以复用。移植到另一个工程时，需要根据该工程修改或参数化：

1. 工程根目录。
2. `.ccxml` 目标配置。
3. `.out` 程序文件名称和位置。
4. 源码根目录。
5. 构建配置与 makefile 位置。
6. 默认监视表达式。
7. 不同芯片或多核目标下的 DSS 会话选择。

因此应理解为：框架可以移植，但目前只有 KEWEI-61/TMS320F28335 这一工程配置完成并可直接使用。

### 9.4 每次启用联合调试是否都要说完整交接语句

不需要每次重复完整长句。

本工程的 `AGENTS.md` 已经保存共享调试规则。后续 AI 能读取本工程规则时，只需要说明本轮目标，例如：

```text
开始联合调试，监视 actionrun、errPLC，在 M_Sub3D.c:1973 打断点。
```

如果共享会话已经存在，可以说：

```text
接管当前联合调试，先读当前状态，不要新建会话。
```

以下完整说法主要用于更换到不了解本工程规则的新 AI、离开当前工作区，或者需要明确重新交接时：

```text
接管当前 XDS2xx 共享调试会话。不要使用 Windows 窗口自动化操作调试，也不要新建 DSS 或 CCS Debug 会话。先读取 Debug/AutoDebug/current-session.json，后续通过 Tools/SendSharedDebugCommand.ps1 与我的共享调试面板共用同一个命令队列。你和我都可以添加删除断点、读写变量、暂停和继续；每次操作后读取事件日志确认结果，未经指令不要自动改变 CPU 状态。
```

### 9.5 操作人员与 AI 的分工写在哪里

分工已经写在工程根目录 `AGENTS.md` 的“XDS2xx 持续联机调试”规则中，特别是第5条：

- 操作人员使用 `Tools/SharedDebugPanel.ps1`。
- AI 使用 `Tools/SendSharedDebugCommand.ps1`。
- 双方共用同一个命令队列和同一个 DSS/XDS2xx 会话。
- AI 不另外建立抢占 XDS2xx 的调试会话。
- 每次操作后，AI读取 `status.txt` 和 `events.log` 确认现场结果。

完整分工为：

- 操作人员：操作 XDS2xx 共享调试面板、手控器和硬件，负责现场安全与动作决策。
- AI：通过命令脚本操作相同的后台会话，读取状态和事件，结合源码分析。
- 双方：都可以读写变量、添加或删除断点、暂停、继续和读取快照；所有命令按共享队列顺序执行。
- 默认约束：未经操作人员明确指令，AI不自动改变 CPU 状态，不自动写值、清除断点、烧录或断开连接。

上述规则同时在 `docs/XDS2xx半自动化联机调试流程.md` 的“常驻共享调试模式”“会话文件和共享命令”“持续监视与等待规则”以及“后续 AI 的执行原则”章节中有更详细说明。

## 10. 迁移示例：HC-SX-Host

本节记录一次实际迁移，用来说明把共享调试流程移到另一个 CCS 工程时，需要复制哪些文件、识别哪些配置，以及如何验证。这里不是假设配置，而是依据两个工程当时的实际版本控制和工程文件完成：

- 工具来源工程：SVN `^/S3-5/KEWEI/Easy6_fastslow-61-IOMAP`，工作副本 r7122，调试工具属于未提交修改。
- 迁移目标工程：Git `master`，提交 `764815b06e2a104dce5fbb80f69d90c92698a258`；迁移时工作区原本已经包含其他未跟踪文件，本次迁移未修改或清理这些既有文件。

### 10.1 迁移的核心文件

当前统一方案从桌面通用模板复制以下共享调试核心文件到目标工程同名位置。KEWEI-61、HC-SX-Host 和桌面模板中的这些核心脚本保持完全一致，工程差异不再写进核心脚本：

| 文件 | 迁移后是否单独修改 | 作用 |
| --- | --- | --- |
| `Tools/AutoDebugHold.js` | 否 | 常驻 DSS 后台，执行共享命令并维护断点、状态和事件。 |
| `Tools/StartSharedDebug.ps1` | 否 | 读取集中配置、建立会话并启动 DSS。 |
| `Tools/RunSharedDebug.ps1` | 否 | 从会话文件可靠启动 DSS。 |
| `Tools/SendSharedDebugCommand.ps1` | 否 | AI向共享队列提交命令。 |
| `Tools/SharedDebugPanel.ps1` | 否 | 操作人员使用的图形面板。 |
| `Tools/BuildProject.ps1` | 否 | 读取集中配置并调用目标工程的 makefile。 |

目标工程另外新增：

| 文件 | 作用 |
| --- | --- |
| `Tools/SharedDebugConfig.ps1` | 集中保存目标工程的 CCS、构建、`.ccxml`、`.out`、源码和默认监视配置。 |
| `打开共享调试面板.bat` | 双击启动面板。 |
| `AGENTS.md` | 让后续 AI 在目标工程中遵守同一个持续调试与共享会话规则。 |

桌面模板另有 `docs/XDS2xx共享调试面板迁移说明.md`，用于说明复制布局和首次配置。目标工程不再重复生成一份“使用说明”；KEWEI-61 中当前这份完整使用手册继续保留，作为主要使用与答疑文档。

`Tools/AutoDebug.ps1` 和 `Tools/AutoDebug.js` 是早期的一次性调试入口，不是共享面板的运行依赖，本次没有迁移。`bfe2.exe`、`link.txt` 和编译后处理批处理属于各工程自己的构建链，也不应从来源工程覆盖到目标工程。

### 10.2 如何识别目标配置

迁移前需要在目标工程内确认以下内容，不能只替换工程名称：

1. 从 `.project`、`.ccsproject` 和 `.cproject` 确认真正的 CCS 工程目录与目标芯片。
2. 查找当前有效的 `.ccxml`，确认连接类型和器件。
3. 查找最新的带调试符号 `.out`，不要误用旧备份或 IAR 输出。
4. 从生成的 makefile 确认实际构建目录和输出名称。
5. 确认源码根目录以及默认监视变量确实存在。

本次在目标工程中识别到：

- CCS 工程目录：`projects/Windows`。
- CPU：TMS320F28335。
- 连接：XDS2xx USB Onboard。
- 目标配置：`projects/Windows/targetConfigs/TMS320F28335.ccxml`。
- 当前构建目录：`projects/Windows/Debug`。
- 当前程序：`projects/Windows/Debug/Easy6_STD.out`。
- 源码根目录：`Easy6/Source`。
- `errPLC`、`ipstep`、`actionrun`、`cliprun` 均能在目标源码中找到。

目标工程中还存在 `zl/Easy6_STD.out` 和 IAR 的 `prj/iar/Debug/Exe/HC_SXL.out`，但它们不是当前 CCS Debug 构建产生的最新目标，因此没有配置到共享调试工具中。

### 10.3 目标工程集中配置

共享调试采用集中配置，是为了把“通用调试能力”和“具体工程路径”分开：

- `AutoDebugHold.js`、面板、构建、启动和 AI 命令脚本保持通用，不写具体工程名称。
- 每个工程只在 `Tools/SharedDebugConfig.ps1` 中保存自己的路径和默认监视变量。
- 工程目录、构建配置或程序名称变化时，只修改集中配置，不分别修改多个核心脚本。
- 更新共享调试功能时可以同步替换核心脚本，同时保留各工程原有配置。

七个配置项的含义如下：

| 配置项 | 作用 | 通常何时修改 |
| --- | --- | --- |
| `CcsRoot` | CCS安装根目录，用于定位 DSS、样式文件和 `gmake.exe`。 | CCS安装位置或版本改变时。 |
| `RuntimeDirectory` | 保存 `current-session.json`、状态、事件和命令队列。 | 通常保持为工程根目录下的 `Debug/AutoDebug`。 |
| `BuildDirectory` | 包含当前构建配置 `makefile` 的目录，Build按钮在此运行。 | Debug/Release配置或 CCS工程位置改变时。 |
| `TargetConfig` | 当前芯片和仿真器使用的 `.ccxml`。 | 芯片、探针或目标配置改变时。 |
| `Program` | 加载符号或烧录时使用的、带调试信息的 `.out`。 | 输出文件名或构建配置改变时。 |
| `SourceRoot` | 用于比较源码与 `.out` 时间、判断符号是否过期的源码根目录。 | 源码目录结构改变时。 |
| `DefaultWatch` | 新共享会话和面板初始显示的默认监视表达式。 | 目标工程的核心状态变量不同时。 |

这些配置由不同入口共同读取：

- `StartSharedDebug.ps1` 使用 `CcsRoot`、`RuntimeDirectory`、`TargetConfig`、`Program`、`SourceRoot` 和 `DefaultWatch`。
- `BuildProject.ps1` 使用 `CcsRoot`、`BuildDirectory` 和 `RuntimeDirectory`。
- `SharedDebugPanel.ps1` 与 `SendSharedDebugCommand.ps1` 使用相同的 `RuntimeDirectory`，保证操作人员和 AI 进入同一个会话。

因此，工程适配只修改 `SharedDebugConfig.ps1`；除非调试功能本身需要升级，否则不修改其他核心脚本。

HC-SX-Host 的 `Tools/SharedDebugConfig.ps1` 使用如下配置：

```powershell
[ordered]@{
    CcsRoot = 'C:\software\CCS\ccs'
    RuntimeDirectory = Join-Path $ProjectRoot 'Debug\AutoDebug'
    BuildDirectory = Join-Path $ProjectRoot 'projects\Windows\Debug'
    TargetConfig = Join-Path $ProjectRoot 'projects\Windows\targetConfigs\TMS320F28335.ccxml'
    Program = Join-Path $ProjectRoot 'projects\Windows\Debug\Easy6_STD.out'
    SourceRoot = Join-Path $ProjectRoot 'Easy6\Source'
    DefaultWatch = @('errPLC', 'ipstep')
}
```

这样迁移到下一工程时，优先修改一个配置文件，不再分别到启动器、面板、命令脚本和构建脚本中查找硬编码路径。

### 10.4 针对目标工程做出的适配

1. 七个核心脚本保持不变，全部从 `SharedDebugConfig.ps1` 取得工程配置。
2. HC-SX-Host 的 `SharedDebugConfig.ps1` 将构建目录设为 `projects/Windows/Debug`，因此 Build按钮会调用该目录中的 `makefile`。
3. 运行记录仍统一写到工程根目录的 `Debug/AutoDebug`，面板和 AI 总是进入同一个命令队列。
4. 默认监视变量由集中配置提供，目前只包含 `errPLC` 和 `ipstep`；`PC`、`actionrun`、`cliprun` 需要时手动添加。
5. 目标工程 `.gitignore` 增加 `/Debug/AutoDebug/`，避免会话日志、状态和命令文件进入 Git。
6. 目标工程根目录保留共享调试专用 `AGENTS.md`，因此可以继续使用“开始联合调试”或“接管当前联合调试”的简短说法。
7. 启动入口统一使用 `.bat`，避免 `.cmd` 被 CCS 当成链接器命令文件加入构建。

### 10.5 迁移后的检查流程

在不访问硬件、不编译的情况下先完成：

1. 检查全部 PowerShell 文件语法。
2. 执行 `SharedDebugConfig.ps1`，确认配置解析后的路径全部指向目标工程。
3. 确认 DSS、`.ccxml`、`.out`、源码目录和 makefile 实际存在。
4. 确认 `AutoDebugHold.js` 与来源工程核心脚本一致。
5. 确认根目录启动批处理指向目标工程自己的 `Tools/SharedDebugPanel.ps1`。

静态检查通过后，现场验证顺序建议为：

1. 断开 CCS Debug 会话。
2. 双击 `打开共享调试面板.bat`。
3. 点击“连接”，确认状态进入 `RUNNING` 或 `HALTED`。
4. 先只读取 `errPLC`、`ipstep`，验证符号和运行中读取。
5. 添加一个无动作风险的源码断点，验证命中位置和删除断点。
6. 明确得到允许后再测试写变量、Resume、编译和烧录。

编译成功不等于目标板已经更新；连接成功也不等于执行过烧录。迁移验证必须分别记录编译、连接、符号加载、烧录和运行状态。

迁移当时的静态检查结果：7个 PowerShell 脚本语法通过，HC-SX-Host 的 CCS/DSS、构建目录、makefile、`.ccxml`、`.out` 和源码目录均存在。目标工程当前 `projects/Windows/Debug/Easy6_STD.out` 的时间早于最新源码 `Easy6/Source/plcsubs.h`，因此首次连接会提示符号可能过期；需要按最新源码打行断点时，应先由操作人员决定是否重新编译并烧录。该次迁移没有执行编译、连接、烧录或 CPU 运行控制。

### 10.6 统一后的维护方式

- 桌面目录 `C:\Users\Harry\Desktop\项目杂件\共享调试面板` 是通用迁移模板。
- 模板默认配置以 HC-SX-Host 的目录结构作为可执行示例；迁移到其他工程后，必须根据目标工程核对并修改 `SharedDebugConfig.ps1`，不能将示例路径当成通用事实。
- KEWEI-61 与 HC-SX-Host 只在各自的 `Tools/SharedDebugConfig.ps1` 中保存不同工程配置。
- 七个核心脚本在 KEWEI-61、HC-SX-Host 和桌面模板中应保持一致。核心功能更新时应同步三处，工程路径变化只修改对应配置文件。
- KEWEI-61 的 `docs/XDS2xx共享调试面板使用手册.md` 保留为完整使用手册；桌面模板只保留迁移说明，HC-SX-Host 不再保存重复副本。
