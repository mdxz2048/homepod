# 通用多声道 device Tap 采集传输（首切片）

日期：2026-11-06。执行：总协调。目标 Mac：macOS 26.5.2 / Apple M1 Pro。

本切片只实现 `VirtualAudioInput` 的通用 device-tap **采集传输**，不实现产品 App 接入、通道布局策略、HPCM v2 或声学验收。

## 代码

- 新增 `platforms/macos/VirtualAudioInput/Sources/VirtualAudioInput/DeviceTapCapture.swift`。
- 复用 `ProcessTapCapture` 的 `CaptureRing`（新增 `CaptureRing` library product）作为预分配 SPSC 环。
- 支持当前/未来虚拟设备的 2...8 声道、interleaved Float32、44.1/48k；按实际 stream ASBD 读取，不假定固定 2ch。
- Tap 使用 `CATapDescription(__excludingProcesses: [], andDeviceUID:withStream:)`，`isMixdown=false`、`isMono=false`、`isPrivate=true`、`unmuted`。
- aggregate 以默认输出为时钟；若默认输出就是被采集设备，则改用 `BuiltInSpeakerDevice`，不允许把 sink 自己当时钟。
- `readBlock()` 返回 interleaved samples、frames、channels、hostTime、sampleTime、timestamp flags、callback sequence、droppedBefore。
- CLI 新增 `virtual-audio-input --capture --seconds 1...10`；无参数仍只打印帮助，`--discover` 仍是只读。

## 运行结果

用普通 `afplay` 播放 3 秒 440 Hz WAV，临时把默认输出切到虚拟设备，再运行 CLI 采集 6 秒：

```text
blocks=468 frames=239616 nonzeroSamples=0
firstHostTime=61899161034 lastHostTime=62018733923
firstSampleTime=1 lastSampleTime=239145 timestampFlags=7
```

采集结束后默认输出已恢复为 `BuiltInSpeakerDevice`。

解释：

- 468 次回调、239616 帧和有效时间戳说明 **device tap 传输/aggregate/ring 已工作**，普通 `afplay` 也确实把声音送进了虚拟设备。
- `nonzeroSamples=0` 是因为该 CLI 进程没有 System Audio Recording 权限；同一台 Mac 上用带 `NSAudioCaptureUsageDescription`、TCC 已授权的 GUI probe 已取得非零、左右独立 PCM。因此本轮不能把 0 样本归因于驱动或传输失败。
- 产品 App 必须使用自己的签名/Info.plist/TCC 身份；CLI 结果只用于传输验证。

## 仍未完成

- 6/8ch 虚拟设备/驱动尚未安装；本采集器已能接受 2...8ch，但没有真实多声道设备可测。
- 通道标签/布局策略（FL/FR/FC/LFE/SL/SR/BL/BR、side/back、unknown 拒绝）尚未冻结到本模块。
- HPCM v2、Flow 路由/downmix/上混、App TCC 身份和多端点声学均未接入。
- 采集环当前只接受单 buffer interleaved；planar/ABL 多 buffer 会明确拒绝，不能静默改格式。

## 原始证据

- `virtual-input-cli-capture.json`
- `virtual-input-cli-restore.txt`
