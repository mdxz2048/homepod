# 虚拟音频 MVP 独立验收

日期：2026-11-06。所有 Mac 驱动、浏览器、声学项目目前均为**未测**。本文是验收设计，不是通过记录。原生设备既有属性数据引用 [原生延迟报告](../reports/Native-output-latency-2026-11-06.md)，不替代本阶段结果。

## 必须区分的三层证据

| 层级 | 要回答的问题 | 可接受证据 | 不能据此声称 |
|---|---|---|---|
| L1 HAL 属性与时钟 | 我们到底报告了什么、实际安排什么时间播放？ | 按设备UID、作用域、采样率逐项读取 device latency、stream latency、buffer、safety、AU latency；回调 host/sampleTime 与调度映射日志 | 浏览器真的读了、音箱实际发声、音画对齐 |
| L2 浏览器采用 | 当前浏览器这一次播放是否使用输出延迟？ | 对应版本媒体/音频 trace 中的真实渲染 delay 与输出时间；或有对照且可复现的真实视频呈现行为实验 | trace 字段名字相似就等于全链路延迟；Chrome 通过就等于 Safari 通过 |
| L3 最终音画 | 人看到闪光、听到 HomePod 声音相差多少？ | 同一录制时钟记录屏幕和音箱声学事件，保存原始录像、逐事件时间戳、误差预算与基线 | 单独系统录音、系统录屏音轨或发包时刻就是实际声学呈现 |

三层分别记录，不用 L1 通过代替 L2/L3。WebAudio 的 outputLatency/getOutputTimestamp 即使读到值，也不能代替 HTMLMedia 视频路径。Safari 若无可核验的内部 trace，L2 内部采用值写“不可观测”，L3 行为证据单独说明。

## 第一轮驱动契约风险审查

以下是安装前审查项；最终字段与边界依 CONTRACT.md，不能测试侧私造另一个协议。

- Float32 stereo 与 44.1/48kHz 都必须可实际工作；rate 改变后以帧为单位的 latency 应一致换算。第一轮不宣称六/八声道。
- driver 设备/流 latency、AU/hostTime 之间只能计一次真实预算。需要独立样本时间映射，不允许把时戳写到未来冒充确实存储了未来音频。
- 固定值必须绑定已准备好的整组输出计划。接收端协商值/路由发生变化时需新的确认边界，不能沿用旧报告值。
- latency 属性变更要发正确属性通知；测试客户端可能仅在 open 时读取，必须分别验证“正在播”和“关闭重开媒体输出”。
- 未准备好下游时是明确 unavailable/transition，不可只输出静音却报告成功；driver 与 App 生命周期独立，需要所有权/健康检查和失效恢复。
- 不修改苹果内置设备 latency；不静默切走用户当前原生 HomePod 输出；无安装授权前不写系统 HAL 目录、不重启服务。
- RT IO 不阻塞、不磁盘/网络、不分配无界内存；所有环形队列预算、溢出行为与清理顺序可审。

## 安静阶段：无需出声的检查

已对照 CONTRACT v0.2 增补以下安装后静默查询矩阵（均未执行）：

| 对象/属性 | 预期 | 负向/边界 |
|---|---|---|
| Device UID/输出stream/输入stream | 固定UID、一个FL/FR输出、输入为零 | 不凭display name选设备，不把output-only当免TCC |
| `deviceLatency` / `safety` | output/main均0 | 错scope/element返回约定HAL错误 |
| `streamLatency` | stream global/main、output/main **均存在、大小UInt32、只读、同值**，当前`hfla`预算帧数 | 两scope的Has/Settable/Size/Get四入口一致；input、未知scope、非main拒绝，与device/AU/hostTime不得重复加 |
| `hfla` | UInt32 global/main，停止且无pending配置可写0..10×rate | 拒绝越界/错误尺寸/运行或pending时改值，状态无部分变更 |
| `hflr` | UInt64只读，初值1 | 同值幂等不增加；有效rate/latency变更才增；重发现使旧revision失效 |
| 44100↔48000 | 真正异步配置提交，latency按秒保持再换帧 | active IO/pending冲突拒绝；Abort不改变原格式 |
| buffer / zero timestamp period | 512 / 16384，互相独立 | 不机械加入上报延迟；timestamp已到周期边界、单调、seed正确 |

`hfla=0`初始值标uncalibrated，不可自动接管。实际校准必须验证源Tap hostTime语义及首块左右独立PCM；需要AudioCapture授权。修改预算后检查stream latency向global/main与output/main两个地址发通知，并检查hflr；两个地址是同一个延迟值，不相加。也必须关闭重开客户端验证采用；客户端不释放IO时返回busy，不能强改或杀服务。意外revision变化、休眠/重启/源gap按契约停止并新epoch，旧队列不能重放。

v0.2兼容修正依据：Chromium [`GetHardwareLatency`](https://raw.githubusercontent.com/chromium/chromium/main/media/audio/mac/core_audio_util_mac.cc) 首先以调用方的output scope构造device latency查询地址，再只改selector查询streams及首stream latency，保留output scope。只支持global时，其查询可能失败并留下0。因此静默测试必须实际分别调用两scope四入口，写非零hfla后再次读取，不能仅凭源码声明或初始零值相等判通过。这是源码依据，尚未在本项目虚拟设备上实测Chrome，也不证明Safari行为。此兼容例外仅适用单输出stream latency，其他未知selector/scope仍按契约拒绝。

1. 构建驱动到工作目录，保存工具链、源码 revision/SHA、签名/依赖与完整构建日志。核对 bundle 与驱动目录的版本标识。
2. 源码审查属性尺寸、scope/element、只读/可写权限、未知属性错误、GetZeroTimeStamp 单调性/周期/seed、并发 StartIO/StopIO 引用计数、变更通知与进程间边界。
3. 运行工具测试：`python -m unittest discover -s tests/virtual_audio -p test_tools.py -v`。仅使用临时目录生成文件，不播放。
4. 生成素材可省略 FFmpeg：`python tests/virtual_audio/make_media_fixture.py --output <不存在的新目录>`。这时只生成参考 WAV、JSON、页面，页面缺 MP4 不能播放，这是预期，不是生成视频成功。
5. 有经过确认的本机 FFmpeg 后显式指定 `--ffmpeg <路径>` 生成 MP4；不自动下载安装依赖，不启动浏览器/服务器，不自动播放。

Windows 离线测试不证明 macOS HAL 可构建或可用。安装、切输出、播放与录制由总协调统一操作，并遵守用户现有授权。

## 播放素材与编码校准

使用一个 HTML `<video controls>` 直接播放本地 `sync.mp4`，不经过 WebAudio，不使用 autoplay。相同文件 SHA 用于所有对照。素材为 11 秒、30fps、2/5/8 秒三次三帧全白闪光，匹配 40ms 1500Hz 脉冲；WAV 是 48kHz 单声道参考，不是产品文件播放入口。

MP4 使用 H.264/AAC。必须用 FFmpeg/ffprobe 或等效离线工具检查实际解码后的音频脉冲起点与视频首白帧 PTS，记录 codec delay、edit list/skip samples 与检测阈值。不要把源 WAV 时间戳直接当压缩文件的精确起点。把实际文件固有 A/V 差记为 C，最终偏差分析扣除 C；若无法可靠校准，结果包含该不确定性，不能报告个位毫秒精度。首次播放先低音量。

## 对照矩阵与操作顺序

记录 macOS/硬件、Chrome/Safari 具体版本、网页与媒体SHA、输出UID、采样率、录制帧率与音箱/相机位置，确认 HomePod Flow 仅在虚拟转发组开启。

| 路径 | L1 属性 | L2 浏览器记录 | L3 同录 | 当前状态 |
|---|---|---|---|---|
| 内置扬声器 | 旧静态数据可参考，当前重新读取 | Chrome/Safari 各一次 | 作为录制系统基线 | 未测 |
| 原生 AirPlay HomePod，Flow关闭 | 旧数据2秒仅参考 | Chrome/Safari 各一次 | 苹果路径对照 | 未测 |
| 虚拟→真实缓冲→同一台 HomePod | 逐项预算和时间映射 | Chrome/Safari 各一次 | 核心判定 | 未测 |
| 虚拟→两台 HomePod | 同组预算、每端计划 | 每浏览器重复 | A/V与两音箱间同步分开测 | 未测 |

每个浏览器和路径至少三次冷启动播放，每次三个事件。再测试暂停/恢复、seek 到第一个事件前、切换输出后重开、44.1/48kHz、输入停止和重启。额外持续播放30分钟，开头/中段/末段嵌入相同事件，不能用11秒素材一次通过代表长期稳定。

验证“采用上报延迟”需要受控干预：仅在开发设备增加**真实共同缓冲**（例如额外500ms），同步增加正确报告值，再对比视频和声音时刻及最终 A/V 差。如果支持只在测试构建使用的‘不通知客户端’负向对照，须隔离于产品、不会修改苹果设备属性且由总协调审查；不要求为实验加入危险的任意假报告接口。无干预、无内部trace时，仅凭最后对齐不能唯一证明播放器采用了哪个属性。

Chrome trace 必须先检查当前版本实际支持的媒体/音频事件类别与字段，保存原始 trace；chrome://media-internals 若只有解码缓冲信息，不够确认 HAL 硬件延迟。Safari 不拿 Chrome 字段套用。没有字段不算失败，但不能声称已读到内部采用值。

## 最终声学测量

首选外部相机/手机同录 Mac 屏幕与 HomePod 发声。使用同一文件视频帧 PTS 与录音采样时间，避免分别录屏、录音后直接相减。关掉相机蓝牙麦克风路径并记录是否有自动降噪/后处理。录制屏幕应包含明显闪光区域，音箱位置固定、避免削波与回声造成错误首峰。

视频事件是录到的第一张亮帧，声学事件是直接声脉冲起点；人工复核每个事件，避免误把回声当新脉冲。30fps至少存在一帧约33.3ms采样量级的不确定性，另外计显示扫描/滚动快门、音频起点检测和录音A/V固有偏差。音箱至麦克风每米约2.9ms传播时间；距离不明则纳入误差。不要用这套普通视频测量报告10ms级音箱同步通过，精测需更高帧率或同步多麦工具。

填写CSV：

```csv
video_seconds,audio_seconds
2.100,2.180
5.100,5.180
8.100,8.180
```

以上仅为示例，不是实测。运行 `python tests/virtual_audio/analyze_events.py <csv路径> --uncertainty-ms <正数>`，正值表示声音晚；工具检查至少三个事件、有限时间与3秒间隔，输出中位数/范围，不自动给通过结论。必须连同原始录像、提取方法、C、距离和不确定性一起审阅，单独CSV可被误标，不是独立事实来源。

## 判定与证据交接

自动补偿机制首轮建议判据：最终校正后 A/V 中位偏差绝对值加声明不确定性不超过80ms，额外真实500ms缓冲后仍保持此界限；该值是**待产品批准的实验门槛**，不是正式全部内容质量承诺。若测量误差过大，先提高测量质量。若产品要求更严格按批准值重判。

每行报告：实测/未测/失败/不可观测、原始证据路径、参与版本、操作、结果和误差。音箱间同步、A/V同步、长期漂移三项分别签署。第一次出现虚拟设备、属性读到2秒、非零PCM、用户听见出声均不能单独算自动音画通过。受保护内容、WebRTC/WebAudio、原生多声道、独占设备的播放器另列兼容性，不从 HTMLMedia 推广结论。

当前已执行：Windows Python3.10本机静默单元测试 **6/6通过**（`python -m unittest discover -s tests/virtual_audio -p test_tools.py -v`）。测试仅在临时目录生成并检查PCM采样位置、禁止覆盖与无自动播放页面，以及人工时间戳汇总/拒绝错误数据的逻辑；没有实际浏览器或声学结论。当前Windows PATH未找到FFmpeg，MP4分支未运行；需总协调在Mac查工具后生成并校核编码后实际PTS/音频起点。未执行任何播放、录音录像、SSH、驱动安装或输出切换。

## 首轮驱动静态审查记录（候选仍在修改）

2026-11-06：仅阅读 `platforms/macos/VirtualAudioDriver/`，未编译或安装，不能将此记录当候选签署。

- 已见 stream latency output/global 两查询入口共享Size/GetData值；四属性入口复用Size，符合兼容修正方向。已见rate/latency提交两scope通知。实际四入口测试及host通知验证仍待Mac运行。
- 已见RT WriteMix只检查对象/operation/pointer并返回，无队列/网络/磁盘/分配，ZeroTime使用有界八次原子快照重试；不能据此证明device Tap确实可读输出数据。
- 已向驱动负责人提交：device latency/safety input scope与契约output-only不一致；未初始化host时从stream format请求重配置的Abort路径错误传stream对象可能残留pending；stage脚本应明确拒绝系统HAL路径，避免把错误stage目标变成安装。
- 需要候选确认或Mac集成验证：设备StreamConfiguration通道枚举支持；全局/输出scope非零查询、错误scope/元素、revision幂等/边界、配置Abort失败不部分应用、多个客户端起停和时钟seed、输出撤销与原设备恢复。
- 总协调反馈首轮Mac编译失败18项，驱动负责人正在修订；该失败不是QA本机编译结果。重点回归：device和stream latency具有相同fourcc `ltnc`，GetData不能在单switch声明重复case，应按对象区分device=0、stream=配置预算；在hfla为非零时同时断言两对象和两stream scope，避免所有值初始0掩盖分支错误。还需修复SDK HostRef指针层级、Size与MacTypes名称冲突及头文件依赖，随后重新构建。当前不签署构建通过。

以上问题由驱动负责人修改或解释，再以候选SHA及实际Mac测试结果关闭；当前保持未关闭，不把正在修改源码的观察写成最终通过。

### 第二候选静态复审

审查版本为源码 `FlowVirtualAudio.c` SHA256 `521798155879f90e292c4ddf9887939f957ae96defb7134b7b37968465e131b2`；头文件 `0b70f3a7817f35b134ae7f38e1eae4a7f36f9f6e0be3bdd88b2c5b5a3c82048a`；DriverChecks `aaf451fea61333c676a1b1e6180c7596a8bb8f6330bbe3104508e90132ca93bc`。这不是整个产品的版本签署。

- 原编译修正静态可见：加入AudioHardware头，HostRef使用直接结构成员，Size改名PropertyDataSize，单一`ltnc` case按对象返回device0/stream配置预算，消除同fourcc重复case。
- stream global/output latency均由同一属性表校验，GetData读取同一gLatency；input及非main在表中拒绝。device latency/safety仅output可读。IsSettable不会将latency误识别为格式可写属性。两个scope变更通知均可见。
- rate请求host缺失或失败都用deviceID调用Abort，清除匹配pending；预算保留原frames/rate有理数，rate变化重新换算，避免往返累积舍入。当前测试直接设置pending再Perform，未独立覆盖host请求失败/通知/所有scope入口，需下一候选补mockHost。
- StartIO/StopIO有固定64槽client表，重复start/stop拒绝，另一个客户端保留运行；重置仅零到一，时钟读最多八次原子快照尝试，不锁或等待。WriteMix不读写音频数据、不阻塞；Tap可读性仍未证实。休眠epoch与长期稳定仍待真机生命周期测试。
- root反馈此SHA的Mac独立测试及stage构建均退出0，plist/codesign通过；QA未直接运行或复核原始Mac日志，保留来源区分。未安装、未枚举实际HAL设备、未做Tap/浏览器/声学测量。

第二候选未关闭问题：stage_root物理父目录虽然受限，但现有bundle/Contents/MacOS/Info.plist/二进制或test可执行文件可为嵌套symlink，后续mkdir/clang/cp/codesign可能沿其写到系统位置。需第三候选拒绝或创建全新私有输出目录，验证嵌套symlink而不只根目录；当前不能据此声称stage绝不写系统。另ValidFormat在验证采样率前转换Float64为UInt32，遇NaN/inf/越界值有未定义转换风险，已要求先验证精确支持值。下一候选同时增加mockHost验证scope/通知/失败回滚。无源变更重跑工具测试不增加本阶段音频证据，因此未重跑既有6项工具测试。

### VirtualAudioInput 第一候选静态复审

审查SHA256：`Control.swift` `2a8bb1306a51149d50b2e6326682a156e566562f469eab3d1e4051ce8f5c7e55`；`HALVirtualDeviceBackend.swift` `d9716f54ea546520f2974f490e7f918c44d5ea18269512fb6577a3c44e48dee1`；`Models.swift` `d45c28b34a8381d2d58e6feeb661c0795c5046038017c57a36147b2c0bbd6c69`；`Recovery.swift` `41d0af9cf2b7836c09fe522be1565f85968888a67c478b1d85bbfccfd49d6e22`。仅静态阅读，Mac编译/12项Swift测试由总协调统一执行，本条未获得结果。

- 设备按精确UID匹配且拒绝重复，再校验model、alive、两离散rate、实际physical/virtual ASBD和advertised formats。读取单输出/零输入、方向/active/starting channel与FL/FR布局，非仅靠名字/通道数猜格式。
- 同时读stream global/output latency及device hfla要求相等，device latency/safety为0、buffer512、period16384；发现前后revision一致且非零，最后重新检查UID。结果仍为tapVerified=false、permission unknown、calibration uncalibrated；不是ready。
- 显式hfla API先读revision/running/range，再写并回读frames、rate与预期revision。外部并发写导致不一致时不确认成功。此步骤不会独自证明真实延迟校准；控制字段写入后仍需监听与session生命周期集成。
- 默认CLI无参只help，`--discover`只有HAL查询。startCapture固定抛capture_path_unverified；没有真实Tap和默认输出writer。takeOver缺helper默认拒绝，未验证路径/uncalibrated也拒绝。恢复意图先持久化再请求切输出，回读确认；当前输出被用户改动时不切回，恢复失败保留journal。
- **正式helper接入前未关闭问题**：FileLeaseJournal只有进程内MainActor，无跨进程事务。旧helper load旧lease后，新App可能clear并保存新generation，旧helper随后removeItem删除新lease；save同样存在检查与写入之间竞态。需要跨进程锁或等价事务协议覆盖load/check/write/clear及切换决策，按统一所有权顺序串行化，并新增可复现交错测试。当前顺序fake测试只证明纯policy，不证明真实crash恢复。
- 次要健壮性：load先读取完整Data再判断16KiB，未对读取本身设上限；应先检查文件类型/大小并使用有界读取，防损坏journal引起巨大分配。首次保存的private父目录、持久化耐久性、helper真实存活/所有权、输出变化监听和恢复原设备均仍属集成验收。

该模块可作为查询与policy骨架继续开发；不能以此宣布虚拟输入已采到声音、自动接管或crash恢复通过。

### 驱动第三候选增量静态审查

源码SHA256 `b9f077536d3d3c7c9780e977dbd1be532c7ba8048f35b4ac42fa45dacf94c610`；DriverChecks `4f12c62bc7870d95f41fdda7c3374ab2b890b98bb8f61e6a3929de63611cb5d4`；safe-output `6e643900f9ea8ebc5a397d972cf6160a00506c24400ac922ecd5cc3497143659`。

- ValidFormat先比较精确支持rate再转整数，关闭第二候选NaN/inf转换问题；新增NaN/inf拒绝断言。
- build脚本对现有bundle、Contents、MacOS、plist和binary逐项拒绝symlink，test脚本拒绝现有测试binary symlink；safe-output解析物理父目录并显式拒绝系统/HAL目标。新增私有目录path-checks覆盖系统路径、相对路径、dot逃逸、symlink bundle和symlink父目录。以上关闭先前报告的直接嵌套输出symlink路径；不将普通shell预检查宣传为抵御并发恶意篡改路径的安全沙箱。
- mockHost测试实际调用两scope四属性入口、input拒绝、非零stream/device分支、两scope通知、幂等、配置请求失败和host缺失回滚、Perform与Abort。这里确认的是测试源码覆盖，运行结果由root统一Mac日志提供。
- 当前未获得第三候选Mac执行结果，未安装。保留实际HAL枚举、AudioUnit初始化、device Tap真实PCM/时钟语义、浏览器采用及声学最终偏差的所有未测项。

Input负责人同时报告下一候选将journal读取改为最多16385字节并增加oversized测试；此项需要新SHA和总协调Mac结果后再关闭。跨进程事务问题仍是helper之前硬门槛，不能以bounded-read修正代替。

### 总协调统一 Mac 执行结果

2026-11-06，总协调反馈以下结果。来源为协调执行通知，QA尚未独立复核原始日志；原始证据包待交接。本次没有重复运行已通过的工具测试。

Input第二候选Recovery.swift SHA256 `a190af985f43e8e72f6f191e3f6ad71252703203c068e81601492cda4d18007e`；测试源码 `8e7ebb38e73540585ccdf3a8995f0ae2d2206fef34e1013223b0ad45d0d2baa5`。QA已读取有界分段读取实现及新增oversized断言。

| 候选/检查 | 协调执行结果 | 实际证明范围 |
|---|---|---|
| 驱动第三候选path-checks | PASS | 私有测试目录内路径拒绝逻辑，无系统安装 |
| 驱动第三候选C检查 | PASS | mockHost属性、通知、重配置与时钟/RT sink测试 |
| 驱动第三候选stage | 退出0，plist/codesign PASS | 形成可审查bundle，尚未安装或加载到HAL |
| Input第二候选 | 13项XCTest全通过 | 可注入policy、查询边界和有界journal测试 |
| Input CLI无参help | 退出0 | 默认无外部动作 |
| Input CLI --discover | 退出1，driver_unavailable | 未安装驱动时诚实不可用，不伪造ready |
| QA工具Mac复跑 | 6/6通过 | 素材/事件分析工具逻辑，不是播放或声学测量 |

结合静态复审及协调反馈，关闭源码层问题：同fourcc对象分支、双scope查询/通知、input scope拒绝、失败配置回滚、NaN/inf先验证、已报告的嵌套输出symlink路径、journal超大文件无界读取。跨进程journal事务/helper真实恢复仍未关闭。实际HAL枚举/初始化、Tap左右独立非零PCM和源时钟语义、浏览器采用及最终声学音画全部保持未测。
