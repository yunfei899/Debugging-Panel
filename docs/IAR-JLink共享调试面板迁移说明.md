# IAR/J-Link 共享调试面板迁移说明

## 文档定位

本文主要供首次适配时的 AI 阅读，操作人员参考。操作步骤和“目录＋版本类型”示例见[使用手册](IAR-JLink共享调试面板使用手册.md)；后台实现、命令和故障处理见[半自动化联机调试流程](IAR-JLink半自动化联机调试流程.md)。AI 先读取目标工程的 [AGENTS.md](../AGENTS.md)。

本分支适配 IAR/J-Link，不使用 CCS DSS。用户将对应版本面板放进目标工程，由 AI 配置 `Tools/SharedDebugConfig.ps1` 即可，不要求独立工具或额外三层配置。文中的路径和硬件参数是来源样本，不能视为新工程已适配。

## AI 识别工程类别与调试后端

用户提供的版本类型是识别线索，最终以目标工程文件和实际版本控制信息为准，不按目录名称推断当前分支包含的工程。

| 用户提供的工程类别 | 可以共用的部分 | 每个工程必须单独识别并保存的配置 |
| --- | --- | --- |
| 大版本 CCS 工程（通常 Git） | CCS DSS 调试后端。 | 工程文件位置、构建配置、芯片与探针、`.ccxml`、对应 `.out`、源码目录、默认监视变量。 |
| 小版本 CCS 工程（通常 SVN） | 同一个 CCS DSS 后端，主要是工程目录结构不同。 | 同上，不能根据大版本工程路径或目录名称推断程序文件。 |
| SXL 核心 IAR 工程（通常 Git） | IAR 构建和 C-SPY 下载；现有 IAR 版持续共享调试采用 J-Link GDB Server＋GDB/MI 后端。 | `.ewp`、构建配置、自定义构建变量、符号文件、C-SPY 参数、初始化宏、芯片与探针接口、源码及监视变量。 |
| EtherCAT 核心 IAR 工程（通常 Git） | 已检查的同族样本可与 SXL 共用 IAR 后端。 | 各工程自己的构建及下载配置、符号文件、初始化宏、内存布局、源码及监视变量。 |

Git、SVN 用于识别实际版本、工作区修改和忽略规则，本身不决定调试后端；每个目标工程都要分别确认。

上述 IAR 同族判断来自已检查样本：`.ewp` 的 `OGChipSelectEditMenu` 为 `R7S910002`，生成的 driver 参数为 Cortex-R4、J-Link＋SWD，`.ewd` 和主要初始化宏一致。此结论不能扩展为所有 SXL 或 EtherCAT 硬件都相同；实际工程中应重新核对。样本的链接内存布局存在差异，必须使用本工程自己的 `.out`，不得沿用其他工程的变量地址或断点地址。

可共用后端不等于所有能力已经联机验证。IAR 构建下载与持续共享调试分别报告验证状态；不得把 CCS 的运行中读取、复位流程或历史联机结果当成 IAR 的既有能力。普通静态适配不自动执行初始化宏、启动调试器或重写后端；发现工具版本与工程类型不匹配时先报告。

## AI 适配任务的输入

面板已放入工程时，用户只需提供：

1. 工程目录。
2. 版本类型：SXL 核心 IAR 工程或 EtherCAT 核心 IAR 工程。

AI 自行读取工程内迁移说明、工程定义和本机工具路径；不要求用户另填 `.ewp`、构建目录、`.out`、启动宏和安装路径。模板尚未放入目标时，才需提供工具来源目录。脚本默认路径只是识别线索，不能直接照用。

默认仅识别、配置、合并必要文件和静态检查，不编译、不连接、不烧录、不复位、不暂停或运行 CPU、不写变量。存在多个无法确定的工程、构建配置、下载参数或探针候选时，只询问影响目标选择的关键项；文件缺失明确报告。配置与现场描述冲突时先确认，不通过启动调试器猜测接口。

已放好的文件不重复复制，已有正确配置不重复改写。完成后列出配置、识别依据、检查结果和未确认项。

## 当前实现架构

```text
IAR .ewp
   │
   ├─ IarBuild.exe                         编译所选构建配置
   └─ cspybat --download_only              使用 IAR 工程宏/下载器下载
        --leave_target_running              按配置请求保持运行后释放 J-Link

J-Link GDB Server ── arm-none-eabi-gdb/MI  常驻实时会话
                              │
             ┌────────────────┴────────────────┐
             │                                 │
       SharedDebugPanel.ps1             SendSharedDebugCommand.ps1
             │                                 │
             └──────── commands/*.cmd ─────────┘
```

本分支使用 `cspybat` 完成一次性下载，使用 J-Link GDB Server＋GDB/MI 承担持续交互。下载与共享连接严格串行，面板和 AI 只写同一个命令队列；不能把反复启动 C-SPY 当作持续共享会话。图中 `--leave_target_running` 仅在 `IarBreakResetGo=true` 时添加，宏的实际复位、初始化和运行效果须按目标验证。

这意味着实时表达式解析采用 GDB 语法，和 C-SPY 表达式并不完全等价；IAR 工程仍负责构建、符号文件和带目标宏的下载。

## 来源样例与实际配置入口

模板保留了来源 IAR 工程的默认值。以下用于说明如何映射配置，不表示这些文件在模板目录或新目标中存在；具体路径和硬件信息由 AI 从目标工程识别。

| 配置字段 | 来源示例或识别方式 |
| --- | --- |
| `IarProject` / `IarConfiguration` | 示例为 `prj/iar/HC_SXL.ewp` / `Debug`；根据 `.eww`、`.ewp` 确认实际配置。 |
| `Program` | 示例为 `prj/iar/Debug/Exe/HC_SXL.out`；绑定实际构建输出，不能用发布 `.bin` 或旧 `.out`。 |
| `IarCustomArgVars` | 示例为 `prj/iar/HC_SXL.custom_argvars`；检查工程使用的自定义变量与 `-varfile`。 |
| `CspyGeneralSettings` / `CspyDriverSettings` | 示例为 `prj/iar/settings/HC_SXL.Debug.general.xcl` / `.driver.xcl`；核对内部绝对路径、驱动、器件、接口和宏引用。 |
| `MacroFile` | 示例为 `prj/iar/startup/spi/RZT1_init_boot.mac`；必须与实际 `.xcl` 引用相符。 |
| `IarRoot` / `IarBuild` / `CspyBat` | 由本机安装和目标所需工具版本确定，不照搬 `C:\software\IAR`。 |
| `Gdb` / `JLinkGdbServer` | 按本机安装及目标联机验证确定；模板版本仅为示例。新版、旧版都需验证连接、运行后暂停和变量读取，不根据版本号认定兼容。 |
| `TargetDevice` / `JLinkDevice` | 示例为精确器件 `R7S910002`；`JLinkDevice` 非空时按精确器件连接，`JLinkCpu` 仅为空时后备。 |
| `HardwareInterface` / `JLinkSpeedKHz` / `JLinkSerialNumber` | 示例为 SWD / 1000 / 空；按目标配置和实际探针核对。 |
| `GdbServerHost` / `GdbServerPort` | 示例为 `127.0.0.1` / `2331`；检查占用，不结束其他工程会话抢占。 |
| `SourceRoots` / `DefaultWatch` | 指向目标源码和已确认的变量，模板变量示例为 `errPLC`、`ipstep`。 |
| `IarBreakResetGo` | 模板为 `true`，会请求下载后保持运行并在共享接管后 Go；不是静态配置验证步骤。 |
| `RuntimeDirectory` | 通常保持工程根目录的 `Debug/AutoDebug`，保存本工程会话和命令队列。 |

来源工程曾出现“口头称 JTAG、driver 实际为 SWD”的差异。这只是历史案例；新工程要比较 `.ewd`、driver 参数和实际接线，不因所有示例写 SWD 就认定现场相同。

生成的 `.cspy.bat`、`.xcl` 可能被 IDE 重写并含旧绝对路径。应以目标当前工程配置核对这些生成文件，不把历史导出文件当作永久正确配置；不能为静态识别而自动启动 IDE 调试重新导出。

## 迁移到其他 IAR 工程

迁移后的目录结构：

```text
目标工程/
├─ Tools/
│  ├─ SharedDebugConfig.ps1
│  ├─ BuildProject.ps1
│  ├─ BuildAndDownload.ps1
│  ├─ IarCspyDownload.ps1
│  ├─ StartSharedDebug.ps1
│  ├─ RunSharedDebug.ps1
│  ├─ IarGdbSession.ps1
│  ├─ SendSharedDebugCommand.ps1
│  └─ SharedDebugPanel.ps1
├─ docs/
├─ AGENTS.md
└─ 打开共享调试面板.bat
```

已有 `AGENTS.md` 合并 IAR 协作规则，不整份覆盖；保留目标业务源码、构建后处理、链接脚本、Flash Loader 和初始化宏。普通适配优先修改 `Tools/SharedDebugConfig.ps1` 中的工程差异：

- `IarProject`、`IarConfiguration`、`IarCustomArgVars`、`Program`；
- `CspyGeneralSettings`、`CspyDriverSettings`、`MacroFile`；
- `Gdb`、`JLinkGdbServer`、`JLinkDevice`、`HardwareInterface`、`JLinkSpeedKHz`；
- `SourceRoots`、`DefaultWatch`。

迁移检查顺序：

1. 分别确认目标实际 VCS、版本、工作区修改，以及 `.eww`/`.ewp`/`.ewd` 和所选构建配置。目录名、Git/SVN 和 Debug/Release 名称本身都不足以判定真实目标。
2. 从工程设置解析对应 ELF/OUT、源码、链接布局和调试信息选项，排除旧发布文件、备份及其他构建配置。时间戳或文件存在不能证明符号与现板一致。
3. 检查 `IarCustomArgVars` 中构建变量，以及 general/driver 参数的内部路径；输出、宏、DDF、驱动和下载配置必须属于同一目标。
4. 核对芯片、探针接口、序列号、下载宏和 Flash Loader。初始化宏可能复位、清 RAM、写寄存器或运行 CPU，不能当作无扰动连接动作执行。
5. 检查本机 IAR、J-Link、GDB 路径与版本依据；离线符号解析可以单独验证，不能启动 GDB Server 来探测帮助或设备。
6. 使用启动批处理实际调用的 Windows PowerShell 5.1 做语法检查，并检查 XAML 和文档引用。保持原文件编码、BOM 和换行；仅 PowerShell 7 解析通过不足以证明双击入口可用。
7. 按实际 Git/SVN 忽略规则排除 `Debug/AutoDebug`；不更改共享脚本的工程根目录约定，不使用其他工程的命令队列。
8. 报告实际配置、检查结果及未验证项。缺少产物或关键参数时，完成不依赖它们的识别工作并明确缺失项，不自动编译或连接。

静态适配完成后，再根据用户授权单独进行连接、读变量、断点、下载及运行验证。不把连接测试列为默认迁移步骤。

## 权限和安全边界

以下操作必须显式带参数：

```powershell
# 只建立实时共享会话，连接可能使 CPU 暂停
.\Tools\StartSharedDebug.ps1 -AllowHardware

# 编译并使用 IAR C-SPY 下载器写入目标
.\Tools\BuildAndDownload.ps1 -AllowHardware -AllowProgramLoad
```

启动器的 `-ResumeTarget`、`-RestartTarget` 需要 `-AllowRun`。组合下载脚本会根据 `IarBreakResetGo` 自动传入运行参数；模板默认值为 `true`，因此批准该流程前必须明确其复位和运行影响。“运行 Go”按钮仍通过队列提交 `RESUME`。没有得到授权时，不执行编译、连接、下载、复位、Resume、Suspend 或变量写入。

## 能力边界

- 共享会话是 J-Link GDB Server + GDB/MI 会话，不是 C-SPY GUI 会话。
- 下载阶段使用 C-SPY 工程宏，因此下载完成后才启动实时 GDB 会话；两次连接严格串行。
- 变量读取和写入默认要求 CPU 已暂停。目标运行时不会为了刷新表达式而暗中停核；面板会记录拒绝原因。
- `file.c:line` 和 `@0x地址` 断点会转换为 GDB 断点。复杂 C-SPY 专用表达式、C-SPY 专用宏和 IAR 特殊格式不保证可用。
- GDB Server 是否支持 `R7S910002`、IAR 生成的调试信息和目标板的外部 SPI Flash，必须用现场版本做一次验证；静态迁移不能替代这次验证。
- `Tools/AutoDebugHold.js` 已改为停用提示，不再加载 TI DSS。

## 静态适配与联机验收分别记录

静态检查按前述清单执行，不启动后台、不生成假会话。不要用启动 GDB Server 的方式探测帮助参数；旧版对未知参数可能直接进入连接流程。

本分支的持续共享实现不等于对所有目标完成稳定性验收。下载成功、首次连接、断点命中、暂停后恢复和持续运行应分别验证；只有日志支持的步骤才能标为通过。出现后台退出、无效寄存器或状态停止刷新，应报告监视失效，不反复 Go。

新目标的验证记录使用自己的 VCS、配置、符号及现场结果。来源样例和模板提交说明不作为新工程的验收依据。

## 模板与目标适配记录

IAR-Project 模板提交通用脚本、三份操作/迁移/实现文档和协作规则。目标工程的适配记录（本机绝对路径、探针序列号、产物哈希、分支提交和现场日志）留在目标本地，不复制到模板；可在目标的 .git/info/exclude 中忽略。可复用问题提炼为通用规则，不携带现场数据。

迁移后核验新按钮：下载并调试使用现有 OUT，初始化后接管暂停；断开时运行中关闭远程连接，暂停时先恢复运行，不先停核；Restart 为 J-Link 复位暂停，不等同于 IAR 专用宏。旧后台不能热加载脚本，更新后需在用户授权范围内重新建立会话。
