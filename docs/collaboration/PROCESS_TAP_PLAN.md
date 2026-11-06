# Process Tap 平台采集：P0 实现契约

日期：2026-11-05。用户决定：先采用 Core Audio Process Tap 作为 Mac 系统声音采集基础，以后向上增加能力。本轮只交付独立可复用平台库、显式有限录制 probe、fake backend 生命周期测试。**不把现有 Python 有限 WAV 流改为 live，不修改 M2 受保护35文件及核心 C ABI v1，不执行自动录音或音箱播放。**

依据：[Apple Core Audio taps 官方文档](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)，以及总协调已核对的本机 Xcode 26.6 SDK `CATapDescription.h`、`AudioHardwareTapping.h`。具体可用性、常量和错误以当前 SDK 与真机为准；运行时检测，不把当前 Mac 支持等同于所有旧 macOS 支持。录制宿主包含 `NSAudioCaptureUsageDescription`，首次实际启动时由系统处理音频捕获授权；不脚本绕过 TCC。

## 模块与当前交付

建议新增 `platform/macos/ProcessTapCapture/` 独立 Swift Package：库 `ProcessTapCapture`、命令行 `capture-probe` 和 fake backend 测试。不依赖 SwiftUI、pyatv、HomePod IP、当前文件播放 worker。Mac API 隔离在 backend；标准 PCM 数据和元数据的含义可供其它平台适配复用，但不把此 Swift 库声称为 Windows/Linux 采集实现。

内部协议建议：`CaptureBackend`封装创建／销毁tap、aggregate、IOProc及启停；`CaptureSession`负责串行状态、所有权和池；`PCMNormalizer`在非实时执行队列转换；`CaptureSink`消费标准块。命名可由实现收敛，以下外部行为必须保留。

| 操作／对象 | 必需语义 |
|---|---|
| configure | 选定系统输出范围、排除进程、容量及有限录制目标；不偷偷开始采集 |
| start | 显式调用后申请／触发系统授权并准备设备，成功事件只表示采集IO已启动，不保证有非静音样本 |
| stop | 幂等、有界，阻止新数据后等待回调退出，再释放对象；可重复创建新session，不能复用过期回调 |
| state | idle / preparing / capturing / stopping / stopped / failed；session UUID区分旧事件 |
| failure | permissionDenied、unsupported、invalidConfiguration、deviceFailure、bufferOverflow、formatChanged、cleanupIncomplete；保留原始OSStatus供诊断 |

P0默认范围是系统输出的立体声 tap，明确排除本App、采集宿主及发送worker进程。配置使用未静音行为，不静音原应用，不改系统默认输入／输出、不改任何音量。进程列表无法确认或新worker PID未纳入排除时，不启动；后续worker重启时先停采集再更新排除并重建，不能靠旧PID继续捕获。权限拒绝不循环弹窗、不重试轰炸。

## 捕获数据契约

回调首先保留原生格式和时钟，不能假定所有输入都是44100Hz、交错Float32或固定352帧。保存tap实际ASBD（采样率、声道、位深、格式／布局／字节序／interleaving）、每个buffer有效字节数、有效帧数及源声道顺序。遇到未知布局标unknown，不能猜成5.1。

每个原始块带session、递增sequence、原始 `AudioTimeStamp` 的 `hostTime` ticks、`sampleTime` double及各自valid flags。保留callback的输入时间与now时间（若提供）；hostTime使用mach时基转换，记录timebase numerator/denominator。无效timestamp不能填零后伪称有效；sampleTime可以不是0或整数，不得直接强转为核心first_frame。hostTime与Python monotonic／C++ steady_clock的历元不得假设相同。

非实时normalizer输出标准 `PCMBlock`：Float32 interleaved、实际sample_rate、channels、frame_count、samples，附原生时钟／格式元数据、epoch/session、discontinuity及本地连续帧索引。P0实际得到立体声就报告2声道；不能仅因源视频含5.1而标6声道。必要的去交错、整型转换／重采样全部在后台完成；本轮**不需要重采样**，保留实际采样率录制。

未来接核心v1时，标准块转成现有AudioBlock并串行submit：epoch来自采集会话，first_frame从新媒体世代0开始；原生sampleTime/hostTime作为旁路元数据保留，不能塞进不同含义的字段。播放origin还需独立的capture-to-playback时钟映射、队列预算和迟到策略。44100Hz传输要求可在后台显式重采样，必须记录算法延迟及时间映射。**这一live桥接不属于P0，不新增／修改v1符号来假装已经接通。**

## 实时回调和背压

IO回调仅验证边界、复制到预分配固定容量块池／单生产者队列、记录最少元数据并返回。不在回调内分配数组／Data、不写文件、不打印、不阻塞等待、不执行重采样、不调用Python／C ABI路由、不销毁设备。池／buffer大小在启动前依据格式确定，超限或池耗尽记录原子故障，通知控制队列停止；不能越界复制，也不能静默丢样后仍把录制标成功。

消费在后台串行队列，完成标准化、有限WAV写入和指标统计。容量显式按帧／字节限定，记录峰值、捕获／写入／丢弃帧、格式与时间戳有效率；队列上限不等于整个进程RSS上限。格式改变、时间跳变须显式报告并停止当前P0文件，后续版本再做新epoch恢复。

## 原生资源生命周期

串行控制路径：配置并建立private process tap -> 读取实际格式 -> 建立引用该tap UID的private aggregate device -> 建立IOProc -> 启动IO。资源句柄逐项登记；中途任一步失败只逆序释放已经创建的资源。内部aggregate不得设为系统默认设备。

正常stop：停止IO -> 确认没有在途回调／销毁IOProc -> 销毁aggregate -> 销毁tap -> 排空并关闭后台writer／释放池。实现可在保证无新回调后排空writer，但**不能在回调仍可能访问时释放pool/user指针**。所有销毁错误保留，失败资源标记cleanupIncomplete而非声称干净；对IO停止失败不能盲目释放回调上下文造成UAF。析构是兜底，正常控制路径必须显式stop。重复stop、start失败后stop、两轮新session均有测试。

## probe和验收

probe只有显式执行带录制参数才采集，例如 `capture-probe record --seconds 3 --output /absolute/test.wav --exclude-pid ...`。默认可打印帮助／能力，不自动record；时长限制1..10秒，输出不覆盖已有文件，默认不打开扬声器、不修改音量。命令行宿主的用途文案、bundle／签名及TCC真实行为需总协调在Mac核验，不能把fake授权当作系统授权成功。

离线fake backend必须覆盖：正常创建和逆序清理；每个创建／启动阶段失败；拒绝授权；重复stop；取消；两个session隔离；缓冲耗尽；格式／timestamp无效；已启动IO停止失败时不释放仍在用内存。测试直接断言资源账本与cleanup结果，不只镜像实现。

真实有限录制由总协调单独执行：记录授权结果、tap实际格式、总帧／时长、host/sample时间有效性、非静音能量及完整清理。非静音文件证明采到声音，不证明5.1、AirPlay、音画同步或声学同步。没有实际系统输出时允许录到静音并明确说明，不能伪造信号填充。录音文件按需保留，不上传、不自动转发。

P0通过后另开任务：与受管worker传输标准PCM（新应用层契约）、后台重采样／时钟锚点、live有界队列、反馈环验证与真机同步。现有文件播放路径继续可独立运行并保持回归基线。
