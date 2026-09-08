# 项目协作规则

## IAR/J-Link 持续联机调试

1. 用户开始一轮联机调试后，只要没有明确说“结束调试”“停止监视”或“断开连接”，就把本轮调试视为持续进行中的会话。
2. 持续保留用户指定的断点和用户要求监视的变量。用户暂停聊天或操作手控器、硬件期间，保持后台共享调试会话，不因一轮回复结束而主动断开。
3. 后续每次继续调试前，先读取 `Debug/AutoDebug/current-session.json` 指向的 `status.txt` 和 `events.log`，以现场实际状态为准，不假定 CPU、断点或变量仍与上次回复时相同。
4. 断点命中后记录 PC、实际断点位置和关注变量快照，并默认保持 CPU 暂停、等待用户指令。用户未明确要求时，不自动 Resume、Suspend、单步、写值、清除断点、重新烧录或断开连接。
5. 用户通过 `Tools/SharedDebugPanel.ps1` 操作后，AI 应读取事件日志确认操作结果；AI 通过 `Tools/SendSharedDebugCommand.ps1` 与用户共用同一 J-Link GDB Server/GDB 会话，不另外建立抢占 J-Link 的调试会话。
6. 如果 GDB 进程、J-Link GDB Server 退出、目标断开、状态文件停止更新或变量读取持续失败，立即说明持续监视已经失效，不得声称仍在监视。
7. 目标工程的共享调试路径集中配置在 `Tools/SharedDebugConfig.ps1`；迁移或调整构建配置时优先修改该文件，不把工程路径散落到其他脚本。
8. IAR 工程首次迁移和目标配置方法见 `docs/IAR-JLink共享调试面板迁移说明.md`；操作手册见 `docs/IAR-JLink共享调试面板使用手册.md`，实现与命令流程见 `docs/IAR-JLink半自动化联机调试流程.md`。
9. 默认不使用联机调试功能，除非用户特意说明使用。

## 下载与实时调试的区别

1. 编译由 IAR `IarBuild.exe` 完成。
2. 下载阶段使用 IAR `cspybat --download_only`、当前 `.xcl` 和启动宏，完成后释放 J-Link。
3. 持续共享阶段使用单一 J-Link GDB Server + `arm-none-eabi-gdb`/MI。面板和 AI 只通过 `commands/*.cmd` 进入该会话。
4. 模板来源示例的 `HC_SXL.Debug.driver.xcl` 指定 `--drv_interface=SWD`，新目标以实际工程配置为准。用户描述与配置不一致时，连接前必须核对物理接口，确认后同步配置，不能根据描述自动改写。
5. GDB 后端默认不在 CPU 运行时为了刷新变量而隐式停核；变量读写前应先确认安全并暂停 CPU。
