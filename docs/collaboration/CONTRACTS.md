# HomePod Flow 接口契约

版本：M0 / source-v0，2026-11-05。类型来源：[core.hpp](../../core/include/flow/core.hpp)。本轮批准最小 C++17 源码契约供实现和离线验收，不承诺稳定 C++ 二进制 ABI。实际通过情况以验收报告为准。

## 数据与所有权

float32 交错样本，有限且在 [-1,1]；采样率和声道数正整数；输入块非空、整帧。Route 每个输出声道复制指定的零起始输入通道，允许重复通道索引。输出 ID 唯一，同一 Output 对象不能绑定多次。本轮不包含混音、增益或重采样。

AudioBlock 拥有样本内存。submit 返回后，不得保留调用方样本引用；异步 Output 必须复制或拥有 enqueue 后需要的数据。

## 时间契约

Clock 注入单调纳秒时间，M0 要求非负。start(epoch,lead_ns) 仅在 Prepared 合法，lead_ns>0，共同 origin=now+lead，检查 int64 溢出。epoch 是媒体世代，首帧索引为 0；后续 first_frame 严格等于 next_frame，按每声道帧数递增。

每块目标时间为 origin+floor(first_frame*1,000,000,000/sample_rate)。全路采用同一时钟域，整数计算检查溢出；不通过逐块累加产生舍入漂移。格式、epoch、连续帧、样本和时间溢出均在 enqueue 前验证，拒绝时不改变 Running 或 next_frame。

scheduled_start 是后端声明能力，不是实测同步。enqueue 成功只表示接受数据。M0 没有设备播放头、漂移校正、提交截止时间、过期帧丢弃或自动恢复；共同未来计划不能保证调用方及时提交，也不能当作真实出声同步证据。

## 状态与故障

Idle -> Prepared -> Running。prepare 先验证全部路由和能力，能力不足返回 Unsupported，不能偷偷降级。准备失败关闭所有已尝试的输出，包含失败的输出，回 Idle；尚未尝试的输出无需关闭。重复 ID 和同一 Output 对象重复绑定均拒绝。

submit 完成验证和路由构造后依次 enqueue。任一路失败（含 WouldBlock 背压）关闭全组并进入 Faulted，不推进 next_frame，不自动重试。早先输出可能已接受数据，close 不能撤销已发出或已播放的声音；M0 不承诺提交物理原子性。恢复必须显式 stop 后重新 prepare/start。

stop 从任意状态回 Idle，清理所有输出和时间线，重复调用安全；析构清理。所有调用串行，禁止 Output 回调重入；有内存分配和复制，不是实时音频回调 API。Output 预期错误通过 Status 返回；实现应捕获后端异常并执行相应失败清理，内存耗尽不作为正常可恢复状态承诺。

## 后续契约（未批准）

- C ABI：M1 窄切片契约见下一节，尚未承诺长期兼容或完整产品 API。
- AirPlay Bridge：既有 Python 路径适配 Output，先明确共享时钟映射、编码、队列和进程退出。
- SyncCoordinator：真实观测、漂移、恢复；本轮策略先置于引擎内部。
- Discovery/Source/App/UI/Video：后续独立设计。

公共接口由架构角色维护。破坏性修改先列影响及迁移任务，再同步通知实现和验收角色。

## M1 C ABI v1 / 有界 AirPlay 桥接契约

类型来源：[bridge.h](../../core/include/flow/bridge.h)。这是新增的小型 ABI，M0 core.hpp 不变。符号包含 flow_v1 前缀，abi_version 必须等于 1；状态值固定为头文件数值。Opaque handle 管理 C++ 实例；类型只包含固定宽度整数、float、C 函数指针和 void*。调用约定 Windows cdecl，所有调用串行。

宿主先 create，add_output 指定输出 ID/通道索引及后端定时能力，再 prepare，start，submit，stop，destroy。所有三个回调必须存在；C++ 所有异常不能越过 C ABI。回调不可抛出或重入；Python 回调必须自己捕获异常，返回状态。回调和 user 生命周期覆盖 destroy 完成。create 失败返回 NULL，其他预期错误返回状态；last_error 是借用 UTF-8，不可释放，下一修改调用或 destroy 后失效。add_output 复制路由，submit 不保留输入；enqueue 回调中的 samples 仅在回调期间有效，Python 必须复制。

C ABI start 使用宿主提供的 now_ns，core 时间和 Python monotonic_ns 明确处于同一域，不能假设 C++ steady_clock 与 Python monotonic 的历元相等。由宿主负责提供单调有效值；有限批次只启动一次，不把固定注入 Clock 当实时观测。

此桥接允许先把全部有限文件输入经真实 C++ submit 路由，再把回调得到的有界数据送入自定义 pyatv AudioSource。数据必须确实经过 native 核心，禁止直接复制旧 Python 分轨文件假冒接通。批次的时长、样本数和总缓冲上限由桥接入口显式校验；不是无限流队列或实时产品实现。

### RAOP 时间映射：基于本机 pyatv 0.18.0 源码

审计路径：`.venv/Lib/site-packages/pyatv/protocols/raop/protocols/__init__.py` 的 StreamContext.rtptime/reset；`stream_client.py` 的 ControlClient._sync_task、_send_packet、_stream_data；`timing.py` 的 ntp2ts/ts2ntp。版本不同必须拒绝或重新审计。

令 R=44100，L=context.latency（以 context 实际值为准；0.18默认为22050+44100=66150），f=媒体帧索引：

- core 的 P0 是首帧预期播放 monotonic_ns。
- 发送起点 S0=P0-floor(L*1e9/R)，不是 P0。
- 冻结一组近同时的 monotonic/NTP 锚点 (M,N)，NTP(S0)=N+floor((S0-M)*2^32/1e9)。使用整数，记录锚点采样误差；冻结后不逐包读墙钟重算。
- context.start_ts=context.head_ts=ntp2ts(NTP(S0),R)。每路 R/L 必须一致。
- 源码 audio RTP=rtptime=head_ts-(start_ts-L)，首包 RTP=L，后续为 f+L。
- sync 包把不含延迟的 RTP=f 绑定到 ts2ntp(head_ts)，所以 RTP=f+L 对应的预期播放时间是 NTP(S0)+(f+L)/R，即 P0+f/R（受协议转换量化误差影响）。

不能把 P0 直接赋给 start_ts 对应的 NTP：这样音频又加了一次 L/R。该映射是协议计划，仍非实际扬声器校准；ntp2ts/ts2ntp 量化和接收端行为须在真机证据中评估。

所有接收端完成准备、进入 _stream_data barrier 后，才选 P0。lead 必须覆盖 L/R 加缓冲/启动 guard；延后 ControlClient.start，避免准备阶段发送旧起点的同步包。路由渲染、共同映射和全部校验在 release 前完成；若准备/渲染已到发送起点前的 guard 截止时刻，整组拒绝播放并清理，不悄悄为单路重新起算。release 后若实际发送因调度迟到超出明确容忍值，同样失败关闭，不能无限追赶后仍标同步。

### PCM、结束和清理

自定义 AudioSource 输出 44100Hz、16bit、stereo。虽然 AudioSource.readframes 文档写 little endian，但本版本 `_to_audio_samples` 在 little-endian 主机 byteswap；现有 AlacAdapter.verbatim_alac 实际输入为 big-endian stereo PCM。新桥接按实际代码输出 big-endian，转换 float 时限幅/量化，不重复交换。每路可由 Route 重复索引得到双单声道。

有限输入完成后 readframes 返回空。保留 pyatv _send_packet 的尾块补零和 latency 长度 padding，使尾部有机会播放；成功等待所有任务完成后再关闭源/连接。任何原生失败、准备失败、超时、取消或网络失败取消其余任务并等待清理，关闭所有 source/connection、destroy native handle，最后恢复所有进程内 monkey patch。不得在仍有任务运行时恢复类方法。

日志分别记录 native路由完成、协议发送完成、用户听感、录音测量；默认 acoustic_sync_verified=false，不能因发送完成而置true。



M1 实现切片上限：render_audio 最多30秒、1..8路、输入1..16声道；输入与路由后样本各不超过16,000,000。真实RAOP限定44100Hz/双声道输出。timing.py 默认ready guard 50ms、release tolerance 20ms，早于发送起点也拒绝；这是当前发送调度容忍，不能解释成声学同步误差指标。

## T015：App 边界冻结

自2026-11-05起，App依赖核心C ABI v1，冻结入口为[docs/api/v1](../api/v1/README.md)及机器清单；当前9个flow_v1符号、错误码、三回调、所有权、串行调用、时钟、fail-stop和启停语义不变。C++接口仅源码兼容，不作为跨编译器ABI。

后续核心修复/按块持续路由不要求App改接口。冻结快照校验、导出符号、旧已编译客户端加载新库及旧语义回归构成兼容门禁。新的adapter有界缓冲可以在调用native前等待容量，但只要实际enqueue失败，仍须按v1全组Faulted处理；不得重新解释WouldBlock或静默丢帧。

旧有限render_audio/单次native submit语义继续保留；新增持续输入另用adapter实现。流结束必须显式区分reader EOF、队列暂空、各路剩余数据及padding完成。运行中块若已错过播放截止应失败停止，不能用旧帧无限追赶掩盖失同步。
