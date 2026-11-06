# HomePod Flow 会话接续入口

更新：2026-11-06（Asia/Shanghai）。用户要求当前进度全部落盘、Git保存，准备换会话。先读本文，再读PROGRESS.md、TASKS.md、virtual-audio/CONTRACT.md与INTEGRATION_2026-11-06.md。不要凭历史成功覆盖当前未验项。

2026-11-06 20:00 后更新：Mac 重启后已确认 3 个可见设备（2/6/8ch），默认输出为内置扬声器；11 份重复主 App 已移入废纸篓，保留用户 Applications 下此前已验证的音量构建及现有权限身份。详见 `reports/VirtualAudio-2026-11-06/Post-restart-and-app-cleanup.md`。Mac 新增专用公钥连接别名 `homepod-mac`，无需再索要密码。用户明确要求本聊天总调度，主要实现交给百炼 DeepSeek；入口、模型选择和派工约束见 `DEEPSEEK_WORKFLOW.md`，不要把当前聊天或其他 OpenAI 子进程称作 DeepSeek。

## Git与当前任务

2026-11-06 23:49 更新：Mac 已重启，系统确认只枚举一个 HomePod Flow Audio（8ch，UID surround71.v1），已是默认媒体输出。013 Swift 47 测试和 Release 通过；014 App Debug/Release 与4组静默检查通过；016 修正 Swift ready 顶层字段与 Python 消费者不一致，Mac Python 24项通过。协调器独立重跑真实 Swift 宿主进程（注入夹具）→Python→原生核心，双端点降混、八独立端点和 EOF 清理均通过。新版 Release 已替换唯一用户 App，runtime 启用受管 v2 host，App 已启动。备份 live-validation/app-backups/20261106-234906，包含旧 App 和 runtime；真实 TCC/实际取声与 HomePod 出声仍待用户确认。没有明确完整端点角色时，实际采用立体声降混，不能宣称原生环绕声。模型启动日志核对为百炼 deepseek-v4-pro-0813，GPT只做派工、审查和安装验收。

2026-11-06 22:42 更新（进行中）：用户要求继续产品接入，并只留一个 Flow 虚拟声卡；又明确“DeepSeek token 不用省，要省的是 GPT 消耗”。故 DeepSeek 默认1800秒/100命令，充分实现自测，GPT只读结果/关键证据。新共享决定为 INTEGRATION_SINGLE_DEVICE.md：产品单个固定8ch设备，沿用surround71.v1 UID，显示HomePod Flow Audio；不是隐藏6设备，也不宣称保留播放器原始源身份。单设备真实driver/mock门禁已在Mac通过，单设备bundle已安装到原HAL路径并严格签名/哈希核对；binary SHA256 031d36674485de0bb7d39da34a7b6be18bdb0eca7e0cc90ca413b88407070825，备份 live-validation/driver-backups/family-before-single-20261106-224217/HomePodFlowAudioFamily.driver。coreaudiod尚未重启，内存旧3可见设备仍需用户最终重启后核对；不要主动重启中断任务。未切默认输出。

本轮活跃DeepSeek任务：012 Python消费/路由/worker及Mac静默测试；013 Swift受管v2 host及Mac编译/DI测试；014 App接线/状态与Mac构建。各结果写artifacts/deepseek/012-python-complete.md、013-swift-host-complete.md、014-app-checks.md。主线程已给这些任务授权SSH同步各自源码/静默编译测试，仍禁止agent安装、改系统、实际录制/出声或修改runtime.json。主线程负责最终安装、新旧App唯一化、TCC与真实信号/播放验收。App尚未被替换，runtime尚未启用新host。早期006/007/008因14命令预算停止无实现；009完成driver三处机械改动，协调器修正宏重定义并通过单设备测试。010/011及两次受限直接API尝试没有生成文件，后续由012/013全面完成。最新已提交基线仍为b40cb95；当前在同一分支继续改动，未提交，不要覆盖工作区。012/013/014互不重叠文件；不要让GPT重读其长日志，只看最终报告/必要diff。

2026-11-06 20:35 阶段进展：DeepSeek 完成 mono 采集格式门禁、独立多声道重采样器与 Swift HPCM v2 编码器；协调器修正并在 Mac 验证 35 项单测及 Release 构建，独立 Swift→Python 验收 14 组/448 包/220052 帧通过。详见 `reports/VirtualAudio-2026-11-06/Multichannel-transport-stage.md`。这覆盖软件组件及合成输入传输，不是产品 App/worker 已接入。下一步做受管 v2 capture host 与有界输出/停止，再做 App 身份实际非零 PCM。mono 真机能打开但 0 回调，不能计实际采集通过。新 worker 统一经有时限/命令次数边界的项目脚本调用。

仓库 https://github.com/mdxz2048/homepod 。当前开发分支codex/virtual-audio-mvp；main备份点4331d3b92cc2330e58dcf28ab50ffd4b7d6d283d，保持不动。分支fda6f14已保存虚拟驱动/输入/工具第一轮；本会话后续提交保存v0.3兼容修正、原始日志及本交接。最新保存点用git log -1查看，以远端核对为准。README只写变更记录。身份凭据不写进仓库。

2026-11-06 16:05 更新：第六候选已安装并完成真机验证。设备已被系统枚举，`hfla`/`hflr` 通过 `CFPropertyList`/`CFNumber` 对客户端可见并可读写，`--discover` 退出0；TCC 授权 GUI 进程中的 device Tap 已取得非零、左右独立 PCM。产品 Input 仍未实现真实 Tap 采集/转换/HPCM，WriteMix 仍为 sink。详见本目录 `virtual-audio/CONTRACT.md` v0.4 与 `reports/VirtualAudio-2026-11-06/Sixth-candidate-runtime-2026-11-06.md`。不要凭“枚举成功”宣称产品链路、浏览器或声学已通过。

## 当前真实能力与限制

- 已真机跑通Mac系统Tap声音到前方HomePod和小白；短时听感同步、多轮启停通过。不是毫秒级声学证明或30分钟稳定验收。
- 动态音量两台两轮25%→0%→15%得到协议ACK，用户确认变化、最后停止。现为硬件协议音量；不是逐样本增益。
- UI单布局设置，真实型号/坐标/数量；菜单影院/同步两模式。没有产品文件播放入口。音画延迟滑块禁用。
- 影院独立processing库Mac Release CTest1/1、Python真实绑定4项通过，尚未接入实际链路。当前影院/同步实际均复制同一L/R；不能宣称真实5.1环绕。
- App尚依赖Python开发环境与绝对runtime路径，非完整正式自包含包。Tap当前unmuted，本机重复出声待处理；一次重启ProtocolError根因未修。
- 虚拟声卡第六候选：系统枚举、AudioUnit create/bind/initialize、`hfla`/`hflr` 读写、revision 单调、stream latency 两 scope 同步、`--discover` 已通过；TCC 授权 GUI 进程的 device Tap 已测到非零、左右独立 PCM。产品 Input 采集/转换/HPCM 未实现；默认输出恢复仍靠人工/协调脚本，自动接管门禁保持关闭。
- 旧核心C ABI v1及35个冻结文件不能改，快照baselines/M2-core-source.json；.gitattributes保留其原始字节。新输入、处理和驱动分库扩展。

## 声卡安装的精确状态

系统路径 `/Library/Audio/Plug-Ins/HAL/HomePodFlowAudio.driver`，root:wheel，group/other不可写，签名严格验证通过。没有重新签名/安装GUI App。

第六候选已安装并验证：

- 源码 `platforms/macos/VirtualAudioDriver/src/FlowVirtualAudio.c` SHA256 `22ef229761c2ac8d4dbb731eda5874d001df612b124063c453cbd530e0167540`（LF 统一后；重新编译 binary 仍为下方 SHA）；安装 binary SHA256 `32a61621dea1bc8016f19b16e5a549b6cd8baaf4a07fc0d519112168738077a3`。
- 第五候选备份：`live-validation/virtual-driver-backup-fifth/HomePodFlowAudio.driver`，SHA256 `78b0ec699ac53ae316343c98e82879605254da36dc3944ff72035712abd63ee5`。
- `system_profiler` 显示 `HomePod Flow Audio`，2ch/48000/Virtual；AudioUnit create/bind/initialize 均 status=0。
- `hfla`/`hflr` 已从 `DataTypeNone` 改为 `CFPropertyList`/`CFNumber`；真机读取 hfla=0、hflr>0；设 4800 后 revision 递增且两个 scope stream latency 同步，重复写不增 revision，归零后继续递增。
- `virtual-audio-input --discover` 真机退出0，读出 UID、stereo/48k、FL/FR、revision、uncalibrated、buffer 512、period 16384。
- **buffer size 重要差异**：`kAudioDevicePropertyBufferFrameSize` 由 coreaudiod 管理；虚拟设备与内置扬声器都报 15..4096，客户端可设 256/1024/4096 并回读同一值，驱动自身 512..512 不生效。不要再宣称“范围仅512”；驱动 DoIO 必须接受 host 给出的可变帧数。
- device Tap：在带 `NSAudioCaptureUsageDescription`、TCC 已授权的临时 GUI app 中，以内置扬声器为时钟，对虚拟设备创建 device tap；只播左声道时 `callbacks=301 frames=154112 nonzero=142436 rmsL=0.169940 rmsR=0.000000 peakL=0.25 peakR=0`，时间戳 flags=7。证明 Tap 数据面与非复制左右声道成立；但这是临时 probe，不是产品 Input。
- 一次 Tap 测试前发现默认输出被改为虚拟设备，已用 CoreAudio 恢复为 `BuiltInSpeakerDevice`；未观察到驱动代码主动切换，但不能据此断言人为/其他进程原因。任何后续测试结束都必须检查默认输出。

多声道 dev family（2026-11-06 傍晚）：

- 7 设备 dev bundle 曾安装并完成 Gate 1：mono/stereo/3.0/4.0/5.1 side/5.1 back/7.1 全部枚举；通道数、ASBD、UseChannelDescriptions 布局、element 名称、每设备 hfla/hflr 隔离均通过；AudioUnit create/init 全 0。
- 8ch device Tap 传输通过：channels=8、bytesPerFrame=32、481 回调/246272 帧、timestamp flags=7；样本仍为 0 仅因 CLI 无 TCC，尚未在授权 GUI 进程验证逐通道非零。
- 用户认为 7 个设备过多，产品默认收敛为 3 个可见设备（stereo/5.1 side/7.1）；mono/3.0/4.0/5.1 back 标记 `IsHidden`，仍可按 UID 使用。
- dev family bundle 已从磁盘卸载；因未重启，7 个 dev 设备仍在 coreaudiod 内存中。
- 随后已安装 production family 到 `/Library/Audio/Plug-Ins/HAL/HomePodFlowAudioFamily.driver`（binary SHA `bdfa251e084451e20e15b2e786ded58909743e37ef3ecfa361df71dbc5163d8c`，codesign 通过），并把原 stereo bundle 移到 `live-validation/virtual-driver-backup-stereo-sixth/HomePodFlowAudio.driver`。**需要重启一次**：重启后应为 3 个可见设备（stereo/5.1 side/7.1），mono/3.0/4.0/5.1 back 标记 hidden；重启前 coreaudiod 仍是旧 stereo + 7 个 dev 设备。
- 证据见 `reports/VirtualAudio-2026-11-06/Family-driver-runtime-2026-11-06.md`。

仍未实现/未验：产品 Input 的真实 Tap 采集、ring、48k→44.1k 转换与 HPCM；App 身份下的 TCC；WriteMix 转发（当前 sink，若 Tap 产品化成立则不必改，但要保留系统 Tap 兜底）；源 render time/延迟校准、Chrome/Safari 采用、声学音画；恢复 helper/lease 跨进程事务/自动默认输出接管；6/8ch；正式签名与自包含安装包。

## Mac连接与位置

- Tailscale已用tailscale up开启，地址100.99.190.37；Windows→Mac ping曾3ms。重启后能否自恢复须检查。
- 最近局域网地址 **192.168.0.100**（mDNS `MacBook-Pro.local`；2026-11-06 17:30 起，旧 .102 已失效），SSH账号lvzhipeng。严格known-host使用HostKeyAlias=192.168.0.108（原地址别名，非当前地址）；不得关闭hostkey验证。密码不落盘，必要时由用户或安全凭据流程取得。
- Mac根目录 `/Users/lvzhipeng/Developer/HomePodSpatialRouter/live-validation`（以下base）。源码base/source。
- 已安装App `/Users/lvzhipeng/Applications/HomePod Flow.app`；不要无故重签，之前ad-hoc重签曾使录音授权失效。
- Python `/Users/lvzhipeng/Developer/HomePodSpatialRouter/.venv/bin/python`。
- 核心 `/Users/lvzhipeng/Developer/HomePodSpatialRouter/core-m2-validation/build/core/libflow_bridge.dylib`。
- runtime配置 `~/Library/Application Support/HomePod Flow/runtime.json`，不要提交其私有内容。
- Xcode `/Applications/Xcode-26.6.0.app`；ffmpeg `/opt/homebrew/bin/ffmpeg`；cmake可用。
- 前方客厅上次192.168.0.104、小白上次192.168.0.113；小黑常断电，重新扫描为准。

## 下次先做这些

1. `VirtualAudioInput.DeviceTapCapture` 已实现 2..8ch/ring/时间戳；下一步接 48k→44.1k、HPCM v2 输出和产品 worker。产品路径必须显式报告 TCC 未授权，不能静默全0。保留系统 Tap 兜底。
2. 在 HomePod Flow App 的签名/Info.plist/TCC 身份下复验同一路径；临时 ad-hoc probe 通过不等于产品 App 通过。未授权时返回 `permission_required`。HPCM v2 校验器 18测试、FlowRoutePlan 21组检查、QA 26测试/84 case/6工具已通过，但都还是离线/模型层。
3. 用 `hfla` 做受控延迟预算实验：先停止全组、确认无 running IO、设置后回读并观察两 scope 通知；记录 AU/device/stream/safety/buffer/callback hostTime/PCM receipt，再验证 Chrome/Safari 是否采用。属性成功不等于音画已同步。
4. 完成恢复 helper、lease 跨进程原子事务和默认输出恢复；在此之前自动接管保持禁用。任何 Tap/测试结束检查默认输出，不得把静音虚拟设备留作默认。
5. 下载/保存本轮第六候选原始证据与报告（已保存到 `reports/VirtualAudio-2026-11-06/`）；后续补 driver test/stage 原始日志、App 身份 TCC 结果和声学测量。
6. 再评估 6/8ch、真实 pair/多声道与正式签名/自包含安装包；不得静默取消历史需求或伪报完成。

原始本地证据在reports/VirtualAudio-2026-11-06/（23文件，首轮构建失败/成功及第三候选重启失败均保留）。QA已独立核对第三候选mock/stage、Input13、工具6项。第五候选执行结果协调已见工具输出，原始Mac日志待下载后再独立复核。

## 多agent工作边界

按用户授权使用总调度+架构+底层+验收协作，文件协作是事实来源；不要假设新会话保留老agent进程或ID。可按需重新分配：driver独占platforms/macos/VirtualAudioDriver；architect独占VirtualAudioInput及virtual-audio/CONTRACT.md、ARCHITECTURE.md；QA独占ACCEPTANCE.md、tests/virtual_audio；总调度统一Mac执行、安装、Git及跨模块整合。其他agent不得自行改系统或播放声音。

测试fixture是内部验收素材，不是恢复已移除的产品文件播放。用户已拿到旧录屏并要求停止传输，不要再访问/下载那个录屏。仓库不存密码、令牌、runtime配置或原音频视频。当前用户要求先保存换会话，不自动继续播放或重启。
