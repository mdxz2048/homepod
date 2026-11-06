# DeepSeek 执行与总调度

2026-11-06 用户要求：本聊天负责方向、拆解、阶段调度、审查与收敛；主要实现交给百炼 DeepSeek，减少总调度上下文和 token 消耗。

## 已配置入口

- 桌面「ChatGPT 百炼版」实际位于 `%LOCALAPPDATA%/OpenAI/ChatGPT-Bailian`；System32 只是 wscript 启动器位置。
- 项目调度脚本：`tools/Invoke-DeepSeekWorker.ps1`，调用百炼版自己的 `codex.exe exec`，使用其独立 CODEX_HOME 和现有 DPAPI 加密凭据。不得记录密钥或把凭据复制进仓库。
- 默认选择账户实时模型列表中可用的旗舰 Pro 固定版本 `deepseek-v4-pro-0813`，reasoning effort=high。账户同时列有较新的 Flash 型号；Pro 是按旗舰档选择，并非已完成不同型号的实测性能排名。不得静默回退到 OpenAI 模型或其他型号。
- 仅覆盖本次 worker 参数，不修改百炼桌面的全局默认模型。当前聊天模型与百炼 worker 是不同执行进程。

## 派工与验收

1. 总调度先写清任务、允许修改的文件、接口约束、验收证据和停止条件。只传递相关文件路径及简短现状，不复制完整聊天历史。
2. worker 默认只读；确需改动时显式使用 workspace-write。并行前划分互不重叠文件；同一模块默认串行。
3. 原始输出写入已忽略的 artifacts/deepseek，worker 只回传短报告。调度先看结果摘要、diff 和必要证据，不反复读取全部日志。
4. Mac 系统安装、音频设备切换、出声、远端操作和最终集成由总调度统一执行。worker 不自行接触凭据、部署、提交或继续派生其他模型。
5. 软件测试、真实采集、端点播放和声学测量分别验收。冻结 C ABI v1 保持不变；失败最多进行一次有依据的修正后重新评估，不循环重试消耗额度。
6. 首任务为 DEEPSEEK-001-audit，只读核对 mono 缺口和后续多声道切片。结果经总调度审查后，再派实现任务。

首次调用已经成功，模型/工具执行通过。后续 shell 输出限制 2000 tokens，并要求 worker 使用 rg 定位和小窗口读取，避免整文件输出。worker 的结论只是待审结果：首次报告称“修改 >=2 为 >=1 即端到端打通”，总调度未接受；这只解除一处格式门禁，产品 HPCM 输出、worker 接入及真机数据仍未验收。下一实现切片应覆盖可独立验证的 1ch 采集格式支持，之后再推进 HPCM v2 生产与真实 worker 路由。

002/003/004/005 阶段已执行；最终证据见 `reports/VirtualAudio-2026-11-06/Multichannel-transport-stage.md`。worker 自述和单元测试不能代替独立集成门禁。现有脚本默认由 `run_bounded_worker.py` 限制 480 秒和 14 次 shell 调用（不计 patch 调用，不是精确 token 限额）；超限终止专属进程树、保留日志，部分文件必须重新审查。必要时可为事先明确的大任务显式调整参数。

示例（在仓库根目录运行）：

```powershell
./tools/Invoke-DeepSeekWorker.ps1 -TaskFile ./docs/collaboration/tasks/DEEPSEEK-001-audit.md -ResultFile ./artifacts/deepseek/001-audit.md
```
