# 017 Chrome 延迟 A/B 准备 — 中文简报

## 已完成（实现方自测范围）

1. 新增 Swift CLI `hflctl`（`hflctl/`），只面向精确 UID
   `com.homepodflow.virtual-audio.surround71.v1`：
   - `status` 只读：上报采样率、running IO（两个标志）、`hfla`/`hflr`
     CFNumber、stream latency 两 scope（global/main 与 output/main）、
     buffer/时钟/设备延迟=0/zero timestamp=16384/通道数等，JSON 输出，失败即关停。
   - `set-ms 0..3000` / `rollback --to-ms`：写前查 revision（可选
     `--expect-revision`）与空闲，写后回读校验 `hfla`、两 scope latency 和
     revision；校验失败自动按“写前帧数/采样率”回滚并复核；不伪造成功。
   - 无 `--uid` 覆盖，无法改其他 UID 或系统默认设备；exit 0/1/2 明确。
2. 离线可复现夹具 `fixture/make_fixture.py`：生成单个 H.264+AAC MP4
   （四象限同时闪烁 + 短哔声在同一编码文件、同一媒体时间轴）+ 普通
   `<video>` 页面；不使用 WebAudio/JS 定时器；媒体按需生成、不入库。
3. Chrome trace 工具与说明 `chrome_trace/`：
   - 主路径 `chrome://tracing`（audio 类别），`analyze_latency_trace.py`
     提取 `hardware_latency_us`/playout 样本并算 P95；没有样本就是缺证据，
     不等于通过。
   - 单相机声学辅助 `measure_recording.py`：检测画面闪烁与音频哔声 onset，
     计算逐事件 |音频-视频| 偏差与 P95；仍需人工抽查确认。
   - `record_experiment.sh`：默认只读准备 + 运行手册；只有显式
     `--apply-ms` 且 `HPF_EXPERIMENT_APPLY=1` 才经 `hflctl` 写盘。

## Mac 实测（仅只读/构建，未写 HAL、未播放、未开 Chrome）

- SSH `homepod-mac` 可连；本机新建目录
  `live-validation/017-chrome-latency/`，源码同步到
  `live-validation/source/tests/virtual_audio/chrome_latency/`。
- `xcrun swift build` 通过；`xcrun swift test`：8/8 通过。
- `hflctl self-check`：8/8 通过；`hflctl --help` 正常。
- 真机 `hflctl status`（只读）通过：设备 `surround71.v1`，model
  `...model.surround71.v1`，8ch，48000Hz，hfla=0，hflr=1，stream latency
  两 scope 均 0，device latency/safety 均 0，buffer 512（15..4096），
  zero timestamp 16384，无 input stream，当前无 running IO。证据已回存
  `tests/virtual_audio/chrome_latency/artifacts/mac-status-20261107.json`。

## 待总调/协调器执行（不属于本次实现方动作）

- 真实 `set-ms 0` / `set-ms 2000` 写盘（写前确认无占用、必要时
  `--expect-revision`），写后要求实验 Chrome 完全重开输出流。
- Chrome 隔离 profile 启动、`chrome://tracing` 捕捉、保存
  `trace-*.json` 与 `chrome_version.json`。
- 单相机录制闪哔画面并跑 `measure_recording.py`。
- 用两层结果共同签字：读值层（P95 hardware_latency_us，若有）与声学层
  （P95 |闪-哔| 偏差）；任缺一层不宣称通过。

## 关键制品路径

- 本地：`tests/virtual_audio/chrome_latency/**`
- Mac：`/Users/lvzhipeng/Developer/HomePodSpatialRouter/live-validation/017-chrome-latency/`
  （构建/测试/只读 status 日志）
- 未入库媒体与实验产物约定：`/tmp/hpf-fixture/`、`/tmp/hpf-ab/<condition>-<ms>ms/`
