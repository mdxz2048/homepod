# 系统声音到两台 HomePod：初步链路与启停验证

日期：2026-11-06。状态：实际系统采集/两路发送/短时持续播放/两轮启停及用户听感初筛通过；尚非完整正式版验收。

## 实际路径

固定安装 GUI HomePod Flow → DEBUG 显式启动内部验收 helper → 同一产品 system_worker start/stop 协议 → TapCaptureHost → 实际系统 PCM → live hub / 原生 C ABI v1 核心 → 两路 AirPlay。Mac 使用 afplay 低电平播放系统 Glass 提示音，音箱音量 15%。不是把文件绕过系统采集直接发送至音箱，产品无文件播放入口；未录下个人音频。

发现设备为客厅（HomePod Gen2，192.168.0.104）、HomePod mini小白（192.168.0.113）。IP 是本轮发现结果，不写入产品固定配置。本轮只有两台，不替代三台最终拓扑。

## 过程与保留的失败

第一次 GUI 发起发现返回空设备并报告 No route to host，没有开始播放，不能据前一次听感把这次记为成功。用户随后手动允许 HomePod Flow 本地网络访问，重新发起。

`T021-macos/route-real-2/route.json`：第一轮运行 30 秒，采集 1346284 帧，实际核心提交 1324057 帧，两路原生 PCM hash 相同，7521 个发送音频包中 3530 个非零；prepared_receivers=2、共同 start_ts/first_presentation、group_failed=false，显式停止及清理成功。第二轮重新开始发生 ProtocolError，清理为 true；当时异常详情不足，不能宣称整个双轮成功，也不能认定原因已修复。后续添加截断异常详情及失败 report，用于定位未来复现；不将增加诊断当作修复根因。

`T021-macos/route-real-3/route.json`：同一 worker 完成两个新 UUID 会话，各运行 10 秒，中间显式 stop 及短等待；两轮 errors=[]、control_path_verified=true、worker_exit_code=0。第一轮采集 463814 帧、非零包 1264、两路消费 441760/441408 帧，stop 确认 864.58ms。第二轮采集 464284 帧、非零包 1331、两路消费 442112/441760 帧，stop 确认 899.71ms。两轮均 native_core_used=true、prepared_receivers=2、输入/捕获/核心 hub 与连接组清理确认；各轮内部两路 first_presentation 相同。

停止时两路已消费帧相差一个 352 帧包，属于同时撤销发送任务时记录的队列位置差，不能直接当作播放声学偏差，也不能因 hash 长度不同判断播放不同步。共同调度仅证明计划相同，不证明实际声学毫秒值。用户针对最后这两轮明确回答：“两台同步响过，现在已停止”。记录为短时听感初筛，通过范围不扩大到客观声学测量。

## 延迟数据

本轮协商 protocol_latency_samples=66150、44100Hz，即 1.5 秒。当前 live 方案额外准备余量 500ms，因此计划播放首块时间为 Python 首次收到 PCM 后 2 秒。此映射持续应用于媒体时间线，不是只在启动时等待、之后就消失。转换/IPC/设备内部及声传播延迟未独立测量，故 2 秒不是已测端到端音画延迟。状态栏现有延迟滑块禁用，没有生效命令。

## 静默验证

Mac StateChecks、SystemSessionChecks 编译及运行均退出 0；更新 App Debug、Release 构建均退出 0；17 个 live 检查（含实际核心动态库）通过。对应 route-state-build/checks、route-session-build/checks、route-app-build、route-app-release-build、route-live-tests 日志和 route-source-manifest.json，打包为 T021-macos/route-evidence.zip。Windows执行同17项时16项通过，实际动态库项目因无 FLOW_CORE_LIBRARY 失败；不能把它作为Windows原生集成通过。Mac验证填补该项，不代表跨平台运行验证。最终 pgrep 未见本轮采集宿主、system_worker、验收 helper 或 afplay 残留。

## 尚未通过

偶发快速重启 ProtocolError 的原因、普通用户菜单点击全流程、真实音乐/视频应用持续采集、长时漂移、毫秒级声学同步、Mac 本机静音恢复、系统音画补偿、三台及影院/原生多声道、运行中音量、独立安装包。既有工作不以开发预览代替完整产品交付。
