# TapCaptureHost：受管系统采集桥

新增独立 executable `tap-capture-host`，依赖既有 ProcessTapCapture 库；未改动 CaptureSource、HAL、probe、核心 C ABI 或旧有限 WAV 适配器。正式使用由 App → Python worker 控制；没有文件选择入口。

权威接口见 `docs/collaboration/LIVE_PCM_PROTOCOL_V1.md`。stdout 严格 HPCM framing（12字节前缀 + 有界JSON header + Float32 LE PCM），stdin 严格 JSONL start/stop。字段与文档保持一致；元数据说明为 `timestampRelation: input_block_metadata`，不能用关联输入块时间当成该输出首样本的精确时间。原始 input/now host/sample/flags 与 Mach 时基保留，不假设 Python 时钟历元。

默认无参数或 `--help` 仅打印帮助，不创建 tap。`--serve` 只监听命令，收到显式 start 后才启动采集；实际执行须带 `Host-Info.plist` 的宿主。start 必须给出排除 PID，宿主自动排除自己；worker/App/发送进程排除由控制方传入。已有 HAL 无法把某个 PID 解析为 Core Audio process object 时会失败，不能静默删除排除对象绕过检查。真实 TCC/进程排除行为尚须明确启动后验收。

转换在独立串行后台队列执行：真实 Float32 stereo → AVAudioConverter → 44100Hz Float32 stereo。拒绝声道变化；不伪造5.1。输出最大4096帧，有限样本超幅显式clip到[-1,1]，`clippedSamplesTotal`报告累计数量。非有限样本直接失败。`primeMethod: none`与公开primeInfo只是配置/元数据，`converterDelayKnown:false`，不是零延迟证明。

stdout writer 在独立队列用非阻塞fd与有限poll写入；总积压≤256KiB、单记录写入截止1秒。控制线程不等stdout写锁；满队列、write超时、broken pipe、捕获丢块/跳序、非法时间戳、格式变化均使会话失败并停止采集。临时没有 PCM 仅等待，不等于 EOF。

进程为单次会话：显式 stop 后资源清理，stopped 沿 stop id，随后 flush 并退出；stdin EOF/SIGINT/SIGTERM 同样取消并清理。仅 cleanupComplete 及退出0共同支持资源已清理；停止不flush converter潜在尾音，`drainComplete:false`，使用过转换器时 `discardedConverterTail:true`，不能声称无损送达。stdout无法写出终态时非零退出，控制方必须报告清理未确认，不能用退出替代确认。

```sh
swift build
swift test
swift run tap-capture-host --help
sh scripts/package-host.sh
```

这些命令不采集、不播放。打包只生成并ad-hoc签名 `dist/TapCaptureHost.app`，不自动运行。4项新增host测试使用合成数据/假采集provider与真实pipe，覆盖HPCM长度/null字段、48k→44.1k帧数与非零/clip、stdout不消费超时、显式启停与资源确认。实际系统采集、权限、live AirPlay与声学同步均不从这些测试继承通过结论。
