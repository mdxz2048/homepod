# 固定安装 App 非零系统采集：独立 QA

日期：2026-11-06。结论：**基本非零采集链与本轮正常停止初筛通过**。不是正式 V1 通过，不扩大到音箱传输、影院、声学或长时稳定性。

## 已审核原始证据

已读取 T021-macos/capture-installed-1 的 capture.json、capture.stderr、exit-code.txt，并对照 System-capture-fixed-install-2026-11-06.md。JSON 报告：284块、133593帧，168017个非零样本，peak=0.010165544226765633，RMS=0.0013742015977597291，errors=[]，capture_verified=true；stderr为空，检查进程退出码0。报告记录本机测试声音2次；用户回复“应该已经可以了”为辅助听感，不替代数值证据。

输入源实际48000Hz/双声道，输出帧按44100Hz计约3.02932秒。首尾 sourceSequence 为0/283，sourceFrameStart 为0/144896，末块512帧，合计145408源帧，与源采样率换算后的输出长度基本一致。首尾 sampleTime 差对应3.018666667秒；mach ticks 结合125/3时间基换算为3.018680708秒，两者差约0.014ms。首尾 timestamp flags/nowFlags 均为7，droppedBlocksBefore均为0。该摘要与正常连续采集相容，但仅有首尾元数据，不能独立重放逐块连续性检查。

capture_cleanup_complete、capture_host_exited、input_closed均为true；capture_last_error与capture_error_code为空。正常 HPCM 停止和进程退出的报告支持本轮清理通过；没有独立系统资源快照，不能进一步断言所有内核对象已逐一外部查证。

排除策略明确：PID24408为已解析排除对象，24406/24407未注册且受监控；policy为注册/身份/object变化即fail-stop。converter_delay_known=false、drain_complete=false、capture_permission=not_inferred、acoustic_sync_verified=false均保留，未伪报权限查询、转换排空或声学结论。

证据 SHA256：

| 文件 | SHA256 |
|---|---|
| capture.json | fc49973820222cc9dad6ef98cc526317a6e480a8e2ee88d6482e541bfe708f67 |
| capture.stderr（0字节） | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 |
| exit-code.txt | 9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa |

GUI归属/固定安装路径及本机Glass两次来源于协调执行记录；上述三个文件本身不含完整源码/安装包manifest或TCC责任链日志，因此不独立证明正式包身份、可重现安装和权限面板状态。本轮可确认从“仅全零帧”推进到了实际非零PCM证据。

## 新会话控制静态审查

只读检查 SystemSessionRecovery、SystemAudioStore、SystemAudioEnvironmentController、SystemRouterService、AppState、FlowApplicationDelegate及静默 SystemSessionChecks。符合的边界：desiredEnabled不持久化；自动恢复仅允许结构化瞬态错误且肯定清理、稳定身份完整；每次fresh scan、唯一stable ID解析、新会话UUID；Stop/quit同步撤销意图；旧generation/session事件不覆盖新会话；未知进程退出锁住清理，权限/内部错误不自动重试；退出等待有界受管服务关闭。

发现一项待 owner 修复：AppState 在 beginPlaybackPreparation 后的连接/扫描/解析失败 guard 返回未收回同一准备意图，可能留下 desiredEnabled=true，导致布局/模式/音量锁住及菜单请求态残留。已通知 app_dev：仅收回仍匹配且没有活动会话的失败 preparation，不能取消后续新意图；补失败后可编辑/重试检查。

本机未运行 Swift 编译或静默测试；上述为静态审查，不签署新代码构建通过。影院仍同声退化、运行中音量仍锁定、偏移实际生效、自包含安装、本机重复出声控制、长时/故障真机恢复均未由本轮证据通过。
