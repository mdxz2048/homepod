# 多声道契约 v1：源优先的输入能力与路由边界

日期：2026-11-06。状态：多声道阶段接口冻结（v1）；实现与 Gate 1/2/3 证据另行验收。本文是 driver / input / app / QA 的唯一多声道接口依据，与 [CONTRACT.md v0.4](CONTRACT.md) 的立体声冻结值并行；不修改 CONTRACT v0.4 已冻结的立体声身份、延迟属性或错误语义。旧 core C ABI v1 与 HPCM v1 均不改变。

本文采用“源优先”模型：虚拟声卡是**输入能力层**，负责让播放器把不同源布局原样送到 Flow；Flow App 再根据“源布局 + 实际音箱布局/数量”决定原样分发、downmix、remap、前置路由或显式上混。捕获层不得偷偷 downmix/upmix，也不得根据静音或通道数猜布局。

**决策摘要**

1. **设备**：固定布局设备家族（mono/stereo/3.0/4.0/5.1 side/5.1 back/7.1；height 只预留），不是单个固定 5.1/8ch 设备。
2. **捕获**：只做 identity / pad_silent / refuse；按标签放 slot，源少于容器补精确静音，源多于容器或标签不匹配就拒绝，不在捕获层 downmix/upmix/remap。
3. **路由**：Flow App 根据 source layout + endpoint layout/数量选择 native/pad/remap/downmix/front-pair/upmix，并记录矩阵、损失和 UI 标签。
4. **协议**：HPCM v2 承载容器通道和源布局；HPCM v1 与 core C ABI v1 保持不变；无共同版本/布局就拒绝。
5. **硬件**：两台 HomePod 只能 downmix/前置路由；true 5.1/7.1 需要 6/8 个位置已知的端点，当前不可宣称。

## 0. 规范性语言与术语

- **MUST / MUST NOT**：实现与验收的硬性要求；违反即不通过对应 gate。
- **SHOULD**：默认要求；偏离必须记录理由和替代证据。
- **MAY**：可选能力；未实现时必须明确拒绝，不能静默降级。
- **R1**：首轮真实实现范围。
- **RES**：只冻结命名、UID、通道顺序和未来语义，本轮不枚举、不采集、不路由。
- **源布局（source layout）**：播放器/解码器/播放器输出所声明的 PCM 布局，可能不等于虚拟设备容器布局。
- **容器布局（container layout）**：虚拟 HAL 设备实际声明并由 tap 给出的通道数与标签。
- **端点布局（endpoint layout）**：Flow 下游每个 HomePod 端点实际承担的位置；两台 HomePod 只能是 `pair`/未知，不能声称 5.1。
- **捕获转换（capture transform）**：捕获层只允许 `identity`（原样）、`pad_silent`（源少于容器时按标签放入并补静音）或 `refused`（拒绝）；不允许 downmix、upmix、remap、增益或延迟。
- **路由计划（route plan）**：Flow App/worker 根据 source/container/endpoints 选择的矩阵与每端点分配。

“原生多声道”只允许用于：源布局有权威报告且通过逐通道夹具验证，并且容器/端点按同一标签原样承载。以下情况一律不得称为原生：立体声 passthrough、播放器/OS 先做过映射、通道数相同但布局不同、仅因其余通道静音、仅因容器有 6/8 个 slot。

## 1. 目标、边界与三层结果

### 1.1 目标

1. 设备家族覆盖 mono、stereo、3.0、4.0、5.1(side)、5.1(back)、7.1；height 布局先冻结接口、后实现。
2. 播放器能把源布局原样输出到对应虚拟设备；源少于容器时只占对应 slot，其余为精确静音；源多于容器时捕获层拒绝，不在捕获层降混。
3. Flow 明确区分“源布局 -> 音箱布局”的 native / pad / remap / downmix / front-pair / upmix，并记录损失。
4. 2 台 HomePod 只能做立体声 downmix 或前置 L/R 路由；完整 5.1/7.1 回放需要 6/8 个可独立分配且位置已知的端点。
5. 所有布局、矩阵、版本拒绝和队列上限可离线测试；所有声学结论另行验收。

### 1.2 非目标

- 不做 AC-3/E-AC-3/DTS/TrueHD/Atmos 等 encoded passthrough；不把压缩 bitstream 当作 PCM。
- 不声称 Atmos 对象渲染、对象元数据保留或 HomePod 按原始 Atmos 渲染。
- 不绕过 DRM、不截取密钥、不承诺受保护内容在所有播放器/服务上可取得非零 PCM。
- 不恢复产品内文件播放器；用户继续使用自己的播放器。
- 不改变冻结 core C ABI v1，不改变 HPCM v1 的字段语义。
- 不声称两台 HomePod 能声学还原 true 5.1/7.1；不声称多台虚拟设备共享硬件时钟或可无条件 aggregate。
- 本轮不做低音管理、房间校正、HRTF/虚拟环绕、逐声道延迟对齐或动态布局重配置。

### 1.3 三层结果必须分开

| 层 | 要回答的问题 | 可接受证据 | 不能据此声称 |
|---|---|---|---|
| L1 HAL/容器 | 设备是否真实枚举、格式/布局/通道是否正确、逐通道 PCM 是否独立、时钟/延迟属性是否成立 | 目标 Mac 枚举 JSON、StreamConfiguration、布局标签、逐通道 tap PCM、buffer/DoIO 记录、hfla/hflr 读写 | 播放器实际采用、音箱出声、声学方向正确 |
| L2 源/播放器布局 | 播放器/解码器实际报告并送到容器的源布局是什么；是否已先降混/上混 | 播放器版本与设置、`audio-params`/`audio-out-params` 或等价权威输出、逐通道夹具、HPCM v2 的 source/container 字段 | 源是原生 5.1、声学还原正确 |
| L3 声学/端点 | 实际端点数量、位置、方向、同步与音画关系 | 端点清单与位置、路由计划、录音/录像、逐事件时间戳、误差预算 | L1/L2 通过、发包成功、哈希一致不能代替 |

**L1 通过不等于 L2/L3；L2 通过不等于 L3。两台 HomePod 上的 L3 不能通过 true 5.1 gate，只能通过 downmix/前置路由 gate。**

## 2. 设备家族与身份

### 2.1 选择：固定布局设备家族（方案 A）

**决策：保留现有 stereo 设备，新增同一 plug-in 内的固定布局设备家族。** 每个设备有固定 UID、固定通道数、固定 channel layout 和固定通道顺序；不做“一个 8ch 设备兼 5.1/7.1”，也不做 R1 的运行时可配置 N-channel 设备。

理由：

1. **布局语义不靠猜。** 不同布局可以共享通道数（5.1 side/back 都是 6ch；5.1.2 与 7.1 都是 8ch），只靠 channel count 无法区分。固定 UID + 固定 layout 让播放器/OS/QA 明确选择。
2. **避免动态 ASBD。** 单设备改 6/8ch 需要停止/重开、失效客户端缓存的格式、定义 layout 变更与 revision；HAL 客户端常在 open 时缓存格式，风险高。
3. **保留源原生路径。** 立体声源可以选 stereo；3.0 源可以选 3.0；5.1 back 可以选 5.1 back 或 7.1；不需要把 5.1 塞进 8ch 后让下游猜“多出来的两个 slot 是什么”。
4. **向后兼容最简单。** 现有 stereo UID、model UID、名称、流、2ch 格式、`hfla`/`hflr` 完全不变；新增设备是增量。

代价与缓解：设备列表变长；由 Flow App 按源布局自动选择（有可靠播放器控制面时）或首次提示用户选择；reserved 设备不枚举；显示名明确写出布局。**不得用 display name 作为程序选择依据；程序必须用 UID/model UID/layout。**

被否决方案：

- **B. 单个 8ch 设备承载 5.1/7.1**：5.1 会被迫占 8 个 slot，播放器/OS 可能按 7.1 处理；3.0/4.0/mono 无法原生表达；容易把“8ch 容器”误报成“7.1 源”。
- **C. 单设备可配置 6/8ch**：需要 stop/reopen、layout 属性与客户端缓存失效、动态 revision；R1 不采用。若未来设备列表成本不可接受，可另立 v2 契约评估，但不能静默改造本契约。

### 2.2 固定身份表

Plug-in bundle identifier 保持 `com.homepodflow.audio.driver`。所有设备由同一 plug-in 静态发布，不使用 `CreateDevice`/`DestroyDevice` 动态创建。

每个设备只发布**一个** interleaved output stream（C 通道），不把声道拆成多个 stream；`kAudioStreamPropertyStartingChannel` 固定 1。

| slug | Device UID | Model UID | Display name | Stream name | Ch | Layout token | 通道顺序 | 状态 |
|---|---|---|---|---|---|---|---|---|
| stereo | `com.homepodflow.virtual-audio.stereo.v1` | `com.homepodflow.virtual-audio.model.v1` | `HomePod Flow Audio` | `HomePod Flow Stereo Output` | 2 | `stereo` | `FL FR` | R1，冻结 |
| mono | `com.homepodflow.virtual-audio.mono.v1` | `com.homepodflow.virtual-audio.model.mono.v1` | `HomePod Flow Audio Mono` | `HomePod Flow Mono Output` | 1 | `mono` | `M` | R1 |
| surround30 | `com.homepodflow.virtual-audio.surround30.v1` | `com.homepodflow.virtual-audio.model.surround30.v1` | `HomePod Flow Audio 3.0` | `HomePod Flow 3.0 Output` | 3 | `3_0` | `FL FR FC` | R1 |
| quad40 | `com.homepodflow.virtual-audio.quad40.v1` | `com.homepodflow.virtual-audio.model.quad40.v1` | `HomePod Flow Audio 4.0` | `HomePod Flow 4.0 Output` | 4 | `4_0` | `FL FR BL BR` | R1 |
| surround51s | `com.homepodflow.virtual-audio.surround51s.v1` | `com.homepodflow.virtual-audio.model.surround51s.v1` | `HomePod Flow Audio 5.1 Side` | `HomePod Flow 5.1 Side Output` | 6 | `5_1_side` | `FL FR FC LFE SL SR` | R1 |
| surround51b | `com.homepodflow.virtual-audio.surround51b.v1` | `com.homepodflow.virtual-audio.model.surround51b.v1` | `HomePod Flow Audio 5.1 Back` | `HomePod Flow 5.1 Back Output` | 6 | `5_1_back` | `FL FR FC LFE BL BR` | R1 |
| surround71 | `com.homepodflow.virtual-audio.surround71.v1` | `com.homepodflow.virtual-audio.model.surround71.v1` | `HomePod Flow Audio 7.1` | `HomePod Flow 7.1 Output` | 8 | `7_1` | `FL FR FC LFE SL SR BL BR` | R1 |
| height512 | `com.homepodflow.virtual-audio.height512.v1` | `com.homepodflow.virtual-audio.model.height512.v1` | `HomePod Flow Audio 5.1.2` | `HomePod Flow 5.1.2 Output` | 8 | `5_1_2` | `FL FR FC LFE SL SR TFL TFR` | RES |
| height712 | `com.homepodflow.virtual-audio.height712.v1` | `com.homepodflow.virtual-audio.model.height712.v1` | `HomePod Flow Audio 7.1.2` | `HomePod Flow 7.1.2 Output` | 10 | `7_1_2` | `FL FR FC LFE SL SR BL BR TFL TFR` | RES |
| height714 | `com.homepodflow.virtual-audio.height714.v1` | `com.homepodflow.virtual-audio.model.height714.v1` | `HomePod Flow Audio 7.1.4` | `HomePod Flow 7.1.4 Output` | 12 | `7_1_4` | `FL FR FC LFE SL SR BL BR TFL TFR TRL TRR` | RES |

`stereo` 的 Model UID 是历史冻结值，不得改成 `model.stereo.v1`。其余设备使用各自 model UID，避免客户端按 model 缓存时把不同通道数/布局当成同一能力。Model UID 前缀只用于家族识别，不表示共享硬件时钟。

开发/试验 bundle 可以使用 `.dev.` UID 和独立 bundle ID 做旁路 staging（避免与已安装 stereo 冲突），但不得把 `.dev.` 身份当产品身份安装；产品安装必须使用本表 UID/model UID。试验 bundle 的 UID/对象 ID/设备子集不构成本契约的冻结值。

### 2.3 对象 ID、枚举与集合

对象 ID 是进程内句柄，不是持久身份；客户端必须用 UID 查找，测试也不得把对象 ID 写进持久状态。下表是推荐给 mock/离线测试的确定性分配；生产实现可以采用等价分配，但同一进程内必须稳定，且 UID 查找、DeviceList、OwnedObjects、Streams 的关系必须正确。

| 对象 | ID |
|---|---:|
| Plug-in | 1 |
| stereo device / stream | 2 / 3 |
| mono device / stream | 4 / 5 |
| surround30 device / stream | 6 / 7 |
| quad40 device / stream | 8 / 9 |
| surround51s device / stream | 10 / 11 |
| surround51b device / stream | 12 / 13 |
| surround71 device / stream | 14 / 15 |
| height512 / height712 / height714 | 不枚举（RES） |

要求：

- `kAudioPlugInPropertyDeviceList` 按 `stereo, mono, surround30, quad40, surround51s, surround51b, surround71` 顺序返回 7 个 device ID；stereo 保持第一，减少既有“首个设备”代码的回归。
- `kAudioObjectPropertyOwnedObjects`：Plug-in 返回全部 7 个 device；device 返回自己的 1 个 output stream；stream 返回空。
- `kAudioPlugInPropertyTranslateUIDToDevice` 必须识别 7 个 UID；未知/保留 UID 返回 `kAudioObjectUnknown`，不能返回第一个设备。
- `kAudioPlugInPropertyTranslateUIDToBox` 返回 `kAudioObjectUnknown`。
- `kAudioDevicePropertyRelatedDevices` 每个设备只返回自身，不因同 plug-in/同 model 前缀而声称共享时钟或硬件。
- reserved height 设备不出现在 DeviceList/OwnedObjects/TranslateUID 中；请求其 UID 视为不存在。

### 2.4 每设备属性矩阵

每个设备都必须独立实现以下矩阵；不得用全局 `gRate/gLatency/gRevision` 让设备互相污染。

| 属性/查询 | 规则 |
|---|---|
| `kAudioDevicePropertyDeviceUID` / `ModelUID` | global/main，返回该设备固定值 |
| `kAudioObjectPropertyName` | global/main，返回 Display name |
| `kAudioObjectPropertyManufacturer` | global/main，`HomePod Flow` |
| `kAudioDevicePropertyTransportType` | global/main，`kAudioDeviceTransportTypeVirtual` |
| `kAudioDevicePropertyClockDomain` | global/main，0；不声称跨设备同钟 |
| `kAudioDevicePropertyDeviceIsAlive` | global/main，1 |
| `kAudioDevicePropertyDeviceIsRunning` / `RunningSomewhere` | global/main，每设备自己的 running 引用计数 |
| `kAudioDevicePropertyDeviceCanBeDefaultDevice` | output/main=true（媒体可显式选为默认） |
| `kAudioDevicePropertyDeviceCanBeDefaultSystemDevice` | 仅 stereo=true；mono/3.0/4.0/5.1/7.1=false，系统提示音默认留在 stereo/内置 |
| `kAudioDevicePropertyStreams` | output/main 返回该设备唯一输出 stream；input/main 返回空；global/main 返回同一 stream |
| `kAudioDevicePropertyStreamConfiguration` | output/main 返回 `mNumberBuffers=1`、`mBuffers[0].mNumberChannels=C`、`mBuffers[0].mData=NULL`、`mDataByteSize=0`，size=`sizeof(AudioBufferList)`；input/main 返回 `mNumberBuffers=0`、size 0。必须真实反映 C，不能固定 2 |
| `kAudioDevicePropertyPreferredChannelLayout` | output/main 返回该设备 layout；见 §3.2。size 按 tag-only 或 descriptions 计算 |
| `kAudioDevicePropertyPreferredChannelsForStereo` | output/main：mono 返回 `{1,1}`；其余返回 `{1,2}`（通道号从 1 开始） |
| `kAudioObjectPropertyElementName` | device output scope，element 1..C 返回逐通道名；element 0 返回 `Main`；大于 C 拒绝。名称见 §3.1 |
| `kAudioDevicePropertyLatency` / `SafetyOffset` | output/main 与 input/main 均只读 0（input 零值仅为枚举兼容，不表示输入流） |
| `kAudioDevicePropertyZeroTimeStampPeriod` | global/main，16384，独立于 buffer size |
| `kAudioDevicePropertyBufferFrameSize` | global/main，Get 返回 preferred 512 或 host 最近接受值；Set 接受 15..4096；不得只接受 512 |
| `kAudioDevicePropertyBufferFrameSizeRange` | global/main，`{15,4096}`；preferred 512 只是建议 |
| `kAudioDevicePropertyNominalSampleRate` | global/main，每设备 44100/48000 |
| `kAudioDevicePropertyAvailableNominalSampleRates` | global/main，精确 44100 和 48000 两个范围 |
| `kAudioDevicePropertyDeviceIsHidden` | 产品默认只显示 stereo / 5.1 side / 7.1；mono / 3.0 / 4.0 / 5.1 back 标记 hidden（仍可按 UID 使用）；reserved 不枚举 |
| `kAudioDevicePropertyRelatedDevices` | 仅自身 |
| `kAudioObjectPropertyControlList` | 空 |
| `kAudioStreamPropertyDirection` | output stream=0（output）；无 input stream |
| `kAudioStreamPropertyTerminalType` | `kAudioStreamTerminalTypeSpeaker` |
| `kAudioStreamPropertyStartingChannel` | 1 |
| `kAudioStreamPropertyIsActive` | 1 |
| `kAudioStreamPropertyVirtualFormat` / `PhysicalFormat` | 当前 rate 的 Float32 native-endian packed interleaved，C 通道；ASBD 见下 |
| `kAudioStreamPropertyAvailableVirtualFormats` / `AvailablePhysicalFormats` | 44100/48000 两项，均 C 通道 |
| `kAudioStreamPropertyLatency` | 该设备 `hfla`；global/main 与 output/main 同值只读；input/非 main 拒绝 |
| `'hfla'` | 该设备 global/main，CFNumber(UInt32)，0..10*rate；仅无 running client 且无 pending 配置可写；回读确认 |
| `'hflr'` | 该设备 global/main，CFNumber(UInt64)，只读，初值 1；仅有效 latency/rate 变更递增 |
| `kAudioObjectPropertyCustomPropertyInfoList` | 每设备 2 项，类型 `CFPropertyList`，qualifier `None` |

ASBD 对每个设备：

```text
mSampleRate       = 44100 或 48000
mFormatID         = kAudioFormatLinearPCM
mFormatFlags      = Float | NativeEndian | Packed
mBytesPerPacket   = 4 * C
mFramesPerPacket  = 1
mBytesPerFrame    = 4 * C
mChannelsPerFrame = C
mBitsPerChannel   = 32
```

`C` 为 1/2/3/4/6/8（R1）或 8/10/12（RES）。`kAudioDevicePropertyStreamConfiguration`、ASBD、`PreferredChannelLayout`、`ElementName` 四者必须一致；任何一处仍固定 2 都视为未实现多声道。

### 2.5 现有 stereo 设备向后兼容

MUST 保持不变：

- UID `com.homepodflow.virtual-audio.stereo.v1`、Model UID `com.homepodflow.virtual-audio.model.v1`、Display name `HomePod Flow Audio`、Stream name `HomePod Flow Stereo Output`。
- 2ch、FL/FR、44.1/48kHz、Float32 interleaved、单 output stream、无 input stream。
- `hfla`/`hflr` 语义、CFPropertyList/CFNumber、两 scope stream latency、device latency/safety 0、zero timestamp 16384。
- stereo 的 `hfla`/`hflr` 与其他设备完全独立；设置 5.1 设备的延迟不得改变 stereo。
- stereo 在 DeviceList 中保持第一；现有按“首个设备”读取 stereo 的工具不应因新增设备而改变结果。

允许的兼容变化：

- `DeviceList`/`OwnedObjects` 从 1 个设备变为 7 个；任何硬编码“只有一个设备”的代码必须改用 UID。这是枚举数量变化，不是 stereo 身份变化。
- `BufferFrameSizeRange` 从旧的 512..512 改为 15..4096；这与 coreaudiod 实际管理一致，且 CONTRACT v0.4 已明确不得宣称仅 512。stereo 的 preferred 仍为 512。

### 2.6 R1 与 RES 的边界

- **R1 实现并验收 HAL/容器**：mono、stereo、3.0、4.0、5.1 side、5.1 back、7.1。
- **R1 真实源布局支持**：上述 7 种源布局在“正确的同布局设备 + 权威源报告 + 逐通道夹具”下原样承载；stereo 是既有已实现项，其余多声道必须在各自 Gate 2 通过后才能对外宣称。
- **R1 声学可宣称**：stereo；5.1/7.1 仅可作为“到 2 台 HomePod 的显式 downmix/前置路由”。true 5.1/7.1 声学回放不在 R1 可宣称范围，除非端点数量达到 §5.5 要求并通过 Gate 3。
- **RES**：5.1.2、7.1.2、7.1.4。只冻结 UID、通道顺序和未来语义；不枚举、不采集、不路由；任何请求返回 `unsupported_channels`/`unsupported_layout`。
- **拒绝**：unknown multichannel、5.1 ambiguous、encoded passthrough、Atmos 对象音频。

### 2.7 设备选择算法

Flow App/播放器适配层选择容器时 MUST 按以下顺序：

1. **先读源布局。** 没有权威 source layout（unknown/ambiguous）时不得自动选多声道设备；只能提示用户或走 stereo 受限兜底。
2. **精确匹配优先。** 源布局有同名设备时选它（mono→mono、3.0→3.0、5.1S→5.1S、5.1B→5.1B、7.1→7.1）。精确匹配不 pad、不 remap。
3. **无精确匹配时选最小超集。** 超集必须包含源的所有标签；例如 5.1S/5.1B→7.1、3.0→5.1/7.1、4.0→5.1B/7.1。记录 `source_padded`，UI 写“源 X 在 Y 容器”。
4. **不得选子集容器。** 例如 7.1→5.1、5.1B→5.1S、4.0→5.1S 在捕获层直接拒绝；Flow 不能从未捕获的通道恢复。
5. **stereo→5.1/7.1 是显式 fallback。** 默认应选 stereo 设备；只有用户/播放器已经选择 5.1/7.1 设备时才走 passthrough，并标 `stereo_passthrough_in_multichannel`。
6. **无精确/超集** → 拒绝 `unsupported_layout`/`route_unsupported`；不得自动上混或降混到错误容器。

## 3. 布局与通道顺序

### 3.1 规范标签

| 标签 | 含义 |
|---|---|
| `M` | mono 单声道；不是 FC 的别名 |
| `FL` / `FR` | 前左 / 前右 |
| `FC` | 前中 |
| `LFE` | 低频效果通道；不是低音管理输出 |
| `SL` / `SR` | 侧环绕（side surround） |
| `BL` / `BR` | 后环绕（back surround） |
| `TFL` / `TFR` | 顶部前左 / 顶部前右（height，RES） |
| `TRL` / `TRR` | 顶部后左 / 顶部后右（height，RES） |
| `unknown_1..n` | 无权威布局的占位标签；不得用于原生声明 |

规范通道顺序（也是 HPCM payload 的交错顺序）：

| Layout token | 通道数 | 顺序 |
|---|---:|---|
| `mono` | 1 | `M` |
| `stereo` | 2 | `FL FR` |
| `3_0` | 3 | `FL FR FC` |
| `4_0` | 4 | `FL FR BL BR` |
| `5_1_side` | 6 | `FL FR FC LFE SL SR` |
| `5_1_back` | 6 | `FL FR FC LFE BL BR` |
| `7_1` | 8 | `FL FR FC LFE SL SR BL BR` |
| `5_1_2` | 8 | `FL FR FC LFE SL SR TFL TFR` |
| `7_1_2` | 10 | `FL FR FC LFE SL SR BL BR TFL TFR` |
| `7_1_4` | 12 | `FL FR FC LFE SL SR BL BR TFL TFR TRL TRR` |

规则：

- 通道数是容器属性，不是布局本身；`8ch` 既可能是 7.1，也可能是 5.1.2。程序必须读 layout/UID，不能按 8 推断 7.1。
- 5.1 side 与 5.1 back MUST 分开；不得把 `SL/SR` 与 `BL/BR` 互相静默替换。
- 7.1 MUST 同时有 side 与 back 两对；不存在“7.1 side-only”或“7.1 back-only”的原生 token。
- 4.0 定义为 quad back：`FL FR BL BR`。4.0 side 变体不在 R1；遇到时按布局不匹配拒绝，不静默重映射。
- LFE 是独立通道 slot；downmix 到 stereo 时默认丢弃，不做低音管理或 LFE fold。
- height 标签仅为 RES；R1 不产生、不接收、不路由。

### 3.2 HAL 布局标签与显式描述

| 设备 | 首选 HAL 表达 |
|---|---|
| mono | `kAudioChannelLayoutTag_Mono` |
| stereo | `kAudioChannelLayoutTag_Stereo` |
| 3.0 / 4.0 / 5.1 side / 5.1 back / 7.1 | `kAudioChannelLayoutTag_UseChannelDescriptions`，按 §3.1 顺序写入 descriptions；这是默认，避免依赖不同 SDK 的 MPEG tag 顺序 |
| height | 目标 SDK 若提供 Atmos/height tag，使用对应 tag；否则显式 descriptions。RES，不实现 |

显式 descriptions 的标签映射（R1）：

| 规范标签 | HAL channel label |
|---|---|
| `FL` | `kAudioChannelLabel_Left` |
| `FR` | `kAudioChannelLabel_Right` |
| `FC` | `kAudioChannelLabel_Center` |
| `LFE` | `kAudioChannelLabel_LFELowFrequencyEffects` |
| `SL` / `SR` | `kAudioChannelLabel_LeftSurroundDirect` / `kAudioChannelLabel_RightSurroundDirect`（side） |
| `BL` / `BR` | `kAudioChannelLabel_LeftSurround` / `kAudioChannelLabel_RightSurround`（back） |

可选：若目标 SDK 的 `kAudioChannelLayoutTag_MPEG_5_1_A/B`、`kAudioChannelLayoutTag_MPEG_7_1_A` 经验证与 §3.1 顺序及 side/back 语义完全一致，可使用对应 tag；但 MUST 在 mock/真机测试中断言 tag 的通道顺序、`SL/SR` 与 `BL/BR` 区分以及播放器实际解释。若任何一项不一致，必须回退显式 descriptions 并记录；不得静默重排数据以“适配”tag。

`SL/SR` 与 `BL/BR` 的 label 语义必须在 Gate 1 中用 Audio MIDI Setup/播放器/录音或等效工具验证；如果目标 SDK 对 `LeftSurround`/`LeftSurroundDirect` 的 side/back 解释与上表不同，按实测修正并记录版本，不能仅凭名称断言。

`kAudioDevicePropertyPreferredChannelLayout` 的 size：

- tag-only：`offsetof(AudioChannelLayout, mChannelDescriptions)`。
- descriptions：`offsetof(AudioChannelLayout, mChannelDescriptions) + C * sizeof(AudioChannelDescription)`，`mNumberChannelDescriptions=C`。
- 不得返回固定 2ch 或与 `StreamConfiguration`/ASBD 不一致的值。

### 3.3 禁止的推断

以下都不是布局证据，MUST NOT 用于改变 source layout、provenance 或 native 声明：

- 容器有 6/8 个 slot；
- 某些通道全静音；
- display name 含 “5.1”/“7.1”；
- 播放器文件名、媒体轨道标签、单帧峰值；
- 通道数与某个常见布局相同；
- 同一设备之前播放过另一种布局。

允许的证据只有：播放器/解码器权威输出、设备容器描述、显式用户覆盖、逐通道夹具验证。静音可以是合法内容；不得因静音推断“源是 stereo”或“源是 5.1”。

## 4. 源布局、容器布局与捕获转换

### 4.1 三个描述符

#### SourceLayoutDescriptor

```json
{
  "schemaVersion": 2,
  "channels": 6,
  "layout": "5_1_side",
  "channelOrder": ["FL", "FR", "FC", "LFE", "SL", "SR"],
  "authority": "decoder",
  "origin": "decoder",
  "verified": true,
  "nativeClaim": true,
  "upstreamTransform": "none_known",
  "evidence": "mpv audio-params + per-channel fixture"
}
```

| 字段 | 类型/枚举 | 规则 |
|---|---|---|
| `schemaVersion` | int | 固定 2 |
| `channels` | 1/2/3/4/6/8/10/12 | 必须等于 `channelOrder` 长度 |
| `layout` | `mono` `stereo` `3_0` `4_0` `5_1_side` `5_1_back` `5_1_ambiguous` `7_1` `5_1_2` `7_1_2` `7_1_4` `unknown` | 不得用通道数代替 |
| `channelOrder` | string[] | §3.1 标签；unknown 用 `unknown_1..n` |
| `authority` | `decoder` `player_output` `device` `user_override` `none` | 谁给出布局 |
| `origin` | `decoder` `player_output` `os_mix` `user_override` `unknown` | 数据在链路中的来源 |
| `verified` | bool | 是否有逐通道夹具/权威证据；仅有名称不算 |
| `nativeClaim` | bool | 派生：仅 `decoder+verified` 或 `device+同布局+verified` 为 true；`player_output` 默认 false |
| `upstreamTransform` | `none_known` `player_map_possible` `player_downmix_possible` `player_upmix_possible` `os_mix_possible` `unknown` | 播放器/OS 是否可能已先变换 |
| `evidence` | string | 有界、无媒体内容；记录播放器版本/字段/夹具 ID |

`player_output` 仍可用于 Flow 路由：它表示“播放器输出给我们的就是 5.1”，但不表示“源文件原生 5.1”。UI 必须显示“播放器输出 5.1（原生性未验证）”，不得显示“原生 5.1”。

`nativeClaim` 只表示**源布局声明可信**，不表示容器或端点原生；容器是否 pad/remap、端点是否 downmix 由 `provenance`/`losses` 另行记录。不得把 `nativeClaim=true` 当作“整条链路原生 5.1”。

`sourceLayout` 是本项目捕获边界可证明的布局，不是对媒体文件原始轨道元数据的最终断言；`authority`/`origin` 说明证据来源，`evidence` 记录播放器版本、字段和夹具，而不是媒体内容。

#### ContainerDescriptor

```json
{
  "deviceUID": "com.homepodflow.virtual-audio.surround51s.v1",
  "channels": 6,
  "layout": "5_1_side",
  "channelOrder": ["FL", "FR", "FC", "LFE", "SL", "SR"],
  "authority": "device",
  "verified": true
}
```

`layout` 只能是 `mono`/`stereo`/`3_0`/`4_0`/`5_1_side`/`5_1_back`/`7_1`（R1）或 RES height；不得是 `unknown`/`5_1_ambiguous`。`verified=true` 只在 Gate 1 对该设备通过后成立。

#### CaptureTransform

```json
{
  "kind": "pad_silent",
  "placed": [
    {"sourceLabel": "FL", "slot": 0},
    {"sourceLabel": "FR", "slot": 1}
  ],
  "silentSlots": [2, 3, 4, 5],
  "transformations": ["stereo_passthrough"]
}
```

| 字段 | 规则 |
|---|---|
| `kind` | 只允许 `identity` / `pad_silent` / `refused` |
| `placed` | 每个源标签到容器 slot index 的精确映射；identity 时可为空或全量 |
| `silentSlots` | 源未占用的容器 slot，必须是精确 `+0.0` |
| `transformations` | 只允许 `identity` `pad_silent` `pad_5_1_side_to_7_1` `pad_5_1_back_to_7_1` `stereo_passthrough` `upstream_player_map` `front_pair_only`；不得出现 `downmix`/`upmix`/`remap` |

### 4.2 捕获层规则

1. **按标签放置，不按索引猜。** 每个源标签必须在容器中有唯一同名 slot；找不到 → `container_layout_mismatch`，不产生 PCM。
2. **源少于容器**：精确放入同名 slot，其余 slot 写 `+0.0`；`kind=pad_silent`。
3. **源多于容器**：`source_exceeds_container`，不产生 PCM；捕获层 MUST NOT downmix、丢声道后继续。
4. **源与容器布局不同但通道数相同**（5.1 side vs back）：`container_layout_mismatch`，不产生 PCM；不得静默把 BL/BR 放进 SL/SR。
5. **捕获层不做 remap。** 如果播放器/OS 已经 remap，记录在 `upstreamTransform`/`origin`，`nativeClaim=false`；这不是我们做的原生映射。
6. **捕获层不做增益、延迟、低音管理、LFE fold、上混。** 只允许拷贝与补零。
7. **不靠静音推断。** 全静音、部分静音、单声道内容都不改变 layout/provenance。
8. **布局在 session 内不可变。** 播放器切轨、切音轨、改输出布局 → 停止当前 session，新 epoch/新 session；不得在旧队列中拼接新布局。

捕获容器必须至少完整承载源布局。Flow 的 downmix 只发生在源/容器已经完整承载源之后，按“源布局 -> 端点布局”执行；如果容器本身小于源，捕获层先拒绝，不能把已经丢失的通道交给 Flow 恢复。

### 4.3 捕获 provenance 与 transformations

| CaptureProvenance | 含义 | 允许的 kind | nativeClaim |
|---|---|---|---|
| `source_native` | 源标签与容器完全同名同序，`upstreamTransform=none_known` | `identity` | authority=decoder+verified，或 authority=device 且容器同布局+verified 时为 true |
| `source_padded` | 源标签是容器子集，额外 slot 静音，upstream 无变换 | `pad_silent` | 仅 authority=decoder+verified 时为 true |
| `stereo_passthrough_in_multichannel` | stereo FL/FR 放进 5.1/7.1，其余静音 | `pad_silent` + `stereo_passthrough` | false（永远不是原生 5.1/7.1） |
| `source_upstream_mapped` | 播放器/OS 可能已映射/降混/上混；我们只观察到容器 | `identity`/`pad_silent` | false |
| `unknown_restricted` | 未知布局，仅在用户显式选择前置对时保留 FL/FR | `identity`/`pad_silent` + `front_pair_only` | false |

`transformations` 不得用于捕获层 downmix/upmix；Flow 的 downmix/upmix 记录在 route plan，不写进 capture provenance。

### 4.4 源布局到容器的捕获矩阵

| 源布局 | 容器 | 捕获结果 | provenance / transformations | 说明 |
|---|---|---|---|---|
| `mono` | `mono` | identity，M→slot 0 | `source_native` | 原生 |
| `stereo` | `stereo` | identity，FL/FR | `source_native` | 既有 |
| `3_0` | `3_0` | identity，FL/FR/FC | `source_native` | 原生 |
| `4_0` | `4_0` | identity，FL/FR/BL/BR | `source_native` | 原生 quad back |
| `5_1_side` | `5_1_side` | identity | `source_native` | 原生 side |
| `5_1_back` | `5_1_back` | identity | `source_native` | 原生 back |
| `7_1` | `7_1` | identity | `source_native` | 原生 |
| `stereo` | `5_1_side` / `5_1_back` / `7_1` | FL/FR 放入 0/1，其余 `+0.0` | `stereo_passthrough_in_multichannel` + `stereo_passthrough` | fallback；不是原生多声道 |
| `3_0` | `5_1_side` / `5_1_back` / `7_1` | FL/FR/FC 放入同名 slot，其余 `+0.0` | `source_padded` | 源子集 |
| `4_0` | `5_1_back` / `7_1` | FL/FR/BL/BR 放入同名 slot，其余 `+0.0` | `source_padded` | BL/BR 存在 |
| `4_0` | `5_1_side` | 拒绝 | `container_layout_mismatch` | side 容器无 BL/BR，不 remap |
| `5_1_side` | `7_1` | SL/SR 放入同名 slot，BL/BR `+0.0` | `source_padded` + `pad_5_1_side_to_7_1` | 7.1 容器承载 5.1 side |
| `5_1_back` | `7_1` | BL/BR 放入同名 slot，SL/SR `+0.0` | `source_padded` + `pad_5_1_back_to_7_1` | 7.1 容器承载 5.1 back |
| `5_1_side` | `5_1_back` | 拒绝 | `container_layout_mismatch` | 不静默 BL↔SL |
| `5_1_back` | `5_1_side` | 拒绝 | `container_layout_mismatch` | 同上 |
| `7_1` | `5_1_side` / `5_1_back` | 拒绝 | `source_exceeds_container` | 捕获层不降混；改用 7.1 容器 |
| `mono` | `stereo`/`3_0`/`4_0`/`5_1`/`7_1` | 拒绝（M 无同名 slot） | `container_layout_mismatch` | 若播放器已先映射，容器报告会是映射后的布局，并标 `source_upstream_mapped` |
| `5_1_ambiguous` | 任意 | 拒绝 | `source_layout_ambiguous` | 需用户显式选 side/back 或 7.1 |
| `unknown` | 任意 | 拒绝 | `unsupported_layout` | 仅显式 front-pair 受限兜底 |
| RES height | 任意 | 拒绝 | `unsupported_channels`/`unsupported_layout` | 本轮不实现 |

“源子集”要求所有源标签在容器中同名存在；只要有一个标签缺失，就拒绝，不做“近似位置”替换。

### 4.5 stereo 进入 5.1/7.1 的固定策略

这是 fallback case，不是主路径，也不是“原生 5.1”：

1. 默认 `stereo_passthrough`：只把 L→FL、R→FR；FC/LFE/SL/SR/BL/BR 全部精确 `+0.0`。
2. `provenance=stereo_passthrough_in_multichannel`；`transformations` 只含 `stereo_passthrough`。
3. 不因容器是 5.1/7.1 就把 stereo 称为 5.1/7.1；UI 必须显示“立体声（仅前置 L/R，其余静音）”。
4. 可选影院上混不是捕获层能力，而是 Flow 的显式 `mode=upmix`；默认关闭，用户每次显式启用；使用 §5.6 的 `M_ST_51S`/`M_ST_71`，并标 `provenance=upmix`。
5. 静音不是布局证据。5.1 内容可能恰好环绕静音；stereo passthrough 也可能全静音；二者必须由 source authority 区分。

### 4.6 unknown 与 5.1 ambiguous

- `5_1_ambiguous`：播放器只说“5.1”但未给 side/back。不得默认 side 或 back；返回 `source_layout_ambiguous`。允许用户显式覆盖为 `5_1_side` 或 `5_1_back`，记录 `authority=user_override`、`verified=false`、`nativeClaim=false`；UI 显示“5.1（环绕位置未确认）”。
- `unknown`：6/8ch 容器但无权威标签。不得产生原生 PCM；返回 `unsupported_layout`。仅当用户显式选择“仅前置 L/R”且设备描述能证明前两个 slot 是 FL/FR 时，允许 `unknown_restricted`：只取前两个 slot，其他丢弃，`nativeClaim=false`，UI 明确“未知多声道，仅前置 L/R”。
- 2ch 且设备标签明确 FL/FR：按 `stereo` 处理，`authority=device`；这不是 unknown。
- 不得从“6 个通道中只有 2 个非零”推断 stereo；也不得从“6 个通道都非零”推断 5.1。

### 4.7 布局变化与不连续

- 播放器切轨、切音轨、改 `audio-channels`、改输出设备、seek 到不同格式、播放器重启：MUST 停止当前捕获，清队列，建立新 session/epoch；不得在旧 HPCM 流中改变 `outputChannels`/`outputLayout`/`sourceLayout`。
- 源布局变化但容器不变：仍按 `source_layout_changed` 停止并重建；不能只改 header 继续。
- 断流、gap、时间戳回退：按现有 `input_discontinuity` 全组 fail-stop；不补零拼接。
- 旧 session 的 PCM 不进入新队列；新 session 从 frame 0 开始。

## 5. Flow 路由：源布局到音箱布局

### 5.1 FlowRoutePlan v1

Flow App/worker 在捕获之后、发送之前调用路由决策。它是独立于 HPCM 的控制面 JSON，不进入实时音频路径。

`FlowRoutePlan v1` 不包含延迟字段。延迟状态由独立的 `InputLatencyStatus`（deviceUID、hflr、reportedFrames、rate、calibration、permission）携带，不能在路由计划里重复或相加。

```json
{
  "schemaVersion": 1,
  "session": "3f1c2a44-5b7e-4f3a-9d1e-2a6b8c0d4e11",
  "source": { "schemaVersion": 2, "channels": 6, "layout": "5_1_side", "channelOrder": ["FL","FR","FC","LFE","SL","SR"], "authority": "decoder", "origin": "decoder", "verified": true, "nativeClaim": true, "upstreamTransform": "none_known" },
  "container": { "deviceUID": "com.homepodflow.virtual-audio.surround51s.v1", "channels": 6, "layout": "5_1_side", "channelOrder": ["FL","FR","FC","LFE","SL","SR"], "authority": "device", "verified": true },
  "endpoints": [
    { "id": "living", "kind": "homepod_stereo", "channels": 2, "position": "pair" },
    { "id": "mini", "kind": "homepod_stereo", "channels": 2, "position": "pair" }
  ],
  "mode": "downmix",
  "allowUpmix": false
}
```

`endpoints[].position` 枚举：`FL` `FR` `FC` `LFE` `SL` `SR` `BL` `BR` `TFL` `TFR` `TRL` `TRR` `pair` `unknown`。

- `homepod_stereo` 端点固定 2ch；`position=pair` 表示左右一对，`position=unknown` 只能用于 stereo/pair 路由。
- true 5.1 需要 6 个端点，位置分别为 `FL FR FC LFE SL SR`；true 7.1 需要 8 个。不得用两个 `pair` 端点冒充 5.1。
- `LFE` 端点必须是能重放低频的端点；HomePod 不自动等于 LFE 端点。若没有合适 LFE 端点，必须显式丢弃 LFE 并记录损失，不得声称完整 5.1。
- 位置必须由用户/安装配置确认；程序不得按设备名称、IP、房间名或发现顺序猜方向。

决策结果：

```json
{
  "accepted": true,
  "routeId": "route-5_1_side-to-stereo-v1",
  "provenance": "downmix",
  "matrices": [{ "id": "M_51S_2", "version": 1 }],
  "endpointPlans": [
    { "id": "living", "matrixId": "M_51S_2", "inputLabels": ["FL","FR","FC","SL","SR"], "outputLabels": ["L","R"], "gains": [1.0, 1.0] },
    { "id": "mini", "matrixId": "M_51S_2", "inputLabels": ["FL","FR","FC","SL","SR"], "outputLabels": ["L","R"], "gains": [1.0, 1.0] }
  ],
  "losses": { "downmixed": ["SL","SR"], "discarded": ["LFE"], "silent": [] },
  "uiLabel": "5.1 源 → 两台 HomePod 立体声下混",
  "error": null
}
```

Route provenance 枚举：`native` `padded` `layout_remap` `downmix` `front_pair` `upmix` `mono_map`。`native` 只允许同布局同标签且端点足够；其余必须带矩阵/损失/UI 标签。

规则：

1. **先校验源。** `source.layout=unknown`/`5_1_ambiguous` 且无用户覆盖 → 拒绝；`nativeClaim=false` 仍可路由，但 `uiLabel` 必须写“播放器输出/未验证”，不得写“原生”。
2. **精确匹配优先。** source layout 与 endpoint layout 完全一致且端点数量/位置足够 → `provenance=native`，矩阵 `M_ID`，不改变任何通道。
3. **源是端点子集且标签同名** → `provenance=padded`；未使用端点/通道静音；不得 upmix。
4. **源大于端点** → 只有存在显式 downmix 矩阵时才允许；`provenance=downmix`，`losses` 必须列出被合并/丢弃的标签。
5. **5.1 side↔back** → `provenance=layout_remap`，不是 native；使用 §5.3 的 remap 矩阵。
6. **两台 HomePod** → 只允许 `M_*_2` 或 `M_FRONT_PAIR`；`provenance=downmix`/`front_pair`；永远不能 `native` 5.1/7.1。
7. **上混** → 只有 `mode=upmix` 且 `allowUpmix=true`；默认 false；`provenance=upmix`；不得称原生。
8. **端点位置未知** → 只允许 stereo/pair 路由；`insufficient_endpoints` 或 `endpoint_layout_unconfirmed`，不得猜。
9. **端点不足但矩阵存在** → 允许显式 downmix，记录损失；不得静默只发 FL/FR 后仍显示多声道。
10. **所有端点共享同一 media timeline**；路由只改变通道分配/系数，不改变 `first_frame`、epoch 或 presentation plan。

### 5.2 源布局 × 端点布局能力矩阵

符号：

- `N` = native：同布局、同标签、端点足够；不改通道。
- `P` = padded：源是端点布局的精确子集；未用端点/通道静音。
- `D` = downmix：显式矩阵，记录损失。
- `R` = layout remap：5.1 side↔back 等位置重映射；不是 native。
- `M` = mono map：显式 mono 分配（见 §5.3），不是影院上混。
- `P/U` = 默认 `P`；只有用户显式 `mode=upmix` 时才 `U`。
- `—` = R1 未定义矩阵，拒绝 `route_unsupported`；不得临时发明。

| 源 \ 端点 | ST(2) | 3.0(3) | 4.0(4) | 5.1S(6) | 5.1B(6) | 7.1(8) |
|---|---|---|---|---|---|---|
| `mono` | `M` | `M`(FC) | `M`(FL/FR) | `M`(FC) | `M`(FC) | `M`(FC) |
| `stereo` | `N` | `P` | `P` | `P/U` | `P/U` | `P/U` |
| `3.0` | `D` | `N` | `—` | `P` | `P` | `P` |
| `4.0` | `D` | `—` | `N` | `R` | `P` | `P` |
| `5.1S` | `D` | `—` | `—` | `N` | `R` | `P` |
| `5.1B` | `D` | `—` | `—` | `R` | `N` | `P` |
| `7.1` | `D` | `—` | `—` | `D` | `D` | `N` |

说明：

- `mono` 的 `M` 是显式单声道分配：到 stereo 时 L=R=`0.707107*M`；到 3.0/5.1/7.1 时只进 FC（其余静音）；到 4.0 时进 FL/FR（各 `0.707107`），BL/BR 静音。
- `stereo` 的 `P` 是 §4.5 的 passthrough；`U` 只对 5.1/7.1 存在（§5.6），3.0/4.0 没有上混矩阵，只有 `P`。默认 `P`，不得默认 `U`。
- `4.0→5.1S` 是 `R`（BL→SL、BR→SR），不是 native；`4.0→5.1B` 是 `P`（BL/BR 同名存在）。
- `5.1S→5.1B` / `5.1B→5.1S` 是 `R`；必须显示“位置重映射”，不能显示“原生 5.1 back/side”。
- `7.1→5.1S` / `7.1→5.1B` 是 `D`；必须记录 SL/SR 与 BL/BR 的合并。
- `3.0→4.0`、`4.0→3.0`、`5.1→3.0/4.0` 在 R1 没有矩阵，拒绝；不能把 FC/SL/SR 静默丢弃。

`R`/`D` 是 Flow 端点路由；捕获容器必须先包含源标签。例如 `4.0→5.1S` 的 `R` 需要 4.0 已进入 7.1 容器（BL/BR 存在），再由 Flow 映射到 5.1S 端点；若用户把 4.0 直接送进 5.1S 容器，捕获层按 §4.4 先返回 `container_layout_mismatch`。`5.1S↔5.1B` 的 `R` 同理需要 7.1 容器同时提供 SL/SR 与 BL/BR。

### 5.3 矩阵注册表

常量（十进制近似，实现按 float64 计算后写 float32；测试按 float32 容差）：

```text
a = 0.414214   (√2 − 1)
b = 0.292893   (1 − √2/2)
c = 0.146447   (b/2)
d = 0.585786   (3.0/4.0 到 stereo 的前通道归一化系数，见下)
e = 0.707107   (1/√2)
f = 0.353553   (1/(2√2))
```

表中数值为 6 位小数；实现 MUST 用精确公式计算（`a=√2−1`、`b=1−√2/2`、`c=b/2`、`d=1/(1+1/√2)`、`e=1/√2`、`f=1/(2√2)`），使行 L1 精确为 1（或 `M_MONO_2` 的 `1/√2`）；6 位小数只用于文档和测试容差。`M_71_2` 的十进制近似行和可能显示 1.000001，这是舍入，不是额外增益。

`d` 的精确定义：3.0/4.0 到 stereo 未归一化行为 1.0 前通道 + 0.707107 中/后通道，行和 1.707107；归一化系数为 `1/1.707107 = 0.585786` 和 `0.707107/1.707107 = 0.414214`。因此 `M_30_2`/`M_40_2` 使用 `d=0.585786` 与 `a=0.414214`；`a` 与 5.1 的 FL/FR 系数同值，但 `b=0.292893` 只用于 5.1 的 FC/surround，不用于 3.0/4.0。下表中 `M_30_2`/`M_40_2` 直接写数值。

#### 5.3.1 原样、补位与位置重映射

| ID | 源 → 目标 | 方程 | 行 L1 | 说明 |
|---|---|---|---:|---|
| `M_ID_<layout>` | 同布局 | `out[i] = in[i]` | 1 | native；不重排、不增益 |
| `M_PAD_<src>_<dst>` | 源子集 → 目标 | 同名标签复制，未用 slot `+0.0` | 1 | 捕获层 `pad_silent` 与 Flow `padded` 共用定义 |
| `M_51B_6` | 5.1 back → 5.1 side 端点 | `FL=FL; FR=FR; FC=FC; LFE=LFE; SL=BL; SR=BR` | 1 | 显式 remap；不是 native |
| `M_51S_6B` | 5.1 side → 5.1 back 端点 | `FL=FL; FR=FR; FC=FC; LFE=LFE; BL=SL; BR=SR` | 1 | 显式 remap；不是 native |
| `M_40_51S` | 4.0 → 5.1 side 端点 | `FL=FL; FR=FR; SL=BL; SR=BR; FC=0; LFE=0` | 1 | 显式 remap；不是原生 5.1 |
| `M_MONO_FC` | mono → 任一含 FC 的多声道端点 | `FC=M; 其余=0` | 1 | 单声道中心分配；不是原生 5.1/7.1 |
| `M_MONO_40` | mono → 4.0 端点 | `FL=FR=BL=BR=0.5*M` | 0.5 | 四端点均分；不是原生 4.0 |
| `M_51S_8` | 5.1 side → 7.1 | `FL=FL; FR=FR; FC=FC; LFE=LFE; SL=SL; SR=SR; BL=0; BR=0` | 1 | pad；BL/BR 精确静音 |
| `M_51B_8` | 5.1 back → 7.1 | `FL=FL; FR=FR; FC=FC; LFE=LFE; SL=0; SR=0; BL=BL; BR=BR` | 1 | pad；SL/SR 精确静音 |
| `M_71_8` | 7.1 → 7.1 | identity 8 | 1 | native |
| `M_71_6` | 7.1 → 5.1 side 端点 | `FL=FL; FR=FR; FC=FC; LFE=LFE; SL=0.5*SL+0.5*BL; SR=0.5*SR+0.5*BR` | 1 | 显式 downmix；LFE 保留 |
| `M_71_6B` | 7.1 → 5.1 back 端点 | `FL=FL; FR=FR; FC=FC; LFE=LFE; BL=0.5*BL+0.5*SL; BR=0.5*BR+0.5*SR` | 1 | 显式 downmix；LFE 保留 |

#### 5.3.2 到两台 HomePod（stereo）

| ID | 源 → 目标 | 方程 | 行 L1 | LFE |
|---|---|---|---:|---|
| `M_MONO_2` | mono → stereo 端点 | `L=R=0.707107*M` | 0.707107 | 无 |
| `M_30_2` | 3.0 → stereo | `L=0.585786*FL+0.414214*FC; R=0.585786*FR+0.414214*FC` | 1 | 无 |
| `M_40_2` | 4.0 → stereo | `L=0.585786*FL+0.414214*BL; R=0.585786*FR+0.414214*BR` | 1 | 无 |
| `M_51S_2` | 5.1 side → stereo | `L=0.414214*FL+0.292893*FC+0.292893*SL; R=0.414214*FR+0.292893*FC+0.292893*SR` | 1 | 丢弃 |
| `M_51B_2` | 5.1 back → stereo | `L=0.414214*FL+0.292893*FC+0.292893*BL; R=0.414214*FR+0.292893*FC+0.292893*BR` | 1 | 丢弃 |
| `M_71_2` | 7.1 → stereo | `L=0.414214*FL+0.292893*FC+0.146447*SL+0.146447*BL; R=0.414214*FR+0.292893*FC+0.146447*SR+0.146447*BR` | 1 | 丢弃 |
| `M_FRONT_PAIR` | 任意含 FL/FR 的源 → stereo | `L=FL; R=FR; 其余丢弃` | 1 | 丢弃；不是 downmix |

#### 5.3.3 可选 stereo 上混

| ID | 源 → 目标 | 方程 | 行 L1 | LFE |
|---|---|---|---:|---|
| `M_ST_51S` | stereo → 5.1 side | `FL=0.707107*L; FR=0.707107*R; FC=0.353553*(L+R); SL=0.5*(L-R); SR=0.5*(R-L); LFE=0` | 1 | 不合成 |
| `M_ST_71` | stereo → 7.1 | 同 `M_ST_51S`，另 `BL=0; BR=0` | 1 | 不合成 |

`M_ST_51S`/`M_ST_71` 只是固定线性矩阵，不是 Dolby/DTS 授权算法，也不是原生多声道。其环绕由 L−R 差信号产生，单声道下会抵消；这是已记录的限制，不是缺陷修复项。

### 5.4 增益、削波与 LFE 策略

1. **输入校验**：矩阵输入必须是有限 Float32，范围 `[-1,1]`；越界 → `invalid_pcm_range`，整块拒绝，不裁剪、不静音掩盖。
2. **行 L1 ≤ 1**：§5.3 所有矩阵每一输出行的绝对值之和 ≤1，因此 `|out| ≤ max|in|`；不需要 limiter。不得再额外乘“安全增益”改变已冻结系数。
3. **无自动归一化/无 limiter/无响度匹配**：R1 不做。若未来增加，必须新 matrix version 并重新验收。
4. **数字静音**：未使用 slot 必须精确 `+0.0`；离线矩阵测试要求全零；经转换/网络后的真实路径要求 ≤ `-120 dBFS`。
5. **LFE**：
   - native/pad/到多声道 downmix：LFE 在目标有 LFE slot 时按 1.0 保留；`M_71_6`/`M_71_6B` 保留 LFE。
   - 任何到 stereo 的 downmix：LFE 丢弃，不折入 L/R。
   - stereo 上混：LFE=0，不合成。
   - 不做低音管理、分频、LFE+10dB 或 LFE fold。
6. **端点增益**：`endpointPlans[].gains` 每项必须在 `[0,1]`；矩阵后再乘，不得 >1。若用户提升音量导致削波，属于下游音量策略，不得回写矩阵。
7. **真峰值**：行 L1 ≤1 只保证样本峰值；不保证 inter-sample true peak。R1 不承诺 true-peak 安全，发送端不得额外加 >1 增益。
8. **不可在 session 内换矩阵**：矩阵 ID/version/系数在 session 内不可变；改变矩阵必须新 matrix version、停止组、新 session/epoch。不得在播放中悄悄替换系数。

### 5.4.1 强制 UI/日志标签

| 条件 | 必须显示 | 禁止显示 |
|---|---|---|
| `source_native` 且容器同布局 | `5.1 Side（源原生）` / `5.1 Back（源原生）` / `7.1（源原生）` | `7.1`（源是 5.1 时） |
| `source_padded` | `5.1 Side 源在 7.1 容器（多出通道静音）` | `原生 7.1` |
| `stereo_passthrough_in_multichannel` | `立体声（仅前置 L/R，其余静音）` | `5.1` / `7.1` / `原生多声道` |
| `source_upstream_mapped` | `播放器输出 5.1（原生性未验证）` | `原生 5.1` |
| `unknown_restricted` | `未知多声道，仅前置 L/R` | `5.1` / `7.1` |
| `downmix`（到 stereo） | `5.1 → 立体声下混（LFE 丢弃）` / `7.1 → 立体声下混（LFE 丢弃）` | `5.1` / `7.1` / `原生` |
| `downmix`（7.1→5.1） | `7.1 → 5.1 下混` | `原生 5.1` |
| `front_pair` | `仅前置 L/R（其余丢弃）` | `5.1` / `7.1` |
| `layout_remap` | `5.1 Back ↔ Side 位置重映射（非原生）` | `原生 5.1 Back/Side` |
| `upmix` | `立体声上混（影院，非原生）` | `原生 5.1` / `Dolby` / `DTS` / `Atmos` |

两台 HomePod 下混时，标签必须写明“下混”，不能只显示源为 5.1/7.1 而不说明端点只有两台。

### 5.5 两台 HomePod 的硬限制

- 两台 HomePod = 两个 stereo AirPlay 端点，不是 5.1 的 6 个独立方向。它们不能声学还原 true 5.1/7.1。
- 允许的路由只有：`M_*_2` 立体声下混，或 `M_FRONT_PAIR` 前置 L/R。两者都必须显示“下混/仅前置”，不得显示“5.1”。
- 完整 5.1 至少需要 6 个可独立分配、位置已知的端点（`FL FR FC LFE SL SR`）；完整 7.1 需要 8 个；height 需要 10/12 个。当前只有两台可用 HomePod，且小黑在线/供电未确认，因此 **true 5.1/7.1 的 Gate 3 在本轮不可通过**。
- 即使有 6 个 HomePod，每个端点仍是 stereo AirPlay 流；把一个离散通道复制到 L/R 只是端点承载方式，不代表该 HomePod 是“中置”或“环绕”音箱。方向必须由摆位和录音验证。
- LFE 需要能重放低频的端点；没有时显式丢弃并记录，不得声称完整 5.1。

### 5.6 可选影院上混

- 默认关闭；只有用户在本次会话显式选择 `mode=upmix` 且 `allowUpmix=true` 才允许。
- 只使用 `M_ST_51S`/`M_ST_71`；不得使用未注册矩阵，不得冒充 Dolby/DTS/Atmos。
- `provenance=upmix`；`uiLabel` 必须含“上混/非原生”。
- 测试夹具的精确期望：

| 输入 | FL | FR | FC | SL | SR | LFE |
|---|---:|---:|---:|---:|---:|---:|
| L=1, R=0 | 0.707107 | 0 | 0.353553 | 0.5 | -0.5 | 0 |
| L=0, R=1 | 0 | 0.707107 | 0.353553 | -0.5 | 0.5 | 0 |
| L=R=0.5 | 0.353553 | 0.353553 | 0.353553 | 0 | 0 | 0 |
| L=1, R=-1 | 0.707107 | -0.707107 | 0 | 1.0 | -1.0 | 0 |

### 5.7 N 端点路由

- 端点计划按位置分配，不按发现顺序；`endpointPlans` 必须覆盖每个端点，或明确标为 silent。
- 每个 `homepod_stereo` 端点接收一对 L/R；离散通道可复制到 L/R，但必须在计划中写 `duplicate: true`。
- 所有端点共享同一 `first_frame`、epoch、presentation origin；路由不得为单端点改变时间线。
- 端点掉线/位置变化 → 停止整组、重新准备、新 session；不得在播放中静默换位置。
- 端点数量不足 → 显式 downmix 或拒绝；不得把 6/8ch 直接送给两个端点后声称 native。

## 6. HPCM v2：多声道捕获协议

### 6.1 版本与 framing

HPCM v1 保持冻结：`v=1`、44100Hz、2ch、`MAX_HEADER=16384`、`MAX_PAYLOAD=65536`、字段语义不变。HPCM v2 是独立版本，不改变 v1 的任何字段或校验。

```text
4 bytes ASCII "HPCM"
uint32 little-endian headerLength   (1..16384)
uint32 little-endian payloadLength  (0..196608)
headerLength bytes UTF-8 JSON object
payloadLength bytes payload
```

- `MAX_HEADER_V2 = 16384`。
- `MAX_PAYLOAD_V2 = 196608`（12ch × 4096 frames × 4 bytes 的上界）。
- R1 只产生 `outputChannels ∈ {1,2,3,4,6,8}`，对应最大 payload `131072`；10/12ch 为 RES，v2 解析器可拒绝 `unsupported_channels`。
- 控制帧 `ready`/`stopped`/`error` 的 `payloadLength` 必须 0；PCM 帧 `payloadLength = outputFrames * outputChannels * 4`。
- 消费者必须 `readexactly` 处理分包/合包；magic/长度/JSON/版本任一失败即全组失败，不得重新搜索 magic 跳过坏帧。
- JSON 拒绝 NaN/Infinity、重复键、非 UTF-8、超长字符串；header 不得超过 16KiB。

### 6.2 PCM header 字段

```json
{
  "v": 2,
  "id": "start-id",
  "session": "3f1c2a44-5b7e-4f3a-9d1e-2a6b8c0d4e11",
  "kind": "pcm",
  "sequence": 0,
  "outputRate": 44100,
  "outputChannels": 6,
  "outputLayout": "5_1_side",
  "outputChannelOrder": ["FL","FR","FC","LFE","SL","SR"],
  "outputFrameStart": 0,
  "outputFrames": 480,
  "container": {
    "deviceUID": "com.homepodflow.virtual-audio.surround51s.v1",
    "channels": 6,
    "layout": "5_1_side",
    "channelOrder": ["FL","FR","FC","LFE","SL","SR"],
    "authority": "device",
    "verified": true
  },
  "source": {
    "sourceRate": 48000,
    "sourceChannels": 6,
    "sourceLayout": "5_1_side",
    "sourceChannelOrder": ["FL","FR","FC","LFE","SL","SR"],
    "sourceLayoutAuthority": "decoder",
    "sourceOrigin": "decoder",
    "sourceLayoutVerified": true,
    "nativeClaim": true,
    "upstreamTransform": "none_known",
    "sourceFrameStart": 0,
    "sourceFrames": 480,
    "sourceSequence": 0,
    "hostTime": 123456789,
    "sampleTime": "0.0",
    "flags": 3,
    "nowHostTime": 123456999,
    "nowSampleTime": "0.0",
    "nowFlags": 3,
    "timebaseNumerator": 1,
    "timebaseDenominator": 1,
    "droppedBlocksBefore": 0
  },
  "captureTransform": {
    "kind": "identity",
    "placed": [],
    "silentSlots": [],
    "transformations": ["identity"]
  },
  "provenance": "source_native",
  "inputFramesConsumedTotal": 480,
  "converterLeadingFrames": 0,
  "converterTrailingFrames": 0,
  "primeMethod": "none",
  "converterDelayKnown": false,
  "timestampRelation": "input_block_metadata"
}
```

字段规则：

| 字段 | 规则 |
|---|---|
| `v` | 固定 2；v1 消费者必须拒绝 v2，v2 消费者必须拒绝 >2 |
| `id`/`session`/`kind` | 与 v1 相同；stale session 帧不得进入新队列 |
| `sequence` | 从 0 严格连续，每 PCM 帧 +1 |
| `outputRate` | R1 固定 44100；48000 需未来 v3/显式协商，不得在 v2 静默改变 |
| `outputChannels` | 1/2/3/4/6/8（R1）；10/12 为 RES |
| `outputLayout` | §3.1 token；必须等于 `container.layout` |
| `outputChannelOrder` | 长度=outputChannels；顺序必须与 §3.1 一致 |
| `outputFrameStart` | 从 0 严格按前块帧数连续；不得用 sampleTime/hostTime 代替 |
| `outputFrames` | 1..4096 |
| `container` | ContainerDescriptor；`deviceUID`/channels/layout/order 必须与实际设备一致 |
| `source` | SourceLayoutDescriptor + v1 源时钟字段；`sourceChannels`=sourceChannelOrder 长度 |
| `captureTransform` | §4.1；kind 只能是 identity/pad_silent/refused；PCM 帧不得是 refused |
| `provenance` | §4.3 CaptureProvenance |
| `inputFramesConsumedTotal` | 非负整数；本 session 送入转换器的累计输入帧 |
| `converterLeadingFrames`/`TrailingFrames` | 非负；所有通道必须相同；不是端到端延迟 |
| `primeMethod` | R1 固定 `none` |
| `converterDelayKnown` | R1 固定 false；不得伪称零延迟 |
| `timestampRelation` | 固定 `input_block_metadata`；不代表输出首样本精确时间 |

`source` 的 v1 字段（`sourceRate`、`sourceFrameStart`、`sourceFrames`、`sourceSequence`、`hostTime`、`sampleTime`、`flags`、`nowHostTime`、`nowSampleTime`、`nowFlags`、`timebaseNumerator`、`timebaseDenominator`、`droppedBlocksBefore`）语义与 HPCM v1 完全一致；v2 只增加布局字段，不改变时钟语义。

### 6.3 三种典型 header 差异

以 §6.2 为基线，替换以下字段：

| 场景 | outputChannels / order | source | captureTransform | provenance |
|---|---|---|---|---|
| stereo → 5.1 side | 6；`FL FR FC LFE SL SR` | `sourceChannels=2`；`sourceLayout=stereo`；order `FL FR` | `kind=pad_silent`；placed FL→0,FR→1；silentSlots `[2,3,4,5]`；transformations `["stereo_passthrough"]` | `stereo_passthrough_in_multichannel` |
| 5.1 back → 7.1 | 8；`FL FR FC LFE SL SR BL BR` | `sourceChannels=6`；`sourceLayout=5_1_back`；order `FL FR FC LFE BL BR` | `kind=pad_silent`；placed FL→0,FR→1,FC→2,LFE→3,BL→6,BR→7；silentSlots `[4,5]`；transformations `["pad_5_1_back_to_7_1"]` | `source_padded` |
| 3.0 → 5.1 back | 6；`FL FR FC LFE BL BR` | `sourceChannels=3`；`sourceLayout=3_0`；order `FL FR FC` | `kind=pad_silent`；placed FL→0,FR→1,FC→2；silentSlots `[3,4,5]`；transformations `["pad_silent"]` | `source_padded` |

注意：5.1 back → 7.1 中，BL/BR 放在 slot 6/7，SL/SR 静音；5.1 side → 7.1 则 SL/SR 放 slot 4/5，BL/BR 静音。两者都是 `source_padded`，但 `transformations` 不同，UI 标签不同。

### 6.4 协商与拒绝

`start` 命令的 `params` 增加消费者能力；v1 字段保持兼容：

```json
{
  "v": 1,
  "id": "start-id",
  "command": "start",
  "params": {
    "session": "3f1c2a44-5b7e-4f3a-9d1e-2a6b8c0d4e11",
    "excludedProcessIDs": [123, 456],
    "container": { "deviceUID": "com.homepodflow.virtual-audio.surround51s.v1", "channels": 6, "layout": "5_1_side" },
    "sourceExpectation": { "layout": "5_1_side", "channels": 6 },
    "consumer": {
      "hpcmMax": 2,
      "channelCounts": [1, 2, 3, 4, 6, 8],
      "maxPayloadBytes": 196608,
      "maxFrames": 4096,
      "supportsDownmix": false
    }
  }
}
```

规则：

1. 消费者在 `consumer.hpcmMax` 声明最高版本；缺省视为 1。host 选择双方最高的共同版本。6/8ch 必须 v2；v1-only 消费者不能接收多声道。
2. `ready` 必须回显 `selectedVersion`、`outputChannels`、`outputLayout`、`outputChannelOrder`、`container`、`source`、`provenance`；控制帧 payloadLength=0。
3. 无共同版本 → `error` 帧，`code=unsupported_version`；不得发 v1 2ch 冒充多声道。
4. 设备不存在/UID 不匹配/布局不匹配 → `device_mismatch` 或 `container_layout_mismatch`；不得自动换到另一个设备继续。
5. 源布局未知/ambiguous → `unsupported_layout`/`source_layout_ambiguous`；不得先采再猜。
6. 源大于容器 → `source_exceeds_container`；不得捕获层降混。
7. v1-only 消费者 + 多声道容器 → 拒绝 `unsupported_version`。需要 stereo 兜底时，App 必须改选 stereo 设备走既有 HPCM v1，或升级到 v2 后在 Flow 端点侧显式 downmix；不得让多声道捕获 host 静默输出 v1 2ch。
8. 未知 `v>2` → `unsupported_version`；v2 消费者对未知可选字段必须忽略，不得因新增字段拒绝；任何既有字段语义变化必须升级 v3。
9. `ready` 只表示资源/格式准备，不表示权限 granted、非静音、声学通过。

### 6.5 有界 payload 与队列

- header ≤16384 bytes；payload ≤196608 bytes；PCM frames 1..4096；channels ≤12（R1 ≤8）。
- payload 必须精确等于 `outputFrames * outputChannels * 4`；不等 → `payload_mismatch`。
- 输入 ring ≤2.0 秒，按 `sourceRate` 和 `sourceChannels` 计：`input_bytes = 2.0 * sourceRate * sourceChannels * 4`。
- 转换后输出队列 ≤2.0 秒，按 `44100` 和 `outputChannels` 计：`output_bytes = 2.0 * 44100 * outputChannels * 4`。
- 每个端点队列 ≤4 块 × 352 frames × 2ch × 4 bytes = 11264 bytes；N 个端点合计 `N * 11264`。
- 总预算（保守上界）：`input_bytes + output_bytes + N * 11264`。8ch/48k 源约 `3,072,000 + 2,822,400 + N*11264` bytes；12ch/48k 源约 `4,608,000 + 4,233,600 + N*11264` bytes。具体实现可更小，但不得超过。
- 超限 → `queue_overflow` 全组 fail-stop；不得丢帧、截断、覆盖或“只保留最后一块”。
- 控制 stdin 单行 64KiB 上限不变；不得把 PCM 放进 JSONL。
- 所有队列/缓存必须有硬上限和清理路径；RT 回调不得分配、锁、日志、网络或等待 App。

### 6.6 连续性与 epoch

- `sequence` 从 0 严格连续；`outputFrameStart` 从 0 严格连续；`outputFrames` 1..4096。
- `sourceSequence` 只要求非递减；同一 source 元数据可对应多个输出块；`sourceFrameStart` 是本 session 输入累计索引，不是原生 sampleTime。
- `outputChannels`/`outputLayout`/`outputChannelOrder`/`container`/`sourceLayout` 在 session 内不可变；变化 → `source_layout_changed`，全组停止，新 session/epoch。
- 源 gap、droppedBlocksBefore≠0、时间戳回退、损坏 PCM → `input_discontinuity` 或 `frame_continuity`；不得补零拼接。
- `hostTime`/`sampleTime` 保留原始 flags；不得把 receipt 时钟冒充源时基；不得把 stream latency 再加进 hostTime。
- 多声道转换必须逐通道同滤波器、同 prime/trailing、同延迟；任一通道相位/延迟不同即 `channel_map_mismatch`，不得继续。
- `primeMethod=none`/`converterDelayKnown=false` 只表示未声明 converter 延迟，不表示零延迟。

### 6.7 与 core C ABI v1 的关系

- **core C ABI v1 不变**：不新增符号、不改结构体、不改 `flow_v1_create`/`add_output`/`submit` 语义。
- `flow_v1_create(sample_rate, channels)` 可传 `channels=2*N`（端点对）或 `channels=N`（离散端点）；`add_output` 的 `input_channels` 仍只是索引，不是增益。
- Flow 路由阶段（`mc_mix`）把容器 PCM 转成端点顺序的 `2*N` 交错缓冲；core v1 每个 output 路由 `[2i, 2i+1]`；离散端点可 `[k, k]` 复制。
- 任何需要系数混合的 downmix/upmix 必须在 `mc_mix` 完成，不能塞进 core v1 的索引映射；core v1 不做 mixing/gain/resample/codec。
- 如果未来必须在 core 内做多声道 mixing，另立 ABI v2；不得静默改变 v1。

## 7. 延迟、revision、buffer 与时钟

### 7.1 每设备 hfla/hflr

- 每个 R1 设备有自己的 `hfla`/`hflr`、rate、anchor、seed、running client 计数；不得共享全局值。
- `hfla`：该设备当前 rate 下的 stream latency frames，0..10×rate；仅当该设备无 running client 且无 pending 配置时可写；相同值幂等，不增 revision；写入后必须回读确认。
- `hflr`：该设备只读单调 revision，初值 1；只有该设备有效 latency 或 rate 变更才递增；相同值重复写不增；coreaudiod 重启/设备重发现后旧 revision 失效。
- `kAudioStreamPropertyLatency`：该设备唯一输出 stream，global/main 与 output/main 同值只读；input/非 main 拒绝。device latency/safety 仍为 0。
- 设置设备 A 的 `hfla` 不得通知/改变设备 B；A 的 revision 变化不得让 B 的 session 失效。
- App session key 必须包含 `{sessionUUID, deviceUID, hflr, rate, seed, containerLayout}`；切换容器设备 = 新 session，不得沿用旧 hflr/校准。
- `hfla` 是能力配置，不是安全认证；其他本地客户端可写；App 监听 revision，意外变化 → 停止组会话并重新准备。

### 7.2 buffer size

- `kAudioDevicePropertyBufferFrameSize` 在本项目目标 Mac 上由 coreaudiod 管理：HAL 暴露范围 `15..4096`，客户端可设 256/512/1024/4096 并回读。
- driver MUST NOT 宣称固定 512；`BufferFrameSizeRange` 报 `{15,4096}`；preferred 512 只是建议。
- `SetData` 接受 15..4096；`GetData` 可返回 preferred 512 或 host 最近值；DoIO MUST 接受 host 给出的 `0..4096` 帧，不得假设 512。
- 每 frame 字节数 = `4 * C`；8ch × 4096 = 131072 bytes；12ch × 4096 = 196608 bytes（RES）。RT 路径不得按固定 512 分配或越界。
- `kAudioDevicePropertyZeroTimeStampPeriod` 固定 16384，与 buffer size 独立；不得把 buffer 或 latency 机械加进 timestamp。
- 4096 帧的 8/12ch IO 必须无溢出、无堆分配、无锁；buffer 变化不得改变设备 UID/布局/revision（除非 host 触发 rate 配置）。

### 7.3 时钟与 epoch

- 每个设备独立使用 `mach_absolute_time`/`mach_timebase_info`，独立 anchor/seed；不得共享 sample clock。
- `GetZeroTimeStamp` 返回当前已到达的周期边界；sample/host 严格对应；重复查询可同边界，不得倒退；不得把 downstream latency 加进 hostTime。
- rate commit、sleep/wake、设备重发现、时钟不连续 → 新 epoch/seed；旧 session 不跨 discontinuity 续用。
- `hflr` 可能不因 sleep 递增；App 仍必须以 seed/新 session 判断，不得只看 hflr。
- 三个/七个设备可以共用 `mach_absolute_time` 的 host 时基，但 sample epoch 不可比；不得把设备 A 的 sampleTime 直接用于设备 B。
- 同一 session 只允许一个活动容器设备。不得同时捕获 stereo 与 5.1 设备拼成一个 timeline；如未来需要，另立 clock master/aggregate 契约。

### 7.4 多设备运行规则

- App 一次只选择一个容器设备作为当前输入；其他设备 idle。
- 切换容器（stereo→5.1、5.1→7.1）必须停止旧捕获/旧发送、清队列、建立新 epoch，再启动新设备；不得热切换 header。
- 不因新增设备而自动改系统默认输出；多声道设备 `CanBeDefaultSystemDevice=false`，媒体默认也需用户显式选择/Flow 接管 lease。
- 不声称多设备 aggregate 同步；R1 不做。

## 8. 错误类型

所有错误必须带 `session`（若有）、`deviceUID`（若有）、`revision`（若有）、可读 `message`、`layer` 和 `cleanupComplete`（若涉及清理）。不得用静音检测猜 DRM/权限原因。

| code | 层 | 触发 | 处理 |
|---|---|---|---|
| `driver_unavailable` | HAL | 驱动未装/未加载/UID 不存在 | 不启动；提示安装/恢复；不自动切默认 |
| `unsupported_format` | HAL | ASBD/rate/channel 不支持 | 拒绝该设备；不静默换格式 |
| `device_busy` | HAL | 有 running client/pending 配置时改 latency/rate | 停止组、清队列、重开；不杀 coreaudiod |
| `buffer_size_unsupported` | HAL | host 给出 >4096 或非法 buffer | 拒绝该配置；记录；不越界 |
| `device_mismatch` | HAL/协议 | HPCM containerUID/layout 与选中设备不符 | 停止；不自动换设备继续 |
| `channel_map_mismatch` | HAL/协议 | 通道数/顺序/逐通道延迟不一致 | 停止；不重排后继续 |
| `container_layout_mismatch` | 捕获 | 源标签在容器中无同名 slot | 不产生 PCM；提示选正确设备/7.1 |
| `unsupported_layout` | 源 | unknown/不支持/height RES | 拒绝原生；仅显式受限兜底 |
| `layout_unverified` | 源 | 声称布局但无权威证据/夹具 | 拒绝 nativeClaim；可受限路由并标未验证 |
| `source_layout_ambiguous` | 源 | 5.1 未分 side/back | 要求用户显式覆盖；不默认 |
| `source_exceeds_container` | 捕获 | 源通道多于容器或标签缺失 | 不降混；改用更大容器 |
| `source_layout_changed` | 源/协议 | session 内布局/格式变化 | 全组停止；新 session/epoch |
| `unsupported_version` | 协议 | HPCM 版本无共同/未知 >2 | 拒绝；不降级冒充 |
| `unsupported_channels` | 协议 | outputChannels 不在允许集合 | 拒绝；RES height 不实现 |
| `payload_mismatch` | 协议 | 长度≠frames×channels×4 | 全组失败；不截断 |
| `payload_too_large` | 协议 | >196608 或 header >16384 | 全组失败；不重搜 magic |
| `queue_overflow` | 协议/发送 | 输入/端点队列超预算 | 全组 fail-stop；不丢帧继续 |
| `frame_continuity` | 协议 | sequence/frameStart 不连续 | 全组失败；新 session |
| `transform_unavailable` | 路由 | 请求的矩阵/上混未实现或未启用 | 拒绝；不近似替代 |
| `route_unsupported` | 路由 | 源×端点组合无矩阵 | 拒绝；提示可用布局 |
| `endpoint_layout_unconfirmed` | 端点 | 端点位置未知/重复/不足 | 只允许 stereo/pair 或拒绝 |
| `insufficient_endpoints` | 端点 | true 5.1/7.1 端点不足 | 显式 downmix 或拒绝；不冒充 |
| `invalid_pcm_range` | 路由/协议 | 非有限或 `abs(sample)>1` | 整块拒绝；不裁剪 |
| `input_discontinuity` | 捕获 | gap/断流/时间戳回退 | 全组 fail-stop；新 epoch |
| `latency_revision_changed` | 会话 | hflr 意外变化 | 停止组、重新准备；不沿用旧 session |
| `permission_required` | 捕获 | 缺少音频录制授权 | 请求公开 TCC；不绕过 |
| `capture_path_unverified` | 捕获 | tap 不保留多声道/无有效 PCM | 保留系统 tap 兜底；不宣称多声道 |
| `cleanup_unconfirmed` | 生命周期 | 停止/释放未确认 | 有界终止专用进程；不假干净 |
| `output_restore_failed` | 生命周期 | 原输出不可用/恢复失败 | 选已验证非本项目输出并明确回报 |

## 9. 验收 gate

### 9.1 Gate 1：HAL/容器正确性

通过条件（全部满足）：

- **G1-01 枚举**：7 个 R1 设备全部出现；UID/model UID/display name/stream name/channels/layout/order 与 §2.2 完全一致；stereo 第一；reserved height 不出现。
- **G1-02 流与格式**：每设备恰好 1 个 output stream、0 个 input stream；`StreamConfiguration` output 1 buffer × C channels；ASBD `mBytesPerFrame=4C`、`mChannelsPerFrame=C`；44.1/48k 可用。
- **G1-03 布局与名称**：`PreferredChannelLayout` 与 §3.2 一致；`ElementName` 1..C 正确；`PreferredChannelsForStereo` 对 mono `{1,1}`、其余 `{1,2}`；没有固定 2ch 的残留。
- **G1-04 逐通道 PCM**：对每个设备，用唯一频率/音高逐通道写入并经 device/stream tap 读取；每通道只出现自己的信号，未用 slot 精确静音；不得出现左右复制、通道交换、把 2ch 复制成 6/8ch。
- **G1-05 buffer/DoIO**：Set 256/512/1024/4096 均成功并回读；DoIO 在 0..4096 帧不崩溃、不越界；8ch×4096=131072 bytes 正常；时间戳单调。
- **G1-06 延迟/revision 独立**：逐设备设置 `hfla`，回读正确、`hflr` 单调、同值幂等；stream latency global/output 两 scope 同值；设置 A 不影响 B；device latency/safety 仍 0。
- **G1-07 rate 独立**：逐设备 44100↔48000 配置请求/commit/abort；active IO 拒绝；失败无部分应用；其他设备不受影响。
- **G1-08 stereo 回归**：现有 stereo discover 字段、2ch ASBD、`hfla/hflr`、两 scope latency、zero timestamp 16384 保持不变；仅 DeviceList 数量变化。
- **G1-09 无输入能力**：input streams/input StreamConfiguration 空；input latency/safety 零值不得被解释为麦克风/loopback。

Gate 1 证据必须是目标 Mac 的真实枚举/属性/tap 记录；mock 通过不能代替。若 device tap 对 6/8ch 只返回 2ch，Gate 1 失败，整个设备家族不能进入 Gate 2。

### 9.2 Gate 2：源/播放器报告布局

通过条件（逐布局）：

- **G2-01 mono**：mono 源 → mono 设备 identity；逐通道夹具证明只有 M；不得用 stereo 设备冒充。
- **G2-02 stereo**：stereo 源 → stereo identity；stereo → 5.1/7.1 时 FL/FR 有信号、其余精确 `+0.0`；provenance `stereo_passthrough_in_multichannel`；UI 不称 5.1。
- **G2-03 3.0**：3.0 → 3.0 identity；3.0 → 5.1/7.1 为 `source_padded`，FC 正确、其余静音。
- **G2-04 4.0**：4.0 → 4.0 identity；4.0 → 5.1B/7.1 为 `source_padded`，BL/BR 正确；4.0 直接进 5.1S 容器必须拒绝（无 BL/BR），不得 remap 后冒充；若先进入 7.1 容器，Flow 才可用 `R` 映射到 5.1S 端点。
- **G2-05 5.1 side/back**：5.1S → 5.1S identity；5.1B → 5.1B identity；5.1S 直接进 5.1B 容器 / 5.1B 直接进 5.1S 容器必须 `container_layout_mismatch`；不得静默换 SL↔BL；若先进入 7.1 容器，Flow 才可用 `R`。
- **G2-06 7.1**：7.1 → 7.1 identity；7.1 → 6ch 必须 `source_exceeds_container`；改用 7.1 容器后由 Flow downmix。
- **G2-07 5.1→7.1 pad**：5.1S→7.1 中 SL/SR 有信号、BL/BR 精确静音；5.1B→7.1 中 BL/BR 有信号、SL/SR 精确静音；两者 provenance 不同。
- **G2-08 unknown/ambiguous**：unknown 6/8ch 不得产生原生 PCM；`unsupported_layout`；5.1 ambiguous 不得默认 side/back；只有显式 user override 才可继续且 `nativeClaim=false`。
- **G2-09 不靠静音**：同一 6ch 容器，分别测试“stereo passthrough（只有 FL/FR 非零）”和“5.1 内容但 SL/SR 恰好静音”；系统必须按 authority 报告不同 source layout，不能都猜成 stereo 或都猜成 5.1。
- **G2-10 变化**：播放中切轨/切音轨/改布局 → 全组停止、新 session/epoch；旧帧不得进入新队列。
- **G2-11 逐通道夹具**：每通道唯一频率/音高、-20 dBFS、10s、首尾 1s 静音；RMS 比例容差 0.1 dB；串音 ≤ -80 dBFS（离线）/≤ -60 dBFS（真实路径）；通道交换零容忍。

Gate 2 证据必须包含播放器版本、设置、源文件/夹具 SHA、播放器报告字段、HPCM v2 header、逐通道 RMS。仅“播放器显示了 5.1”或“发送成功”不算。

### 9.3 Gate 3：Flow 路由/端点/声学

通过条件（逐场景）：

- **G3-01 两台 HomePod**：只允许 `M_*_2` 或 `M_FRONT_PAIR`；矩阵数值与 §5.3 一致；录音可区分 L/R；UI 显示“下混/仅前置”；不得出现“5.1/7.1 原生”字样。此项可通过，但不等于 true 5.1。
- **G3-02 六端点 5.1**：6 个端点位置已确认（FL FR FC LFE SL SR）；每端点只收到自己的通道（或显式 duplicate）；录音/测向可区分 6 个方向；30 分钟同步与掉线恢复通过。LFE 端点必须能重放低频；否则记录丢弃，不能宣称完整 5.1。
- **G3-03 八端点 7.1**：8 个端点位置确认；SL/SR 与 BL/BR 可区分；30 分钟同步/恢复通过。
- **G3-04 端点不足**：少于 6/8 时只能 downmix/front；`losses` 完整；不得静默丢声道或把 6/8ch 直接送两个端点。
- **G3-05 位置未知**：端点位置未确认 → 只允许 stereo/pair；不得按发现顺序猜 FL/FR/SL/SR。
- **G3-06 height RES**：5.1.2/7.1.2/7.1.4 不测试、不宣称；请求返回 `unsupported_channels`/`unsupported_layout`。
- **G3-07 硬件限制**：两台 HomePod 的 true 5.1 gate 明确为 blocked；只有 N≥6/8 且位置/同步通过后才可 reopen。

同步/A-V 门槛：沿用 [ACCEPTANCE.md](ACCEPTANCE.md) 的实验门槛（A/V 校正后中位偏差加声明不确定性 ≤80ms，待产品批准）；端点间 30 分钟漂移作为实验指标记录，目标 ≤20ms，未获产品批准前不得写成正式质量承诺。没有录音/测向/时间戳证据，不得宣称 Gate 3。

### 9.4 证据边界

- 离线矩阵/哈希/发送成功只证明软件计划，不证明播放器采用、音箱出声或方向。
- L1 通过不等于 L2/L3；L2 通过不等于 L3；两台 HomePod 的 downmix 通过不等于 true 5.1。
- 任何“未测/不可观测/失败”必须逐项记录；不得用“大体能响”覆盖。

## 10. R1 实现范围与预留总结

| 源布局 | 设备 | 状态 | HAL/容器 | 捕获 | Flow 路由 | 声学可宣称 |
|---|---|---|---|---|---|---|
| mono | `mono.v1` | R1 | 实现/待 Gate 1 | identity | mono map/FC | 仅端点验证后 |
| stereo | `stereo.v1` | R1，既有 | 已实现 | identity/passthrough | native/downmix | 既有 stereo；两台可 |
| 3.0 | `surround30.v1` | R1 | 实现/待 Gate 1 | identity/pad | downmix to ST；pad to 5.1/7.1 | 仅 downmix/端点验证后 |
| 4.0 | `quad40.v1` | R1 | 实现/待 Gate 1 | identity/pad | downmix to ST；pad to 5.1B/7.1；5.1S 仅经 7.1 容器 remap | 仅 downmix/端点验证后 |
| 5.1 side | `surround51s.v1` | R1 | 实现/待 Gate 1 | identity/pad to 7.1 | native/remap/downmix | 两台仅 downmix；true 5.1 需 6 端点 |
| 5.1 back | `surround51b.v1` | R1 | 实现/待 Gate 1 | identity/pad to 7.1 | native/remap/downmix | 两台仅 downmix；true 5.1 需 6 端点 |
| 7.1 | `surround71.v1` | R1 | 实现/待 Gate 1 | identity | native/downmix | 两台仅 downmix；true 7.1 需 8 端点 |
| 5.1.2 | `height512.v1` | RES | 不枚举 | 不实现 | 不实现 | 不宣称 |
| 7.1.2 | `height712.v1` | RES | 不枚举 | 不实现 | 不实现 | 不宣称 |
| 7.1.4 | `height714.v1` | RES | 不枚举 | 不实现 | 不实现 | 不宣称 |
| unknown multichannel | 无 | 拒绝 | — | `unsupported_layout` | — | 不宣称 |
| 5.1 ambiguous | 无 | 拒绝/用户覆盖 | — | `source_layout_ambiguous` | 仅覆盖后受限 | 不宣称原生 |
| encoded/Atmos | 无 | 非目标 | — | — | — | 不宣称 |

状态说明：表中的 `R1` 是**目标实现/验收范围**，不等于已通过；当前只有 stereo 有真机 HAL/device Tap 证据，其余设备与源布局均待实现并通过 Gate 1/2。`RES` 只冻结命名，不产生任何可枚举对象。

**首轮真实支持结论：** R1 真实实现并逐项验收 mono、stereo、3.0、4.0、5.1 side、5.1 back、7.1 的设备与捕获路径；stereo 是既有能力，其余多声道只有在 Gate 2 通过后才可对外说“支持该源布局”。5.1.2/7.1.2/7.1.4 只预留命名/UID/通道顺序，本轮不实现。两台 HomePod 只能 downmix/前置路由，true 5.1/7.1 声学回放必须等 N 端点。

## 11. 开放问题

1. **device tap 是否保留 6/8ch**：第六候选只验证了 stereo tap 的非零左右独立 PCM；多声道 tap 是否被 Core Audio 降混、ASBD 是否保留 C 通道，必须 Gate 1 实测。若 tap 只给 2ch，整个设备家族不能进入 Gate 2，需要另立共享内存/loopback 契约。
2. **播放器对 1/3/4/6/8ch 虚拟设备支持**：mpv/IINA/VLC/浏览器具体版本能否选择并原样输出；`audio-channels`/`audio-out-params` 是否给出 side/back；浏览器可能只给 stereo 或只给容器布局。
3. **5.1 back / 4.0 的 HAL 表达**：目标 SDK 的 `LeftSurround`/`LeftSurroundDirect` 语义、显式 descriptions 在 Audio MIDI Setup/播放器中的实际显示与顺序；MPEG tag 仅作为可选替代，需要逐项断言。
4. **height tag 可用性**：5.1.2/7.1.2/7.1.4 的 SDK tag、通道标签和播放器支持均未验证；RES 不实现。
5. **端点数量/位置**：当前只有两台 HomePod；小黑在线/供电未确认；6/8 端点摆位、LFE 端点、方向测量均未准备。
6. **多设备时钟**：多个虚拟设备能否 aggregate、是否共享 sample clock、sleep/wake 行为；R1 明确不声称，未来另立契约。
7. **上混质量**：`M_ST_51S`/`M_ST_71` 只是可测线性矩阵，未做主观/声学验证；默认关闭，不能作为卖点。
8. **源布局权威性**：浏览器/部分播放器不暴露 decoder-native 布局；只能标 `player_output`，`nativeClaim=false`。是否接受“播放器输出 5.1”作为产品显示，需要产品确认。
9. **2 HomePods 的 L/R 摆位**：前置路由/下混的实际声像与延迟需声学验证；不能用软件计划代替。
10. **受保护内容**：不同 DRM/播放器/系统版本的可捕获性未验证；不得承诺通用。
11. **buffer 4096×8/12ch 的 host 行为**：需在目标 Mac 对所有设备重复 256/1024/4096 测试；驱动不得假设 512。
12. **设备列表长度**：7 个 R1 设备对用户是否过载；若产品要求收敛，需另立“可配置 N-channel”v2 契约，不能在本文静默改造。
13. **4.0 side vs back**：R1 只冻结 4.0 quad back（`FL FR BL BR`）。若目标播放器/内容把 4.0 报为 side 变体，需要单独 UID 或显式 remap 策略；不得把 side 静默装进 back 设备。

现有实验原型 `README-MULTICHANNEL.md` 使用 `.dev.` UID、仅 3 个设备实例（2ch/5.1 side/7.1）、`partial_layout_in_container` 命名、把 10ch 预留写成 5.1.4，并用 `TBL/TBR` 表示顶部后声道；它只能作为表驱动实现参考，不是生产身份。整合时必须按本文的 7 设备生产 UID、model UID、对象关系、`source_padded` 命名、7.1.2（10ch）预留与 `TRL/TRR` 标签对齐；`.dev.` bundle 可以保留作旁路 staging，但不得作为产品安装身份。

QA 验收草案 `MULTICHANNEL_ACCEPTANCE.md` 目前把 7.1 写成 `FL FR FC LFE BL BR SL SR`（WAVE mask 0x063F 顺序），并使用 `TBL/TBR`；本文冻结的是 Apple/HAL 语义的 `FL FR FC LFE SL SR BL BR` 与 `TRL/TRR`。两套顺序不能混用；QA 工具、夹具和期望 JSON 必须按本文顺序重排，并在启动时断言 `channelOrder`，否则同一 8ch 文件会把 side/back 对调。`mono` 在本文是 `M` 标签（`kAudioChannelLayoutTag_Mono`），不是 FC；QA 若继续用 FC mask，只能作为测试输入映射，不得作为容器 identity。7.1→5.1 的 side/back 折叠以本文 `0.5*SL+0.5*BL` 为准；QA 草案正文若写 0.7071，必须按 §5.3 与期望电平重算。

## 12. 变更记录

- v1（2026-11-06）：首版“源优先”多声道契约。冻结固定布局设备家族（mono/stereo/3.0/4.0/5.1 side/5.1 back/7.1；height RES）、源/容器/捕获转换分离、Flow 路由矩阵、HPCM v2、每设备延迟/revision/buffer/时钟规则、三层验收 gate 与非目标。未修改 driver/test 代码；未改变 core C ABI v1 与 HPCM v1。
