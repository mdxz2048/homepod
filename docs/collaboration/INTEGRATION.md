# 总协调集成记录

## 最新：2026-11-05 接口冻结与有界持续流

用户要求接口先固定、后续调试保持调用边界。架构建立docs/api/v1原样快照和语义契约，未改两个公共头；底层新增streaming.py与stream命令，依旧用C ABI v1逐块submit；验收完成7项流式/3项接口门禁及旧binary替库脚本。底层/验收在最后交接阶段触发usage limit，总协调接手执行，未伪造独立终审。

Mac地址从108变100，根协调发现后以旧主机密钥别名严格验证并重新登录，未要求用户改网络。旧已编译C客户端已在core-api-v1-baseline保留。

Mac构建、CTest2/2、Python42/42零跳过、冻结头C消费者、旧binary只换新库、60秒三路加速dry-run通过。进一步实际两台60秒发送正常，队列峰值704/1408帧（上限1408），每路2646000帧且消费哈希等于native输出；同一进程两次3秒自然结束后重启也完成，补丁恢复，异步任务无遗留。

根协调已复核35源文件、dyld实际加载新库、旧binary不变、逐路帧数/哈希/峰值及清理。证据见reports/M2-macos及M2执行报告。独立终审待额度恢复补齐；未录音、未测小时级漂移或真实中途停止/拔电恢复。UI继续暂缓。

下次从TASKS的T016/T017和docs/api/v1恢复。M1旧有限路径仍保留；新stream输入为有限长但按需读取，不是Mac系统捕获或无限输入。后续任何改动保持v1接口和语义，跑兼容门禁。

## 2026-11-05：核心库优先阶段启动

用户明确要求优先保证核心库。总协调将执行范围调整为 M0 可运行无界面核心基础 → M1 真正 AirPlay 集成 → M2 持续流与恢复。UI、应用产品层暂缓。

当前专业任务：

- architect：公共头文件、接口契约与架构审核。
- core_dev：共享核心实现、构建、无声离线例子。
- qa：独立测试、契约边界和证据。

本轮权威范围见 PRODUCT；既有源码哈希见 baselines/M0-original-source.json。共享工作目录按明确文件责任隔离，历史原型不改动。

Windows PATH 暂无 CMake/C++ 编译器；Mac 已有 Xcode clang++21 和 Homebrew CMake。拟在 Mac 独立验证目录构建，不改全局工具路径，不自动播放音频。

结果：M0 组合验证完成并经 QA 独立复核，可进入 M1。

- 公共接口：core/include/flow/core.hpp；实现：core/src/core.cpp；交付无第三方依赖 C++17 静态库、CMake工程和无声离线例子。
- 在 Mac `/Users/lvzhipeng/Developer/HomePodSpatialRouter/core-m0-validation` 独立目录，使用 AppleClang 21 和 CMake 3.27.8 完成 configure/build。
- CTest 1/1 测试程序通过；该程序包含 21/21 组独立离线行为测试，直接执行也通过。离线例子三路样本内容不同、presentation一致，并演示队列满时全组停止。
- 验收 Agent 复核原始日志、9个源文件哈希及 Windows 原型保护3项检查，无阻断缺陷。
- 源码清单：baselines/M0-core-source.json；日志和验收报告：reports/M0-macos-validation.log、reports/M0-core-acceptance-2026-11-05.md。

范围限制：本轮仅验证模拟输出下的路由、时间计划和生命周期。真实 AirPlay 适配、声学误差、漂移/恢复、Windows/Linux原生构建、稳定 C ABI尚未通过。下一步T012先明确协议桥接和时间映射，再实现M1。当前三个专业 Agent 已结束本轮任务，恢复时根据 TASKS 重新调度。

## 2026-11-05：M1 软件桥接交付

按用户“继续”指令重新调度架构、底层和独立验收。新增版本化 C ABI、Python ctypes绑定、有限PCM输入的真实native路由、自定义pyatv AudioSource，以及显式scan/dry-run/play命令。真实发送按所有会话就绪后确定共同时间线，扣除协议latency映射到发送起点，包含过期拒绝、ALAC、尾padding检查和失败清理。

组合验证在 Mac core-m1-validation 下执行：

- 动态库/静态库/C消费者构建成功；CTest2/2（包含原21组核心行为）通过。
- 实际native库参与Python32项测试，全通过、零跳过。
- CLI真实执行1秒dry-run，三路各44100帧；输出内容哈希不同，源消费哈希逐路匹配。
- QA另在Windows执行原型保护3/3；两平台共35项Python检查，不能误写Mac35项。
- 27个源文件和回传manifest、当前工作区一致；证据见 reports/M1-macos 和 baselines/M1-core-source.json。
- 发现并修复：Python失败构造析构异常、不同ID绑定同一Python输出、异步close异常被误报清理成功。QA已复测。

独立结论：仅M1软件桥接离线Pass。未播放音箱；Mac Python对前方104和小白115连接errno65，路由查询却存在en0路由；原因尚未证实，需检查本地网络权限/网络状态。Windows发现这两台，未发现小黑。已向用户请求确认设备通电和Mac授权；具体事实见网络预检JSON。

下一步恢复T008真机测试，之后录音定量和长时同步。UI、持续实时流、自动恢复和其他平台原生构建不在本轮已通过范围。

## 2026-11-05：两设备真实链路和短时听感验证

用户说明黑mini暂时断电，明确要求先测试两台。Mac Python对192.168.0.104和192.168.0.115的TCP7000连接均已恢复可达；未确认此前errno65的具体原因，不推断权限已由谁修改。

使用已验证的M1源码/动态库和新CLI实际执行两轮，未调用旧sync_probe：

| 轮次 | 内容/设备 | 音量/时长 | 发送结果 |
|---|---|---|---|
| A | 前方客厅440Hz、小白660Hz，各自双声道复制自己的音调 | 15%，3秒 | native_core_used=true，prepared=2，各132300帧，共同起点、不同PCM哈希，cleanup=true |
| B | 相同设备与路由；用户明确要求最大音量再测10秒 | 100%，10秒 | native_core_used=true，prepared=2，各441000帧，共同起点、不同PCM哈希，cleanup=true |

两轮均为sender_completed_unverified_acoustically，表示原生路由、发送、全帧消费和尾padding检查正常。报告中发送协程释放的时间差不代表实际出声误差，不将其用于声学结论。

用户对轮次B明确反馈：“两台都响，听起来基本同步”。据此可以确认本轮新核心链路的两台实际出声与短时主观同步初筛通过；量化声学标记仍为false，未录音、未测长期漂移，也未验证当前三台组合。

证据：reports/M1-two-device 下保存两轮原始JSON、元数据、源码manifest。27个部署文件与M1基线一致；元数据保存本次动态库SHA-256。CLI控制台仅输出JSON，未启用独立debug日志。最初证据元数据脚本误用系统Python导致依赖版本查询失败，改用项目venv后成功保存；两轮实际播放始终使用正确的venv，与此元数据错误无关。

验收Agent已完成独立复核，报告为 reports/M1-two-device-acceptance-2026-11-05.md；两设备短时初筛通过。尾padding的通过依据是代码成功路径检查及包数一致性，原始报告没有逐路最终padding计数，不将其描述为新增遥测。停止后未再触发播放。下一步应开展两设备重复启停/较长播放及可行的录音测量，黑mini恢复供电后补三台；产品UI继续暂缓。现有桥接有限30秒，长期测试需先扩展持续流能力。

## 2026-11-05：用户UI交接后的原生演示切片

按新授权并行完成架构评审、SwiftUI视图和App状态壳；核心35文件SHA不变。Debug clean build/最终增量build、Release构建、Swift状态自测运行通过，首轮SceneBuilder与Observation递归问题均已修复。9场景18缓存快照有采集限制，完整视觉和真实手势待验，不标整体验收。详见reports/UI-integration-2026-11-05.md及独立UI-qa-review；架构恢复入口APP_ARCHITECTURE.md。真实音频服务未接UI，不自动连接或播放。

## 2026-11-05：0.2受管文件服务

T018执行及独立终审通过：两平台各30协议检查，Swift状态/真实Pipe测试，Store→Python→native三路影院不同内容和同步相同内容各44100帧，真实native在4224/2646000帧中途stop及EOF清理通过。63源/包SHA核对一致，35M2保护文件未改；Mac已部署runtime和0.2 Release，无自动播放。未计scan/airplay/真实UI点击/Tap/声学为通过。证据见reports/T018-integration-2026-11-05.md和T018-worker-qa。用户选择Core Audio Process Tap兜底，当前独立平台库开发，不变更已有WAV worker或核心v1。

## 2026-11-05：Process Tap兜底平台首切片

独立包platforms/macos/ProcessTapCapture已完成Mac编译、15项mock/PCM运行、默认/help不采集及Release探针打包/签名验证；12源和zip SHA一致。仅公开API、显式录制、真实格式/时钟、有限缓冲及逆序清理，不修改核心v1或0.2文件worker。本轮未实际授权/录制/连接live，见reports/ProcessTap-integration-2026-11-05.md；后续T022真实采集、T021实时桥。
