# HomePod Flow 当前进度

## 2026-11-21 0.4.4/build32 采集宿主自愈

- 与 0.3.5 对比：`platforms/macos/VirtualAudioInput`、`hub.py`、`pcm_v2.py` 均无差异；0.3.5 不是免疫，而是没校准（HAL 2000 ms）或没在影院模式下开浏览器。0.4.x 的 2413 ms 校准时间线让浏览器新客户端接入时的设备侧不连续更容易触发宿主的致命退出。
- 0.4.3 日志确认：宿主退出码 3、stderr 空、无 error 帧、Python 读到 HPCM 前缀 EOF；输入队列峰值仅 0.52 s（预算 2 s），不是消费者溢出。宿主在设备侧不连续时直接 `exit(3)`。
- 0.4.4 改为 worker 侧 supervisor：宿主异常退出时自动重建 `virtual-audio-host` 并继续向同一 hub 供 PCM；30 秒内最多 3 次，超过则干净失败；影院 hub 的 stall 容忍从 2 s 放宽到 5 s；报告新增 `capture_restarts`、`capture_last_restart_error`、`capture_stderr_tail`、`capture_host_returncode`。
- 44 项 live PCM/volume 测试通过；0.4.4/build32 已构建并安装，`build/releases` 与 `/Applications` 只保留 0.4.4。

## 2026-11-21 0.4.2/build30 worker 会话诊断

- 0.4.1 复现日志：`worker error code=cleanup_failed message=system session failed (ProtocolError)`。浏览器启动后 AirPlay/pyatv 会话报协议错误，worker 结束；App 无法确认清理，自动关闭并恢复默认输出。没有 SIGSEGV。
- 0.4.1 的 worker stderr 为空，拿不到 pyatv 的 traceback。0.4.2 在 `system_worker._run_session` 失败时把完整 traceback 与 `session.report`（含 capture_error_message、capture_last_error_detail、hub_stopped、cleanup_complete 等）写入 `~/Library/Application Support/HomePod Flow/Diagnostics/worker-session.log`。
- 0.4.2/build30 已构建并安装；只需复现一次即可定位是采集宿主被浏览器新音频客户端打断，还是 pyatv 的 AirPlay 控制/流连接超时。

## 2026-11-21 0.4.1/build29 会话失败日志

- 0.4.0 实测：校准通过、影院模式可切换；打开 YouTube 后 App 自动关闭，状态为 `cleanupUnconfirmed`（“音频服务已中断，未能确认音箱会话已清理”）。默认输出已正确恢复为内置扬声器，Flow 设备空闲，worker 已退出；没有崩溃报告，说明是 worker 返回了清理失败而非 SIGSEGV。
- 0.4.0 不落盘 worker stderr，无法判断是采集宿主停止超时、设备被新音频客户端占用，还是 AirPlay 会话错误。新增 `FlowDiagnosticsLog`：worker 失败时把 stderr 写入 `~/Library/Application Support/HomePod Flow/Diagnostics/worker-failure.log`，会话错误与 stop 失败写入 `session-events.log`（512 KB 轮转）。
- 0.4.1/build29 已构建并安装；App 签名校验通过，`build/releases` 与 `/Applications` 只保留 0.4.1。下一步复现后读取这两个日志定位根因。

## 2026-11-21 0.4.0/build28 文档、隐私收敛与打包

- 声学测量方案与算法已完整写入 `docs/ACOUSTIC_CALIBRATION.md`：信号参数（1 s × 6、间隔 0.6 s、总长 9 s、300–6000 Hz）、逆滤波定位、85% 最早峰、共享速度搜索、弱信号回退、时钟窗口、残差拟合、多台补偿与 100 ms 复验容忍度。
- 隐私收敛：`AudioComponentService.locateInstaller()` 不再枚举 Downloads/Desktop/Documents，只查环境变量、App 内置资源、App 同目录、`/Users/Shared` 与 `/Applications` 的固定文件名；已用 `tccutil` 重置该 App 的 Downloads/Desktop/Documents 授权记录。安装后的二进制中不再包含这些目录字符串。
- README 增加 0.4.0 变更记录；版本按 GitHub 0.3.5 +1 设为 0.4.0/build28。
- 0.4.0/build28 已构建并安装：App 签名校验通过，内置 Runtime 含 weak-signal 回退；`build/releases` 与 `/Applications` 只保留 0.4.0。驱动未变，无需重启。

## 2026-11-21 复验容忍度调整与 0.3.24/build27 安装

- 0.3.23 实测：首测客厅 2417.4、小白 2413.8、小黑 2409.8 ms（三台间 7.6 ms，单台波动 0.1–1.8 ms）；复验客厅 2413.4、小白 2396.2、小黑 2408.5 ms。小白两轮之间移动 17.6 ms，触发“音箱间 17 ms、目标误差 22 ms”。
- 原因不是算法或环境声，而是 HomePod AirPlay 每次新建流时的缓冲差异；单台重复测量的 17–22 ms 漂移在此范围内属于正常。原验收门槛“音箱间 ≤10 ms、目标误差 ≤15 ms”过严。
- 按用户标准（单台两次波动 100 ms 内可接受），将 `CalibrationVerification.toleranceMS` 设为 100 ms，音箱间与目标误差都用该值；首测每段 12 ms 的波动上限保持不变。
- 0.3.24/build27 已构建并安装：App 签名校验通过，内置 Runtime 仍为含 weak-signal 回退的版本；`build/releases` 与 `/Applications` 只保留 0.3.24。驱动未变，无需重启。

## 2026-11-21 复验写入 device_busy 修复与 0.3.23/build26 安装

- 0.3.22 实测已经能稳定测出延迟：客厅 2401.9/2406.5/2399.2 ms、小白 2412.5/2419.1 ms、小黑 2410.8/2415.8 ms，单轮波动 0.08–4.1 ms。环境声没有再影响峰值定位。
- 这次失败发生在逐台复验：测试播放引擎在每一轮结束后只静音、不停止，持续占着 Flow HAL 设备；下一轮会话写入测得延迟时被驱动判为 `device_busy`（guarded write deferred），App 因此把整轮校准重跑 4 次后报“逐台复验未通过”。报告里 analysis 均为成功值，latency_state 为 pending/device_busy。
- 修复：`CalibrationStore.measure` 每轮结束调用 `player.stop()` 释放 HAL client，下一轮由 `player.start()` 新建引擎；不再让测量引擎跨轮占用声卡。最终写入延迟前设备已空闲。
- 0.3.23/build26 已构建并安装：App 签名校验通过，内置 Runtime 仍含 weak-signal 回退；`build/releases` 与 `/Applications` 只保留 0.3.23。驱动未变，此次修复只涉及 App，无需重启。
- 后续若单段被环境瞬态污染，可再加“六段中孤立离群点剔除”（仅当次大偏差 <4 ms 且最大偏差 >8 ms 时丢弃该段），避免为一段噪声重跑整轮。

## 2026-11-21 反射环境判据修复与 0.3.22/build25 安装

- 0.3.21 实测仍失败，但不是版本或定位规则问题：小白六段直达峰 PSR 258–1065、直达 439.6 ms、反射在 +14.2/+29.4 ms，逆滤波定位很清楚；失败是因为波形相关系数只有约 0.10，旧的 `score >= .15` 有效性门槛在正确速度 0.9979 下只留下 1/6 段，速度搜索被迫选到 0.99，残差每段增加约 6 ms，最终报漂移 3.96 ms/s。
- 小黑是 iPhone 麦克风在录音 0.50/0.76 s 发生 +4.35/−3.08 ms 时钟重同步；测试音在 3.17 s 后才开始，旧检查扫描整份 clock 文件，用 3 ms 阈值误拒。
- 修法以“已知测试音”的匹配峰为主判据：常规路径不变，仅在常规搜索失败时启用弱信号回退，要求 PSR ≥ 20、score ≥ .05、至少 5/6 段、波动 ≤ 10 ms、漂移 ≤ 1 ms/s；时钟连续性只检查测试音窗口（注入前 0.25 s 到注入后 12 s），不再被麦克风启动重同步误伤。
- 两份真实录音复算：小白 2444.3 ms/波动 1.43 ms/漂移 0.02 ms/s，小黑 2418.1 ms/波动 2.58 ms/漂移 −0.33 ms/s；27 项声学与连续测量测试全部通过。
- 0.3.22/build25 已构建并安装：App 签名校验通过，内置 Runtime 含 weak-signal 回退；`build/releases` 与 `/Applications` 均只保留 0.3.22。驱动二进制未变（bf22a636…），此次修复只涉及 App/worker，可不重启直接复测。

## 2026-11-21 近反射定位修复与 0.3.21/build24 安装

- 真实失败录音复算：六段到达时间稳定（小白 405.13→410.20 ms，小黑 404.03→404.74 ms），失败原因是每段都带 81%–92% 强度的近反射，旧规则“次峰超过 80% 即无法定位”直接把有效单元判死；同时搜索半径 350 ms 小于 iPhone 路线约 405 ms 的实际到达。
- 定位改为在有效到达范围内取“最早达到最强峰 85% 的峰”，`MATCH_RADIUS_MS` 350→550；两份真实录音复算小白 2404.9 ms/波动 5.1 ms、小黑 2403.8 ms/波动 0.9 ms。
- 失败录音保留改为最近 6 组，并用 produced/preserved 标记避免同一失败重复保存、不再误删第一台录音。
- 打包脚本修复：`hdiutil` 默认 APFS 自动尺寸对 68 MB pkg 留量不足，复制时报“设备上无剩余空间”；`build-installer.sh` 改用 `-fs HFS+` 后正常生成 DMG。
- 0.3.21/build24 已构建并安装：pkg/dmg SHA256 与 manifest 一致，DMG 挂载校验通过，App/驱动签名及 App 可执行文件 SHA256（8936877a…）、驱动 SHA256（bf22a636…）核对通过；postinstall 已把默认输出恢复为 MacBook Pro 扬声器，并写入 `upgrade-requires-reboot` 等待重启。
- 已清理 0.3.20 pkg/dmg 与 `/Users/Shared/HomePodFlow-0.3.0`、`0.3.1` 到废纸篓；`build/releases` 仅保留 0.3.21-24，`/Applications` 仅保留 0.3.21。驱动磁盘文件已更新但内存实例仍是启动时版本，需重启后复验声学延迟。

## 2026-11-21 外部标准测试音与逐台复验 0.3.20/build23

- 用户要求不再自行合成测量音。改为打包外部 WAV：MIT 许可的 `Useful-Audio-Signals` 对数/线性扫频及配套逆滤波，和 Wikimedia Commons 公有领域粉红噪声。来源、许可证、SHA-256 和 44.1/48 kHz 转换过程记录在 `adapters/calibration/assets/SOURCES.md`。
- 播放与 Python 分析读取同一组资源；Swift 与 Python 的 9 秒重复波形逐样本一致（44.1k/48k 最大差 0）。每个一秒单元峰值 -6 dBFS，边界 10 ms 余弦淡化。
- 对数扫频改为逐单元逆滤波求脉冲响应，不再只做整段归一化相关。六个一秒单元分别定位，允许一个单元缺失，至少需要四个有效单元；保留速度/漂移、双峰、削波和硬件时钟连续性检查。
- 失败录音现在同时写入 `first_sample_ns`、`injection_ns`、`nominal_ms`、`probe_kind`、`probe_rate` 和 `signal_version`，以后可以直接离线复算。旧 10:08 失败录音的两份 `.f32` 完全相同，双峰间隔 15.3 ms、次峰比 0.945；较早峰对应约 310 ms，与客厅成功测得的 309.8 ms 一致。因旧文件未保存麦克风起始时间，只能给出候选值，不能认证。
- 多台测试改为逐台测量、逐台复验。单台失败会记录“音箱名：原因”后继续测下一台，不再让第一台的异常中断整轮。共同同时播放的复验已取消，避免相同测试音在同一录音里互相污染。
- 外部音频文件随 App 和冻结 worker 一起打包；PyInstaller 增加 asset 数据目录。10 项连续测量 DSP 测试、17 项原有校准/延迟测试通过，Swift 波形与 Python 完全一致。
- 构建并安装 0.3.20/build23，删除旧版本包与旧安装。

## 2026-11-21 iPhone 麦克风、精细速率搜索与录音尾部修复 0.3.16/build19

- 允许 iPhone 通过 Continuity（ccwd/ccwl）作为录音输入，并新增“录音麦克风”选择。时间戳仍由 Mac 的 CoreAudio HAL 统一提供，不需要跨设备对时。iPhone 拾音峰值 0.31，远高于 Mac 内置的 0.02–0.15。
- 修复录音尾部边界 bug：8 秒模板加 0.75 秒搜索半径超出 14.4 秒 iPhone 录音末尾，导致每台都报“录音未完整覆盖”。改为裁剪搜索上界，同一份录音现在可解析。
- 播放链路会以略偏的速率消费样本，粗候选后再做 ±0.4% / 0.1% 精细搜索；延迟改用窗口拟合线在起点处的截距，避免残余速率误差被折进延迟值。真实 iPhone 扫频录音：残差 409.7ms、波动 4.22ms、匹配度 0.407、漂移 -0.27ms/s、速度 1.001。
- 注意：iPhone 录到的绝对延迟含约 90ms Continuity 传输延迟，多台相对同步不受影响，写绝对音画补偿前需要用 Mac 内置麦克风标定。
- 29 项校准/延迟测试通过；冻结 worker 对三种信号均测得 314.0ms、匹配度 1.0。已安装 0.3.16/build19，删除全部旧包。


## 2026-11-21 三种宽带测量音可选 0.3.12/build15

- 用户放弃悦耳诉求，要求直接选三组最有利于测量的测试音。0.3.11 的真实录音已能到 0.747 匹配度，但整段次峰比 0.954 被歧义判据拒绝：周期性旋律不适合整段匹配。
- 新增 `probe_signal(rate, code, kind)`：白噪声（LCG 均匀噪声）、粉红噪声（一阶低通混合）、对数扫频（150·1.05^code → 8000/1.02^code，附加每码 0.9rad 慢速频率扰动以分离同时播放）。三者峰值 0.5、120 毫秒淡入淡出，Swift 与 Python 逐样本一致。
- 分析统一到 400–4000Hz：整段相关粗定位 + 12 个 0.8 秒窗口精测。自相关半宽：白 0.08ms、粉红 0.10ms、扫频 0.10ms；次峰(>5ms)分别 0.017/0.017/0.006。合成验证：3kHz 低通 0.96–0.98，相位打乱 0.43–0.49，8 台同播 8/8（min 0.31–0.33）。
- 模板按播放采样率生成再重采样到麦克风采样率（`probe_rate`），否则白噪声跨率无法相关。安装包内冻结 worker 对三种信号均测得 314.0ms、匹配度 1.0。
- UI 增加“测试音”分段选择，默认对数扫频（Farina 2000 的对数扫频是房间脉冲响应测量的主流方法），选择持久化。已安装 0.3.12/build15，删除 0.3.11-14。


## 2026-11-21 真实录音定位：高频相位失配，换高能测试音 0.3.11/build14

- 0.3.10/build13 复测失败并留下了真实录音（`failed-probe-20261121-084418-0`）。频谱显示能量 89% 在 600Hz 以下；模板 1.2–4.2kHz 占 1.3%，录音占 1.7%，比例一致，说明 MacBook Pro 内置麦克风没有额外衰减，是测试音本身在该频段能量太少。
- 录音在 1.2–4.2kHz 的峰值（1569/1572/1319Hz）与模板峰值完全吻合、信噪比 20dB 以上，但整段 8 秒波形相关只有 0.133，而 0.8 秒窗口有 0.226+、波动 1.7ms、漂移 0：真实房间与扬声器让高频相位在整段上失相干，窗口内仍然清晰。
- 信号改为 3/5/7 次泛音更强的五声音阶拨弦（2次.28/3次.24/5次.20/7次.12），纹理降到 9.6kHz 采样并把振幅提到 .030，整体电平 ×1.3；峰值 0.164、1.2–4.2kHz 能量占比从 1.4% 提到 9.2%。Swift/Python 逐样本一致。
- 分析改为两段分工：500–2000Hz 整段粗定位（真实录音 0.80），1200–4200Hz 的 12 个 0.8 秒窗口精测（±12ms 搜索），用窗口最小分作 confidence。真实旧录音上该结构得到 0.226/1.7ms/零漂移。
- 新增“高频相位被打乱”回归测试；56 项校准/延迟测试通过。已构建安装 0.3.11/build14，删除 0.3.10-13。签名、Runtime 源码、冻结 worker、驱动哈希、偏好核验全部通过。


## 2026-11-21 内置麦克风降噪适配与失败录音留存 0.3.10/build13

- 用户复测 0.3.10/build12 仍失败（08:32，音量44%），并怀疑麦克风选择。核对 CalibrationMicrophone：只接受内置/USB 传输，当前系统唯一符合的是 `MacBook Pro麦克风`（UID `BuiltInMicrophoneDevice`，输入增益0.45）；iPhone 的 continuity-wired 麦克风与虚拟设备都会被排除，不存在选错设备。
- 判断：笔记本内置麦克风带波束成形/降噪，会削弱上一版依赖的宽带噪声层。改为分析 1200–4200Hz 的完整旋律谐波（避开261–523Hz基频造成的周期性假峰），旋律能量在降噪后仍保留。合成验证：单台 clean 1.00/次峰0.04、3kHz低通 0.96/0.05、距离衰减 0.79/0.05、8台同播最低 0.34/次峰0.09；55 项校准/延迟测试通过。
- 分析失败现在会写出 `metrics.json`（录音RMS/峰值、带内RMS、模板比、最佳匹配度、次峰比、PSR、每窗残差），Swift 侧把失败录音与指标存到 `Diagnostics/failed-probe-*`，最多保留 3 次；顶层诊断增加麦克风名称。之前失败只留下“不够清晰”，无法区分麦克风、音量与房间。
- 已构建安装 `0.3.10/build13`，删除旧包 0.3.10-12。签名完整性、主二进制、冻结worker、Runtime源码、HAL驱动哈希、偏好核验通过。pkg 未做 Developer ID 签名，双击会被 Gatekeeper 拒绝，命令行 installer 加管理员授权可正常安装。真实两台复测仍待用户执行。


## 2026-11-21 第二台 HomePod mini 匹配度不足修复与本机安装 0.3.10/build12

- 用户实测 0.3.9：第二台 HomePod mini 已正常出声，但稳定提示“连续测试音不够清晰，请检查麦克风、音量和环境噪声”。诊断为分析频段问题，不是播放或网络失败。`calibration-last-run.json` 显示客厅 conf=0.2026，只比 0.20 门槛高 0.0026；residual≈316.25ms，12 窗波动 0.235ms，第一台实际测得很准。
- 根因：舒缓旋律的主要能量在低频，旧分析带 1800–6500Hz 只保留约 1.3% 能量，模板 RMS 仅 0.004，任何频响差异都会把匹配度压到门槛附近。
- 修复：分析带改为 1000–4500Hz，并用独立宽带纹理层做相关模板，避免旋律基频的周期性假峰；生成波形与之前逐样本一致，Swift 端无需改动。整段相关、12 窗中位数、0.20 最低匹配度、多峰歧义/回声/12ms 波动/1.5ms/s 漂移拒绝全部保留。
- 合成回归：3kHz 低通 HomePod mini 场景 conf=0.765；叠加距离衰减与噪声 conf=0.658；极端噪声 conf=0.263。新增该场景断言 conf>0.45。校准/延迟 55 项测试通过，Swift 与 Python 波形逐样本一致，冻结 worker 对 314ms 合成延迟测量正确。
- 已构建 `build/releases/0.3.10-12`，安装替换本机版本并删除 0.3.5–0.3.9 与中间包 0.3.10-11。每台结果列表新增“匹配度 N%”，复测时可直接看到余量。App 签名、主二进制、冻结 worker、Runtime 校准源码、HAL 驱动哈希和安装前后偏好核验全部通过。默认输出仍为内置扬声器，未自动出声；实际两台连续测量与听感待用户复验。


## 2026-11-21 本机安装 0.3.9/build10 并清理旧版

- 用户明确要求直接替换并删除旧版。确认默认输出为 BuiltInSpeakerDevice、无 worker/capture、Flow IO 空闲；旧 App 的错误 modal 阻止正常退出（AppleEvent 返回 -128），结束已确认空闲的 PID949 后安装。
- macOS 管理员授权安装成功，`/Applications/HomePod Flow.app` 为0.3.9/build10；App 签名完整性、主二进制、冻结worker、内置校准源码、磁盘HAL驱动哈希核验通过，安装前后偏好 plist 完全一致。默认输出仍是内置；新进程 PID5880 于07:51:38启动，避免内存仍运行旧App。
- 已删除0.3.8 pkg/dmg及两份构建目录中的重复App，保留最新版pkg/dmg、源码与测试证据。安装器已清理旧组件备份和root临时安装目录；验证后删除临时偏好备份。证据见 `build/calibration-comfort/install-verification.json`、`cleanup-latest-only.json` 与 `install-result.log`。
- 安装器设置同boot-session等待重启，未擅自重启或自动出声；实际三台逐一测量和共同声学复验仍待用户重启后确认。未切换正式发布源。

## 2026-11-21 舒缓测试旋律与逐台输出会话修复（候选 0.3.9/build10）

- 用户反馈原连续变频纯音刺耳，三台布局在客厅测量通过后，第二台输出启动失败。失败证据保存到 `build/calibration-comfort/user-failure.json`；系统日志 07:31:30 显示 HAL `_TellHardwareToStart` 返回 0x77686174 / AVFAudio 2003329396。第二遍 latency_state=unchanged、无 pending，不能把此次错误归为之前的延迟事务未提交。
- 信号改为五声音阶的柔和拨弦旋律、自然衰减和 200ms 首尾淡入淡出，叠加低电平宽频纹理。纹理以固定 12kHz 时间网格生成，Swift/Python 与不同麦克风采样率一致。分析只提取 1.8–6.5kHz 测时层，保留整段相关、12窗中位数、歧义/漂移/缺音/回声拒绝，不降低验收门槛。
- 每轮校准只保留一个 Flow 输出引擎和 HAL client；成功的单台测量结束仅静音，下一台独立 AirPlay/capture 准备确认后重新装载并触发。全部逐台测量后依旧进行共同补偿复验；失败/取消/结束释放引擎。波形生成不再持有渲染锁。
- Python 42 项校准/延迟检查通过；最终降低纹理音量后 10 项连续测量测试重新通过，含新增不同输出/输入采样率和八台经 4kHz 房间低通。Swift 校准状态检查、9组跨语言逐样本对比通过；真实 Flow 静音硬件检查通过 1→1→1→3→8 声道重新准备，未调用 beginProbe、未让音箱自动出声。源码与安装包构建证据位于 `build/calibration-comfort`。
- 本次候选为 0.3.9/build10，完整 pkg/dmg 位于 `build/releases/0.3.9-10`。已核对包内 Runtime 源码、冻结 worker 对最终旋律的 314ms 合成延迟测量、App 签名完整性、镜像校验及版本/build。尚未替换本机 0.3.8，未更新正式发布源；实际三台连续出声、听感与共同复验仍待确认，不能声称真实声学校准已通过。保留现有未提交改动。

## 2026-11-21 连续测试音与多窗口延迟估计（合并入候选 0.3.8/build9）

- 用户要求：连续变化的专用测试音，优先准确性；一次录音取得多个延迟样本后求最终实际延迟，保存布局内所有音箱都必须测试。暂停安装早先0.3.8制品，重新构建同一未发布候选。
- 新增8秒相位连续、种子固定、频率持续变化的信号；每个并发音箱独立码型/频段。整段归一化互相关定位，然后12个重叠0.8秒时间窗估计延迟，以中位数输出；检查相关度、峰值歧义、≤12ms波动和≤1.5ms/s漂移。缺音、时钟中断、削波、强回声不保存。
- 输出注入锚改用源渲染回调 AudioTimeStamp.hostTime，麦克风使用输入硬件时钟；缺少有效输出硬件时间戳则失败，不以回调送达时间代替。1秒全零输出自检（未启动测试音、未修改默认输出/延迟）得到渲染时间戳约提前10.64ms且有效。
- 每台逐一完整测量后仍执行全组补偿复验；任何音箱缺失/测量无效/复验失败均不保存部分配置。结果显示每台延迟、12窗口数量与波动，保留音量滑块。保存格式版本3，旧短音结果不作为新测量结果加载。
- 安装后核对发现旧App的错误modal sheet阻止正常退出（统一日志明确 termination blocked by modal sheet）；在确认默认输出为内置、Flow IO空闲、无capture进程后结束旧idle worker并强制结束旧App，重新启动最新0.3.8进程，避免磁盘已更新而内存仍跑旧版。后续本机安装必须核对进程启动时间，不只看磁盘版本。
- Swift/Python波形在3采样率×3码型逐样本一致；8项连续信号DSP测试（含8台同播、真实重采样、回声、缺音、漂移、硬件时钟中断）与17项既有校准/发现测试通过；Debug构建通过。真实声学效果仍需重启加载驱动后测试。

## 2026-11-21 首次发现与复验延迟更新修复（候选 0.3.8/build9）

- 0.3.7 用户重启实测：首次发现为空，第二次才找到音箱；单台测量成功，复验报 ProtocolError。已读取 `~/Library/Application Support/HomePod Flow/Diagnostics/calibration-last-run.json`，证据备份 `build/volume-calibration/0.3.7-user-calibration-failure.json`。测得 residual≈313.716ms，第一遍声卡0→2000ms成功，复验有 acoustic_compensation 但无 latency_state；统一日志匹配 request action2/3/4 后 perform-busy，未成功提交。上一版解决槽占死，未解决 host 已准许配置却被 ownership running 计数拒绝。
- 驱动：延迟仅在匹配 action 的 host PerformChange 回调提交，不再以尚未释放的客户端 ownership 计数否决；只更新延迟原子报告，不重置时钟/seed/PCM/客户端。采样率仍要求 idle。新增在客户端注册期间提交、保持clock/ownership、旧action无效的回归。
- 查找：校准向 worker 提供保存的设备身份；首次定向查找，缺失时自动进行至多三次多播重试，每轮4秒、短退避，总等待受限。全程按稳定身份匹配，不按名字或旧IP误认，取消后不再重试。
- 错误：记录准备阶段原始失败及 latency_state，避免 pyatv 将声卡错误包装成 ProtocolError 后丢失根因。
- family dev/production/single-device、17项校准/发现/诊断测试、15项延迟应用测试通过。完整包构建及本机替换完成：0.3.8/build9已安装，App/冻结worker/runtime源码/磁盘驱动哈希与构建一致、签名完整性通过。按用户最新要求清理旧App/独立开发测试版、旧pkg/dmg、旧冻结测试Runtime，保留最新pkg/dmg与测试证据；清理记录见build/volume-calibration/cleanup-latest-only.json。只保留最新版的要求已写入AGENTS.md。声学复验仍需重启加载后实测，不切换正式更新源。

## 2026-11-21 校准复验失败与重试卡住修复（候选 0.3.7/build8）

- 用户实测：0.3.6 单台测量打勾后复验报 `system session failed (ProtocolError)`；重试报 AVFAudio 2003329396，均附延迟恢复未确认。已确认用户重启过（当前 boot-session 与安装记录不同）。测试本来就自动切影院模式并走 Flow 虚拟输出，不需要手动打开主开关。
- 本机只读诊断：Flow IO 空闲、hfla=2000ms/revision2，但 hfls=pending。系统日志 06:54:25 latency action1 request/commit；06:54:37 action2 request 后无 commit；06:55:56 AVAudioEngine 在 Flow StartIO 失败（`what`/2003329396）。不能把第一次 AirPlay ProtocolError 的具体原因当成已确认。
- 修复驱动匹配事务的 PerformChange 因 running 拒绝后永久占住 pending 槽：保留已提交 latency/revision，释放槽并标为 rejected，旧 action 不能再提交，新 IO/新事务可继续。新增回归覆盖拒绝后无 Abort、重试、旧 action 不得清除新事务。未改核心 C ABI。
- worker calibration_snapshot 检查 pending，录音/默认输出切换前阻止测试并提示重启；校准结束保存本地 timing/cleanup 诊断 JSON（不保留录音），恢复失败显示具体原因。
- family dev/production、single-device 驱动测试、13 项声学校准/预检及15项延迟应用 Python 测试、Swift CalibrationChecks、完整 Release pkg/dmg 与签名完整性/镜像检查通过。管理员安装已成功，/Applications 为0.3.7/build8；App/worker/runtime/磁盘驱动哈希核对通过，旧安装备份与0.3.6 pkg/dmg已清理。新 App 已启动，需用户重启以加载修复驱动。真实复验成功仍未确认，暂不切换公开更新源。

## 2026-11-21 延迟测试音量可调（本机候选 0.3.6/build7）

- 用户要求完成延迟测试、方便改测试音音量，并清理旧版后直接安装本机新版。开发源码仍在 `/Users/lvzhipeng/Developer/homepodflow`，Documents 下目录只有演示素材。
- 测试弹窗新增 1%–100% 音量滑块，默认 10%，独立持久化；打开弹窗不自动播放，点击开始才测量。测试及共同复验保持同一音量，不自动提高；停止后可调整，改音量会清除未完成测量并重新测全部音箱，已保存校准保留。worker 协议与复验有效范围同步更新。
- Swift CalibrationChecks、12 项声学校准 Python 测试、19 项 worker 协议测试、安装器静态检查通过；Debug 构建及测试弹窗截图检查通过。
- 完整 Release pkg/dmg 构建、签名完整性/镜像校验和检查通过。用户完成 macOS 管理员验证，installer 成功替换 `/Applications/HomePod Flow.app` 为 0.3.6/build7；App、冻结 worker、runtime 源码和磁盘驱动哈希与构建相符，新 App 已启动。旧安装器备份已清理，旧 Calibration 开发 App 及本地 0.3.5 pkg/dmg 已删除，布局/偏好保留。
- 驱动源码未修改；测试音量改动不需要新驱动能力，校准复用现有 latency 接口。本次统一完整安装器仍替换驱动并设置 needs-restart，尚未重启，不能称新版内存驱动已加载。
- 仍无成功的真实声学校准记录；按照 AGENTS.md「未完成的实验不得冒充正式可用更新」，本候选先本机安装，不切换公开更新源。真实麦克风/音箱测量及浏览器音画验收需另行记录。

## 2026-11-21 无线延迟校准开发中（未发布）

- 用户最终要求：在现有软件中加弹窗；保存音箱/布局后提示；先切换影院模式和系统默认输出到 Flow，测试成功后自动保存、验证写入共同声卡延迟，日常播放自动加载每路 PCM 补偿。当前测试音量固定 10%，不再自动提高。
- 已实现单台三次独立码型测试、稳健中位数/相关度/波动检查、全组码型复验、声卡读回、设备身份/布局/角色失效、失败不覆盖、默认输出恢复、权限预检及可取消/30 秒超时。逐路补偿和共同声卡目标的软件集成检查通过；真实虚拟采集 → native hub → AirPlay 的发声链路已跑通且有清理确认。
- 实测未验收：此前 AVAudioEngine 麦克风记录无可用校准结果，已改用物理输入 AudioDevice IOProc 与每块输入硬件时间戳。当前静默自检等待首次麦克风授权；TCC 日志显示 com.homepodflow.calibration.dev 的授权弹窗被延后。已通过异步问题请用户在 Mac 上允许开发版；尚未收到有效硬件录音自检结果。
- 开发构建独立安装在 ~/Applications/HomePod Flow Calibration.app，bundle id 为 com.homepodflow.calibration.dev，读取原软件布局用于测试；未替换 /Applications 的原版，未发布更新源。开发版弹窗/麦克风自检入口只在 DEBUG 代码和开发包配置中启用。原版麦克风/本地网络开关刷新后已恢复为允许。
- 正常 GUI 启动必须走访达/LaunchServices；直接 CLI 进程继承 Codex 的权限归属，早期 GUI 工具也会命中旧的同 ID App。命令行可发现客厅 192.168.0.104 / 361AC6F1EFBF；正常访达启动后发现与真实采集均成功。修正 probe 的 8ch 物理输入误用每路混音输出声道数导致帧数放大和队列溢出，以及 7.1 AVAudioFormat 显式 layout、Swift 6 render callback Sendable。
- 没有成功保存任何实测校准。最近读回声卡 2000 ms、IO 空闲，默认输出已恢复内置。证据：build/calibration-e2e/result-*.json、calibration-trace.txt、microphone-selfcheck.txt（starting authorization=0）、driver-final-status.json。解锁后仍需首次授权，不能把发声链路成功称为校准准确或浏览器声画通过。
- 后续：用户允许开发版麦克风后先完成 2 秒静默自检，再固定 10% 跑单台及补偿复验；验证生产影院加载保存值。完成后重新冻结最新 Runtime、编译最终包，并按 AGENTS.md 完成发布流程。未验收实验不得推送正式更新源。


## 2026-11-18 音乐/影院双模式

- 产品 UI 只保留音乐/影院两个模式，默认音乐；用户切换后持久化，下次启动沿用上次模式。旧 `synchronized` 值只做兼容解码并迁移到音乐。
- 音乐模式走 `tap-capture-host` 的 Process Tap 2ch，固定 `.mutedWhenTapped`：读取期间静音当前默认输出（内置/HDMI/蓝牙），停止/崩溃自动恢复；不写默认输出、无 latency 注入、不要求 HAL 驱动，音量走 HomePod。
- 影院模式走 `virtual-audio-host` 的 Device Tap 8ch：保存并切默认输出到 Flow，worker 写入协商 latency，停止恢复 previous UID。
- 模式切换只在完全关闭时允许；ON/STARTING/STOPPING 时模式选择器禁用。
- App 启动始终为 OFF（启用意图不持久化）。启动自愈：默认输出仍是 Flow 时，优先恢复记录的 previous UID，否则回退内置/首个非 Flow 输出；无法恢复则提示手动选择。影院开启时若 Flow 已是默认，先恢复真实输出再重新租用，避免把 Flow 记成 previous。
- 影院开启前检查 Flow 占用：枚举 Core Audio process objects，按 output devices + `IsRunningOutput` 找出真正占用者；弹窗列出应用，用户确认后正常退出，轮询设备 idle ≤10s 后继续。取消/超时保持 OFF、默认输出不变。
- 音频组件区块只在影院模式显示；音乐模式可添加/移除/保存音箱，位置拖拽只在影院生效。
- 验证：Debug/Release 构建；StateChecks、DefaultOutputRouteChecks、SystemVirtualInputChecks、SystemVolumeChecks、SystemSessionChecks、LatencyControlChecks；ProcessTapCapture 27 tests；`tap-capture-host` release 构建通过。真实 TCC、音乐出声、占用弹窗/退出、影院声学仍未验收。

## 2026-11-18 官网更新与采集架构评估

- 官网从 0.3.1 文案/截图更新到 0.3.3：补充应用内更新、延迟与占用修复、安装器不可重定位；修正“不修改系统输出设备”等与实现不符的描述。新截图由 0.3.3 Debug 构建生成（设置页、菜单、局部细节），已部署树莓派并通过源站/公网/制品哈希校验。
- 发布流程固化到 Codex skill `homepodflow-release`。`tools/updates/build-and-publish.sh` 只构建并切换 `release.json`/`updates/latest.json`，不会改 `index.html`；网页文案与截图必须单独发布。
- 采集架构评估见 `AUDIO_CAPTURE_OPTIONS_2026-11-18.md`：日常立体声建议 Core Audio Process Tap（无驱动、2 声道、启停更轻）；影院多声道与浏览器音画同步保留 HAL 8ch + latency 注入。系统级视频延后无法脱离可控输出设备用公开 API 实现。
- 下一步：把 `platforms/macos/ProcessTapCapture` 接进 `adapters/live`，加 TCC/静音提示、`.mutedWhenTapped` + watchdog；完成 30 次开关、30 分钟播放、睡眠唤醒、默认输出变化、权限拒绝/撤销和崩溃恢复验收。上述均为待做，不是已完成能力。

## 2026-11-13 树莓派发布与应用内更新

0.3.3/build4已构建并通过局域网发布到 https://homepodflow.mddxz.top。网页release.json、版本化pkg/dmg、签名updates/latest.json均已上线。公网下载完整pkg后，Swift客户端同源/架构/版本、Ed25519签名及SHA256/大小校验通过。

App新增启动检查、设置中检查/一键更新和菜单新版本提示。先验证下载再停止播放并恢复默认输出，系统管理员授权后由独立进程安装；完整替换旧App/driver，成功后清理临时备份及缓存，提示重启。同boot-session期间禁止将旧内存driver显示为就绪。

首次需要手动安装带更新入口的0.3.3。当前电脑已由用户完成0.3.3首次安装，签名、版本/build及旧备份清理通过；生产配置在线检查显示当前最新，同boot-session显示需要重启。下一次完整应用内授权升级及重启后音频仍待验收。用户音箱布局/偏好保留。发布与密钥流程见APP_UPDATES.md，密码与私钥不进仓库。


## 2026-11-13 延迟与开关修复

已从 origin/codex/virtual-audio-mvp 拉取 ae6c844 并合并本地进度记录。
本机只读复验：Flow 延迟上报 0ms、revision=1，浏览器退出且 IO 空闲时 hfls 仍为 busy；当前实际声画不同步，不能用 11-07 的可用反馈覆盖此次故障。

修复候选：RemoveDeviceClient 清理其遗留的 IO slot；允许呈现延迟在已有 IO 时申请 HAL 配置事务，仍只在 host 停稳 IO 后提交；worker/helper 不再提前因 running 拒绝请求。App 开关显示默认输出回读确认状态，恢复失败保留恢复归属和错误，不提前显示关闭。

驱动 dev/production/single-device 检查、27 项 Python 延迟测试、8 项 Swift helper 测试、默认输出/虚拟输入/会话检查及 App Release 构建通过。用户已授权并执行清理安装，当前 /Applications/HomePod Flow.app 为自包含0.3.2/build3，签名及App/driver二进制核对通过，coreaudiod已重新加载。

真实HAL验证：空闲0→2000ms通过；静音IO占用时2000→1500ms提交与两scope回读通过，revision4→5；退出/终止客户端后idle，无遗留busy。现已恢复2000ms，revision6。该值为驱动验证后保留值，后续Flow激活仍按AirPlay协商更新；不冒充本轮已测声学同步。浏览器实际对口型与App真实菜单交互仍待用户复验。安装包与旧构建已删除；用户完成最后清理后再次核对，5个管理员所有的旧备份/临时目录均已不存在，cleanup-result 为 CLEANUP_COMPLETE。最终复核延迟2000ms/revision6，当前IO运行中，busy与实际运行状态一致。


更新：2026-11-07（Asia/Shanghai）。当前源码基线 `b343216`，分支 `codex/virtual-audio-mvp`。

用户在本次接续中确认：**目前基本上已经能用，已能与浏览器自动同步延迟。** 此为用户实际使用反馈，覆盖旧文档中“浏览器自动补偿尚未验证”的总体状态。本次仅同步文档和保存 Git，没有重新播放、测量或部署；具体浏览器名称、版本、网页类型及毫秒误差尚未补录，不推定所有浏览器和来源均兼容。

换会话先读 [MacBook 入口](../MACBOOK_START_HERE.md) 和 [交接文档](SESSION_HANDOFF.md)。正式方向仍是 Mac 系统声音输入、影院/同步两种模式、单一布局设置、按真实设备显示，无产品文件播放入口。当前为基本可用的开发版本，完整正式版验收仍待完成。

## 当前状态

| 模块 | 已完成／当前事实 | 后续工作 |
|---|---|---|
| 基础使用 | 用户确认目前基本可用；历史系统声音→两台 HomePod 出声、听感同步和动态音量实测已通过 | 补录当前安装版本、配置对应关系及完整菜单操作验收 |
| 浏览器音画同步 | 用户确认已能自动同步延迟；源码按 AirPlay 协商延迟加共同 500ms 预算，在采集开始前经 helper 上报到 Flow 虚拟设备，并向 App 报告结果 | 补录浏览器/版本/网页类型；量化声画误差，覆盖暂停、seek、重开输出流及兼容性；不再列为完全未实现 |
| 虚拟声卡与采集 | 产品已收敛为单一固定 8ch HomePod Flow Audio；受管 v2 host、转换、HPCM v2、Python worker 和 App 已接入；历史软件串联测试通过 | 真实逐通道信号、权限撤销和设备变化场景；8ch 容器不代表保留原始源身份或原生环绕已验收 |
| 默认输出与开关 | 源码已有默认媒体输出切换、回读及停止/错误等路径恢复；保留用户手动改换输出的处理 | 异常退出、恢复失败、热插拔及跨进程恢复保障仍需验收，不能按旧文档记为完全未实现 |
| 路由与影院 | 冻结 C ABI v1 保持不变；共同时间线、多端点矩阵与按 role 路由已有实现；独立 processing 库历史构建/绑定检查通过 | 核对影院处理库的实际接入与效果，真实音箱角色/布局、第三台与逐通道声学验收；不能凭菜单名宣称原生环绕 |
| 音量与状态 | 动态协议音量已实测；会话隔离、停止取消、有限重试及网络/睡眠处理已有实现 | 长时间拖动、断网、睡眠唤醒、音箱掉线恢复；历史重启 ProtocolError 根因仍待定位 |
| 打包与安装 | 已有将两个采集宿主嵌入主 App 的打包脚本和优先使用内嵌宿主的代码 | 仍依赖 Python/开发路径；固定签名、独立安装/卸载/恢复、自包含正式包尚未完成 |
| 开发迁移 | Mac 开发目录为 `/Users/lvzhipeng/Developer/homepodflow`；迁移基线与 HEAD 一致 | 新源码目录与旧部署目录独立；修改代码不会自动更新已安装 App，运行配置不提交仓库 |

## 下一阶段顺序

1. 保存当前可用基线：记录已安装 App 与源码/配置的对应关系、已验证浏览器及条件；整理迁移文档和测试工具到 Git。
2. 完成稳定性验收：至少 30 分钟连续播放、暂停/恢复、拖动进度、反复开关、断网、睡眠唤醒、音箱掉线，以及默认输出恢复。
3. 扩展浏览器兼容性和客观测量，分别记录协商值、设备回读值与声学实测；保持现有自动同步可用状态，不将其重新列为从零开发。
4. 核对影院处理接入，验证多声道角色、布局与真实出声；保留原生 pair/多声道等未验需求。
5. 完成固定签名、自包含安装包、权限、卸载恢复与正式发布验收。

## 证据与边界

最新可用性和浏览器同步状态来源：2026-11-07 用户在 Mac 接续聊天中的实际使用确认。历史组件检查和阶段实测见 `reports/`；浏览器工具的旧 SUMMARY 仅记录其当时的准备阶段，不能覆盖本次用户反馈。此次文档更新没有新增自动化测试或声学测量结果。

架构：SwiftUI/AppState → SystemAudioStore → system_worker → 输入适配/采集宿主 → live 桥 → 处理与冻结路由核心 → AirPlay。正式发布门槛仍见 RELEASE_V1_CONTRACT.md 与 RELEASE_V1_ACCEPTANCE.md。
