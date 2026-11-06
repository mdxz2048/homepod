# Core Audio Process Tap 采集模块

独立 Swift Package，macOS 14.2+ / Swift 6。当前交付可复用采集库、有限探针、C11 有界缓冲和无权限的 mock 生命周期测试。尚未接入 HomePod Flow App 或 AirPlay worker；此目录不修改冻结核心或既有 App。

实现依据：[Apple 官方 Process Tap 示例](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)和本机 Xcode 26.6 SDK 头（项目 `artifacts/process-tap-sdk.txt`）。Apple 要求宿主声明 `NSAudioCaptureUsageDescription`，首次开始读取包含 tap 的设备时可能出现系统音频权限提示。模块不读取私有 TCC 数据库、不自动授权，也不从静音或错误码猜测「权限已授予」。

## 边界

- 默认 stereo mixdown，输出真实查询得到的 ASBD；仅接受 packed Float32 PCM（交错或非交错），不伪造 44.1kHz，不自动重采样，也不宣称获得原生 5.1。
- 指定进程 PID，或全局捕获并排除本进程；`excludedProcessIDs` 还可显式排除发送 worker / App。选定目标与排除集合冲突直接失败。PID 不能解析成 Core Audio process object 时失败，不扩大范围兜底。
- private tap + private aggregate，固定 `.unmuted`，不修改默认输出、系统音量或进程静音。设备或 tap 格式变化产生 fault；下一次非实时 `readBlock` 执行 fail-stop，必须显式处理错误，不自动重新捕获。
- `AudioDeviceIOProc` 仅调用 C ring；所有 slot/PCM 内存提前分配并触页。回调不创建 Swift 数组、不分配、不写文件、不锁、不 dispatch、不打印。初始化检查 C atomics 为 lock-free。
- 单生产者、单消费者；队列满时丢弃最新块，`callbackSequence` 和 `droppedBlocksBefore` 标明具体断点。callback 帧超限或 buffer 布局改变会报 fault，绝不截断或假装连续。
- 实际 ring 分配总预算最高 64 MiB；队列为 2...256 的二次幂，callback 帧上限 1...16384；超过预算明确失败。数据转换、有限 probe 落盘都在非实时消费端执行。
- block 带本次 session UUID、原始 input/now host ticks、sampleTime、有效标志和 Mach timebase。消费端检查有效 host ticks 回退，以及有效 sampleTime 相对上一块末帧的异常跳变（半帧容差），发现后 fail-stop；明确队列溢出的向前缺口保留 gap 标记，probe 仍判为未验证。新 session 重置比较基线。无效标志不参与连续性推断。host ticks 不是纳秒；换算 API 只改单位，不建立 Python/Core/Unix 的时钟 epoch 映射。无效时间戳原样保留，不能当作已验证。

## 使用

推荐作用域 API，确保正常、异常、取消都执行清理：

```swift
let source = CaptureSource()
try await source.withCapture(configuration: .init(
    selection: .processes([selectedPID]), excludedProcessIDs: [senderPID]
)) { source in
    // 在非实时消费任务中轮询；nil 是暂时无数据，不是 EOF。
    if let block = try source.readBlock() {
        let interleaved = try block.interleavedFloat32()
        // 交给下一层时保留 timestamp、sequence、gap 与 session。
    }
}
```

也可显式 `start/readBlock/stop`，但必须保持实例并在所有出口调用 `stop`。不能依赖 deinit 进行可能失败的 HAL 销毁，更不能在回调仍存在时释放 ring。停止按设备 stop → IO/监听 detach → aggregate → tap 逆序进行；任一依赖未确认时保留资源，进入 `cleanupUnconfirmed` 并拒绝重新 start，可显式重试 stop。此时不报告「干净停止」；不可丢弃该 owner。使用作用域 API 的 probe 每个出口均尝试清理，清理失败最终以非零退出和错误报告呈现。

## 构建与不录音验证

```sh
swift build
swift test
swift run tap-capture-probe --help
swift run tap-capture-probe
```

以上命令不会创建 tap 或录制。测试注入 mock backend，并直接验证 C ring 的数据、时间戳、容量和断点；不需要麦克风、音箱或系统音频权限。

## 显式有限探针

```sh
sh scripts/package-probe.sh
# 以下命令仅供操作者明确要录制时执行；打包本身不运行它：
dist/TapCaptureProbe.app/Contents/MacOS/tap-capture-probe --capture --seconds 5
```

探针没有 `--capture` 时只打印帮助；录制范围 1...10 秒。`--pid` 可重复选择目标，`--exclude-pid` 可重复排除发送端，`--output /absolute/new.wav` 可选写入新文件，使用 `O_EXCL` 原子创建而不覆盖已有文件。裸命令行二进制缺少权限用途说明时拒绝开始，须使用带 Info.plist 的宿主。

JSON 报告包含实际 format、帧数、非零样本、峰值/RMS、首末 input/now 时间戳、timebase、gap/drop 与清理结果。零帧、静音、无效时间戳、丢块、非有限 PCM、异常或清理失败均不能使 `captureVerified` 为 true，退出码为 3；有效采集退出 0，参数或宿主配置错误退出 2，报告编码失败退出 4。探针显式运行后会把 SIGINT/SIGTERM 转为任务取消并走作用域清理。信号数据不等于权限状态查询，也不证明声学同步。

可选文件是 **IEEE Float32 WAV（format tag 3）**；现有 Python 文件 worker 只接收 signed16 PCM WAV。两者尚未桥接，不能把 probe 文件或编译通过解释成已完成实时 AirPlay、持续流、重采样或全链路同步。

本轮只进行 build/mock tests/help；真实权限、非静音采集、设备切换与实际多进程排除尚待操作者明确执行探针后验收。

