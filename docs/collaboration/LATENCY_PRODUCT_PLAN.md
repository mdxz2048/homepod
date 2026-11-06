# 音画延迟产品与控制计划

## 2026-11-06 浏览器调研补充：输出设备延迟上报

原先将补偿收敛为播放器专用控制不够完整。当前Tap复制路径没有把新增AirPlay延迟反馈到浏览器的实际输出设备，因此不能期待浏览器自动补偿；但虚拟输出设备可研究通过公开HAL设备/流latency及正确时钟语义，向系统表达端到端呈现延迟，由浏览器原生同步管线使用。此为待验证候选，不是现有能力，也不保证Safari/Chrome或所有网页均支持。

依据：Chromium当前media README说明视频渲染通过TimeSource与音频协调；Mac AUHAL实现Open时读取GetHardwareLatency，GetPlayoutTime结合输出host timestamp和hardware latency，ProvideInput传递BoundedDelay。Apple presentationLatency文档明确对应设备/流latency属性。

- https://chromium.googlesource.com/chromium/src/media/
- https://raw.githubusercontent.com/chromium/chromium/main/media/audio/apple/audio_auhal.cc
- https://raw.githubusercontent.com/chromium/chromium/main/media/audio/mac/core_audio_util_mac.cc
- https://developer.apple.com/documentation/avfaudio/avaudioionode/presentationlatency

优先实验：只在本项目虚拟设备原型上报告可控延迟，配套真实音频缓冲，使用已知闪光/提示音同步素材，在目标Mac的实际Chrome/Safari版本下逐档测量。核对延迟边界/截断、是否仅初始化读取而需重开流、pause/seek/换设备/改变session的时钟行为，防设备/stream/hostTime重复计入延迟；不能改系统内置设备属性来伪装。普通HTML媒体与WebAudio/WebRTC/DRM分别列兼容性。成功再提升为默认补偿路径，失败或不兼容才使用播放器适配；不依据通道数/属性值声明音画已同步。

日期：2026-11-06。状态：正式功能实施契约补充，未实现/未测量项不标通过。本文区分启动等待、持续播放延迟和用户可改变的额外延迟，约束单一状态栏控件的真实含义。

## 当前实现事实

- 先准备全部 AirPlay 接收端，再启动采集、等待首块真实 PCM、建立共同时间线。发现、协议准备、首次权限交互属于启动等待，不应全部算作每个样本持续经历的媒体延迟。
- 当前 `adapters/live/session.py` 与 `hub.py` 使用：首 PCM 在 Python 收到的 monotonic 时间为 `R0`，协议报告的 latency 样本数为 `n`，采样率为 `f`；计划 `P0=R0+n/f+500ms`，发送锚点 `S0=P0-n/f=R0+500ms`。`n/f` 是协商参数，不是假定固定两秒，也不能再减/再加一次造成重复计算。
- 此 P0 是计划 presentation，不是实测扬声器开始发声时间。采集到 receipt、转换、设备最终声学行为的不确定量仍存在；报告已经明确 converter delay unknown、capture-to-receipt uncertainty unknown、acoustic_sync_verified=false。
- 500ms 是当前共同预缓冲/调度预算，持续媒体的时间映射包含它；不是启动结束后自动消失的一次性等待。实际是否能减小，须在网络、消费队列和迟到测试中验证，不能直接改为0承诺低延迟。
- worker 当前 `av_offset:false`，没有音画调节命令；菜单 `AVOffsetControl.disabled(true)`。当前滑块没有真实作用，旧 ±3500ms 外观或持久化偏好均不是能力证据。

## 为什么仅调音频不能修复所有视频

系统 live 输入在应用已经生成音频后才能取得它，无法读取未来声音。若声音已经比视频晚，给音频增加缓存只会更晚。真正补偿这种情况，必须让可控播放器的视频更晚呈现，或者在安全预算内降低现有音频路径延迟。

HomePod/协议、采集、转换和调度各自可能产生延迟；虚拟声卡解决的是可控音频端点/多声道接入，不会消除接收端和网络预算。没有实测之前不固定宣传“总延迟两秒”，也不承诺所有浏览器自动对口型。普通第三方 App/浏览器没有本项目已验证的视频控制适配，必须显示实际能力。

## 单一控件，按能力表达

正式状态栏保持一个相关控件，不要求用户理解多级缓存或逐音箱延迟。根据当前输入/播放器能力采用以下互斥状态：

| 有效能力 | 控件文案与范围 | 生效条件 |
|---|---|---|
| 当前尚无任何后端调节能力 | 显示“音画调节暂不可用”的状态；不显示看似能拖动的无效滑块。 | 当前实现状态，不能将保存偏好显示成已应用。 |
| 仅系统声音额外 holdback | “声音延后”，`0…3500ms`，默认0；旁注“只能延后声音”。 | 后端实现有界共同缓存及全组生效确认；不宣传自动音画校正。 |
| 已验证播放器视频控制 | “音画校正”，双向有效范围由该适配器返回；清楚说明正值对应声音延后/画面提前的实际策略。 | 同一播放器确认视频/音频控制真正生效、暂停/seek/切源恢复及旧设置恢复通过。 |

默认额外 holdback 为0。不要为了让滑块出现负数而人为预留几秒基准缓存。若未来确有业务需要的可减少基准 B，负值仅表示减少这部分缓存，最低为 `-B`；必须显示相对哪个基准，不能称“声音提前到采集之前”。不得把最小网络保护预算当作任意可释放缓存。

能力切换不沿用语义不同的历史数值：系统 holdback 偏好与播放器 A/V 偏好分开存储。切换到不兼容来源后禁用相应能力并展示原因，不自动把播放器偏移变成系统额外声音延迟。未知浏览器保持 system-only 状态。

## 控制协议建议（尚未落码）

保留现有v1命令/session关联，向后兼容增加能力对象；旧 `av_offset:false` 继续表示无通用双向校正，不能因为实现正向 holdback 就置true冒充双向能力。建议新增：

```text
latency_control {
  kind: unavailable | audio_holdback | player_av;
  min_ms; max_ms; step_ms;
  default_ms: 0;
  sign_semantics; apply_strategy: restart_group | player_confirmed;
  source_identity; revision;
}
```

参数严格有限、按能力范围验证。请求包含当前session、request id、能力revision、目标值；UI区分requested/applied，后端只在真实完成后确认applied。来源或session变化后旧确认无效；失败保留先前确认值与明确提示，不能乐观显示成功。未协商能力时拒绝参数，不能静默接受。

holdback 初版采用：用户修改→停止全组→确认清理→新epoch/current PCM重新预缓冲→共同开始→确认实际应用。旧会话buffer不重放；允许显示短暂“正在应用”，不宣称无缝。绝不通过某一路单独改时戳或跳帧实现滑块。所有额外缓存纳入总驻留预算，不能仍宣称原2秒上限涵盖另加3.5秒。

播放器适配须区分请求设置值、播放器读取确认值和声学实测值。视频输出延迟策略依公开能力及版本确认，不能从存在 audio-delay 参数推断可控制任意已运行播放器；它可能仅额外缓冲声音，必须验证符号和真实效果。

## 契约核对与发布验证

核对结果：`LIVE_PCM_PROTOCOL_V1.md` 的共同起点公式、`RELEASE_V1_CONTRACT.md` 的非负holdback/整组重建，以及当前worker能力false、菜单禁用状态相互一致。尚未有真正holdback实现或播放器A/V适配，因此现在不能开放旧双向滑块。`WORKER_PROTOCOL_V1.md` 是历史文件worker协议，不能把其启动lead_seconds当成正式系统声音的音画参数。

验证分别报告：按下开启至已准备的启动时长；输入已知事件至PCM receipt的捕获延迟；计划presentation；实测声学延迟；视频对应画面至声学事件的A/V误差。不能用启动耗时代表持续媒体延迟，不能用协议参数代表测量结果。

额外holdback测0/min/max与反复调整，检查全组共同生效、相对音箱同步保持、实际延迟差与设定差对应，停止/错误清理有界。播放器适配需检验正负方向、暂停恢复、seek、切源、退出恢复以及超范围拒绝。若录音/录像时基不同，先建立共同参考，不能给未经误差分析的毫秒精度结论。

责任：底层实现共同holdback及预算；应用实现能力与确认状态；播放器适配另立任务；UI依能力显示一个有效控件；QA区分目标/参数/实测并独立签署。当前文档不改变正式需求，不将尚未实现的A/V补偿收窄成“只显示限制就完成”。
