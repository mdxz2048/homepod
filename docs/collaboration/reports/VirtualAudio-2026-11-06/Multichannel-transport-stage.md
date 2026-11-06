# 多声道输入转换与 HPCM v2 软件链路验收

日期：2026-11-06（Asia/Shanghai）。主要实现由百炼 `deepseek-v4-pro-0813` 执行，总调度审查、纠错和统一 Mac 验证。此阶段不安装或替换用户 App、不切换系统默认输出、不向 HomePod 播放。

## 实现

- `DeviceTapCapture` 格式校验由 2..8ch 扩为 1..8ch；原始 device tap 不请求 mono mixdown。格式校验抽为内部静态函数，供无 HAL 副作用的测试调用。
- 新增独立 `VirtualPCMResampler`：1/2/3/4/6/8ch，44.1k 直通或 48k→44.1k 流式转换；显式 discrete slot 布局和 identity channel map，保留顺序；有界输入、输出、有限值检查及限幅计数。末尾 drain 尚未提供，不宣称停止时尾部完整。
- 新增 `VirtualHPCMEncoder`：标准 HPCM v2 分帧；明确区分输入块与输出包帧数，保留真实时钟标志，拒绝丢块/倒退/非法 PCM/计数溢出；校验和编码全部成功后才提交计数状态。
- 源信息固定为 device/os_mix、未验证原生布局、nativeClaim=false、source_upstream_mapped；这是设备容器数据，不伪称播放器原始多声道。

## 门禁与证据

| 项目 | 结果 | 证据 |
|---|---|---|
| Mac Swift 全包单测 | 35/35 通过 | hpcm-input-tests-final.log |
| Mac Release 构建 | 通过 | virtual-input-release.log |
| 既有 Python HPCM v2 回归 | 18/18 通过 | 本轮协调器实际运行 `unittest tests.test_live_pcm_v2` |
| Swift 转换→Swift 编码→Python 解析 | 14/14 组合、448 包、220052 输出帧通过 | hpcm-swift-python-acceptance.log、hpcm-cross-language-final.log |
| 实际 mono 设备打开 | 1ch、48k、4 bytes/frame 能建立；0 回调/0 帧，未证实实际取声 | mono-tap-postboot.json |

跨语言夹具覆盖 mono/stereo/3.0/4.0/5.1 side/5.1 back/7.1，各 44.1k/48k，连续 32 块。检查帧比率、协议连续性、逐通道不同值的顺序与保守 provenance。夹具由真实 Swift 库生成，再下载给本机现有 Python 解析器；不是 Python 自制 header 的同侧测试。可复现工具位于 `tests/virtual_audio/swift_transport_probe` 与 `check_swift_transport.py`，二进制夹具在忽略的 artifacts 中。

## 审查纠正

首轮发现测试的可选枚举匹配无法编译、AVAudioFormat 多声道初始化错误和 Swift 6 回调捕获问题；协调器修正并在 Mac 重测。SDK 头文件确认：channels-only 的 AVAudioFormat 初始化器拒绝 >2ch；显式布局与 identity map 必须同时配置。

协议初稿的 33 项单测虽通过，独立串联因 `block_frame_mismatch` 失败。协调器拒绝初稿，派回 DeepSeek 修正输入/输出帧数混淆、原始/转换 PCM 错误比较、伪造 flags、wrapping arithmetic 与 Data 对齐假设，再完成上述最终门禁。首轮失败日志保留，不用全绿单测替代集成证据。

一次 worker 超出派工边界继续生成 Python 同侧 probe，已停止，其临时文件移至忽略的 artifacts，不计验收证据。调度器新增 480 秒/14 次 shell 调用的默认硬边界；普通成功、超时停止和命令次数停止三种路径已用无模型子进程验证。不声称这是精确 token 预算。

## 尚未完成

此阶段仅完成采集格式与转换/编码组件，以及合成数据软件链路。产品 capture host 的控制协议、HPCM v2 持续输出、worker 消费/路由执行和 App 身份下 TCC 尚待接入；HALVirtualDeviceBackend 的旧发现入口仍为 stereo。真实 mono/6/8ch 逐通道非零 PCM、音箱多声道分发、恢复 helper、默认输出接管、浏览器音画与声学均未因此通过。

下一切片：以显式 UID/layout 选择建立受管 v2 capture host，接入现有有界 writer 与停止确认；先做无播放的协议/取消/清理验收，再进入 App TCC 和两台音箱 downmix 路径。自动默认输出接管继续关闭。
