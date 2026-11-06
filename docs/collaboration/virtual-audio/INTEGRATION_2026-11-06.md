# 虚拟音频 MVP 第一轮集成记录

日期：2026-11-06。协调执行；不是完整产品发布或自动音画同步验收。

## 备份与协作

GitHub main 已核对为4331d3b92cc2330e58dcf28ab50ffd4b7d6d283d，与本地main一致。后续开发位于codex/virtual-audio-mvp。首次推送凭据管理器等待用户认证，认证后完成；仓库本地后续采用Windows证书存储并开启TLS校验，不沿用失效CA路径/禁用验证配置。

virtual_architect负责契约与VirtualAudioInput；virtual_driver负责独立驱动；virtual_qa负责独立静态复核及工具；root统一Mac执行。冻结核心35文件保持原始SHA一致。

## 当前已执行的 Mac 检查

- 驱动第一候选编译失败，已保留日志。SDK host指针、函数名Size冲突、缺AudioHardware头、device/stream latency同fourcc等问题由底层修正。
- 第二候选native检查、stage构建、plist/codesign通过。第三候选补充mockHost、NaN/Inf格式校验及路径保护后再次检查：path-checks PASS、C检查PASS、stage退出0、plist/codesign通过。第三源码SHA b9f077536d3d3c7c9780e977dbd1be532c7ba8048f35b4ac42fa45dacf94c610。
- 输入第一候选Swift编译两处SDK导入/类型错误，修正后第二候选swift test退出0，13 XCTest通过。默认CLI帮助退出0；未安装时显式--discover退出1并输出driver_unavailable，为正确事实。
- QA工具Windows及Mac各6项静默测试通过；Mac显式FFmpeg生成11秒HTMLMedia MP4成功。未播放/录制；编码后flash/pulse实际时刻基准校准尚未完成，不能把素材生成成功称音画测量通过。
- 现有processing独立库另补MacRelease CTest1/1与Python真实绑定4/4，不等于产品影院接入。

## 安装：用户明确授权“直接安装”

已先记录默认输出为用户选择的原生AirPlay UID，退出HomePod Flow。核对目标 `/Library/Audio/Plug-Ins/HAL/HomePodFlowAudio.driver` 解析为该精确路径且不存在旧同名bundle后，复制已审查stage产物，设置root:wheel归属并移除group/other写权限。安装后codesign严格验证通过。没有覆盖其他HAL插件，没有把虚拟设备设为默认。

文件安装后立即discover仍driver_unavailable。尝试一次受控launchctl重载音频服务，系统拒绝：`Operation not permitted while System Integrity Protection is engaged`。未关闭SIP、未改安全策略，也未改用kill绕过保护。已请用户保存工作后重启，随后SSH实际收到系统shutdown消息，确认Mac开始重启。

状态：等待重启后的真实枚举/属性/AudioUnit/Tap检查。没有将安装文件到位标作已加载或已接通HomePod。

## 仍未实现或未验收

driver真实HAL加载/生命周期、device/stream Tap实际PCM、源render时间映射、浏览器实际采用和最终声学音画偏差均待测。独立恢复helper、跨进程journal事务和真实默认输出writer尚缺，默认接管门禁保留；不能让App退出后系统落入静音设备。多声道仍未实现，不宣称8slot等于7.1。

当前用户App与签名未修改，保留此前系统Tap同步/动态音量能力。本阶段驱动与输入包是新增模块，没有改冻结核心ABI。
