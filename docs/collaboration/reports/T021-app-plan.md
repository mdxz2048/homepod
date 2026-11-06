# T021：系统声音采集接入 App 的最小桥接方案

状态：只读代码评估；用户已明确优先系统声音采集，停止新增文件试听导航。评估时未修改 App、冻结核心或既有适配器，未启动采集、播放或 Mac SSH。

## 已有能力与实际缺口

`ProcessTapCapture` 提供显式 start/stop、private tap/aggregate、真实 Float32 ASBD、原始 input/now hostTime/sampleTime/valid flags、Mach timebase、session、sequence/gap，以及有界回调存储。它不负责 AirPlay，也没有把原始 Mach ticks 对齐到 Python/Core 的时间轴。

现有 `WorkerStore` / `adapters.worker` 面向有限 signed16 WAV；`BoundedHub` 校验正的 `total_frames`，用确定总长和 EOF 验证完成。不能伪造一个巨大总帧数、把暂时没有采集数据当 EOF，或逐段播放 WAV 来冒充实时系统声音。

## 下一实现切片

总协调后续指定新增独立 `TapCaptureHost` executable，继续复用独立平台库。host 处理明确的 start/stop 命令、系统授权、后台 44.1kHz Float32 转换、有界媒体 IPC 和逆序清理；默认帮助模式不采集。新的实时 Python hub/reader 与有限文件路径分离，核心 C ABI v1 不变。

App 仍通过一个受管服务控制会话。先获得专用 worker 和采集宿主的真实 PID、建立排除集合，再显式启动采集；worker/App PID 变化时先停止旧会话，不沿用旧排除列表。global tap 始终排除捕获宿主、本 App 和发送 worker；无法确认排除对象时失败，避免反馈。用途说明由实际捕获宿主的 Info.plist 提供，不能从另一 probe 的授权推导 App 或 host 已获授权。

stdin 控制与 stdout PCM 使用独立 framing/类型，协议由 `LIVE_PCM_PROTOCOL_V1` 冻结后实现；不把二进制混入现有 worker 的 stdout JSONL。单条长度、积压字节数、写入截止时间均有上限。回调仅写预分配 C ring，转换、IPC、日志与销毁均在非实时侧。无消费者、格式变化、时间跳变、队列溢出或写入超时均显式终止当前会话，不丢样后继续声称连续。

标准媒体块输出 Float32 interleaved、44100Hz 和实际声道数；首切片是立体声，不宣称自动获取5.1。元数据保留原始源帧区间、源格式、input/now时间戳与有效标志、Mach时基、转换延迟、连续媒体帧索引和session。重采样前后索引分别计数，不能把原生 sampleTime 强转为核心 first_frame。

播放端独立建立 capture-to-playback 时钟映射、共同未来 origin、启动缓冲预算与迟到策略。输入 Mach ticks 与 Python monotonic 的 epoch 不假定相同；媒体 first_frame 在新 epoch 从0开始。停会话需同时停止采集、唤醒实时 reader、停止 native group、关闭连接并确认所有受管进程退出；异常退出只报告未确认清理，不自动重启/出声。

## App 首个统一入口

系统采集服务就绪后，主开关才调用真实 start/stop；展示准备中、等待系统声音、正在发送、停止中、失败和清理未确认，不能以 accepted/已创建tap 代替正在出声。示例布局继续明确标识；音量仅在启动时应用，运行中调整未接入前不能伪称生效。立体声对、自动空间混音和音画偏移仍按真实能力禁用或说明。

## 验证顺序

1. host mock 数据 → framing → Python live reader/native dry-run；覆盖48k→44.1k转换、任意输入块尺寸、时间戳、sequence、容量、取消及断流，不触发系统采集或音箱。
2. 使用者显式操作后，有限真实系统采集：核实权限、实际格式、非静音、排除与逆序清理。零帧/静音/无效时间/丢块均未验证。
3. 使用者显式操作后，再验证系统声音 → 两个独立输出、共同计划和清理；发送成功与主观听感、量化声学同步分别记录。

本报告不是已接通声明，也不提供未经实测的完成时间。当前可确定的开发边界是先完成受管实时采集桥，保持文件路径与既有回归基线可独立验证。
