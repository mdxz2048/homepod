# 系统音频到两台 HomePod：独立 QA 初筛

日期：2026-11-06。结论：**route-real-3 两轮10秒真实系统输入→核心→两台音箱的发送、重复启动和正常停止初筛通过；用户确认两台同步响过且已停止。**这是短时主观同步初筛，不是毫秒量化、正式版、三台、影院或原生5.1验收。

## 原始证据审核

已读取 T021-macos/route-real-2 与 route-real-3 的 route.json、route.stderr、exit-code.txt，并独立计算会话/时间/队列边界。两目录 stderr 均为空。

| 检查 | real-2 第1轮 | real-3 第1轮 | real-3 第2轮 |
|---|---:|---:|---:|
| 请求运行秒数 | 30 | 10 | 10 |
| native_submitted_frames | 1324057 | 442057 | 442176 |
| 两路 consumed_frames | 1323872 / 1323520 | 441760 / 441408 | 442112 / 441760 |
| audio_packets / nonzero_packets | 7521 / 3530 | 2509 / 1264 | 2511 / 1331 |
| 输入峰值 / 容量（帧） | 23050 / 88200 | 22580 / 88200 | 22580 / 88200 |
| 两路输出峰值 / 容量（帧） | 1293,1293 / 1408 | 1059,1293 / 1408 | 823,1293 / 1408 |
| stop请求→确认（秒） | 0.882664 | 0.864577 | 0.899712 |

上述三轮均 native_core_used=true、prepared_receivers=2、group_failed=false、共同 start_ts 与输出 first_presentation 相符；各路首 RTP 为66150，对应44100Hz的1.5秒协议 latency。send_origin=首次PCM接收+0.5秒，playback_origin=send_origin+1.5秒。两路 native PCM hash 相同，符合本次同步同声模式；不构成影院不同内容证据。

显式停止会截断尚未发送/消费的尾部，所以 native hash 与各路 consumed hash 不同、两路最终消费计数相差352帧，不能要求它们在停止瞬间相等；这些摘要计数也不能反推实际声学偏差。报告不宣称converter排空，drain_complete=false保留。

real-3 两轮 session 分别 b9b53dac-515f-4c93-b1a3-fd6123e4f69a 与 fe4ccb36-d85c-4385-9f3e-2b1f62ad7eee，native报告session均匹配，捕获session与capture host PID也更新。两轮终态与stop回包均 stopped/cleanup_complete=true，报告 input_closed/hub_stopped/capture_cleanup_complete/capture_host_exited均true，无capture错误。外层 errors=[]、worker_exit_code=0、进程exit-code=0，支持重复完整启停通过。

内层报告 status=failed、error_type=CancelledError是当前 play_system_audio 对显式取消仍写 failed 的实现语义；外层worker在确认用户stop及清理后返回 stopped。不能据此隐藏真正错误，也不应把这一内层字段单独算成播放故障。此状态命名存在诊断歧义，正式版应区分预期停止与异常。

## 必须保留的失败与限制

real-2 整次检查退出1：第1轮30秒正常结束，第2轮新会话 4ed1315b-f404-48c1-b482-c89db05e378d 在启动阶段收到 operation_failed / ProtocolError，cleanup_complete=true；未进入该轮streaming，未保存异常详细原因。该失败仍存在于证据，不能因后来两轮成功宣称已定位或修复根因。real-3仅补充error_detail/report观测后重试成功，属于后续成功证据，不证明错误已根除。

用户对 real-3 明确回复“两台同步响过，现在已停止”，可作为真实出声与短时主观同步初筛。没有录音量化，acoustic_sync_verified=false正确保留。未验证三台、影院不同内容、原生多声道、30分钟漂移、故障自动恢复、运行中音量/偏移、本机静音恢复、自包含发布包。

根协调转述新 StateChecks、SystemSessionChecks、Debug构建与17项live检查通过，本报告未取得相应新原始日志，不额外独立签署其构建/测试结论。本轮未SSH、采集或播放。

## 证据哈希

| 文件 | SHA256 |
|---|---|
| route-real-2/route.json | 6f6d08cdd7293f31476cccf2cd7938951de3b4929bca3c652f664e9480f2f8c0 |
| route-real-3/route.json | 529813f244caf1f99a3b7922c81b3650b7a3365bea6fb5c1c19fb66de516beee |
| real-2/exit-code.txt（1） | 4355a46b19d348dc2f57c046f8ef63d4538ebb936000f3c9ee954a27460dd865 |
| real-3/exit-code.txt（0） | 9a271f2a916b0b6ee6cecb2426f0b3206ef074578be55d9bc94f6f3fe3ab86aa |
| 两份空 route.stderr | e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 |
