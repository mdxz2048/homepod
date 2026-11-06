# HomePod Flow 会话接续入口

更新：2026-11-06（Asia/Shanghai）。用户要求当前进度全部落盘、Git保存，准备换会话。先读本文，再读PROGRESS.md、TASKS.md、virtual-audio/CONTRACT.md与INTEGRATION_2026-11-06.md。不要凭历史成功覆盖当前未验项。

## Git与当前任务

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

仍未实现/未验：产品 Input 的真实 Tap 采集、ring、48k→44.1k 转换与 HPCM；App 身份下的 TCC；WriteMix 转发（当前 sink，若 Tap 产品化成立则不必改，但要保留系统 Tap 兜底）；源 render time/延迟校准、Chrome/Safari 采用、声学音画；恢复 helper/lease 跨进程事务/自动默认输出接管；6/8ch；正式签名与自包含安装包。

## Mac连接与位置

- Tailscale已用tailscale up开启，地址100.99.190.37；Windows→Mac ping曾3ms。重启后能否自恢复须检查。
- 最近局域网地址192.168.0.102（可能改变），SSH账号lvzhipeng。严格known-host使用HostKeyAlias=192.168.0.108（原地址别名，非当前地址）；不得关闭hostkey验证。密码不落盘，必要时由用户或安全凭据流程取得。
- Mac根目录 `/Users/lvzhipeng/Developer/HomePodSpatialRouter/live-validation`（以下base）。源码base/source。
- 已安装App `/Users/lvzhipeng/Applications/HomePod Flow.app`；不要无故重签，之前ad-hoc重签曾使录音授权失效。
- Python `/Users/lvzhipeng/Developer/HomePodSpatialRouter/.venv/bin/python`。
- 核心 `/Users/lvzhipeng/Developer/HomePodSpatialRouter/core-m2-validation/build/core/libflow_bridge.dylib`。
- runtime配置 `~/Library/Application Support/HomePod Flow/runtime.json`，不要提交其私有内容。
- Xcode `/Applications/Xcode-26.6.0.app`；ffmpeg `/opt/homebrew/bin/ffmpeg`；cmake可用。
- 前方客厅上次192.168.0.104、小白上次192.168.0.113；小黑常断电，重新扫描为准。

## 下次先做这些

1. 把已真机验证的 device Tap 路径实现进 `platforms/macos/VirtualAudioInput`：create tap/aggregate、IOProc、有界 ring、48k→44.1k、HPCM v1 字段与源时间戳；产品路径必须显式报告 TCC 未授权，不能静默全0。保留系统 Tap 兜底。
2. 在 HomePod Flow App 的签名/Info.plist/TCC 身份下复验同一路径；临时 ad-hoc probe 通过不等于产品 App 通过。未授权时返回 `permission_required`。
3. 用 `hfla` 做受控延迟预算实验：先停止全组、确认无 running IO、设置后回读并观察两 scope 通知；记录 AU/device/stream/safety/buffer/callback hostTime/PCM receipt，再验证 Chrome/Safari 是否采用。属性成功不等于音画已同步。
4. 完成恢复 helper、lease 跨进程原子事务和默认输出恢复；在此之前自动接管保持禁用。任何 Tap/测试结束检查默认输出，不得把静音虚拟设备留作默认。
5. 下载/保存本轮第六候选原始证据与报告（已保存到 `reports/VirtualAudio-2026-11-06/`）；后续补 driver test/stage 原始日志、App 身份 TCC 结果和声学测量。
6. 再评估 6/8ch、真实 pair/多声道与正式签名/自包含安装包；不得静默取消历史需求或伪报完成。

原始本地证据在reports/VirtualAudio-2026-11-06/（23文件，首轮构建失败/成功及第三候选重启失败均保留）。QA已独立核对第三候选mock/stage、Input13、工具6项。第五候选执行结果协调已见工具输出，原始Mac日志待下载后再独立复核。

## 多agent工作边界

按用户授权使用总调度+架构+底层+验收协作，文件协作是事实来源；不要假设新会话保留老agent进程或ID。可按需重新分配：driver独占platforms/macos/VirtualAudioDriver；architect独占VirtualAudioInput及virtual-audio/CONTRACT.md、ARCHITECTURE.md；QA独占ACCEPTANCE.md、tests/virtual_audio；总调度统一Mac执行、安装、Git及跨模块整合。其他agent不得自行改系统或播放声音。

测试fixture是内部验收素材，不是恢复已移除的产品文件播放。用户已拿到旧录屏并要求停止传输，不要再访问/下载那个录屏。仓库不存密码、令牌、runtime配置或原音频视频。当前用户要求先保存换会话，不自动继续播放或重启。
