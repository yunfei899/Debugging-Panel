/*
 * 旧版 CCS/XDS2xx 共享会话入口已停用。
 *
 * 当前 IAR 工程的共享调试后台是：
 *   Tools\IarGdbSession.ps1
 *   J-Link GDB Server + arm-none-eabi-gdb/MI
 *
 * 保留这个文件只是为了让旧的快捷方式给出明确错误，不再加载 TI DSS
 * 或创建第二个调试会话。请使用 Tools\StartSharedDebug.ps1 或根目录
 * “打开共享调试面板.bat”。
 */
throw new Error('AutoDebugHold.js is retired. Use the IAR/J-Link shared debug scripts instead.');
