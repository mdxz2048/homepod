# 第六候选虚拟声卡运行验证

日期：2026-11-06（Asia/Shanghai）。执行：总协调。目标 Mac：MacBook Pro `MacBookPro18,3` / Apple M1 Pro / macOS 26.5.2（25F84）。

本文只记录本轮真机证据。它证明 HAL/AudioUnit/自定义属性/device Tap 数据面的一部分已通过，**不证明**产品链路、浏览器音画补偿、恢复 helper 或正式安装包已完成。

## 安装

- 第六候选源码 `platforms/macos/VirtualAudioDriver/src/FlowVirtualAudio.c` SHA256：`22ef229761c2ac8d4dbb731eda5874d001df612b124063c453cbd530e0167540`（已将 2 处 CRLF 统一为 LF；重新编译后 binary SHA 未变，仍是 `32a616…`，系统内已装 binary 与最终源码对应）
- 安装 binary SHA256：`32a61621dea1bc8016f19b16e5a549b6cd8baaf4a07fc0d519112168738077a3`
- 系统路径：`/Library/Audio/Plug-Ins/HAL/HomePodFlowAudio.driver`，`root:wheel`，group/other 不可写，`codesign --verify --strict` 通过。
- 第五候选已备份：`live-validation/virtual-driver-backup-fifth/HomePodFlowAudio.driver`，SHA256 `78b0ec699ac53ae316343c98e82879605254da36dc3944ff72035712abd63ee5`。
- 安装与验证期间默认输出保持 `BuiltInSpeakerDevice`；一次 Tap 测试前发现默认输出被改为虚拟设备，已用 CoreAudio 显式恢复为内置扬声器。未观察到驱动代码主动切换默认输出，但不能据此断言其他进程/人工操作原因。

## 自定义属性与延迟

第六候选把 `hfla`/`hflr` 从 `kAudioServerPlugInCustomPropertyDataTypeNone` 改为 `CFPropertyList`，数据用 `CFNumber` 承载。真机读取：

```text
hfla status=0 size=8 value=0
hflr status=0 size=8 value=1
```

写入验证：

```text
before hfla=0 hflr=3 stream_global=0 stream_output=0
set_hfla=4800 status=0
after  hfla=4800 hflr=4 stream_global=4800 stream_output=4800
set_same_status=0 hflr=4
reset_status=0 hfla=0 hflr=5 stream_global=0 stream_output=0
```

结论：

- 客户端已能看到并读写 `hfla`，`hflr` 单调递增。
- 相同值重复写入不增加 revision。
- `kAudioStreamPropertyLatency` 的 global/main 与 output/main 都同步为同一值。
- 立即归零后 revision 仍继续递增；这是配置 revision，不是“已校准”信号。
- 本轮只验证属性/通知，不代表真实下游延迟或声学延迟已测准。

## HAL 枚举与输入发现

`virtual-audio-input --discover` 退出 0，读出的关键字段：

- UID：`com.homepodflow.virtual-audio.stereo.v1`
- 采样率：48000
- 格式：Float32 interleaved stereo，labels `FL/FR`
- latency：revision 3（该次运行）、reportedFrames 0、`uncalibrated`
- bufferFrames：512
- zeroTimestampPeriod：16384
- deviceLatencyFrames：0，safetyOffsetFrames：0
- `tapVerified`：false（discover 只做属性发现，不创建 Tap）

AudioUnit 仍可 create/bind/initialize，status 均为 0，输出仍是虚拟设备自身、未切默认。

## 真实 HAL 的 buffer size 行为差异

核心发现：`kAudioDevicePropertyBufferFrameSize` 在这台 Mac 上由 coreaudiod 管理，未采用驱动返回的固定 512。

```text
虚拟设备：fsz# status=0 size=16 min=15.000 max=4096.000
内置扬声器：fsz# status=0 size=16 min=15.000 max=4096.000
```

对虚拟设备连续设置并回读：

```text
set=256  status=0 read=256
set=512  status=0 read=512
set=1024 status=0 read=1024
set=4096 status=0 read=4096
set=512  status=0 read=512
```

驱动 `GetData` 仍返回 512、`SetData` 对非 512 返回 IllegalOperation，但客户端实际看到的是 host 缓存值。结论：

- “buffer 范围仅 512”在真实 HAL 上不成立，不能作为客户端验收前提。
- 驱动的 sink IO 路径不依赖 512；`DoIO` 只消费 host 给出的帧数，当前不会因 256/1024/4096 崩溃。
- 需要单独决定是否把 buffer size 改成只读、实现真实可变 buffer，或在契约中明确“host 管理、驱动接受可变帧数”。本轮为不阻塞发现，Input 只校验当前值在 host 范围内且 16...4096。

## device Tap 数据面

用带 `NSAudioCaptureUsageDescription` 的临时 GUI app（ad-hoc 签名，TCC 允许后运行）对虚拟设备创建 device tap，aggregate 以 `BuiltInSpeakerDevice` 为时钟。播放端是同一 app 内写入虚拟设备的 HALOutput AudioUnit；虚拟设备本身是 sink，不会出声。

只播左声道 440 Hz、右声道静音，结果：

```text
callbacks=301 frames=154112 nonzero=142436 badLayout=0
rmsL=0.169940 rmsR=0.000000 peakL=0.250000 peakR=0.000000
timestamps flags=7 firstHost=13864714507 lastHost=13941514625
```

同一 app 早前以左右各 440/880 Hz 播放时，左右 RMS 均约 0.1696；左单声道测试进一步证明左右没有被复制成同一内容。

结论：

- 在 TCC 已授权的 GUI 进程中，output-only 虚拟设备的 device/stream Tap 能取得非零、左右独立的 Float32 PCM。
- 同一测试在 SSH CLI 进程中对虚拟设备和内置扬声器都读不到非零 PCM；因此此前“全 0”不能归因于驱动失败，CLI 进程缺少系统音频录制授权/打包身份是主要变量。
- 时间戳 flags=7（host time + sample time 有效）已记录；尚未验证源 render time 是否已含呈现偏移。
- 这不等于产品 App 已接入 Tap，也不等于浏览器音画补偿或声学同步通过。

## 仍未完成

- VirtualAudioInput 目前只有 discover，没有真实 device Tap 采集、ring、格式转换与 HPCM 输出实现。
- 产品 App 尚未接入该 Tap 路径；App 的 TCC/Info.plist 身份需单独验证。
- 驱动 WriteMix 仍是 sink；若 device Tap 产品化成立，不需要改 WriteMix 转发，但必须保留系统 Tap 兜底。
- 延迟校准、Chrome/Safari 实际采用、真实音画与声学测量均未做。
- 恢复 helper、lease 跨进程原子事务、默认输出自动接管门禁仍未实现。
- 正式签名、自包含安装包、卸载/回滚流程仍缺。

## 原始证据

同目录：

- `virtual-sixth-discover.json`
- `virtual-sixth-discover.err`
- `virtual-sixth-props.txt`
- `virtual-sixth-latency-set.txt`
- `virtual-sixth-latency-probe.json`
- `virtual-sixth-tap-left-only.txt`
- `virtual-sixth-default.txt`
