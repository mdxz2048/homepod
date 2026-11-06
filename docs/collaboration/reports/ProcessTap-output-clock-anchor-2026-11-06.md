# Process Tap 输出时钟锚定修正

真实现象由总协调记录：GUI宿主 ready 后仍可能0 PCM/静音；此前预先存在本地播放时偶尔产生块。随后取得独立TCC证据：具体请求msgID677.261的`AUTHREQ_RESULT authValue=0`表明当前未授权，总协调已请求用户在系统设置允许HomePod Flow仅录音。本次输出时钟修正用于持续时钟稳定性，不把它解释为全零根因，也不预先宣称权限或真实采集已修复。待用户完成授权后用同一冻结版本复测。

参考作者原项目 [AudioCap ProcessTap.swift](https://github.com/insidegui/AudioCap/blob/main/AudioCap/ProcessTap/ProcessTap.swift) 的aggregate配置思路：把实际默认输出UID同时作为主subdevice与subdevice列表项，并保留tap输入。未复制其整份文件或采集/销毁实现，沿用本项目原有严格资源依赖与故障路径。

实现先只读查询实际默认输出ID、UID、alive及输入/输出stream数。仅接受存活、有输出、且**没有任何硬件input stream**的设备；带输入的USB/虚拟/组合设备本切片明确unsupported，不把麦克风静默加入aggregate。Tap实际格式仍必须是2声道Float32，不匹配直接失败。配置只创建privateaggregate，保持tap unmuted，不修改系统默认设备、音量或进程静音。

IOProc先调用无分配/无锁的C helper，把HAL提供的全部有效output buffer按其字节数置零，再把预期tap输入复制到原有ring。绝不把tap PCM写到物理output；无效output指针置fault6，输入buffer/声道不匹配仍由ring拒绝。零填充仅操作HAL预分配的输出内存，不在回调分配存储。

保留tap格式、aggregatealive、默认输出及进程排除监听；增加物理输出alive和input/output stream拓扑监听。创建aggregate、安装监听前后、启动前后复核输出snapshot。设备或拓扑变化fail-stop，需要显式重建，不悄悄切换或录入新硬件输入。

新增3项无音频设备测试：输出时钟准入/切换拒绝、多buffer零填充与字节边界、坏buffer不阻止其它有效buffer清零。实际0PCM问题是否解决，由总协调重新build/package并显式运行诊断后记录；本报告不把纯测试等同真实非静音采集成功。Core ABI及35文件保护基线无改动。
