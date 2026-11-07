# chrome_trace — Chrome 音频硬件延迟证据通道诊断（018）

本目录由 018 独占维护：`tests/virtual_audio/chrome_trace/**`。
不要修改 `chrome_latency/**`（017 所有）。

## 用途

在 Mac 上自动拉起一个**隔离的新 Chrome 实例**（远程调试只监听 127.0.0.1，
全新临时 profile），播放一个本地 HTML `<video>`（普通视频资产，音画同封装），
再用 CDP 采集 Chrome 音频硬件延迟证据通道：

- `Browser.getHistogram`：
  `Media.Audio.Mac.HardwareLatency.Output.AudioUnit / .Device / .Stream / .Total`
  （Chromium `media/audio/mac/core_audio_util_mac.cc` 的 `UmaHistogramTimes`
  四个子项），以及 `Media.Audio.Render.SystemDelay`
  （`media/audio/apple/audio_auhal.cc` 的 `UMA_HISTOGRAM_COUNTS_1000`）。
- `Browser.getHistograms` 过滤 `Media.Audio*` 做发现（写入 `evidence.json`）。
- `Tracing.start/end`（分类 `audio` 与 `disabled-by-default-audio`）提取 AUHAL
  事件：`streamFramesTotal`（`AUHALStream::Render` 的 `output_buffer_size`
  累加，即上报的流帧数）、`hardware_latency_us`、`source_request_playout_delay_us`。

是否播放成功由页面回读 `currentTime / readyState / audioDecodedBytes /
videoFrames` 佐证；不把“缺 trace”当作浏览器负结果：trace 与 histogram 是
两个独立通道，哪个采集到就报告哪个。

## 接口（与 017 协调）

```
node chrome_audio_diag.mjs --media <本地视频文件> --out <输出目录> [--play-sec 8] [--port 0]
```

- `--media`：本地音画同封装的视频文件绝对路径（例：017 或本目录生成的
  `fixture.mp4`）。harness 只读取并 symlink/copy，不修改。
- `--out`：输出目录，产物为 `report.json` 与 `evidence.json`。

## 生成安静的合成资产（自测）

```
/opt/homebrew/bin/ffmpeg -y \
  -f lavfi -i testsrc2=duration=8:size=640x360:rate=30 \
  -f lavfi -i sine=frequency=440:sample_rate=48000:duration=8 \
  -filter_complex "[1:a]volume=0.02[a]" \
  -map 0:v -map "[a]" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest -movflags +faststart \
  fixture.mp4
```

不提交任何媒体文件。

## 安全边界

- 不写 HAL、不切换系统输出、不启动 Flow、不向 HomePod 发送、不关用户 Chrome、
  不 commit、不用 sudo、不碰凭据。
- 只关闭自己拉起的 Chrome 进程（`Browser.close` + SIGTERM + 兜底 SIGKILL），
  临时 profile 与 staging 目录用完即删。
- 若 headless 通道取不到音频证据、确需 GUI 会话启动时，记录具体 blocker；
  不会把“没有 trace 文件”判定为浏览器负结果。