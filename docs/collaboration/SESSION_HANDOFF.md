# HomePod Flow 会话接续入口

更新：2026-11-06（Asia/Shanghai）。用户要求当前进度全部落盘、Git保存，准备换会话。先读本文，再读PROGRESS.md、TASKS.md、virtual-audio/CONTRACT.md与INTEGRATION_2026-11-06.md。不要凭历史成功覆盖当前未验项。

## Git与当前任务

仓库 https://github.com/mdxz2048/homepod 。当前开发分支codex/virtual-audio-mvp；main备份点4331d3b92cc2330e58dcf28ab50ffd4b7d6d283d，保持不动。分支fda6f14已保存虚拟驱动/输入/工具第一轮；本会话后续提交保存v0.3兼容修正、原始日志及本交接。最新保存点用git log -1查看，以远端核对为准。README只写变更记录。身份凭据不写进仓库。

用户最新已授权继续声卡安装。第五候选修正版已安装，用户已回复“已重启并登录桌面”。尚未成功读取这次重启后的枚举结果：Tailscale SSH一次超时，局域网SSH返回system locked预启动解锁提示；为执行用户保存/换会话要求已取消该连接。此提示可能来自启动过渡，不能据此否定用户桌面操作。下次先重连、验证，不要直接再次重装或让用户再重启。

## 当前真实能力与限制

- 已真机跑通Mac系统Tap声音到前方HomePod和小白；短时听感同步、多轮启停通过。不是毫秒级声学证明或30分钟稳定验收。
- 动态音量两台两轮25%→0%→15%得到协议ACK，用户确认变化、最后停止。现为硬件协议音量；不是逐样本增益。
- UI单布局设置，真实型号/坐标/数量；菜单影院/同步两模式。没有产品文件播放入口。音画延迟滑块禁用。
- 影院独立processing库Mac Release CTest1/1、Python真实绑定4项通过，尚未接入实际链路。当前影院/同步实际均复制同一L/R；不能宣称真实5.1环绕。
- App尚依赖Python开发环境与绝对runtime路径，非完整正式自包含包。Tap当前unmuted，本机重复出声待处理；一次重启ProtocolError根因未修。
- 旧核心C ABI v1及35个冻结文件不能改，快照baselines/M2-core-source.json；.gitattributes保留其原始字节。新输入、处理和驱动分库扩展。

## 声卡安装的精确状态

系统路径 `/Library/Audio/Plug-Ins/HAL/HomePodFlowAudio.driver`，root:wheel，group/other不可写，签名严格验证通过。没有切换默认输出，没有重新签名/安装GUI App。

第三候选首次安装后重启：coreaudiod创建remote driver service成功，但add-device初始化UnknownProperty（2003332927，'who?'）；CLI driver_unavailable。不是加载成功即设备可用，也未定位具体失败selector。

第五候选补齐HAL初始化属性兼容并有界诊断，Mac tests/stage均退出0。源码SHA256 `7e8987cd76780fa3ca2bafb94d1c2b70be30e36ca081666bdd8f9a8e8b37f536`，已安装binary SHA256 `78b0ec699ac53ae316343c98e82879605254da36dc3944ff72035712abd63ee5`。

原第三候选已备份：Mac live-validation/virtual-driver-backup-third/HomePodFlowAudio.driver。第五候选stage：live-validation/virtual-driver-stage-fifth/HomePodFlowAudio.driver。安装后再discover仍旧服务驻留/退出1，随后用户再次重启；新枚举尚待检查。SIP已拒绝launchctl热重载；不关闭SIP、不用kill绕过。不要自动重启未保存工作。

驱动仅output-only立体声Float32/44.1或48k/512frames，目前WriteMix sink本身不会转发HomePod。输入Tap真实PCM、源时钟、浏览器采用和声学音画均未验。契约v0.3初始reported latency0=uncalibrated，不能理解为真实零延迟。无独立恢复helper、无跨进程journal事务或真实默认输出writer，自动接管必须保持禁用。

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

1. 重连Mac（优先Tailscale；超时则LAN发现），确认桌面会话和Tailscale实际状态。不要复用旧SSH session ID。
2. cd到base；执行只读 `./source/platforms/macos/VirtualAudioInput/.build/debug/virtual-audio-input --discover`，保存JSON、stderr和exit code；再执行 `./output-latency-probe`，检查UID `com.homepodflow.virtual-audio.stereo.v1` 是否存在、AudioUnit是否可初始化以及延迟属性。
3. 若仍失败，读取重启后CoreAudio Driver helper与coreaudiod日志，查HomePodFlowAudio新增32条上限的property read rejected诊断，将十进制selector/scope解FourCC。精确关联HomePod段，勿误用Parrot等其他插件错误。再交driver/architect/QA；不盲目反复重启。
4. 下载base中的virtual-driver-tests-fourth.log、virtual-driver-stage-fourth.log、virtual-driver-tests-fifth.log、virtual-driver-stage-fifth.log、virtual-fifth-installed-verify.log与virtual-fifth-installed-discover.{json,err}。这些仍仅在Mac，本次尚未下载，不能误称已有本地原始证据。此前virtual-fifth-evidence.zip打包命令因Mac重启未执行。
5. 设备真实枚举和AudioUnit通过后，才设计device/stream Tap有限实验，验证左右独立非零PCM、源render时间戳。尚无该数据面实现；保留现有系统Tap兜底。不要将静音虚拟设备留作正常默认输出。
6. 依次完成恢复helper/lease跨进程原子事务、输入桥接、可控延迟上报实验、浏览器真实采用及同一时钟音画录制测量。播放器/浏览器可不一定采纳；属性成功不等于音画已自动同步。

原始本地证据在reports/VirtualAudio-2026-11-06/（23文件，首轮构建失败/成功及第三候选重启失败均保留）。QA已独立核对第三候选mock/stage、Input13、工具6项。第五候选执行结果协调已见工具输出，原始Mac日志待下载后再独立复核。

## 多agent工作边界

按用户授权使用总调度+架构+底层+验收协作，文件协作是事实来源；不要假设新会话保留老agent进程或ID。可按需重新分配：driver独占platforms/macos/VirtualAudioDriver；architect独占VirtualAudioInput及virtual-audio/CONTRACT.md、ARCHITECTURE.md；QA独占ACCEPTANCE.md、tests/virtual_audio；总调度统一Mac执行、安装、Git及跨模块整合。其他agent不得自行改系统或播放声音。

测试fixture是内部验收素材，不是恢复已移除的产品文件播放。用户已拿到旧录屏并要求停止传输，不要再访问/下载那个录屏。仓库不存密码、令牌、runtime配置或原音频视频。当前用户要求先保存换会话，不自动继续播放或重启。
