# T014：M1 原生桥接独立验收

日期：2026-11-05。负责人：独立验收 Agent。状态：Verified（软件桥接离线切片）；真机、声学同步与长期稳定待外部条件，不代表整个 M1 通过。

范围：版本化 C ABI -> ctypes -> 真实 C++ 路由 -> 自定义 pyatv AudioSource -> 定时发送桥接。旧 sync_probe.py 单独成功不能作为新核心接通证据。

交付入口：tests/bridge_c_contract.c（C 语言调用真实动态库）；后续 Python 跨语言和实际桥接离线测试；reports/M1-* 独立报告。保留 M0 21 组测试和原型保护检查。

验收重点：

- ABI 版本、固定宽度类型、null/状态、所有权、回调失败和销毁清理。
- 不同内容确实由 C++ 路由，AudioSource 消费其输出，不允许旁路复制原始声道冒充。
- mono 时间锚点、NTP、latency、RTP 映射，迟到拒绝，格式/latency 不同拒绝。
- 全路准备后才释放；取消/超时/异常恢复 monkey patch 并关闭全部资源。
- 导入/离线检查不得触发发现、连接、音箱播放。真实播放仅由总协调安排，验收 Agent 不自行播放。

pyatv 0.18.0 源码审计结论：rtptime=head_ts-start_ts+latency；首个音频 RTP 为 latency，sync packet 将 RTP0 绑定 head_ts 的 NTP。因此 core origin 表示预计呈现时，发送原点须为 core_origin-latency/sample_rate，不能直接把 core_origin 当 start_ts 后再叠加 1.5 秒。

离线通过不代表实际声学同步；未完成录音测量时同步误差、长期漂移继续 Not Tested。
