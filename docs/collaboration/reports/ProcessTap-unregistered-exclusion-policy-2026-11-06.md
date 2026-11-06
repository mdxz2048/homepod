# Process Tap：尚未注册音频对象的排除 PID

触发证据：真实 host 在解析专用 Python 网络发送 worker 时返回 `No Core Audio process object for PID ...`。没有 Core Audio process object 只表示该进程当前没有可解析的音频对象，不能据此认定系统音频权限被拒绝。

本次受控变更只放宽 **exclusive 全局排除** 的特定情况：TranslatePID 返回 `noErr`、AudioObject 为 unknown、且 libproc 验证该 PID 确实存活并取得内核启动秒/微秒。记录为 `notRegistered`，不声称存在已排除的音频对象。指定 `.processes` 的正向目标没有音频对象仍失败。任意 HAL 错误、身份不可读、进程消失、PID 复用均不能转换成 notRegistered 成功。

初次解析在 HAL 查询两侧比较进程身份。所有排除 PID（包括已有对象者）保存 `(pid,startSeconds,startMicroseconds,expectedAudioObject?)`。安装 `kAudioHardwarePropertyProcessObjectList` 监听前后复核，启动前后再次复核；另以100ms非实时定时器检测没有触发音频对象列表变化的进程消失/复用。出现对象注册、更换、消失、身份变化或读取失败即 ring fault 5，整个采集 fail-stop，不在运行中动态修改 tap 的排除列表。

查询和监听均在非实时控制/属性队列，IOProc 仍仅预分配 C ring 复制。Source 在消费前检查 fault；host 在异步转换后、每次 IPC enqueue 前再检查。监听和timer清理属于原有资源依赖链，未确认detach不释放ring/tap/aggregate。非实时监听token还带失效保护：即使延后到达的事件执行，失效后也不能写已释放的ring；此锁不进入IOProc。

host.ready 增量输出 `exclusionPolicy`：`objectExcludedPIDs`、`notRegisteredPIDs`、`registrationMonitoring` 与 fail-stop policy 名称。两类PID分开，不把未注册进程描述为已排除的Core Audio对象。

监控属于异步观察，进程注册到事件执行、消费检查之间有调度窗口；100ms timer也有调度延迟。因此不能承诺「绝无一帧反馈」或已完成反馈环验证。真实注册变化、权限与声学效果仍须另行验证；失败后须显式停止并重建，不自动恢复。

新增5项无采集策略检查：exclusive-only admission、HAL错误/不可验证身份拒绝、注册/消失/PID复用/对象变化失败、报告分类、真实当前进程libproc身份稳定性。Mac build/test由总协调执行；本文不提前记为通过。冻结核心 C ABI 和35文件保护基线未修改。
