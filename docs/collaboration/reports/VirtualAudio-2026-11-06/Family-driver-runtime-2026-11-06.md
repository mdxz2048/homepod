# 多声道 family 驱动真机运行记录（Gate 1 + 8ch Tap 传输）

日期：2026-11-06。执行：总协调。目标 Mac：macOS 26.5.2 / Apple M1 Pro。

本文记录 dev family bundle 的真实 HAL 枚举、格式/布局、每设备延迟隔离和 8ch device Tap 传输。它**不代表**产品 3 设备方案、HPCM v2、App 路由或声学验收通过。

## 安装

- dev bundle：`/Library/Audio/Plug-Ins/HAL/HomePodFlowAudioFamily.driver`
- bundle id：`com.homepodflow.audio.driver.family.dev`
- binary SHA256：`6b938e7572b852ca87143c62abc63da9085fdb3a19ba9e52545cc5508d99c6d2`
- 独立 factory UUID / `.dev` UID，不覆盖现有 stereo 驱动。
- 现有 stereo bundle `/Library/Audio/Plug-Ins/HAL/HomePodFlowAudio.driver` 未改动。

## Gate 1：7 设备枚举

`system_profiler` 与 CoreAudio 都枚举出：

| 设备 | 通道 | ASBD bytes/frame | Element labels |
|---|---:|---:|---|
| Dev Mono | 1 | 4 | M |
| Dev Stereo | 2 | 8 | FL FR |
| Dev 3.0 | 3 | 12 | FL FR FC |
| Dev 4.0 | 4 | 16 | FL FR BL BR |
| Dev 5.1 Side | 6 | 24 | FL FR FC LFE SL SR |
| Dev 5.1 Back | 6 | 24 | FL FR FC LFE BL BR |
| Dev 7.1 | 8 | 32 | FL FR FC LFE SL SR BL BR |

所有设备：

- AudioUnit create / bind / initialize 均 status=0。
- `kAudioDevicePropertyPreferredChannelLayout` 返回 `tag=0`（`UseChannelDescriptions`）+ 正确数量的 channel descriptions；side/back、7.1 顺序和 azimuth 均正确。
- `hfla=0`、`hflr=1`；每设备独立设置 4800 后 revision 从 1→2，归零后 2→3，其他设备不受影响。
- 默认输出仍是 `BuiltInSpeakerDevice`。

结论：Gate 1 的枚举、通道数、ASBD、layout descriptions、逐设备延迟/revision 通过；仍是 dev bundle，不是生产身份。

## 8ch device Tap 传输

用 8ch 7.1 WAV（300...1000Hz 每通道不同频率，3 秒）作为源，临时把默认输出切到 Dev 7.1，运行 `virtual-audio-input --capture --device-uid ...dev.surround71.v1`：

```text
channels=8 bytesPerFrame=32
blocks=481 frames=246272
firstHostTime=12805903463 lastHostTime=12928785843
firstSampleTime=21 lastSampleTime=245785
timestampFlags=7
channelRms=[0,0,0,0,0,0,0,0]
```

解释：

- 8ch Tap 能创建、aggregate 能启动、ring 能收到 8ch 块并保留时间戳，说明 **8 通道传输路径格式正确**。
- 样本全 0 仍是 CLI 进程缺少 System Audio Recording TCC；此前 TCC 已授权的 2ch GUI probe 已拿到非零、左右独立 PCM。
- 因此“8ch Tap 有真实逐通道非零 PCM”尚未通过；需要把同一采集放进 TCC 授权 GUI 进程再测。
- 测试后默认输出已恢复 `BuiltInSpeakerDevice`。

## 产品设备数量决定

7 个 dev 设备仅用于验证能力；用户明确认为系统声音列表不应出现 7 个设备。产品默认收敛为 3 个：

- Stereo 2ch
- 5.1 Side 6ch
- 7.1 8ch

Mono / 3.0 / 4.0 / 5.1 Back 作为高级/后续能力，不作为默认枚举。完整 family 保留为 dev/QA 构建。

## 未完成

- TCC 授权 GUI 进程下的 6/8ch 逐通道非零 PCM。
- 产品 3 设备 minimal build 与安装；当前系统仍是 7 设备 dev bundle。
- HPCM v2、Flow 路由、App 集成。
- 多端点声学；两台 HomePod 只能 downmix/前置。

## 原始证据

- `virtual-family-system-profiler.txt`
- `virtual-family-probe.txt`
- `virtual-family-layout-probe.txt`
- `virtual-family-latency-set.txt`
- `virtual-family-8ch-tap.json`
