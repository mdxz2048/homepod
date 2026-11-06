# 本轮接入与单设备决定（2026-11-06）

用户最新要求：接入产品链路，Mac 只需要一个 Flow 虚拟声卡。此决定覆盖旧多声道契约的“产品显示3个设备”部署策略；旧7设备family仅供dev/QA。

本轮选择一个固定8通道设备，而非运行中更改ASBD：产品build真正只发布1个device/1个stream，UID沿用 `com.homepodflow.virtual-audio.surround71.v1`，显示名 `HomePod Flow Audio`，布局7_1，顺序FL FR FC LFE SL SR BL BR。单声道/立体声内容由播放器/系统映射进此容器；不承诺容器自动保留原始mono/5.1源身份。Flow按设备容器与端点配置路由，保守标记device/os_mix/nativeClaim=false。未来可靠播放器源元数据另接适配层。

控制协议：新独立 `virtual-audio-host --serve`，JSONL v=2，start params严格为session/deviceUID/layout；stop params仅session。HPCM v2 ready/pcm/stopped/error。ready包含outputRate=44100、outputChannels、outputLayout、deviceUID、sourceRate、sourceChannels；stop确认cleanupComplete、drainComplete=false、discardedConverterTail。一个进程仅一次会话；EOF/信号有界清理，不自动捕获、不切默认输出。

Python系统worker v1请求增加可选input字段：{backend:"virtual_device_v2",device_uid:UID,layout:"7_1"}。未提供input保持原系统Tap路径。请求routes仍为output_id/host/channels[0,1]；允许可选role（FL/FR/FC/LFE/SL/SR/BL/BR）。同步模式把保守立体声降混发给每个端点；影院模式按role分配对应信号并复制到该独立HomePod两输出通道。无role时不得丢弃中置/环绕，使用降混。完整5.1/7.1声学仍需实际端点与位置验收，不由菜单名推出。

Python先把输入按每端点矩阵生成2*N通道（最多16），再通过参数化LiveHub与原冻结ABI路由到各端点；AirPlay输出继续44.1k/2ch。矩阵明确并记录，降混考虑中置/环绕、LFE遵循现有多声道契约；限幅/归一化策略不能隐藏。App可选runtime.virtual_capture_host用于新路径，原capture_host保持兜底。默认设备自动接管仍关闭，测试结束检查原默认输出。

文件分工：Swift host worker独占VirtualAudioInput新增host/support和Package.swift；Python worker独占adapters/live/capture_v2.py、routing_v2.py、hub.py、session.py、adapters/system_worker.py及相关新增测试；driver worker独占VirtualAudioDriver；总调度独占App接线、共享决定、Mac安装/验证和Git。worker不连接Mac、不装驱动、不出声、不提交。
