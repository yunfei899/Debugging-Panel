# XDS2xx 共享调试面板迁移说明

## 文档定位

本文是共享调试工具包的统一迁移入口。将本文路径和目标 CCS 工程路径提供给 AI，AI 应先依据本文识别目标工程，再修改目标工程配置，不得直接套用示例路径。

本文主要回答“如何把工具适配到一个新工程”，不能完全替代以下两类文档：

- `XDS2xx共享调试面板使用手册.md`：面向操作人员，说明面板按钮、变量读写、断点、状态、日志和结束调试方法。
- `XDS2xx半自动化联机调试流程.md`：面向 AI 和维护人员，说明共享会话架构、命令、安全边界、持续监视规则和故障排查。

建议把这两份文档也放入模板的 `docs` 目录，但不能把某个工程的路径、版本号、变量案例和历史验证结论当成所有工程的事实。复制后需要先完成“文档通用化检查”。

## 迁移方法

把本目录中的内容合并到目标 CCS 工程根目录：

```text
目标工程/
├─ Tools/
├─ docs/
├─ AGENTS.md
└─ 打开共享调试面板.bat
```

不要把“共享调试面板”整个目录作为子目录放进目标工程。`Tools`、`docs`、`AGENTS.md` 和启动批处理应位于上述位置。

目标工程已有 `AGENTS.md` 时合并其中的 XDS2xx 规则，不要覆盖原有工程规则。

## AI适配任务的输入

开始适配前，至少向 AI 提供：

1. 本迁移说明的完整路径。
2. 目标 CCS 工程根目录。
3. 实际使用的仿真器；不是 XDS2xx 时必须明确说明。
4. 是否只做静态迁移，还是允许编译、连接或烧录。

没有得到额外授权时，AI只进行文件迁移、配置修改和静态验证，不执行编译、连接、烧录、复位、Suspend、Resume或变量写入。

## AI必须先识别的工程信息

AI不得根据目录名或其他工程的配置推断目标。应在目标工程内依次确认：

1. 实际版本控制类型和当前版本；Git、SVN或无版本控制要分别判断。
2. `.project`、`.ccsproject`、`.cproject` 所在位置和当前构建配置。
3. 目标芯片与仿真器类型。
4. 当前有效的 `.ccxml`，避免误用旧工程或其他探针配置。
5. 当前构建目录及其中的 `makefile`。
6. 当前 CCS 构建生成、带调试符号的 `.out`；不能误选IAR输出、备份目录或旧发布文件。
7. C/C++源码根目录。
8. 默认监视变量是否确实存在；默认建议只使用 `errPLC` 和 `ipstep`，不存在时按目标工程实际变量调整。

如果存在多个合理候选并会影响烧录或调试目标，AI应停止猜测并向用户确认。

## 必须配置的项目

打开目标工程中的 `Tools/SharedDebugConfig.ps1`。配置原则和四个必须填写的相对路径如下。

### 为什么使用集中配置

共享调试的核心脚本在不同工程中保持一致，所有工程差异集中放在 `Tools/SharedDebugConfig.ps1`。这样做有三个目的：

1. 迁移到新工程时只确认和修改一处配置，不在面板、构建、启动和 AI 命令脚本中重复替换路径。
2. 更新共享调试功能时可以统一替换核心脚本，不覆盖各工程自己的目标配置。
3. 静态检查可以直接检查一个配置对象，较容易发现误用旧 `.out`、旧 `.ccxml` 或错误构建目录。

配置项说明：

| 配置项 | 作用 | 迁移时的处理 |
| --- | --- | --- |
| `CcsRoot` | CCS安装根目录，用于定位 DSS 和 `gmake.exe`。 | 默认是 `C:\software\CCS\ccs`，本机不同则修改。 |
| `RuntimeDirectory` | 保存共享会话状态、事件和命令队列。 | 通常保持 `Debug\AutoDebug`，不要与构建目录混淆。 |
| `BuildDirectory` | 包含目标构建配置 `makefile` 的目录。 | 必须根据 Debug/Release 和实际 CCS工程位置填写。 |
| `TargetConfig` | 当前芯片与仿真器对应的 `.ccxml`。 | 必须确认，不能看到同名文件就猜测。 |
| `Program` | 加载符号或烧录所用的带调试信息 `.out`。 | 必须确认是当前 CCS构建输出，不使用IAR输出或旧备份。 |
| `SourceRoot` | C/C++源码根目录，用于检查源码与 `.out` 的新旧关系。 | 必须指向本轮调试使用的源码。 |
| `DefaultWatch` | 新会话和面板初始监视的表达式。 | 默认仅 `errPLC`、`ipstep`；目标工程不存在时按实际调整。 |

`StartSharedDebug.ps1`、`BuildProject.ps1`、`BuildAndDownload.ps1`、`SharedDebugPanel.ps1` 和 `SendSharedDebugCommand.ps1` 都读取该配置。工程适配只修改 `SharedDebugConfig.ps1`；除非修改共享调试功能本身，否则不修改其他核心脚本。

### 四个必须填写的相对路径

```powershell
$buildDirectoryRelative = '包含 makefile 的构建目录'
$targetConfigRelative = '目标 .ccxml 文件'
$programRelative = '带调试符号的 .out 文件'
$sourceRootRelative = 'C/C++ 源码根目录'
```

例如 CCS 工程结构为：

```text
projects/Windows/Debug/makefile
projects/Windows/Debug/Easy6_STD.out
projects/Windows/targetConfigs/TMS320F28335.ccxml
Easy6/Source/
```

则配置为：

```powershell
$buildDirectoryRelative = 'projects\Windows\Debug'
$targetConfigRelative = 'projects\Windows\targetConfigs\TMS320F28335.ccxml'
$programRelative = 'projects\Windows\Debug\Easy6_STD.out'
$sourceRootRelative = 'Easy6\Source'
```

如果 CCS 不在 `C:\software\CCS\ccs`，还要修改 `CcsRoot`。默认监视仅包含 `errPLC` 和 `ipstep`，可按工程变量修改 `DefaultWatch`。

桌面模板默认使用上述 HC-SX-Host 目录结构作为可执行示例。复制到其他工程后，AI必须根据目标工程重新核对这四个路径，不得直接使用示例中的 `.out`、`.ccxml` 或源码目录。

`RuntimeDirectory` 默认使用工程根目录下的 `Debug/AutoDebug`，一般不需要修改。该目录只存放运行状态、事件日志和命令队列，不是 CCS 构建输出目录。

## AI允许修改的范围

一次普通迁移应限制在：

- 合并模板中的 `Tools` 目录。
- 创建或修改 `Tools/SharedDebugConfig.ps1`。
- 添加根目录的 `打开共享调试面板.bat`。
- 将 XDS2xx 协作规则合并到目标工程现有 `AGENTS.md`。
- 在 Git或SVN忽略规则中排除 `Debug/AutoDebug`。
- 按用户要求修订共享调试文档中的目标工程配置说明。

不应覆盖目标工程已有的构建后处理工具、链接器命令文件、业务源码或整个 `AGENTS.md`。启动入口必须使用 `.bat`，不能使用 `.cmd`，因为 CCS可能把根目录 `.cmd` 当作链接器命令文件加入构建。

## 迁移后检查

1. 确认 `BuildDirectory/makefile` 存在。
2. 确认 `TargetConfig` 指向当前硬件使用的 `.ccxml`。
3. 确认 `Program` 是当前 CCS 构建生成且带调试符号的 `.out`。
4. 确认 `SourceRoot` 包含本次调试使用的源码。
5. 在 `.gitignore` 或 SVN忽略属性中排除 `Debug/AutoDebug` 运行记录。
6. 先做 PowerShell 语法和路径检查，再由操作人员决定是否编译、连接或烧录。

迁移后手动运行 `BuildAndDownload.ps1` 时，必须显式传入 `-AllowHardware -AllowProgramLoad`。图形面板会在“编译并下载”前显示安全确认，未确认时不会连接或改写目标板。

7. 确认6个核心脚本没有写入目标工程专属路径，工程差异仅保存在 `SharedDebugConfig.ps1`。
8. 确认根目录不存在 `打开共享调试面板.cmd`，生成的 makefile 也没有残留该依赖。
9. 报告目标源码是否晚于 `.out`；源码较新时只能提示符号可能过期，不得自动编译或烧录。

## 启动与协作

配置完成后，双击 `打开共享调试面板.bat`。CCS可以保持打开用于编辑，但必须断开其 Debug 会话，避免两个会话同时占用 XDS2xx。

操作人员使用 `Tools/SharedDebugPanel.ps1`，AI使用 `Tools/SendSharedDebugCommand.ps1`，双方共用一个 DSS/XDS2xx 会话。断点命中后默认保持暂停，未经操作人员明确指令，AI不自动写值、继续、清断点、烧录或断开连接。

## 可直接引用给 AI 的指令

把下面两处路径替换为实际位置即可：

```text
请阅读“<共享调试模板路径>\docs\XDS2xx共享调试面板迁移说明.md”，将这套共享调试工具适配到“<目标CCS工程根目录>”。

先识别目标工程的实际VCS、CCS工程目录、芯片、仿真器、构建目录、makefile、ccxml、带调试符号的out和源码根目录，再填写Tools/SharedDebugConfig.ps1。不要沿用示例工程路径，不要覆盖现有AGENTS.md，只合并XDS2xx规则。启动入口使用bat，不得使用cmd。

本轮只允许迁移文件、修改配置和执行静态检查；不要编译、连接、烧录、复位、暂停、继续或写变量。完成后列出迁移文件、实际配置、未确认项和验证结果。
```

如果同时提供了完整使用手册和半自动化流程，可以增加：

```text
同时阅读模板docs目录中的“XDS2xx共享调试面板使用手册.md”和“XDS2xx半自动化联机调试流程.md”。其中出现的旧工程路径、版本号、变量案例和历史验证只作为示例，不得直接写入当前目标工程；请根据当前工程改写相关配置章节。
```

## 文档通用化检查

如果从已有工程复制两份完整文档到模板，至少检查并改写以下内容：

### 使用手册

- “当前适用范围”中的芯片、`.ccxml`、`.out` 和源码目录。
- 断点示例中的本机绝对路径和业务文件行号。
- 默认监视变量是否适用于目标工程。
- 指定工程的问答、迁移案例和版本说明应标记为示例，不能写成通用结论。

### 半自动化联机调试流程

- 工程VCS、版本号和工作副本状态。
- 芯片、探针、目标配置和 Real-time Mode 前提。
- 早期一次性 `AutoDebug.ps1/AutoDebug.js` 的说明；目标未迁移这两个文件时不能把它们列为可用入口。
- 业务源码、断点、变量和报警案例。
- “当前已验证事实”只能保留在实际完成验证的工程中；复制到模板时应明确标为来源工程历史，不能当作新工程验证结果。

## 文档迁移建议

目前通用模板只具备本迁移说明。为了让操作人员和AI都能只通过模板获得完整上下文，建议由用户手工把以下两份文件复制到模板的 `docs` 目录：

```text
XDS2xx共享调试面板使用手册.md
XDS2xx半自动化联机调试流程.md
```

复制完成后，再让 AI 按上一节执行通用化修改。这样可以保留完整操作知识，同时避免AI把 KEWEI-61 的工程事实误套到新工程。
