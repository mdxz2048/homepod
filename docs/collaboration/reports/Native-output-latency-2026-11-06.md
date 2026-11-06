# Mac 扬声器与原生 HomePod 输出延迟属性实测

日期：2026-11-06。MacBook Pro，macOS26.5.2。用户要求比较原生输出时系统给播放器的延迟。状态：Core Audio公开属性读取完成；不是浏览器实际采用值抓取，也不是音画/声学测量。

方法：新增 tests/mac_output_latency.swift，枚举输出设备、查询设备与首输出流 latency、sample rate、buffer和safety；为各设备创建并初始化私有HAL output AudioUnit读取unit latency，随后释放，从不AudioOutputUnitStart。未采集音频、未播放测试音、未修改默认输出。系统输出由用户手动从扬声器切到客厅HomePod；用户确认HomePod Flow转发关闭。

probe实际Swift编译/运行退出0。先读latency-builtin.json，再由用户用Mac声音设置选择客厅后读latency-homepod.json。后者默认设备名为AirPlay，不把广播名字当作设备属性；“客厅”目标依据用户实际选择确认。两次均各查询状态0。

同口径静态和按当前Chromium GetHardwareLatency源码计算：AudioUnitLatency + deviceLatency/sampleRate + firstStreamLatency/sampleRate。不是完整渲染延迟公式；未包括实际AudioUnit回调output hostTime相对当前时间的lead、浏览器队列/合成/显示和最终声学误差。源码还存在device latency是否包含于AudioUnit的注释，故保留逐组件值，不自称通用无重复的硬件真实延迟。

| 当前设备 | 采样率 | AU延迟 | device延迟 | 首stream延迟 | Chromium式静态和 |
|---|---:|---:|---:|---:|---:|
| MacBook Pro扬声器 | 48000Hz | 0.3628118ms | 70帧=1.4583333ms | 690帧=14.375ms | 16.1961451ms |
| 用户选中的原生AirPlay/HomePod | 44100Hz | 0ms | 0帧=0ms | 88200帧=2000ms | 2000ms |

扬声器buffer512帧=10.6667ms，safety74帧=1.5417ms；AirPlay buffer512帧=11.6100ms，safety0。不能将这些值与静态和机械相加后称实际延迟，实际callback时钟关系需另验。原始字段及独立OSStatus保存在 T021-macos/latency-builtin.json、latency-homepod.json。

意义：原生HomePod输出确实向系统报告2秒stream latency。结合Chromium读取stream latency并传递播放时间的源码，存在让媒体管线补偿画面的机制依据；本轮没有证明特定已装浏览器真实消费了此值、没有实测Safari路径或音画最终偏差。虚拟设备正确上报真实整链路延迟仍是下一步实验，不能以本轮属性读取替代该功能验收。

该原生AirPlay的2秒属性，与HomePod Flow测试中RAOP协商1.5秒+软件准备0.5秒仅数值恰好同为2秒，是不同路径/不同含义，不互相替代。没有更改HomePod Flow签名、安装或恢复其采集。

官方源码依据：https://raw.githubusercontent.com/chromium/chromium/main/media/audio/mac/core_audio_util_mac.cc （GetHardwareLatency）；https://raw.githubusercontent.com/chromium/chromium/main/media/audio/apple/audio_auhal.cc （GetPlayoutTime/ProvideInput）。
