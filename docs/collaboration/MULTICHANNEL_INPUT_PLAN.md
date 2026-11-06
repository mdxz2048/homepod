# 多声道输入调查与实施计划

日期：2026-11-06。技术架构专项；仅文档调查，未更改采集代码、未在 Mac 执行验证。正式产品仍无文件播放入口，用户继续在自己的播放器中播放影片。系统声音采集是兼容兜底，不应成为只能保留立体声的架构上限。

## 结论与证据等级

正确目标是取得播放器**已经解码、尚未降混的多声道 PCM**，随后才按实际房间布局分配。播放器支持读取 5.1、当前选中轨道是 5.1、Core Audio 实际输出为六通道、我们取得六个具有正确方向的独立 PCM 通道，是四件分别需要证明的事。

当前 `HALCaptureBackend.swift` 明确采用 stereo mixdown，并要求实际格式为两通道；这条实现无法保留离散 5.1。此为当前实现选择，不能推广为“所有 Core Audio tap 都只能立体声”。Apple 同时提供 device/stream 定向描述和 mixdown 开关；需要首先验证指定目标设备输出流、关闭 mixdown 后，实际 tap ASBD 与数据是否保留六/八通道。初始化器存在不等于每个设备/播放器组合都已验证成功。[Apple CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)、[指定进程/设备/流初始化器](https://developer.apple.com/documentation/coreaudio/catapdescription/init(processes:deviceuid:stream:))

当播放器因为当前 Mac 内置输出只暴露 stereo 而已降混时，后置 tap 不能恢复丢失的 FC/SL/SR。下一方案是向播放器提供我们管理的六/八通道虚拟音频输出，让播放器输出解码后的多声道 PCM，再由 loopback 接入共同处理与发送。虚拟设备的能力必须真实实现，不能仅把两通道数组改名为八通道。此方案是基于公开 HAL 驱动机制的工程设计，尚不是本项目可用能力。[Apple 虚拟驱动样例](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)

## 四条输入路线

| 路线 | 可取得内容及条件 | 优先级、成本与未验证项 |
|---|---|---|
| A. 指定 process/device/stream tap | 指定进程在所选输出流上的实际 PCM；是否保留多声道要读取 tap ASBD/声道布局并逐通道验证。 | 首先做可行性实验；不强制安装 HAL 驱动。已有真实多声道输出设备时最值得先测。不能许诺内置 stereo 设备上会凭空出现5.1。 |
| B. HomePod Flow 六/八通道虚拟 HAL 输出 | 播放器输出到虚拟设备；驱动接收/loopback 解码 PCM，或通过 A 取得该设备输出流。设备公开真实 channel layout、格式和稳定时钟。 | 正式多声道通用接入的主候选。驱动安装/卸载/签名/权限与重启流程、RT安全、时钟、跨进程内存及恢复均需开发验收。 |
| C. 播放器公开控制/集成 | 可控播放器选择正确音轨、输出设备、PCM模式及布局；若有明确 PCM callback/plugin，再通过专用适配取得内容。 | 优先 mpv/IINA/VLC 已公开且当前版本可用的能力。控制API不等于PCM传输API；不能假设任意现有播放器可无配置连接。 |
| D. 系统 stereo tap 兜底 | 获取实际两通道系统声音，同步复制或经过影院立体声布局矩阵。 | 已有实现基础，真实非零采集仍在验收；显示“立体声·空间分配”，不能称原生5.1。 |

A/C/B 的优先顺序依**实际能力**决定，不反复抢占输出设备。没有可保留多声道的路径时回到 D，并清楚显示已降为两通道；不能默默丢声道后仍显示 5.1。

## Apple 官方接口能够证明什么

Apple 样例同时配置 `isMixdown`、`isMono`、`deviceUID`、`stream`，说明输出范围和混音策略可配置；tap 加入 aggregate 后作为输入读取。实际格式必须查询，不依赖初始化器名称或固定44100/2ch。[捕获样例](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

Apple 的 Audio Server Plug-in 样例提供发布虚拟设备的机制，但样例成品只有两通道 Float32 I/O、44.1/48kHz。文档要求安装 `.driver` 到 `/Library/Audio/Plug-Ins/HAL` 并重启。扩展为8ch、完整声道布局、用户态读取与正式安装是本项目额外工作，不能把样例当现成多声道驱动。其样例是用户态 Audio Server 插件机制，不等于必须编写内核扩展。[官方驱动样例](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)

Audio MIDI Setup 支持对多通道输出设备配置环绕扬声器映射；设备有多个流时，还可以选择所用流。它支持验证输出映射，但不能将本来只有两通道的设备变成真实六通道端点。[Apple 多声道扬声器配置](https://support.apple.com/en-ae/guide/audio-midi-setup/ams1005/mac)

## 播放器适配及限制

### mpv / IINA

mpv 官方控制面提供设备枚举、`audio-device` 设置、`audio-channels` 策略、输出格式信息及 JSON IPC。`auto-safe` 使用系统偏好布局，没有适用信息时可能为 stereo；`auto` 尽量使用源布局，但最终 AO/操作系统仍可能转换。显式6/8通道选项也不能替代实测。`audio-params` 与 `audio-out-params` 应分别记录，前者也不是可信的媒体原始文件唯一事实。[mpv 声道与输出设备文档](https://mpv.io/manual/stable/#options-audio-channels)

IINA 官方仓库维护者说明音频由 libmpv 处理，IINA 负责设置相关选项。可以研究其公开的 mpv 配置/插件方式实现一次授权后的集成，不能假设所有已启动 IINA 都提供可直接连接的 IPC，不能无条件改写用户配置或关闭用户播放器。[IINA 官方讨论](https://github.com/iina/iina/discussions/5774)

方案：对明确启用的 mpv IPC 客户端，读取并保存设备/布局/bitstream设置；设置为 HomePod Flow 虚拟设备和经过验证的 PCM 布局；观察实际输出变化及设备失联；关闭转发时只恢复我们仍拥有的设置。没有受支持的控制面则提示用户首次在播放器音频设备中选择 HomePod Flow，之后尽量记住选择。不要求用户在我们的 App 选文件。

JSON IPC 是控制协议，不是已提供的多通道 PCM pipe。PCM 仍走 A/B，或另外经播放器正式支持的专用音频输出插件；后者需独立开发、版本验证及许可审查。

### VLC

VideoLAN 官方 LibVLC 文档说明原有通道能否保留受操作系统及音频 API 接受能力限制；输出设备选择也有对应接口。但 `audio_output_set_mixmode` 的该项文档明确属于 LibVLC 4.0+，不能直接宣称已装 VLC 3.x GUI 具备该外部控制接口，更不能把操作我们自己的 LibVLC 实例当控制用户现有 VLC。[VideoLAN 官方音频接口](https://videolan.videolan.me/vlc/master/group__libvlc__audio.html)

先验证用户实际 VLC 版本的音频设备选择与 PCM 六通道输出；若没有可靠公开控制，保留一次选择虚拟设备的步骤，而不是新建产品内置文件播放器。插件/控制扩展如需实现另列兼容矩阵，不根据主干文档推断旧版本已支持。

## PCM、编码直通、DRM 和 Atmos

本项目输入目标是可解释布局的线性 PCM。AC-3/DTS/E-AC-3/TrueHD 的 encoded passthrough 不是六/八通道 Float32；不能把压缩载荷作为 PCM 送入音箱。mpv 官方将压缩 passthrough 作为独立 `audio-spdif` 能力；需由播放器正常解码后再路由。多声道 PCM 不依赖本 App 获得影片文件。[mpv 编码直通文档](https://mpv.io/manual/stable/#options-audio-spdif)

禁止从“影片轨道标记 Atmos”推断捕获到了对象元数据或 HomePod 已按原始 Atmos 渲染。普通 bed PCM、stereo 降混、对象音频解码输出必须分别报告。原生对象/bitstream链路是另外能力，本方案未实现。

受保护媒体能否通过具体播放器、输出设备及捕获路线取得非零 PCM，本次资料没有提供对所有 DRM 内容的保证。必须逐服务/应用/系统版本测试兼容情况，遵守公开授权，不截取密钥、不注入解密、不绕过保护；如果实际静音或不支持，显示原因和已验证兼容范围，不能承诺 HAL 绕过 DRM。静音检测本身无法区分授权拒绝、保护和用户静音，不臆测原因。

## 统一输入接口（新增独立版本，不修改冻结核心 ABI）

建议定义 `AudioInputSource v1` 适配边界：`capabilities / prepare / start / read / stop`，公开描述以下内容。源选择由策略层完成，DSP/传输只读取统一 PCM。

```text
AudioFormat {
  sampleRate; sampleType=f32; packing=interleaved|planar;
  channelCount;
  channelLayout { labels[], nativeTag?, authority, verified };
}
InputDescriptor {
  backend=process_stream_tap|virtual_hal|player_adapter|stereo_tap;
  sourceIdentity; deviceUID?; streamIndex?;
  capturedFormat; decoderReportedFormat?;
  provenance=discrete_pcm|device_mix|stereo_mixdown|unknown;
  knownTransformations[]; permissionState;
}
AudioBlock {
  session; epoch; sequence; firstFrame; frameCount;
  formatRevision; payload;
  sourceClock { domain; hostTicks; timebase; validFlags };
  discontinuity; gapFrames?;
}
```

- `labels` 是与样本索引一一对应的 FL/FR/FC/LFE/SL/SR/BL/BR 或 unknown。不能把“6”直接当通道顺序；5.1 side 与 back 要区分，缺权威布局时禁止猜测方向后宣称验证。
- 8ch固定设备承载6ch时，容器格式仍8ch，源布局可以为已证实5.1加两个空槽；不得因为slot数或两个通道临时静音自动改称7.1/5.1。布局来自设备/解码器权威信息及通道验证，不来自峰值猜测。
- PCM格式变化、输出设备/流变化、新source、seek等已知不连续点产生新revision/epoch；全路重新准备，不能在旧立体声core会话内突然塞六通道。
- 所有输入在独立转换层保留声道标签并转换采样率，不默认 stereo downmix。D 路线明确标记降混；任何降混必须写入 knownTransformations。
- 不把 HPCM v1 当前 `outputChannels=2` 的定义静默改成可变通道。新增 HPCM v2/协商能力，旧worker应拒绝未知版本。payload上限按通道数/帧数重新计算并硬限；RT环形缓存、IPC和各路队列计入总预算。
- processing目前立体声布局矩阵与多声道原生路由分成不同策略。原生5.1以实际FC/SL/SR分配并在少设备下做可测downmix，不能再经过M/S伪造原生环绕。对话覆盖、LFE有界混入及峰值预留需明确矩阵验收。

## 最少用户操作与恢复策略

默认自动检测当前来源与输出能力：可用的可证原生多声道路径优先，否则系统兜底。菜单只显示当前取得的格式与必要说明，不新增音效/声道选择。唯一布局设置页可有折叠式“连接播放器”首次帮助；高级技术信息留诊断。

驱动安装属于首次可见系统操作；由正式安装器说明用途、签名、重启及卸载。不能承诺完全无管理员/无系统操作。自动切默认输出前保存原设备、默认/系统提示音角色和所有权；用户改动优先。停止、失败、卸载后恢复可用原设备；原设备消失选择系统可用输出并解释。播放器明确绑定设备时优先控制其单独输出，不无谓修改整个 Mac。

每次只用一条主输入路径，不能将 tap 与虚拟loopback同一内容相加导致重复。路由切换先共同停止、释放、建立新epoch再恢复，隔离旧队列。不能因为某进程新出现而在权限未经同意时扩大捕获范围。

## 执行与验收顺序

| 步骤 / owner | 完成依据 | 不得替代的事实 |
|---|---|---|
| MC-01 架构/底层：stream tap实验 | 设备UID/stream、非mixdown设置、实际ASBD/layout、已知独立6ch源逐通道响应，含内置stereo与真实/虚拟多声道端点对照。 | 返回成功、6ch字段或播放器轨道标签不等于六个正确独立通道。 |
| MC-02 底层：虚拟6/8ch原型 | 设备可枚举、正确布局、44.1/48k转换、逐通道loopback、时钟/延迟/背压、稳定性；默认设备改变与恢复。 | Apple2ch样例成功不代表8ch驱动已完成。 |
| MC-03 应用：播放器适配 | 实际版本mpv/IINA/VLC选中设备、原生输出、暂停/seek/切轨/格式改变；一次配置后恢复；不打开产品内文件。 | 对自建LibVLC实例的测试不等于控制用户VLC GUI。 |
| MC-04 底层/QA：统一格式与路由 | 2/6/8ch、side/back不同顺序、未知布局拒绝、bad frame/version、epoch隔离；6ch输入到三台内容不丢FC且左右环绕方向正确。 | 8ch载体不等于7.1，stereo降混不等于5.1。 |
| MC-05 QA：实际系统与声学 | 浏览器stereo兜底+至少一个第三方播放器原生5.1路径；三台实际不同内容、30min同步及故障恢复，录音可区分各路。 | 离线矩阵/发送hash不替代实际出声和同步测量。 |
| MC-06 总协调/QA：正式安装 | 固定包身份、驱动签名/安装卸载、无开发环境、授权拒绝/恢复、退出/崩溃恢复输出设备。 | 开发机手动脚本成功不等于正式用户可用。 |

测试素材可以由QA在第三方播放器中播放已知6通道独立标识片段，仅为验收工具，不恢复本产品的文件播放功能。关键原始证据记录sample source、解码/输出/捕获各级格式、通道映射、转换、source时钟与共同presentation，不收集无关个人音频。

当前明确未知：目标Mac指定stream tap保留6ch的结果、虚拟设备实现与安装、已装播放器版本的自动控制、多声道来源的DRM兼容、输入全链路和三台声学结果。上述均未验证，不能从现有2ch采集或历史5.1文件发送继承通过。
