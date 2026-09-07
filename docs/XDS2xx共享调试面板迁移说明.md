# IAR/J-Link 共享调试面板迁移说明

## 文档定位

本文件沿用原来的文件名，内容已经改为适配 IAR 工程。当前目标工程是：

```text
C:\work_file\IAR\HC-SXL-Host-ECAT
```

本方案解决的是“面板和 AI 共用同一个实时调试会话”，不是把两个 IAR/C-SPY 图形调试窗口同时连接到同一个 J-Link。

## 当前实现架构

```text
IAR .ewp
   │
   ├─ IarBuild.exe                         编译 Debug 配置
   └─ cspybat --download_only              使用 IAR 工程宏/下载器下载
        --leave_target_running              执行 Break → Reset → Go 后释放 J-Link

J-Link GDB Server ── arm-none-eabi-gdb/MI  常驻实时会话
                              │
             ┌────────────────┴────────────────┐
             │                                 │
       SharedDebugPanel.ps1             SendSharedDebugCommand.ps1
             │                                 │
             └──────── commands/*.cmd ─────────┘
```

IAR 的 `cspybat` 是批处理入口，当前安装版本没有可直接供 PowerShell 面板长期交互的公开命令通道。因此没有继续使用旧的 TI DSS/XDS2xx 脚本，也没有把每次读写伪装成重新启动一次 C-SPY。实时会话由一个 J-Link GDB Server 和一个 GDB/MI 进程独占；面板、AI 只写同一个命令队列。

这意味着实时表达式解析采用 GDB 语法，和 C-SPY 表达式并不完全等价；IAR 工程仍负责构建、符号文件和带目标宏的下载。

## 当前工程已确认的配置

| 项目 | 当前值 |
| --- | --- |
| IAR 工程 | `prj/iar/HC_SXL.ewp` |
| 构建配置 | `Debug` |
| 调试程序 | `prj/iar/Debug/Exe/HC_SXL.out` |
| IAR C-SPY 通用参数 | `prj/iar/settings/HC_SXL.Debug.general.xcl` |
| IAR C-SPY 驱动参数 | `prj/iar/settings/HC_SXL.Debug.driver.xcl` |
| IAR 启动宏 | `prj/iar/startup/spi/RZT1_init_boot.mac` |
| IAR 目标器件 | `R7S910002`，Cortex-R4 |
| J-Link 实时模式 | 通用 `Cortex-A_R`（当前 J-Link 设备库没有 `R7S910002` 条目） |
| J-Link GDB Server | `C:\software\jlink\JLink_V610g\JLinkGDBServerCL.exe` |
| GDB | `arm-none-eabi-gdb.exe` |
| 运行记录 | `Debug/AutoDebug` |
| 默认监视 | `errPLC`、`ipstep` |

### JTAG/SWD 配置冲突必须先处理

用户描述为 JTAG，但当前生成的 `HC_SXL.Debug.driver.xcl` 中实际存在：

```text
--drv_interface=SWD
```

因此 `Tools/SharedDebugConfig.ps1` 暂时将 `HardwareInterface` 保持为 `SWD`，没有擅自改成 JTAG。使用真实硬件前，必须核对板卡接线、J-Link 接口和 IAR 工程设置；如果实际链路是 JTAG，应同步修改 IAR driver 参数和集中配置，不能只改面板文字。

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

只应首先修改 `Tools/SharedDebugConfig.ps1` 中的工程差异：

- `IarProject`、`IarConfiguration`、`Program`；
- `CspyGeneralSettings`、`CspyDriverSettings`、`MacroFile`；
- `Gdb`、`JLinkGdbServer`、`JLinkDevice`、`HardwareInterface`、`JLinkSpeedKHz`；
- `SourceRoots`、`DefaultWatch`。

迁移检查顺序：

1. 确认 IAR 工程文件和实际 Debug 配置。
2. 确认带调试信息的 ELF/OUT，而不是旧发布文件或备份文件。
3. 确认 C-SPY driver 文件、目标器件、接口和下载宏。
4. 确认 J-Link GDB Server 的版本能够识别目标器件，并确认 GDB 能读取该 IAR 输出的调试信息。
5. 确认源码根目录和默认表达式确实存在。
6. 再进行一次经过现场安全确认的连接测试。

不要把工程路径散落复制到面板、构建和命令脚本中。`Debug/AutoDebug` 仅保存运行状态、日志和命令文件，应加入 Git 忽略规则。

## 权限和安全边界

以下操作必须显式带参数：

```powershell
# 只建立实时共享会话，连接可能使 CPU 暂停
.\Tools\StartSharedDebug.ps1 -AllowHardware

# 编译并使用 IAR C-SPY 下载器写入目标
.\Tools\BuildAndDownload.ps1 -AllowHardware -AllowProgramLoad
```

`-AllowRun` 只在启动时要求自动运行目标时使用；当前面板的普通“继续”仍通过共享队列执行，操作人员应先确认设备安全。没有得到授权时，不应执行编译、连接、下载、复位、Resume、Suspend 或变量写入。

## 能力边界

- 共享会话是 J-Link GDB Server + GDB/MI 会话，不是 C-SPY GUI 会话。
- 下载阶段使用 C-SPY 工程宏，因此下载完成后才启动实时 GDB 会话；两次连接严格串行。
- 变量读取和写入默认要求 CPU 已暂停。目标运行时不会为了刷新表达式而暗中停核；面板会记录拒绝原因。
- `file.c:line` 和 `@0x地址` 断点会转换为 GDB 断点。复杂 C-SPY 专用表达式、C-SPY 专用宏和 IAR 特殊格式不保证可用。
- GDB Server 是否支持 `R7S910002`、IAR 生成的调试信息和目标板的外部 SPI Flash，必须用现场版本做一次验证；静态迁移不能替代这次验证。
- `Tools/AutoDebugHold.js` 已改为停用提示，不再加载 TI DSS。

## 静态验证

未授权连接硬件时，只做文件和脚本检查：

```powershell
.\Tools\SharedDebugConfig.ps1
Get-Content .\prj\iar\settings\HC_SXL.Debug.driver.xcl
Get-Item .\prj\iar\Debug\Exe\HC_SXL.out
```

不要用启动 GDB Server 的方式探测帮助参数；旧版 J-Link GDB Server 对未知参数可能直接进入目标连接流程。
