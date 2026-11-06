# T018：受管音频服务与文件播放入口

用户2026-11-05要求继续按总协调节奏开发。目标是连接App与现有正式核心链路，避免把音频协议或Python私有补丁运行在SwiftUI进程中。

- architect独占WORKER_PROTOCOL_V1.md：JSONL契约和能力边界。
- core_dev独占adapters/worker及tests/test_worker_protocol.py：复用已有streaming适配器，不改M2保护文件。
- app_dev独占App中非Views/Style文件：Foundation Process服务、状态、配置与测试。
- 总协调负责小型设置入口、Mac部署、编译和真实核心离线端到端检查。
- 架构交付后由qa占空闲槽，独立审计关联ID/会话隔离、取消、异常退出和测试证据。

本轮不自动音箱播放，不捕获系统/麦克风。不改核心v1 ABI；hello/inspect/scan及显式start/stop/shutdown为App内部进程协议。采样/声道检查、播放状态与声学出声证据分开。运行环境由部署器写本机Application Support配置；用户日常仅选择文件与输出。

验收：Python协议测试、Mac Swift状态与真实Process测试、App构建、实际native库参与WAV inspect/offline start、停止/EOF/失败回传。AirPlay可用入口必须要求显式选择设备与动作；未出声验收单列，不用离线结果替代真机。
