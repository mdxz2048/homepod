# HomePod Flow

Mac采集兜底：[独立Core Audio Process Tap模块](platforms/macos/ProcessTapCapture/README.md)已通过Mac编译和15项mock/PCM测试、探针打包；[执行记录](docs/collaboration/reports/ProcessTap-integration-2026-11-05.md)明确本轮没有真实录制、尚未接live发送。[整体进度](docs/collaboration/PROGRESS.md)按模块列出证据和缺口。

0.2.0进展：[受管文件服务](docs/collaboration/reports/T018-integration-2026-11-05.md)已通过Swift→Python→真实核心离线两模式、native中途stop/EOF、Mac/Windows各30项协议检查及Debug/Release构建。通用设置新增显式文件测试入口，主菜单仍明确演示；本轮未实际播放音箱。用户指定下一步以Core Audio Process Tap作Mac采集兜底，实时发送桥单独接入。

原生界面首版：[macOS工程](apps/macos/README.md)已通过Debug/Release构建和状态逻辑运行，当前明确为演示，不接管声音。[App架构](docs/collaboration/APP_ARCHITECTURE.md)保持核心/适配器独立；[整合记录](docs/collaboration/reports/UI-integration-2026-11-05.md)区分已通过检查与待补视觉/实际交互。

最新：[核心接口v1已冻结](docs/api/v1/README.md)，后续内部调试保持九个C符号、错误码、回调/生命周期及时间语义。旧已编译C客户端直接加载新库通过；[有界持续流](docs/collaboration/tasks/T016-bounded-stream.md)通过42项Python测试、60秒两台实际发送及同进程两次自然结束后重启。[M2报告](docs/collaboration/reports/M2-stream-acceptance-2026-11-05.md)保存证据；独立终审因Agent额度待补，不等于声学量化/长期稳定已通过。

已跑通：真实 5.1 声道分配、三台独立 HomePod 播放不同内容，以及短时听感基本同步。实际出声误差、长期漂移和 Mac 实时音频接入尚未验收。

跨平台核心库开发已启动：[M0 核心基础](core/README.md)在 Mac 构建成功，21组独立离线行为测试通过。M0证据仅涵盖离线行为；后续M1进展见下，不能与上面的Python真机原型混为同一条已验收链路。核心公开接口保持冻结；用户提供新版UI后，现已并行启动菜单栏SwiftUI界面与App壳开发。

后续进展：[M1 发送适配](adapters/airplay_pyatv/README.md)已实现 C ABI→Python→native路由→pyatv音频源/发送桥接。Mac构建、原生2个测试程序、32项Python测试及三路离线运行通过。网络恢复后，新核心已实际驱动前方HomePod与小白播放不同内容；用户确认10秒测试“两台都响，听起来基本同步”，[两设备独立验收](docs/collaboration/reports/M1-two-device-acceptance-2026-11-05.md)初筛通过。小黑由用户暂时断电；三台、录音量化与长期稳定尚未验证。

## 完整文档

[实现方案与测试记录（2026-11-04）](docs/HomePod_Spatial_Router_实现方案与测试记录_2026-11-04.md)

[MacBook 开发环境与安装验证（2026-11-05）](docs/MacBook开发环境_2026-11-05.md)：已安装完整 Xcode 26.6 及音频开发依赖，并通过 SwiftUI App 编译／签名检查。

[产品架构与自动化方案（2026-11-05）](docs/产品架构与自动化方案_2026-11-05.md)：模块划分、首次设置和日常自动化、同步恢复、音画边界及分阶段验收建议。

[跨平台模块与接口设计（2026-11-05）](docs/跨平台模块与接口设计_2026-11-05.md)：共享核心库、平台适配器、播放与同步边界、数据契约及原型迁移顺序。

[多 Agent 协作工作流](docs/collaboration/README.md)：架构、底层与验收已完成首轮 M0 交付，包含任务状态、接口和恢复入口。

文档包含架构、ALAC 传输、共同播放时间线、声道分配公式、测试结果、失败尝试、录音分析状态、复现命令、需求覆盖与后续验收。

[固定证据与环境索引](docs/evidence/2026-11-04/index.json)保存 11 份报告快照、依赖版本、代码散列和录音索引。对应代码快照位于 `docs/evidence/2026-11-04/source/`。

[早期实验笔记](docs/早期实验笔记_2026-11-04.md)保留阶段性历史，当前结论以完整文档为准。

## 当前设备映射

| 角色 | 设备 | 测试时 IP |
|---|---|---|
| 前方 | 客厅 HomePod 二代 | 192.168.0.104 |
| 左后 | 小黑 HomePod mini | 192.168.0.113 |
| 右后 | 小白 HomePod mini | 192.168.0.111 |

两台 mini 当前独立连接。原生立体声对路线尚未通过验证。

## 快速复现

在项目根目录运行，音箱 IP 变化时需修改参数。下列命令会实际出声：

```powershell
.venv/Scripts/python.exe sync_probe.py --scan
.venv/Scripts/python.exe prepare_sync_pulses.py
.venv/Scripts/python.exe sync_probe.py --front 192.168.0.104 --rear-left 192.168.0.113 --rear-right 192.168.0.111 --bundle artifacts/sync15 --volume 50
```

默认使用已确认出声的 ALAC 格式。原型使用预生成音轨，尚未实现产品级暂停续播、跳转和断线同步恢复。音频素材仍存于 `artifacts/`，运行报告会写到 `artifacts/last_run.json`；该文件会被后续测试覆盖。
