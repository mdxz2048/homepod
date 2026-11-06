# HomePod Flow M0 核心架构

日期：2026-11-05。当前范围以 PRODUCT.md 为准。

调用方 -> PlaybackEngine -> N 个 Output。Clock 由外部注入。引擎内部完成输入校验、声道复制、共同纳秒播放计划和故障清理。

core/include/flow/core.hpp 为公共源码接口，core/src 为实现。只依赖 C++17 标准库，无 Swift、Python、OS API、固定设备地址。先在一个有限状态机内形成可运行闭环，避免空模块；确认独立复用需要后再提取 Router/SyncCoordinator 库。

Output 负责协议和队列，不能私自替换媒体时间基准。M0 模拟输出只能证明路由和时间计划，不能证明音箱同步；scheduled_start 声明不等于真实测量。

阶段：

1. M0：无界面核心，离线行为与故障测试；Windows/Mac 各自实际构建后记录结果，Linux 未实测不得标通过。
2. M1：保留 sync_probe.py/alac_adapter.py，建立真实 AirPlay 桥接；明确时钟跨进程映射、背压、ALAC和退出语义后再连接正式核心。
3. M2：持续输入、真实观测、长期同步、漂移与恢复，随后才接 Mac 捕获和 UI。

M0 C++17 是源码契约，不是稳定 ABI。M1 已新增版本化 C ABI（见下节），其所有权、异常和版本须独立验收。

故障采用 fail-stop：prepare 部分失败释放所有已尝试输出；发送失败含背压全组 Faulted。没有原子提交、自动重试或恢复。具体契约见 CONTRACTS.md。

本轮禁止自动播放音箱；历史真机结论仍仅为不同内容和短时主观同步，定量与长期稳定尚待验证。

## M1 有限真实桥接

新增 flow/bridge.h 的版本化 C ABI，由 Python ctypes 调用 C++ PlaybackEngine。数据路径固定：有限多声道输入 -> C ABI submit -> C++ 路由及时间线 -> callback复制有界输出 -> 自定义 pyatv AudioSource -> 既有ALAC适配 -> RAOP。旧原型保留作证据，不作为旁路替代 native 核心。

native使用宿主注入时钟值；RAOP共同barrier就绪后选计划，桥接将预计播放时间减去协议latency得到发送起点，再用冻结mono/NTP锚点映射。映射、guard、PCM字节序及清理细节以CONTRACTS.md为权威。

本轮不支持持续实时、运行中重配置、自动恢复、原生配对组或无限输入。真实音箱播放由总协调安排，不由各开发Agent独立触发。


## T015 接口冻结与持续路由

App依赖边界固定为core C ABI v1，快照和兼容门禁在docs/api/v1。旧头文件、导出符号和外部行为保持；C++不是跨编译器稳定ABI。

持续路由只改变adapter实现：有界全路队列，单个native Engine连续submit；容量预检在读取输入/submit之前，所有控制及回调串行。每路独立消费，队列暂空要等待而非返回EOF；明确reader EOF并排空该路后才允许pyatv补尾padding。实际native enqueue失败仍全组fail-stop；超时/取消唤醒全部等待者并关闭reader、native、source及连接。此为有限容量的拉取式持续输入，不预先承诺硬实时或漂移校正。
