# Process Tap P0 独立 QA

日期：2026-11-05。最终结论：**平台库/探针首切片的编译、离线契约与打包验收通过。** Mac最终15项测试通过；未做系统授权、真实采集或音箱播放，不声明真实捕获成功或完整系统采集功能已完成。

## 范围与独立检查

已读 PROCESS_TAP_PLAN.md、ProcessTap-review-2026-11-05.md，并独立阅读Models、CaptureSource、HALCaptureBackend、C ring、probe及打包配置。范围仅独立Mac采集库、有限显式probe和离线fake/转换测试；不增加live worker桥接、不改核心ABI或M2受保护35文件。

| 门禁 | 源码审查结论 | 执行证据 |
|---|---|---|
| RT路径 | 非捕获IOProc转C ring；预分配池、memcpy、边界检查、lock-free原子；无数组/Data分配、锁、文件、日志、Python/native路由 | Mac编译/fake通过；无真实实时性能测量 |
| 有限队列 | 容量/内存预算、全满不覆盖读slot、drop计数/sequence/gap元数据 | owner overflow测试Mac通过 |
| 清理依赖 | stop未确认时不detach；IO/listener未detach不释放aggregate/tap；ring在callbackDetached后才释放 | owner分阶段错误账本及取消测试Mac通过 |
| 实际格式/时钟 | 实际ASBD、输入/now时钟flags及mach时基；不假定44100/5.1；sampleTime有限性独立判断 | 格式/NaN/planar/nil/BE/跳变离线测试Mac通过 |
| 无隐式操作 | 默认/--help只打印帮助；只有--capture才调用采集；private/unmuted、不改默认设备/音量、不播放 | 默认/help/bundle-help日志已审，均为帮助内容；本轮未--capture |
| 文件与授权 | bundle用途文案，正常公开HAL/TCC流程；输出O_EXCL不覆盖；captureVerified需非静音/时钟/无gap/完整清理 | 静态符合；真实授权/录制未测试 |

## 独立测试交付

只新增 `Tests/ProcessTapCaptureTests/IndependentPCMTests.swift` 两项，不重复已有planar/lifecycle/overflow测试：

1. 已知IEEE754 big-endian字节转换为正确交错样本，同时确认timestamp flags无效时保留非零原值且不伪称valid。
2. Float与signedInteger矛盾格式flags必须拒绝。

第二项对应真实静态缺口：初始格式校验只看Float32，矛盾flags可通过。已交App开发修为明确白名单Float/Packed/BigEndian/NonInterleaved，必须Float+Packed，拒绝signedInteger/alignedHigh/未知flags；没有改核心接口。随后owner增加一项包含三种时间跳变输入的测试，最终共15项（owner13+QA2），Mac日志已确认全部Pass。

## 待明确边界

PLAN要求timestamp跳变显式报告并停止；初始实现只有flags/finite/sequence检查，没有有效timestamp回退检测。QA已交App开发并独立复审修复源码：有效host ticks回退拒绝；有效sampleTime相对上块末帧超出半帧容差拒绝，明确drop增量导致的前向缺口保留gap而不伪称连续；无效flags不比较并重置比较基线。故障在非RT读取侧stop，保留原始metadata。Mac实际离线测试通过；不能仅把valid flag等同连续时钟。

同步HAL stop/detach的真实耗时与系统行为未实测，mock只能证明操作顺序、失败保留和作用域取消清理，不能证明真实IO停止的硬时间上限。当前公开对象依靠显式stop或withCapture作用域，不能依赖析构自动安全清理；漏掉该调用的使用方式未获通过结论。

未执行--capture、未申请/确认真实系统音频权限、未产生录音。Float32证据WAV不是现有signed16 worker文件链路已接通；没有系统采集到Python/native播放的live时钟/队列/反馈环验证，也没有声学或音画同步通过结论。

## 最终原始证据独立复核

目录：[ProcessTap-macos](ProcessTap-macos/)。环境macOS26.5.2 arm64、Xcode26.6 build17F113。

| 检查 | 实际复核结果 |
|---|---|
| Swift库/探针Debug编译 | swift-test-final.log显示库、probe、两个测试文件均编译/链接成功 |
| Swift Testing | 最终明确“15 tests … passed”，约0.004秒；日志中的XCTest“0 tests”是另一测试运行器，未误计为没有测试 |
| 默认与帮助 | default.log、help.log、bundle-help.log均为帮助文本；源码及metadata确认capture_requested=false/real_audio_capture_tested=false |
| Release与bundle | package.log编译成功并明确packaging did not start capture；signature.log为valid on disk及Designated Requirement满足 |
| 源码一致性 | QA实际计算source-manifest.json列出的12个源文件SHA，全部与当前平台包一致，0漂移 |
| 核心隔离 | QA实际复核M2受保护35文件SHA，0漂移；未重开C ABI设计或更改文件播放链路 |
| 探针产物 | QA实际计算artifacts/ProcessTapCapture-probe-macOS.zip的SHA与metadata一致：6f79570ba28189e000a82bae3838dce04c2d21a8d11c8b0a8cf9a644eebebfad |
| bundle用途文案 | QA独立读取zip内Info.plist确认NSAudioCaptureUsageDescription非空、最低系统14.2、指定可执行文件存在；不将用途文案/签名等同授权成功 |

首轮SDK旧kAudioTimeStamp常量不可见，以及owner测试的Swift Testing宏缺try编译错误均保留原始失败日志；改用OptionSet并修复宏调用后最终15项通过。未隐藏首轮失败，不用最终静态审查替代实际构建。

本轮可关闭平台库/有限探针离线首切片；真实授权、采到非静音及真实资源清理、设备/格式变化、回调性能与统计、App/发送worker PID排除和重启更新、live桥接仍须后续显式验收。当前没有剩余已确认阻断此离线交付的缺陷。
