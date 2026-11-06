# Process Tap 平台首切片整合

2026-11-05。平台离线首切片执行与独立终审通过（见ProcessTap-qa-2026-11-05.md）；真实授权/采集未验。用户明确选择Core Audio Process Tap作为Mac采集兜底。实现位置platforms/macos/ProcessTapCapture，为独立Swift Package：ProcessTapCapture库、C11 lock-free SPSC有界缓冲、tap-capture-probe显式有限探针、用途Info.plist和打包脚本。冻结核心与M2保护35文件未改变；现有0.2文件服务仍独立可用。

## 已执行

在Mac arm64/macOS26.5.2/Xcode26.6执行，原始证据ProcessTap-macos：

| 项目 | 结果 |
|---|---|
| Swift库/C缓冲/探针编译 | Pass，swift-test-final.log构建成功 |
| 生命周期与PCM测试 | 15/15：13开发+2独立QA；无跳过，无HAL真实采集 |
| 默认启动/--help | help.log、default.log均退出0，只帮助；不创建tap |
| Release探针打包 | package.log成功，含NSAudioCaptureUsageDescription |
| 包内探针--help | bundle-help.log成功；未带--capture |
| adhoc签名验证 | signature.log通过，只证明本机开发包完整性 |
| 源码与产物 | 12源文件SHA与工作区全相等，zip SHA与metadata一致；baseline见ProcessTap-P0-source.json |

最终代码保留实际ASBD、原生input/now的hostTime/sampleTime/flags、Mach时基、session、callbackSequence及drop断点；不是完整AudioTimeStamp所有字段的快照。仅接受packed Float32，消费端去交错/字节序转换、拒NaN/Inf，捕获格式不硬编码44100或5.1。有效时间回退/异常跳变触发非RT fail-stop，原生时钟尚未映射到Python/core epoch。

实时IOProc只调用C固定池复制，无Swift数组/文件/锁/打印；初始化预触页并检查原子lock-free，实际总预算64MiB。超限/设备格式变化明确fault，满队列drop标断点，probe禁止把drop/gap当验证成功。结构审核不等于真实IO deadline/CPU性能已测。

资源按stop、IO与监听detach、aggregate、tap逆序处理；依赖未确认不释放回调storage，重启禁止。作用域API覆盖正常、异常和Task.cancel。测试还覆盖每阶段失败、重复stop、新session、nil callback、planar、bigEndian、非法flags、时间戳、内存预算；mock清理有证据，但实际HAL stop是否及时仍未验证。

probe必须显式--capture，1..10秒；不播放、不改输出/音量/静音，目标PID解析失败不扩大范围。用途文案通过bundle读取，不私查TCC；permissionStatus不推断。文件O_EXCL不覆盖，报告编码失败非0；零帧/静音/无效时间/drop/NaN/异常/清理失败不能captureVerified=true。Float32 WAV探针文件不等同signed16 WAV worker输入，两者没有伪接通。

## 首轮发现及修复

首轮SDK把旧kAudioTimeStamp常量从Swift作用域隐藏，已改AudioTimeStampFlags OptionSet；随后SwiftTesting #require参数内缺try导致测试编译失败，已修并全15项运行通过。初始source审查还修正了清理依赖、时间连续性、内存cap、未知格式flags及报告假成功风险。保留build-first.log/swift-test-first.log，不把静态审查当首次成功。

## 未验收与下一步

本轮capture_requested=false、real_audio_capture_tested=false。没有系统授权、真实Tap创建/录制、有声样本、设备切换、多进程排除或实时AirPlay证据。不要把15项mock/转换通过解释成捕获到系统声音。实际权限与有限录制单列T022；后台重采样、capture-to-playback时钟锚点、live PCM受管通道、有界发送及回路验证为T021。核心v1保持不变。

探针开发产物artifacts/ProcessTapCapture-probe-macOS.zip，正常HomePod Flow 0.2仍只含文件服务入口，没有默认启动Tap。
