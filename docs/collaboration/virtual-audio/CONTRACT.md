# Virtual Audio MVP 契约 v0.3

日期：2026-11-06。状态：首轮实现接口冻结；所有安装、Tap 可读性、客户端音画补偿与声学结果尚待验收。本文是本阶段 driver / input / app / QA 的唯一接口依据；变更需总协调确认并更新版本。旧 core C ABI v1 与35个保护文件不变。

## 1. 驱动身份、设备与真实能力

| 项 | 冻结值 |
|---|---|
| Plug-in bundle identifier | `com.homepodflow.audio.driver` |
| Device UID | `com.homepodflow.virtual-audio.stereo.v1` |
| Model UID | `com.homepodflow.virtual-audio.model.v1` |
| Display name | `HomePod Flow Audio` |
| Output | 一个 active 输出 stream，起始通道1，FL/FR；无输入 stream、无输入通道 |
| Stream logical key | `<deviceUID>.output.0`，仅本项目逻辑标识；不伪造 HAL 标准 stream UID 属性 |
| PCM | Float32 native-endian packed interleaved，2ch；8 bytes/frame，1 frame/packet |
| Rates | 精确44100、48000Hz；初始48000Hz |
| Buffer | 首轮512 frames；范围仅512，不能声明未实现的任意尺寸 |
| Zero timestamp period | 16384 frames，与 buffer size 独立；目标 SDK 若有更严格约束需先报告 |
| Input provenance | `device_mix`，不是已证实的源轨道 stereo；labels 的权威来源是设备布局 |

physical/virtual ASBD 必须与 IO 样本一致；输入方向设备查询返回零 stream/零通道。不可把 output-only 设备误报为物理麦克风。驱动接受输出但不提供本机回放；App 未接通时该设备可能无声，未验收前不得自动接管系统输出。首轮不声明6/8ch，不声明 encoded passthrough/Atmos。驱动只实现 `WriteMix` 数据面；实现者需按 SDK 的 IO operation 调用约束报告 in-place 支持，不支持操作应明确拒绝。

所有对象属性必须符合 HasProperty / IsPropertySettable / GetPropertyDataSize / GetPropertyData 的 scope、element、大小、错误语义。**单输出 stream 的 `kAudioStreamPropertyLatency` 必须同时接受 global/main 与 output/main 查询，返回同一 UInt32 值与同一大小，均只读。** 该兼容例外需贯穿上述四个属性入口；stream 的 input scope 或非 main element 仍拒绝。**device 的 latency、safety offset 接受 output/main 与 input/main 查询，两者均只读UInt32零。** input 查询返回零仅是空方向的兼容数值，不代表存在输入流、输入格式或输入IO能力。格式、采样率、默认输出 eligibility 等按 HAL SDK 查询矩阵实现，不能将这些例外推广为所有 selector 通吃。object IDs 为进程内句柄，不能持久化。

v0.2审查修正：当前 Chromium `GetHardwareLatency` 先用调用方 output scope 构造 device latency 地址，随后只改 selector 查询 streams 及首 stream latency，保留 output scope（源码478–508行）。v0.1仅 global 的契约可能使 Chrome 此查询失败并保留初值0，导致有属性却未取得延迟。原生路径实测两 scope 查询均成功；本项目实现需以独立测试验证相同行为。这是特定 selector 的客户端兼容要求，不等于 Safari 行为已验证。

v0.3枚举兼容审查：目标Mac已创建driver remote service，但HAL add-device返回UnknownProperty（`'who?'`错误码）；该错误码本身**不指出缺失selector**，以下是逐项补齐属性矩阵的候选修正，不能写成已定位根因或已枚举成功。

- device `kAudioDevicePropertyRelatedDevices`：global/main只读，返回仅含本device的AudioObjectID数组，不声称与其他设备硬件共钟。
- device `kAudioObjectPropertyOwnedObjects`：global/main、output/main返回单输出stream；input/main返回空数组。其余对象按自己的对象树矩阵实现，不泛化为所有对象都拥有此stream。
- device latency/safety的input/main零值兼容如上；input streams、stream configuration、owned objects仍明确为空，input default eligibility仍false。
- 所有空数组查询Size=0、Get written=0一致，不能解引用零长payload，不能把零个stream包装成一个空对象。非main element、未声明scope仍拒绝。
- 可在非RT属性查询失败路径记录有界诊断：object、selector、scope、element、失败入口/OSStatus，不记录PCM/用户媒体。不得在IO、ZeroTimeStamp或实时路径加入日志；静态诊断需有rate limit，不能让未知selector查询风暴无限刷日志。

这些兼容扩展不改变冻结核心ABI、驱动output-only能力或麦克风权限语义。需独立mock属性测试与目标Mac重新枚举证据；安装/服务加载并不等于设备枚举、PCM捕获或音画验证通过。

## 2. 时钟与格式重配置

- 时钟基于 `mach_absolute_time` 和 `mach_timebase_info`，不使用墙钟或网络时钟。anchor=(sample0,host0,rate,seed) 在运行 epoch 内稳定，host ticks 与 frames 的换算采用可审查的溢出保护/舍入策略。
- `GetZeroTimeStamp` 依当前实际 host ticks 返回已到达的周期边界：`sample=sample0+floor(elapsedFrames/period)*period`，host 与之严格对应；重复查询可返回同一边界，不得倒退。不得将 downstream latency 加进 hostTime 或虚构 future sample clock。
- 所有客户端共享设备时钟；running client reference count 零→一启动，一→零停止；underflow/重复 StopIO 不下溢。新增客户端不得重置正在运行的时钟。
- 采样率修改必须走 host RequestDeviceConfigurationChange / PerformDeviceConfigurationChange / AbortDeviceConfigurationChange。active IO 时拒绝发起；pending 配置唯一；commit 时重新检查无 active IO。失败无部分应用。
- rate 改变会换 epoch/seed、重新建立 anchor，更新 nominal rate、stream ASBD 与 available/current 格式的对应通知。休眠/时钟不连续同样新 epoch，不跨 discontinuity 连旧样本。
- RT 回调不分配、锁互斥、日志、文件/网络、属性通知或等待 App；控制修改在非 RT 路径。统计原子有界，不能以看门狗耗尽 RT 线程。

## 3. 延迟只记一次

所有 HAL latency 单位为该设备当前 rate 的 frames：

```text
deviceLatency = 0
deviceSafetyOffset = 0
streamLatency = round(configuredSeconds * sampleRate)
```

首轮把本项目可归属的 downstream 呈现预算全部放单输出 stream latency；不再同时填 device latency。AU 自身可能产生非零值，必须实测保留组件，不能改 AU 值消重。IO buffer / callback lead 不是额外任意相加项。QA 必须分别记录 AU、device、stream、safety、buffer、callback hostTime、实际 PCM receipt 和声学时间。

`configuredSeconds` 初始0，状态 **uncalibrated**。这只是属性/时钟基础实验值，不代表零延迟可正常播放，不得自动接管。驱动不宣称自身知道 HomePod 链路是否 ready；App 提供校准与会话所有权。

自定义设备属性（global/main，必须在 CustomPropertyInfoList 枚举，固定原生整数，不传 ObjC/JSON）：

| selector | 类型 | 规则 |
|---|---|---|
| `'hfla'` | UInt32 | get/set；设置当前 rate 下 streamLatency frames，0..10*rate。停止且无 pending 重配置时才能更改；相同值幂等不增 revision。控制器必须回读确认。 |
| `'hflr'` | UInt64 | read-only monotonic config revision；首次为1，生效 latency/rate 变更才递增。跨 coreaudiod 重启不保证连续，设备重发现使旧 revision 失效。 |

`hfla` commit 保存等价秒预算（frames/rate），未来 rate commit 按新rate重算；先验证所有值再原子提交。主动改变 rate 后 App 必须重新读取预算，重新校准并生成新 session；不能在旧 session 继续。通知 stream 的 `kAudioStreamPropertyLatency`，同时发布 global/main 与 output/main 两地址，使两类监听者均可观察；通知 device 的 `hflr`。两个 stream 地址只是同一值的通知，不是两份延迟。rate commit 还需完整格式通知。不在 holding RT mutex 下通知。

此 custom property 是能力配置，不是安全认证；其他本地音频客户端可能写入。App 监听 revision，意外变化→停止组会话并重新准备，禁止以假定独占继续发送。不能仅凭 driver property 值把状态置 calibrated。

真实预算应从源 render time 到计划 acoustic presentation 的映射确定，包括可证的 Tap/转换/排队与发送接收预算；当前 receipt-based AirPlay 起点不能无条件替代源 render time。必须验证 Tap 时间戳是否已含呈现偏移，防止再次加同一 stream latency。第一实验可固定一档预算且真实等待对应时长，但明确为实验，不称已测准最终声学延迟。

客户端可能只在 open 时读 latency；每次修改先全组停止、清队列、确认 no running IO，再设置属性/回读、通知，要求受测播放器重开输出后新 session/epoch。浏览器仍持有 IO 时不得强改，报告 `device_busy`，不杀播放器或 coreaudiod。通知不等于客户端采用。

## 4. 输入边界 v1（独立于旧 HPCM / core ABI）

此段是新 VirtualAudioInput 模块数据模型，不是另建共享内存 wire 协议。首选 output-only device + device/stream Tap，但必须实测能否取得非零、左右独立 PCM。初始化返回成功不能替代真实数据。

```text
InputDescriptor {
  schemaVersion: 1;
  backend: virtual_device_stream_tap | system_stereo_tap;
  deviceUID?: string; streamIndex?: UInt32;
  capturedFormat: { sampleRate, sampleType:f32, packing, channelCount,
                    labels:[FL,FR], layoutAuthority:device, layoutVerified };
  provenance: device_mix | stereo_mixdown;
  transformations: []; sourceClockDomain: mach_absolute;
  permissions: { audioCapture: unknown|notDetermined|allowed|denied };
  latency: { revision, reportedFrames, sampleRate,
             calibration: uncalibrated|planned|measured };
}
AudioBlock {
  sessionUUID; epoch; sequence; firstFrame; frameCount; formatRevision;
  hostTicks; timebaseNumer; timebaseDenom; timestampValidFlags;
  sourceSampleTime?; sourceSampleTimeValid;
  payload; discontinuity; gapFrames?;
}
```

- labels 与数据索引对应；未来扩展 FL/FR/FC/LFE/SL/SR/BL/BR/unknown，不能从 count/静音猜源布局。captured format 与 decoder-reported source format 独立。
- source host ticks 必须来自实际输入/stream 时间戳，保留有效标志，不拿 Python receipt clock 冒充。无有效源时基可继续明确受限兜底，但不能宣称自动音画补偿已校准。
- prepare 只枚举/查询并校验能力；不自动安装、切默认设备或采集。start 仅在显式会话授权、下游准备后开始，read 为有界 pull/现有host回调，stop 必须可取消并释放。
- 最大输入块4096 frames；队列有界，沿用现有捕获 ring16 blocks与IPC256KiB上限；转换后44100 stereo进入现有HPCM v1，字段语义不静默改变。overflow/gap/格式改变全组 fail/reprepare，新 epoch 隔离旧队列，不能拼接时间线。
- 若 device Tap 在该驱动/系统上不可读或需要未知变通，返回 `capture_path_unverified` 并保留原系统Tap兜底。loopback input 或共享PCM只可通过新契约增量开发，不各自实现另一套传输。output-only 不代表无需系统音频录制权限。

## 5. App 控制、所有权和恢复

独立 controller 状态：`unavailable → discovered → preparing → ready → switching → running → stopping → restored`，失败带类型错误。区分 desired/running/applied，不能枚举即 ready。

takeover lease 持久记录：sessionUUID、driverUID、original default-output UID、original system-output UID、各自是否实际修改、配置revision、owner token、开始时间。第一次修改前原子落盘；设备身份用 UID，不保存对象ID。MVP只接管默认媒体输出，不改系统提示音角色；若后续确有需要单独记账。

开始顺序：用户启用→查驱动/权限→准备整组接收端与预算→配置驱动延迟并回读→准备Tap→保存lease→切换默认输出并确认→验证 PCM→运行。驱动未装/路径未验证/uncalibrated时不能自动切。首轮安装前只构建，不执行以上切换。

正常停止、启动失败或可恢复错误：停止全组、释放输入；当前默认输出仍是本lease设置的虚拟UID且用户未手动改动时，恢复仍在线的原UID。原设备不可用时选择已验证非本项目/非纯输入可用设备，明确回报；不能盲选任意Aggregate/AirPlay或递归选本设备。用户手动改默认输出优先，停止转发并撤销接管，之后不替用户切回。

App 崩溃不能靠 App 的 defer 自救。正式自动接管前必须实现独立用户态恢复 helper/watchdog：观察 owner 存活/lease、持久 journal、串行化恢复；被启动的 helper 必须与 lease generation 关联，防新session被旧helper恢复。driver 不在 coreaudiod 内替用户改默认输出。helper失败/被杀仍需下次App启动检查 stale lease；该极端限制需记录，不宣称系统绝对不可能无声。

首次驱动安装、签名、管理员授权、必要服务重载/重启和卸载由正式安装流程负责；总协调在可审查产物及风险/恢复步骤齐全后统一操作。TCC用户手动授权，不修改数据库/绕过授权。driver/app签名更新与权限身份稳定是交付门槛。

## 6. 变更、错误与验收

最小错误类型：`driver_unavailable`, `unsupported_format`, `device_busy`, `permission_required`, `capture_path_unverified`, `input_discontinuity`, `latency_revision_changed`, `cleanup_unconfirmed`, `output_restore_failed`。每项包含session/revision（若存在）与可读说明；不得用静音检测猜DRM或权限原因。

三层结果分开：①HAL属性与稳定时钟；②浏览器实际读取/采用；③最终画面与声学偏差。第①层通过不等于②③。Chrome、Safari、普通HTML media/WebAudio/WebRTC分别列实际版本；重开、pause/seek和设备切换分别验证。未实现项不得在应用或报告显示已支持。

依据：本项目 [原生延迟报告](../reports/Native-output-latency-2026-11-06.md)；[Apple AudioServerPlugIn](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)；[Chromium latency读取](https://raw.githubusercontent.com/chromium/chromium/main/media/audio/mac/core_audio_util_mac.cc)；[Chromium播放时间计算](https://raw.githubusercontent.com/chromium/chromium/main/media/audio/apple/audio_auhal.cc)。Chromium源码是实现依据，不能推广为Safari的已验证行为。
