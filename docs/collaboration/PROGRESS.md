# HomePod Flow 当前进度

更新：2026-11-06。换会话先读[SESSION_HANDOFF.md](SESSION_HANDOFF.md)。正式方向：Mac 系统声音输入、影院/同步两种模式、单一布局设置、按真实设备显示；无产品文件播放入口。基础链路已真机跑通，完整正式版尚未验收。以下为当前状态；历史失败与阶段证据保留在 reports/，不以早期条目覆盖本页。

| 模块 | 当前完成情况 | 仍需完成 |
|---|---|---|
| 系统音频采集 | 固定安装GUI归属下取得真实非零48000Hz立体声，转换为44100Hz；基本停止清理通过；Tap平台27项离线检查通过 | 普通应用连续声音、暂停/恢复、权限撤销、输出设备变化及长期稳定 |
| 路由/同步核心 | 冻结C ABI v1不变；有界实时队列、共同时间线；Mac17项live检查含实际核心通过 | 三台目标配置、客观声学测量、长期漂移和跨平台原生验收 |
| AirPlay实际链路 | 系统音频到两台HomePod：一轮30秒及后续两轮各10秒，用户确认听感同步/已停止 | 一次重启ProtocolError原因仍待定位；不能因后续成功标根因已修 |
| 动态音量 | 新App已安装；播放中可拖动，整组ACK、单在途请求+最新待发、旧ACK隔离；两台两轮25%→0%→15%实测及用户确认通过 | 更长拖动/设备故障兼容；当前为硬件协议音量，不是逐样本平滑增益 |
| 状态与恢复 | 开启意图/真实会话分离、停止取消、稳定设备ID、有限重试、网络/睡眠处理已实现；MacStateChecks/SystemSessionChecks通过 | 真实断网/睡眠唤醒/设备掉线验收；缺安全恢复证据不盲目重试 |
| UI | 单布局页、真实型号/坐标/数量、保存/取消；菜单开关、两模式、动态音量；Debug/Release构建通过 | 从正常菜单操作的完整交互验收及必要状态文案；影院仍未实际接算法 |
| 影院处理 | 独立processing库Mac Release构建、CTest1/1及Python真实绑定4项通过 | 接入真实音频链路及听感/路由验收；当前实际仍同一L/R复制 |
| 音画延迟 | 已明确当前协议1.5秒+软件0.5秒余量=计划约2秒；现有控件禁用 | 实测总延迟、优化准备余量、有用的声音延后/可控播放器画面补偿；任意来源不能假承诺负延迟 |
| 虚拟声卡/原生多声道 | 契约v0.4+多声道v1；7设备 dev family 完成 Gate 1；8ch Tap 传输 481回调/246272帧/flags=7；production family 已安装（3可见/4 hidden），原 stereo 已备份；HPCM v2 18测试、QA 26测试/84 case/6工具、App FlowRoutePlan 21组检查均通过 | **需重启一次生效**；6/8ch Tap 逐通道非零仍需 TCC 授权；产品 Input 真实采集/转换未接入；浏览器/声学/恢复 helper/正式包未验 |
| 安装与签名 | Mac固定路径内部构建可运行 | 当前依赖开发目录/Python环境；固定签名、独立安装/卸载/恢复和正式包尚缺。ad-hoc更新曾使旧录音授权不匹配，用户重新允许后动态音量实测通过 |
| Git备份 | GitHub main已确认4331d3b，与本地main一致；35个冻结文件在Git内字节校验一致；README仅变更记录 | 这是开发快照，不是完整正式版；后续在codex/virtual-audio-mvp开发 |

## 下一阶段顺序

用户授权GitHub登录后，已完成远端main校验并启动虚拟声卡第一批agent：virtual_architect负责共享契约/时钟与延迟策略；virtual_driver负责最小立体声驱动；virtual_qa负责独立验收设计和工具。统一入口VIRTUAL_AUDIO_MVP_WORKFLOW.md；系统安装与出声由总协调审核后统一执行，agent不自行安装/改系统。下列系统路径稳定性工作保留，虚拟入口预研与其共享已有发送模块。

1. 先稳定系统声音路径：正常菜单添加/保存/开关/调音量完整验收；普通音乐/视频应用持续播放、静音恢复、30分钟连续测试；复现重启错误；处理Mac本机重复出声；分别记录计划时序和实际声学结果。
2. 接入已分库的影院处理，验证与同步播放确实不同、布局确实影响内容且不丢主声音；增加第三台和故障/恢复场景。
3. 单独推进真实音画能力：测量当前延迟，安全优化；仅延后声音不能解决声音已晚于画面，可控播放器适配负责视频延后。虚拟声卡并行预研，不阻断优先链路。
4. 固定签名与自包含安装包、正式UI/权限/兼容验收、文档及首次Git备份。未通过的原生pair/多声道/应用选择等需求不得静默取消或伪报完成。

### 虚拟声卡第六候选后的顺序

1. 把已真机验证的 device Tap 路径实现进 VirtualAudioInput：创建 tap/aggregate、IOProc、有界 ring、48k→44.1k 转换、HPCM v1 字段与源时间戳；保留系统 Tap 兜底。
2. 在 HomePod Flow App 的 TCC/Info.plist 身份下验证同一路径，确认不是只有临时 ad-hoc probe 可用；未授权时显式报 `permission_required`，不静默全 0。
3. 用 hfla 做受控延迟预算实验并观察 revision/通知；记录 AU、device、stream、safety、buffer、callback hostTime、PCM receipt，再验证 Chrome/Safari 是否采用。
4. 完成恢复 helper、lease 跨进程事务和默认输出恢复；在此之前保持自动接管关闭。

架构未打乱：SwiftUI/AppState → SystemAudioStore → system_worker → 输入适配/TapCaptureHost → live桥 → 处理与冻结路由核心 → AirPlay。输入、DSP、调度、传输、UI保持模块边界，新增处理不修改旧核心ABI。

主要证据：reports/System-to-HomePods-2026-11-06.md、reports/Live-volume-2026-11-06.md、reports/T021-system-route-qa-2026-11-06.md；具体发布门槛以RELEASE_V1_CONTRACT.md及RELEASE_V1_ACCEPTANCE.md为准。
