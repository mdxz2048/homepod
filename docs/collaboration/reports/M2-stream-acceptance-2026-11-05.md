# M2 连续流与接口兼容独立验收

日期：2026-11-05。状态：执行验证Pass，独立终审待补。底层/验收Agent在实现与用例完成后触发额度限制，由总协调接手Mac构建、测试和原始证据核对；不视作独立验收已签字。

## 冻结接口

权威快照 docs/api/v1/bridge.h、core.hpp、manifest.json。验收工具 test_api_freeze.py 将原有固定哈希与快照/live对比，并检查固定错误码、声明和实际动态库九符号/版本。Windows已实际执行两个无需动态库的检查，2/2 Pass。

根协调已保存 M1 旧原生 C 客户端，SHA-256：`9d677488a19f76fb84238985fa726f3e9328838ff5ea6feb5aae58bd69c47aef`。check_binary_compatibility.py 检查旧binary不变，以 DYLD_LIBRARY_PATH 替换库，并必须在 DYLD_PRINT_LIBRARIES 的实际加载日志中看到新库绝对路径；没有加载证据不能算二进制兼容通过。另安排冻结头编译新C调用方，作为源码兼容的不同证据。

## 连续流范围

验证按需逐块读取源、真实 native submit、全路有限缓冲与逐路消费。不接受将多个短play拼接，或把全部输入/分路输出预加载后称作连续流。加速的60秒以上逻辑流仅证明媒体时间/内存和生命周期，不证明真实60秒以上音箱稳定或量化同步。

已交付 tests/test_streaming.py 七项，等待真实动态库执行：

- 61 秒、44100 Hz 媒体流加速消费，分别按127/509帧异速读取，真实 Engine.submit 的spy只观察后调用native，检查epoch/严格连续first_frame；不保存全部输出。
- 每路 native/consumed PCM 哈希相等且两路不同，presentation 使用共同origin加绝对帧时间；各路resident queue峰值不超过1056帧（352x3），输入单次读取不超过352帧。
- 开始不预读、暂空不误报EOF，读完整个媒体源后才EOF。
- 慢消费者超时fail-stop并关闭组，主动stop唤醒等待者，输入读取故障、迟到、取消均清理并不误报同步。

队列峰值只指队列常驻PCM，不把它说成整个进程内存上限；读取结果缓冲另有单次65536帧上限，原生路由存在逐块临时复制。保持原M0/M1契约门禁。加上API冻结三项，unittest discover预计42项，原型保护另3项。

## 未验证项目

真机与真实时钟证据由总协调安排；验收 Agent 不自行播放。现有两台短时听感初筛不替代本轮流式链路和长时声学验收。三台、录音定量、漂移、断线恢复、Mac捕获/UI均不能在本轮离线结果之前或之外宣称通过。

## 实际执行证据（总协调补充）

证据位于[M2-macos](M2-macos/)，源包清单为 `baselines/M2-core-source.json`，35文件与部署及当前工作区一致，公开头未修改。Mac由108变100，使用旧主机密钥别名严格校验后恢复连接。

| 检查 | 结果与证据 |
|---|---|
| Mac构建/CTest | 2/2通过，含M0 21组与C消费者；validation.log |
| Python全套 | 42/42，零跳过，约5.295秒；validation.log |
| Windows原型保护 | 3/3，约0.279秒，由协调使用现有venv执行 |
| 冻结头C消费者 | 来自docs/api/v1的头编译、链接、运行通过 |
| 旧客户端替库 | binary_recompiled=false，SHA保持9d6774...47aef；dyld证明加载M2新库，returncode=0；binary-compatibility.json |
| 60秒三路加速dry-run | 各2646000帧、7518次native提交、每次输入最多352帧、队列峰值1408帧；stream-dry-run.json |
| 60秒两台实际发送 | sender完成；各2646000帧，7518次native提交，内容不同且逐路消费哈希一致；two-device-stream-60s.json |
| 真机缓冲/结束 | 上限1408帧，峰值704/1408帧；结束队列0，input_eof/input_closed/hub_stopped及cleanup正常，无group_failed |
| 同进程两次3秒重启 | 每次各132300帧/路、补丁恢复、清理正常、remaining_async_tasks=[]；restart-summary.json及逐轮JSON |

真机音量15%，前方104为440Hz，小白115为660Hz。小黑按用户说明断电，未测第三台。首帧presentation一致、send origin扣除1.5秒协议延迟，均为计划而非声学误差。

本轮一分钟听感反馈已请求但尚未收到；此前用户“响了，同步的”属于M1短时证据。没有录音量化、小时级漂移、RSS/泄漏测试，不把队列上限说成整个进程固定内存；自然EOF后的重启不能代替真实中途取消/拔电恢复。

结论：冻结接口、逐块有界持续流及以上执行检查通过。独立终审待补；下一步补实际中途停止/恢复、录音量化和更长时稳定性，不宣布全部核心需求通过。
