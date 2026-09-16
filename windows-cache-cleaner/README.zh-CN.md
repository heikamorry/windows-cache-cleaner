# Windows 系统盘缓存清理器

这套脚本用于释放 **C 盘**上的可再生成数据，并把“释放更多空间”和“保留恢复能力”分开处理。目标路径位于其他盘时跳过；Windows 不在 C 盘时跳过其系统维护操作。脚本不会泛扫整个 C 盘，也不会把文档、桌面、下载、项目源码、应用账户数据、Windows Installer、DriverStore、分页文件或系统还原点列为清理目标。

> 保持足够的系统盘空闲空间有利于 Windows 更新、分页和整体稳定性；但频繁清空浏览器、着色器等缓存不会持续提速，缓存重建时首次启动反而可能稍慢。

## 推荐顺序

1. 普通双击 **Run-Analyze.bat**，查看可清理项目和报告。
2. 普通双击 **Run-Cleanup-DryRun.bat**，按 Maximum 范围预演。此步骤会写报告，但不删除缓存、不停止服务、不改系统配置。
3. 保存工作并关闭浏览器、开发工具，等待 Windows 更新安装完成，然后**只选一个清理入口**：日常用 **Run-Cleanup-Safe.bat**；深度清理用 **Run-Cleanup-Admin.bat**；希望在默认保护范围内尽量释放空间，用 **Run-Cleanup-Maximum.bat**，在提示时输入 `Y`。

**Maximum 已包含 Safe 和 Deep 的默认范围，无需按 Safe → Deep → Maximum 重复运行。** 每个入口完成后再运行下一个，避免重叠运行。脚本不会自动重启；若 Windows 提示需要重启，请完成重启后检查 C 盘剩余空间。

所有 BAT 都从普通双击开始，**不要右键“以管理员身份运行”**。启动器先用当前账户的普通权限处理用户缓存，再弹出 UAC 请求，使用**同一个账户**的管理员权限处理 Windows 缓存。系统阶段在后台运行，原窗口会等待并显示退出码；DISM 可能需要几分钟或更久，请等待完成。两个阶段分别生成报告。

若 UAC 要求输入另一个管理员账户的密码，启动器会拒绝账户切换。取消提权时，已完成的用户阶段不会回滚，系统阶段不执行。普通标准用户可只运行下文的 `-Scope User` 命令。实际清理入口若一开始就已提权，会明确拒绝并提示从普通窗口重新启动；分析和预演允许已提权运行。

当前交付不等于已经清理过电脑：开发验证使用语法检查、隔离测试和预演，**没有替你执行真实 C 盘清理**。释放空间不保证系统一定提速，也不能修复磁盘故障或其他性能瓶颈。

## 三个清理级别

| 级别 | 范围 | TEMP 保留策略 |
|---|---|---|
| Safe | 当前用户/Windows 旧临时文件、DirectX/显卡/图标/缩略图缓存、Delivery Optimization | 默认保留最近 7 天 |
| Deep | Safe + 浏览器缓存、应用明确缓存、UWP TempState、Windows Update 下载缓存、DISM 组件清理 | 默认保留最近 2 天 |
| Maximum | Deep + 可重新下载的浏览器模型、受支持的开发工具下载/构建缓存 | 默认保留最近 1 天 |

浏览器 Service Worker/CacheStorage 可能承载 PWA 离线内容，因此即使 Maximum 也不会自动删除；必须显式使用 -IncludeOfflineWebCaches。

Maximum 会纳入以下可重新生成但可能很大的内容：

- Chrome/Edge 用户数据根的 shader、CRX 和下载模型缓存
- 受支持的 npm、pip、Yarn、Go 下载/构建缓存，以及 NuGet HTTP/插件缓存；具体支持范围以分析报告为准
- VS Code、Teams、Discord、Slack 的明确缓存叶目录

正在运行的相关应用或开发工具，其缓存会被跳过；关闭应用后可重新预演。脚本不会为了增加删除量而自动强杀应用。清理开发缓存后，后续构建可能需要重新下载依赖。Maven 本地仓库、NuGet global packages、Gradle 缓存和 pnpm store 不在清理范围内。

WER、应用/系统崩溃转储、其他用户 TEMP、PWA 离线内容及回收站均不随 Maximum 默认开启。诊断文件需显式使用 `-IncludeWindowsErrorReports` 或 `-IncludeCrashDumps`，仅处理至少 7 天前的文件。其他用户 TEMP 需显式使用 `-IncludeAllUserTemp`，仅处理未加载、非系统专用的本地配置文件，至少保留最近 1 天。如果正在排查蓝屏或应用崩溃，应保留诊断文件。

## 安全边界

- 每个目标都有固定允许根目录；规范化后必须仍位于 C 盘和允许根内。
- 拒绝盘符根、Windows 根、用户配置根等宽泛目录。
- 拒绝 UNC、其他磁盘、相对路径、无限制文件通配符。
- 目标或任一祖先是 junction、符号链接、挂载点等重解析点时直接跳过。
- 删除前逐文件检查年龄、路径和重解析点；使用文件句柄再次验证对象身份，遇到路径变化或无法确认的目标即保留，再自底向上删除空目录。
- Windows Update 所需服务必须全部停止成功才会处理；服务随后按原状态恢复，恢复失败会中止后续清理并产生非零退出码。
- Delivery Optimization 使用 Windows 的 Get-DeliveryOptimizationPerfSnap 和 Delete-DeliveryOptimizationCache，不再猜测内部缓存目录。
- 同一系统盘只允许一个实际清理实例，预防并发停止/启动服务。
- DryRun 与 WhatIf 在调用任何删除、服务、进程或系统配置命令前返回。
- 回收站默认不清；显式启用时也只清当前用户在系统盘上的回收站。
- 实际清理按权限分阶段。管理员进程跳过当前用户缓存路径；这些缓存由原账户非提权进程处理。

## 常用命令

建议优先使用 BAT。以下命令在本项目目录的 PowerShell 中执行。

完整双阶段分析（默认分析 Maximum 范围；从普通窗口启动）：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-CleanupElevated.ps1 -Mode Analyze
~~~

双阶段 Maximum 预演（从普通窗口启动）：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-CleanupElevated.ps1 -Mode MaximumPreview
~~~

双阶段 Maximum 清理（从普通窗口启动）：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Invoke-CleanupElevated.ps1 -Mode Maximum
~~~

仅当前账户缓存（普通权限，不请求提权）：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-CDriveCache.ps1 -Scope User -CleanupLevel Maximum
~~~

用户缓存 Maximum 清理并额外删除 PWA 离线缓存（可能失去网页应用离线内容，普通权限）：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-CDriveCache.ps1 -Scope User -CleanupLevel Maximum -IncludeOfflineWebCaches
~~~

用户缓存 Maximum 清理并显式清空当前账户 C 盘回收站（回收站文件将无法通过回收站还原，普通权限）：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-CDriveCache.ps1 -Scope User -CleanupLevel Maximum -IncludeRecycleBin
~~~

浏览器默认不会被强制关闭。可先请求当前登录会话中的浏览器优雅退出；只有再加第二个开关才会强制结束仍未退出的已快照进程：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-CDriveCache.ps1 -Scope User -CleanupLevel Maximum -StopBrowserProcesses

powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-CDriveCache.ps1 -Scope User -CleanupLevel Maximum -StopBrowserProcesses -ForceCloseBrowserProcesses
~~~

可以用 `-TempFileAgeDays 14` 自定义 TEMP 的保留天数。`-TempFileAgeDays 0` 表示当前用户/Windows TEMP 不按年龄保留，但可能清掉仍有用的会话临时文件，仅在保存工作、关闭应用并检查相同参数的 `-DryRun` 后自行选用。这个选项不自动随 Maximum 开启；其他用户 TEMP 仍至少保留最近 1 天。

直接运行主脚本时，`-Scope User` 仅包含用户阶段，`-Scope System` 仅包含系统阶段，`-Scope All` 为默认值。管理员实际清理会跳过用户路径，因此完整清理应使用 BAT 或启动器。自定义额外开关不会自动传给启动器；需要分别在适当权限窗口执行对应 Scope，并先用相同参数加 `-DryRun` 检查。

## 高影响空间选项

这些不是冗余缓存，不会由 Maximum 自动启用。以下命令在**管理员 PowerShell** 中手工执行，仅针对系统阶段。执行前可在同一命令后加 `-DryRun` 预演。

将休眠文件改为 Reduced，通常能释放一部分空间并保留“快速启动”，但会失去完整休眠：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-CDriveCache.ps1 -Scope System -HibernationMode Reduced
~~~

彻底关闭休眠与快速启动：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-CDriveCache.ps1 -Scope System -HibernationMode Off
~~~

删除全部已被取代的组件版本；执行后现有 Windows 更新包不能卸载：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-CDriveCache.ps1 -Scope System -ResetComponentBase -AllowRecoveryLoss
~~~

让 Windows 自己清理升级遗留；可能失去退回上一 Windows 版本的能力：

~~~powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Clean-CDriveCache.ps1 -Scope System -RemovePreviousWindowsInstallation -AllowRecoveryLoss
~~~

脚本不会自动压缩系统、删除卷影副本、禁用分页文件、删除保留存储或清理个人 OneDrive/下载内容，因为这些操作可能降低恢复能力、兼容性或稳定性。

## 报告与退出状态

每个阶段在 reports 中生成带毫秒、PID 和随机后缀的文件。普通双击入口通常有用户、系统两组报告，可通过报告中的 Scope、时间和管理员状态区分：

- .txt / .log：完整、不会截断路径的可读报告
- .json：运行配置、候选大小、系统盘清理前后空闲空间和逐项目状态；`RetainedItems` 记录执行时保留的条目数
- .csv：便于排序和历史对比

重要状态包括：

- Preview / PreviewPartial：只预演，未调用变更命令；后者表示扫描不完整
- Cleaned：候选项已成功处理
- CleanedWithRetained / Retained：部分已删但仍有执行时保留项 / 全部保留，属于警告
- Partial：部分条目锁定、访问失败或因重解析点被保留
- UnsafePath：路径安全校验拒绝
- ServiceStopFailed / ServiceRestoreFailed：服务事务未完整成功；恢复失败时中止后续清理
- ScanFailed：无法完整测量；清空回收站后测量失败也不会标记为 Cleaned
- SkippedBusy：相关应用仍运行，或系统下载/安装活动不适合清理
- SkippedElevation / SkippedAdmin：当前阶段的权限不符合目标要求
- SkippedScope：目标不符合 C 盘限定或系统缓存位置不明确
- RebootRequired：系统维护已完成但要求重启

启动器退出码 `0` 表示两个阶段未返回错误（仍需查看跳过及保留项）；`2` 表示存在部分失败；`1` 表示中止或启动器错误；`5` 表示权限或账户不符合要求；`1223` 表示 UAC 取消或提权失败。`SkippedElevation`、`SkippedScope`、`RebootRequired`、`CleanedWithRetained` 和 `Retained` 属于警告，不会仅因这些状态返回失败。若系统阶段返回其他非零码，将原样保留。用户阶段部分失败但仍完成时可继续系统阶段，最终不会把该用户阶段的错误改成成功。BAT 在暂停等待前保存退出码，启动器或 PowerShell 启动失败时窗口也会保留错误供查看。

实际运行发生 Partial、路径/服务错误或外部命令失败时，脚本返回非零退出码。候选大小是文件逻辑大小；真正释放空间以 JSON 中的 FreeSpaceDeltaBytes 为准，它可能受压缩、稀疏文件、硬链接和同时运行的程序影响。

## 开发验证

无需安装 Pester。在项目目录运行隔离安全测试：

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-SafetyTests.ps1
~~~

如果已安装 PowerShell 7，也可运行：

~~~powershell
pwsh.exe -NoProfile -File .\tests\Invoke-SafetyTests.ps1
~~~

测试仅在 tests 下独立生成的测试目录内执行受控删除；系统操作使用模拟实现，不会实际清理 Windows 缓存、停止服务或修改休眠设置。通过测试不等于已执行真实清理。

## 官方机制参考

- [Microsoft：清理 WinSxS 组件存储](https://learn.microsoft.com/windows-hardware/manufacture/desktop/clean-up-the-winsxs-folder)
- [Microsoft：Clear-RecycleBin 的 DriveLetter 参数](https://learn.microsoft.com/powershell/module/microsoft.powershell.management/clear-recyclebin)
- [Microsoft：Delivery Optimization 缓存清理](https://learn.microsoft.com/windows/deployment/do/waas-delivery-optimization-faq)
- [Microsoft：cleanmgr 参数](https://learn.microsoft.com/windows-server/administration/windows-commands/cleanmgr)
