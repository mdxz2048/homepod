# Process Tap P0 独立架构审查

日期：2026-11-05。范围：`platforms/macos/ProcessTapCapture`。审查方式为读取源码与错误路径，未执行Mac编译、系统授权、录制或音箱播放；构建和测试由总协调执行。本报告不把fake backend通过等同于真实捕获成功。

## 当前结论

库主体的关键P0问题已向App开发提出并看到修补；probe／fake tests尚未交付完整时，不给整个切片终审通过。下列结果以本次读到代码为准，末尾补充后续复核。

| 检查 | 独立审查结果 |
|---|---|
| RT回调 | 非捕获C回调仅转发预分配ring；C push只有边界检查、memcpy和已验证lock-free原子，无分配、锁、日志、文件IO、dispatch及重采样 |
| SPSC／容量 | 单HAL生产者、单非RT消费者；release/acquire保护slot；全满丢最新块，不覆盖消费者slot。新增callback_sequence与dropped_before，消费者能识别gap，不能冒充连续音频 |
| 时间／实际格式 | 保留原始hostTime/sampleTime/flags及ASBD、buffer通道/字节；没有拿host ticks直接当纳秒；host/sample有效性分别由flags决定。timebase需probe旁路记录 |
| 格式限制 | 已从初始int16扩展收敛为仅合法Float32 PCM，未知/零格式拒绝；去交错及字节序转换在read消费侧分配处理，不在IOProc里 |
| 格式／设备变化 | HAL监听tap格式、设备存活与默认输出变化，listener只设fault；read发现fault已改为非RT调用stop，报告原fault／清理失败，不继续旧格式 |
| 失败清理 | 已补HAL依赖guard：stop失败禁止detach；IO/listener未detach禁止aggregate销毁；aggregate未销毁禁止tap销毁。callbackDetached含startAttempted检查；ring只在真正detach后释放，未确认状态拒绝start |
| 捕获范围 | private tap/aggregate，unmuted，无默认设备／音量改动；global自动排除当前PID+额外名单，选定进程拒自己／排除名单；解析不到PID报错而不扩大到全局 |

## 已发现并要求修复的P0

1. 初始只有全局dropped计数、输出块无gap信息：现已新增slot callbackSequence/droppedBefore，probe还必须将丢块视为未验证／不连续，不能仅生成WAV就称成功。
2. 初始callback fault只是state.failed并抛错、IO继续：现已在非RT读取路径自动stop。
3. 初始stop循环无条件继续销毁依赖：现HAL各destroy具备严格前置guard；失败时保留回调内存及句柄。
4. 初始global只排除录制宿主，不能排除App／发送worker：现配置可额外传excludedProcessIDs；接live前仍须由上层提供并更新真实PID。

## 等待probe／fake复核的门禁

- 默认运行只帮助／能力信息，只有显式有限record录制；输出不得覆盖已有文件。
- `NSAudioCaptureUsageDescription`与系统标准TCC流程；不得使用私有TCC接口、自动绕过授权或把权限未知标granted。
- 无块、静音、所有timestamp无效、非有限样本或丢块不能标capture_verified；需要明确unverified/失败及可靠清理。
- sidecar保留实际格式、原始时钟valid flags／mach时基、seq/gap、帧数、非静音统计、cleanup；不虚构44100/5.1。
- fake分别注入创建／启动／stop／detach／aggregate／tap失败，确认资源账本、ring保留、重启禁止；还需ring满队列、nil输入／timestamp、格式变化与planar转换测试。

核心v1及M2保护文件不应变化；本模块尚无live→Python worker桥接，也没有真实授权、录制、立体声／多声道捕获或同步通过结论。

## Probe 源码复核补充

已查看TapCaptureProbe与打包脚本/Info.plist：默认无`--capture`只打印帮助；有用途文案并要求从bundle读取；只调用公开CoreAudio流程，无私有TCC API。probe不播放、不修改系统音量；report.permissionStatus为not_inferred，captureVerified需有帧、非静音、时间有效、无drop/gap、清理完整且无错误。Float32样本NaN/Inf已在消费转换侧拒绝。输入/now两份原始时间、session、序号、drop累计与mach时基已加入模型。

继续向开发提出：WAV创建应使用O_EXCL消除先exists后create的覆盖竞态；有限时长与计划对齐；sampleTime有效性除flag还应要求finite。Float WAV格式3仅用于探针证据，不能当成现有signed16 WAV worker已接通。Fake lifecycle tests及Mac运行结果尚待最终复核。

## 最终源码复核（同日更新）

以上历史待办已逐项复读关闭：

- WAV已用 `O_CREAT|O_EXCL` 原子创建且0600权限，时长收敛1..10秒，不能覆盖已有文件。
- 样本NaN/Inf在非RT转换侧拒绝；sampleTime有效性要求flag与finite，原始非有限值仍保留；JSON编码失败stderr并exit4，不能无报告exit0。
- slot元数据含input及now原始host/sample/flags、callbackSequence和drop累计；块另带session与mach时基。queue上限含64MiB分配预算，预触页在启动前执行。
- 12项fake测试源码已审：正常／两轮session、各创建启动失败、四阶段清理失败保留依赖、满队列gap、callback格式故障fail-stop、作用域消费失败、unsupported格式／容量、非有限样本、无效时间、真实Task.cancel清理、planar双buffer转换、nil回调指针。
- README明确Float WAV格式3与现signed16文件worker不兼容，不能宣称live接通；未确认清理必须保留owner并禁止start，不能靠丢弃owner恢复。

**独立源码审查结论：当前未见未关闭的P0阻断，可进入Mac构建与fake运行验收。** 本审查没有执行这些测试，运行通过与否以总协调的实际日志为准。首次系统授权、真实录制、真实格式、静音／非静音、音频路由、声学同步均仍未实测，不因代码门禁关闭而升级结论。
