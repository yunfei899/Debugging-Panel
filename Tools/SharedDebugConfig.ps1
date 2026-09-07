[CmdletBinding()]
param(
    [string]$ProjectRoot
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    $ProjectRoot = Split-Path -Parent $PSScriptRoot
}
$ProjectRoot = [IO.Path]::GetFullPath($ProjectRoot)

# 该文件是整个共享调试工具的唯一工程配置入口。
# IAR 负责生成带调试信息的 ELF/OUT，实时共享会话由 J-Link GDB Server
# 和 arm-none-eabi-gdb 共同持有；面板和 AI 只向同一个命令队列提交操作。
$iarRoot = 'C:\software\IAR'
$gdbRoot = 'C:\software\CCS\ccs\tools\compiler\gcc-arm-none-eabi-7-2017-q4-major-win32'
$jlinkRoot = 'C:\Program Files\SEGGER\JLink_V974'

$projectRelative = 'prj\iar\HC_SXL.ewp'
$configuration = 'Debug'
$programRelative = 'prj\iar\Debug\Exe\HC_SXL.out'
$driverSettingsRelative = 'prj\iar\settings\HC_SXL.Debug.driver.xcl'
$macroRelative = 'prj\iar\startup\spi\RZT1_init_boot.mac'
$sourceRootRelative = 'Easy6\Source'
$sourceRootRelatives = @(
    'Easy6\Source',
    'cg_src',
    'driver',
    'prj\iar\startup\spi'
)

$requiredSettings = [ordered]@{
    projectRelative = $projectRelative
    configuration = $configuration
    programRelative = $programRelative
    driverSettingsRelative = $driverSettingsRelative
    sourceRootRelative = $sourceRootRelative
}
$missingSettings = @(
    $requiredSettings.GetEnumerator() |
        Where-Object { [string]::IsNullOrWhiteSpace([string]$_.Value) } |
        ForEach-Object { $_.Key }
)
if ($missingSettings.Count -gt 0) {
    throw "IAR shared debug configuration is incomplete. Edit Tools\SharedDebugConfig.ps1: $($missingSettings -join ', ')"
}

function Resolve-ProjectPath([string]$RelativePath) {
    return [IO.Path]::GetFullPath((Join-Path $ProjectRoot $RelativePath))
}

[ordered]@{
    ProjectRoot = $ProjectRoot
    RuntimeDirectory = Join-Path $ProjectRoot 'Debug\AutoDebug'

    IarRoot = $iarRoot
    IarBuild = Join-Path $iarRoot 'common\bin\IarBuild.exe'
    CspyBat = Join-Path $iarRoot 'common\bin\cspybat.exe'
    CspyServer = Join-Path $iarRoot 'common\bin\CSpyServer.exe'
    IarProject = Resolve-ProjectPath $projectRelative
    IarConfiguration = $configuration
    # C-SPY 下载完成后执行工程要求的 Break -> Reset -> Go，并在退出时保持目标运行。
    IarBreakResetGo = $true
    IarCustomArgVars = Resolve-ProjectPath 'prj\iar\HC_SXL.custom_argvars'
    IarDebugBatch = Resolve-ProjectPath 'prj\iar\settings\HC_SXL.Debug.cspy.bat'
    CspyGeneralSettings = Resolve-ProjectPath 'prj\iar\settings\HC_SXL.Debug.general.xcl'
    CspyDriverSettings = Resolve-ProjectPath 'prj\iar\settings\HC_SXL.Debug.driver.xcl'
    Program = Resolve-ProjectPath $programRelative
    DriverSettings = Resolve-ProjectPath $driverSettingsRelative
    MacroFile = Resolve-ProjectPath $macroRelative

    Gdb = Join-Path $gdbRoot 'bin\arm-none-eabi-gdb.exe'
    GdbRoot = $gdbRoot
    GdbArchitecture = 'arm'

    JLinkRoot = $jlinkRoot
    JLinkGdbServer = Join-Path $jlinkRoot 'JLinkGDBServerCL.exe'
    TargetDevice = 'R7S910002'
    # 新版 J-Link 已支持 R7S910002，共享会话优先使用精确器件名。
    # JLinkCpu 仅在 JLinkDevice 为空时作为通用后备配置。
    JLinkDevice = 'R7S910002'
    JLinkCpu = 'Cortex-A_R'
    # HC_SXL.Debug.driver.xcl 当前实际写的是 --drv_interface=SWD。
    # 用户描述为 JTAG 时，必须先核对线缆/板卡和 IAR 工程设置，再把这里改成 JTAG。
    HardwareInterface = 'SWD'
    JLinkSpeedKHz = 1000
    JLinkSerialNumber = ''
    JLinkJtagConfig = ''

    GdbServerHost = '127.0.0.1'
    GdbServerPort = 2331
    DefaultWatch = @('errPLC', 'ipstep')
    DefaultBreakpoint = @()
    SourceRoot = Resolve-ProjectPath $sourceRootRelative
    SourceRoots = @($sourceRootRelatives | ForEach-Object { Resolve-ProjectPath $_ })
}
