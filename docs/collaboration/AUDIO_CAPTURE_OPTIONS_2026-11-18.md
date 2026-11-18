# 音频采集架构与音画同步评估

日期：2026-11-18。范围：macOS 系统声音采集是否必须依赖虚拟声卡、可替代方案、立体声限制、音画同步接口可行性。本文是架构评估，不把任何未实测项标成已通过。

## 结论先行

1. **日常立体声可以不用虚拟声卡。** macOS 14.2 起的 Core Audio Process Tap 可以在不切换默认输出、不安装 HAL 驱动、不重启 `coreaudiod` 的前提下，抓取“除自己以外的全部进程”的立体声混音。启停是进程内创建/销毁 tap + private aggregate；App 崩溃时 tap 随进程消失，不会留下系统级“被占用”的设备。
2. **代价是 2 声道、TCC 权限和音量键。** 内置扬声器/普通立体声输出下，系统混音就是左右声道，拿不到 5.1；首次要授权“系统音频录制”；音量键不再作用于 Flow 设备，音量改由 App/HomePod 控制。权限被拒时系统通常不报错，只给静音，必须自己做“无信号/无权限”提示。
3. **不用虚拟声卡，就没有系统级音画延迟注入。** Chromium 会读默认输出设备的 `kAudioDevicePropertyLatency` 与首个输出流的 latency 来做 A/V 对齐；Process Tap 不改变这个值。没有可控输出设备时，浏览器画面会比 HomePod 声音早约一个 AirPlay 缓冲（通常约 2 秒）。
4. **推荐双引擎，而不是二选一：**
   - **轻量模式（默认）**：Process Tap 全局立体声，不切默认输出，适合音乐、播客、日常系统声音。
   - **影院/视频模式（按需）**：保留 HAL 8 声道虚拟设备与延迟上报，用于多声道实验和浏览器音画同步。
5. 现有 `platforms/macos/ProcessTapCapture` 已经具备大部分轻量模式基础：private tap、2 声道校验、以当前默认输出为主时钟的 private aggregate、进程排除、时间戳校验、逆序清理。缺的是产品接线、权限 UX、静音策略和端到端验收。

## 1. 当前实现与“声卡被占用”的根因

当前链路：

```text
App 开启
  → 把系统默认输出切到 HomePod Flow Audio（8ch HAL 设备）
  → 等待系统确认默认输出
  → 对虚拟设备输出流做 Device Tap
  → system_worker → HPCM → 冻结 C ABI 路由 → ALAC/RAOP → HomePod
关闭
  → 等默认输出恢复原设备 → 停 worker → 释放采集
```

这条链路把三件互相耦合的事绑在了一起：

- **系统级设备所有权**：HAL 设备由 `coreaudiod` 管理，任何 App 都可能成为它的 IO client；设备可能处于 running / busy / 采样率切换 / 客户端残留状态。
- **默认输出迁移**：写 `kAudioHardwarePropertyDefaultOutputDevice` 是同步返回，但已打开的播放器是异步迁移；必须轮询确认，失败还要回滚。
- **安装与加载生命周期**：驱动写入 `/Library`，需要管理员权限；macOS 26 SIP 拒绝脚本重载 `coreaudiod`，安装/卸载后经常要重启。

所以“驱动被占用”通常不是 CPU 被占满，而是 **HAL client/IO 状态、默认设备所有权、采样率/缓冲区协商** 三者叠加。仓库里 `RemoveDeviceClient` 清理、运行中延迟事务、默认输出回读确认，都是在给这套复杂度打补丁。

Process Tap 把这些耦合拆开：设备不是系统可见的，默认输出不动，采集资源由 App 私有持有。它不能消灭 AirPlay 准备时间，但能消灭“切换默认输出 + 等应用迁移 + 驱动加载/占用”这一段。

## 2. 方案对比

| 方案 | 安装 | 改默认输出 | 声道 | 权限 | 启停/崩溃 | 系统级延迟注入 | 适用 |
|---|---|---|---|---|---|---|---|
| **A. Process Tap 全局立体声** | 无 | 否 | 2 | 系统音频录制 | 进程内创建/销毁；崩溃自动释放 | 否 | 日常音乐/播客，推荐默认 |
| **B. Process Tap 指定设备/流（非 mixdown）** | 无 | 否 | 跟随该设备，可能 >2 | 同上 | 同上 | 否 | 已接 HDMI/多声道接收器的场景 |
| **C. ScreenCaptureKit 音频** | 无 | 否 | 1–2 | 屏幕录制 | 中等，依赖 SCStream 生命周期 | 否（有 PTS） | 录音/录屏兜底，不作为纯音频主路径 |
| **D. HAL 虚拟驱动（当前）** | 是 | 是 | 任意（现为 8ch） | 无额外采集权限 | 受 `coreaudiod`/client/采样率影响 | **是** | 影院、多声道、浏览器音画同步 |
| **E. 运行时 Aggregate Device** | 无 | 是 | 2+ | 视子设备 | 受聚合时钟/漂移/设备变化影响 | 不能可靠自定义 | 不推荐作为主路径 |
| **F. 手动 Multi-Output Device** | 无 | 是 | 2 | 无 | 人工维护 | 否 | 只适合临时对照 |
| **G. 应用内 AirPlay（AVPlayer/pyatv）** | 无 | 否 | 源内容 | 无 | 由播放器管理 | 仅该播放器内容 | 自有播放器/单应用 |
| **H. 第三方采集引擎（ACE/BlackHole/Loopback）** | 是 | 是 | 视产品 | 视产品 | 与 D 同类 | 部分产品可 | 不解决当前痛点 |

### 2.1 为什么 A 的启停会明显轻

- 不写系统默认设备，不需要等已打开的应用迁移。
- 不创建系统可见设备，不会有别的 App 抢 Flow、留下 IO client 或把设备弄成 busy。
- 不需要安装/卸载驱动，不需要 `coreaudiod` 重载，不需要为驱动升级重启。
- 失败路径是“销毁自己创建的 tap/aggregate”，不会把整机默认输出留在错误状态。
- App 被杀时 tap 随进程销毁；配合 `.mutedWhenTapped`，原声音会自动回到扬声器。

它仍然要做 private aggregate 和 IOProc，仍可能遇到默认输出设备变化、采样率变化、睡眠唤醒；但这些是“自己重建采集”，不是“系统设备被谁占着”。

## 3. Process Tap 的关键语义

Apple 文档：[Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)、[CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)、[CATapMuteBehavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)。

- **可用版本**：macOS 14.2+。
- **创建**：`CATapDescription` → `AudioHardwareCreateProcessTap`，拿到 tap `AudioObjectID`；再用 `AudioHardwareCreateAggregateDevice` 建 private aggregate，把 tap 放进 tap list。
- **全局 tap**：`isExclusive = true` 表示“tap 除 `processes` 列表之外的所有进程”；仓库的 `HALCaptureBackend` 正是这样排除自己和发送 worker。
- **私有**：`isPrivate = true`，其他进程看不到这个 aggregate；它不能作为系统默认输出，这正好避免设备占用。
- **时钟**：aggregate 的主 subdevice 必须选当前真实默认输出设备，tap 作为输入子设备，并开 drift compensation；默认输出变化就 fail-stop 重建。
- **权限**：Info.plist 需要 `NSAudioCaptureUsageDescription`；首次读取 tap 时系统提示“系统音频录制”（TCC `kTCCServiceAudioCapture`），不需要屏幕录制权限，也不会有紫色录屏指示。
- **权限失败形态**：多数情况下 API 不返回错误，只是持续给静音。产品必须用“有播放但连续 N 秒全零”提示用户去系统设置授权，不能把静音当成功。
- **静音行为**（原文语义）：
  - `.unmuted`：tap 拿到副本，原进程照常送到硬件（Mac 扬声器继续响）。
  - `.muted`：tap 拿到音频，进程不再送到硬件（tap 存在期间一直静音）。
  - `.mutedWhenTapped`：tap 未被读取时照常送到硬件；一旦有音频客户端在读 tap，读取期间不送硬件。读取停止/崩溃后原声音自动回来。
- **推荐**：如果目标是“声音只在 HomePod 出”，用 `.mutedWhenTapped` + watchdog（发送链路连续失败就停止读取/销毁 tap，让 Mac 声音回来）。如果要做“Mac 和 HomePod 同时响”，用 `.unmuted`，但要接受同房间回声/梳状滤波。

## 4. 是不是只能拿到左右声道？

先澄清：**2 声道不是 Process Tap API 的硬上限。** API 有两类用法：

- `stereoMixdownOfProcesses` / `stereoGlobalTapButExcludeProcesses`：主动混成 2 声道；
- `init(processes:deviceUID:stream:)` / `init(excludingProcesses:deviceUID:stream:)` 且 `isMixdown = false`：跟随指定设备/流的真实声道数。

轻量模式如果采用“全局立体声 tap”，输出当然只有 2 声道；但即使换成 device/stream tap，**内置扬声器本身也只有 2 声道**，所以结果仍然是左右声道。限制来自“默认输出设备 + App 的下混策略”，不是 tap 只能 2ch。

**在典型 Mac（内置扬声器或立体声输出）上：是。**

- 进程 tap 抓的是进程输出到当前设备的混音；设备是立体声，混音就是 2 声道。
- App 里的 5.1 内容会先按系统/播放器策略下混到立体声，tap 之后无法还原原始声道。
- 现有 8ch HAL 设备的意义，就是让 App 认为输出设备支持 8 声道，从而愿意输出多声道；没有这个“声明”，就没有 5.1。

**例外：默认输出本身是多声道设备。** 如果 Mac 接了支持 5.1/7.1 的 HDMI/DisplayPort 接收器，并把它设为默认输出，可以用 `initWithProcesses:andDeviceUID:withStream:` / `initWithStreams:deviceUID:`、`isMixdown = false` 去 tap 该设备的流，保留更多声道。这不是“无驱动也能任意多声道”，而是“借真实多声道设备”。

#### HDMI 直连电视，到底是 2ch 还是多声道？

HDMI 的声道数由 **EDID 协商**决定：电视/功放/回音壁告诉 Mac 自己支持哪些 LPCM 格式，macOS 再把这个能力暴露成输出设备的声道布局。常见情况：

| 连接 | Mac 通常看到的 HDMI 输出 | 实际出声 |
|---|---|---|
| Mac → 电视直连 | 多数电视只报 2ch LPCM；部分支持 5.1 LPCM | 电视内置扬声器通常仍是立体声，5.1 可能被下混 |
| Mac → AVR/回音壁 → 电视 | 常见 6ch/8ch LPCM | 由 AVR/回音壁解码播放，电视只负责画面 |
| Dolby/DTS/Atmos 位流 | 压缩位流，不是 6ch PCM | 需要接收端解码；普通 PCM tap 未必能直接拿到可用多声道 |

所以“音频也到电视”不等于“电视在播 5.1”：链路可以是多声道，电视扬声器却只出立体声；也可能是电视只接受 2ch，App 直接下混。判断方法：在“音频 MIDI 设置”里选中 HDMI 输出，看格式/声道数；再用 5.1 测试音和 tap 实际格式（`ProcessTapCapture` 会报告 channels）确认。不要仅凭“接了 HDMI”或“片源是 5.1”推断。

另需注意：仓库当前 README 写明“当前 tap 为立体声，影院模式按同声播放退化”。即使虚拟设备是 8ch 容器，也不等于原生逐声道环绕已经验收。

## 5. 音画同步：哪些接口能做什么

### 5.1 现在为什么能同步

AirPlay/RAOP 到 HomePod 的音频链路有约 2 秒的协议缓冲。视频在 Mac 本地正常播放，所以声音会晚约 2 秒。

当前做法是让 Flow 虚拟设备向系统报告约 2000ms 的 `kAudioDevicePropertyLatency` / 首输出流 latency。Chromium 的 `CoreAudioUtilMac::GetHardwareLatency()` 会读取：

- `kAudioUnitProperty_Latency`
- `kAudioDevicePropertyLatency`
- 首个输出流的 `kAudioStreamPropertyLatency`

源码注释明确写着这些延迟 “likely using this delay information for a/v sync”。仓库实测：内置扬声器按 Chromium 口径约 **16.2ms**，原生 AirPlay/HomePod 流约 **2000ms**（`docs/collaboration/reports/Native-output-latency-2026-11-06.md`）。这解释了为什么把 Flow 设备延迟写成 2000ms 后，Chrome 会把画面也压后。

但这依赖“默认输出设备是 Flow”。Process Tap 模式下默认输出仍是真实扬声器，浏览器读到的是 16ms，不会补偿。

### 5.2 接口能力表

| 接口/路径 | 能否系统级延后视频 | 需要驱动/设备 | 浏览器兼容 | 结论 |
|---|---|---|---|---|
| HAL 设备/流 latency（当前） | **能** | 需要可控输出设备（虚拟 HAL） | Chromium 已按此读取；Safari 未本轮验证 | 保留给视频/影院模式 |
| Process Tap | 不能 | 否 | 不改变浏览器读到的设备延迟 | 只解决采集，不解决口型 |
| `AVPlayer.sourceClock` / `AVSampleBufferRenderSynchronizer` / `CMTimebase` | 能，但只限自有播放器 | 否 | 不适用于浏览器 `<video>` | 自有播放器/影院 App 可用 |
| Web Audio `outputLatency` / `baseLatency` | 不能 | 否 | 只读，Web 应用可自愿使用 | 不能改 `<video>` 管线 |
| 浏览器扩展/JS 偏移 `currentTime` | 部分能 | 否 | 仅非 DRM 页面；seek/暂停易失效 | 不作为核心能力 |
| ScreenCaptureKit + 延迟显示 | 能（整屏延迟镜像） | 否 | 系统级但很重 | 不是产品路径 |
| AirPlay 协议降延迟（preroll 等） | 降低 offset，不等于注入延迟 | 否 | 依赖协议/系统版本 | 研究项，需实测 |
| Apple 系统 AirPlay 输出 | 能（系统自己处理） | 系统设备 | 浏览器原生 | 但无法做多台逐声道路由 |

### 5.3 结论

- **没有可控输出设备，就没有公开 API 能让 Chrome/Safari 系统级延后视频。** `outputLatency` 是只读的；tap 不改变默认设备属性；浏览器不会因为“音频要绕 AirPlay”而自动补偿。
- 因此轻量模式必须接受“音乐/播客无画面”这个主场景；一旦用户要看视频，切到 HAL 视频模式，或者把视频放进自有 `AVPlayer` 管线。
- 如果未来能把 AirPlay 延迟从 2s 降到 200–400ms，轻量模式的视频体验会明显改善，但仍不是零偏移；这需要协议层实测，不能先写成承诺。

## 6. 推荐架构：双引擎

### 6.1 轻量模式（默认）

```text
Process Tap（全局，排除自己/worker，2ch）
  → private aggregate（主时钟=当前默认输出）
  → IOProc → 有界 ring
  → PCM 规范化/重采样 → HPCM
  → 现有 C ABI 路由 → ALAC/RAOP → HomePod
```

- 不改默认输出，不安装驱动，不重启音频服务。
- `.mutedWhenTapped`：只让 HomePod 出声；watchdog 失败时停止读取，Mac 声音自动恢复。
- 音量：App 滑块 → `set_volume` 下发 HomePod；音量键不再控制 Flow（可后续评估媒体键监听，但需要额外权限）。
- 权限：首次引导“系统音频录制”；检测到持续静音时提示授权，不循环弹窗。
- 设备变化：默认输出/采样率/tap 格式变化 → 停采集、重建、恢复播放；不静默切设备。

#### 轻量模式能解决哪一种“同步”？

必须区分两件事：

- **多台 HomePod 之间的同步：能。** Process Tap 仍然把同一份 PCM 送入共同的播放时间线，多台音箱按同一计划开始，和当前路由核心的能力一致。
- **音频与视频的口型同步：不能，至少不能系统级。** 轻量模式不改变浏览器/播放器读取的默认输出设备，也就没有地方发布“这段声音还会晚约 2 秒”的信息。浏览器按真实扬声器的十几毫秒延迟排画面，HomePod 的声音却晚一个 AirPlay 缓冲，画面会领先。

可选缓解只有四类：

1. 看视频时切到 HAL 视频模式，继续用虚拟设备注入 2000ms 设备延迟；
2. 视频放进自有 `AVPlayer` 管线，用 `sourceClock` / `CMTimebase` 主动延后画面；
3. 用浏览器扩展/脚本偏移画面（仅非 DRM，seek/暂停易失效，不作为核心）；
4. 降低 AirPlay 协议缓冲（研究项；即使降到 200–400ms 也仍有可感知偏移，不是“解决”）。

所以轻量模式的产品定位应是 **音乐、播客、系统声音**；不要把“浏览器看视频也能对口型”写进它的能力范围。

### 6.2 影院/视频模式（按需）

- 保留现有 HAL 8ch 驱动、安装器、默认输出切换与 latency 注入。
- 只在用户开启“影院模式”或“视频音画同步”时启用；未安装时给出安装入口，而不是让日常模式也依赖它。
- 继续保留运行中延迟事务、client 清理、默认输出回读这些修复。
- 多声道/逐通道路由仍按现有验收边界，不因菜单名宣称原生环绕。

### 6.3 模式选择

| 用户意图 | 引擎 | 原因 |
|---|---|---|
| 听音乐/播客/系统声音 | Process Tap | 轻、无驱动、启停快 |
| 看浏览器视频、要口型 | HAL + latency | 需要向浏览器注入输出延迟 |
| 多声道/影院实验 | HAL 8ch | 需要让 App 看到多声道设备 |
| 只想 Mac 和 HomePod 同时响 | Process Tap `.unmuted` | 不需要切默认输出 |

## 7. 实施与验收建议

### P0：把 Process Tap 接进产品（1–2 天量级）

- 在 `adapters/live` 增加 tap 采集后端，复用 `platforms/macos/ProcessTapCapture`，用环境变量/偏好切换 `tap|hal`。
- 增加 TCC 状态与“持续静音”检测；权限未授予时给出明确入口。
- 增加 `.mutedWhenTapped` 与 `.unmuted` 两种策略；默认前者。
- 加 watchdog：连续 N 秒无有效 PCM 或发送失败 → 停止读取/销毁 tap → 恢复 Mac 声音 → 报错。
- 保留 HAL 路径，作为视频/影院模式和回退。

### P1：稳定性与体验验收

- 连续开关 30 次：每次都能在限定时间内 start/stop，无残留 tap/aggregate/IOProc。
- 30 分钟连续播放；暂停/恢复、切歌、拖动进度、浏览器重开输出流。
- 睡眠/唤醒、默认输出切换（扬声器 ↔ 蓝牙 ↔ AirPlay）、采样率切换、设备拔出。
- 权限拒绝/允许/撤销；App 崩溃/强杀后 Mac 声音是否恢复。
- AirPlay 断连、HomePod 断电、网络抖动；错误后不留下静音状态。
- 记录：启动耗时、停止耗时、CPU、内存、丢块、端到端延迟。

### P2：A/B 与音画同步决策

- 同一内容分别用 tap 与 HAL 播放，记录启动/停止耗时、CPU、稳定性。
- 用已知闪光+提示音素材，在真实 Chrome/Safari 上测 A/V 偏差；确认 HAL 的 2000ms 注入是否仍生效。
- 如果 tap 模式视频偏差不可接受，把“视频模式使用影院引擎”做成显式开关，并在 UI 说明原因。

### P3：可选驱动

- 把 HAL 安装器定位为“影院/多声道组件”，不再作为首次使用的必经步骤。
- 评估是否能进一步减少驱动暴露面（只在影院模式加载/启用），但不要在没有实测前承诺。

## 8. 风险与未验证项

- **DRM/受保护音频**：部分流媒体可能对 tap 返回静音或受限，需逐服务验证。
- **独占/Hog 模式或非 Core Audio 输出**：个别游戏/专业 App 可能抓不到。
- **权限静默失败**：TCC 拒绝时通常无 OSStatus 错误，必须靠信号检测与用户提示。
- **默认输出是 AirPlay/蓝牙**：tap 的时钟锚点和路由会变化；需要明确策略（重建/提示/拒绝）。
- **多声道**：无真实多声道设备时只能 2ch；现有 8ch 路径也未完成逐通道声学验收。
- **音画同步**：HAL 注入对 Chromium 有代码依据和仓库实测依据，但 Safari、不同网页、DRM、WebAudio 的兼容性仍需逐项验证。
- **系统版本**：Process Tap 在 macOS 14.2+ 可用；macOS 26/27 的行为、权限文案和 AirPlay 低延迟路径可能变化，需以真机为准。

## 9. 参考资料

Apple：

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
- [CATapMuteBehavior](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)
- [SCStreamConfiguration.capturesAudio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)
- [SCStreamConfiguration.channelCount](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/channelcount)
- [AVPlayer.sourceClock](https://developer.apple.com/documentation/avfoundation/avplayer/sourceclock)
- [AVAudioIONode.presentationLatency](https://developer.apple.com/documentation/avfaudio/avaudioionode/presentationlatency)

Chromium：

- [core_audio_util_mac.cc（GetHardwareLatency）](https://chromium.googlesource.com/chromium/src/+/HEAD/media/audio/mac/core_audio_util_mac.cc)
- [audio_auhal.cc（GetPlayoutTime/ProvideInput）](https://chromium.googlesource.com/chromium/src/+/HEAD/media/audio/apple/audio_auhal.cc)

同类实现/产品（外部资料，未在本机逐一复验）：

- [AudioCap](https://github.com/insidegui/AudioCap)：Process Tap 抓系统/单应用音频的参考实现。
- [CoreAudioTapKit](https://github.com/CJStanfield/CoreAudioTapKit)：Process Tap 生命周期封装。
- [SystemAudioKit](https://github.com/pieralukasz/SystemAudioKit)：Process Tap + ScreenCaptureKit 兜底。
- [audiotap](https://github.com/graphaelli/audiotap)：C 接口的系统音频 tap。
- [catap](https://github.com/sbetko/catap)：Python 绑定与录制工具。
- [BlackHole](https://github.com/ExistentialAudio/BlackHole)：开源虚拟声卡，与当前 HAL 方案同类。
- [Background Music](https://github.com/kyleneideck/BackgroundMusic)：虚拟声卡 + 每应用音量，可作为“驱动型方案复杂度”的对照。
- [Loopback](https://rogueamoeba.com/loopback/) / [Audio Hijack](https://rogueamoeba.com/audiohijack/) / [Airfoil](https://rogueamoeba.com/airfoil/mac/)：商业采集/转发实现；Airfoil 文档也说明 AirPlay 约 2 秒延迟。
- [Shairport Sync](https://github.com/mikebrady/shairport-sync)：AirPlay 接收端，文档说明 AirPlay 2 实时流约 2 秒延迟。
- [preroll](https://github.com/ksha23/preroll)：第三方尝试把 macOS AirPlay 输出延迟降到约 360ms，属于待验证研究，不是公开 API 承诺。
