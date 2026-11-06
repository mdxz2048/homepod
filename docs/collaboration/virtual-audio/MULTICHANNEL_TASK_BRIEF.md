# 多声道阶段任务简报

日期：2026-11-06。总协调写给 architect / driver / QA 的共享边界。用户要求“一开始就把 5.1/7.1 功能做全，这一步要验证好”；本简报只定义任务与不可越过的边界，最终接口以 architect 产出的多声道契约为准。

## 已确认的当前事实

- 立体声虚拟设备 `com.homepodflow.virtual-audio.stereo.v1` 已在目标 Mac 枚举成功；AudioUnit 可初始化。
- `hfla`/`hflr` 已改为 `CFPropertyList`/`CFNumber`，真机可读写；revision 单调；两个 scope 的 stream latency 同步。
- `virtual-audio-input --discover` 真机退出 0。
- TCC 授权 GUI 进程的 device Tap 已取得非零、左右独立 PCM；产品 Input 尚未接入。
- `kAudioDevicePropertyBufferFrameSize` 由 coreaudiod 管理（15..4096），驱动不能宣称固定 512。
- 当前只有两台可用 HomePod（客厅、小白）；真正 5.1 声学回放至少需要 6 个可独立分配的输出端点或等效多声道端点。小黑是否在线、是否能长期供电未确认。

## 源优先目标（用户澄清后的正式方向）

虚拟声卡是**输入能力层**：尽可能多地接受不同源布局，并把源声道原样交给 Flow。Flow App 再根据“源布局 + 实际音箱布局/数量”决定直通、路由、downmix 或显式上混。不能把虚拟声卡做成“只支持 5.1”或“捕获时就偷偷降混”的固定管线。

当前基线：Flow 输入只有 HPCM v1 stereo，虚拟设备也只有 2ch；这两处都要扩展。

源布局目标矩阵（architect 需冻结首轮真实/预留范围）：

| 源布局 | 通道 | 首轮目标 |
|---|---|---|
| mono | 1 | 支持（明确路由/复制策略，不冒充立体声） |
| stereo | 2 | 支持，现有基线 |
| 3.0 / 4.0 | 3/4 | 支持或明确预留 |
| 5.1 side / 5.1 back | 6 | 支持，side/back 必须区分 |
| 7.1 | 8 | 支持 |
| 5.1.2 / 7.1.2 / 7.1.4 | 8/10/12 | 条件允许预留 height，首轮可标未实现 |
| unknown | 任意 | 拒绝猜测，报 `unsupported_layout` |

虚拟设备方向：优先设计**设备家族**（2ch / 6ch / 8ch，条件允许 height 设备）或可配置 N-channel 设备，让播放器能把不同源布局原样输出；不要只做一个固定 5.1 设备。

## 立体声源进入 5.1/7.1 时的策略（只是矩阵中的一个 fallback case）

必须把“源布局”和“捕获容器布局”分开记录：

- `decoderReportedFormat`/`sourceLayout`：播放器/解码器报告的源布局，可能为 stereo、5.1(side/back)、7.1 或 unknown。
- `capturedFormat`/`containerLayout`：虚拟设备/tap 实际给出的通道数与标签。
- 不能因为容器有 6/8 个 slot 就宣称源是 5.1/7.1；不能靠“其余通道静音”自动推断源布局。

推荐默认策略（源优先原则下）：

1. **stereo 源 → 6/8ch 容器**：默认 passthrough，只把 L/R 放到 FL/FR，其余通道保持静音；`provenance=stereo_passthrough_in_multichannel`，`transformations=["stereo_passthrough"]`。不称原生 5.1/7.1。
2. **显式影院上混模式**（用户可选，默认关闭）：使用有文档、可测的矩阵生成 FC/SL/SR/LFE，标记 `transformations=["stereo_upmix_v1"]`；不能冒充 Dolby/DTS 或原生多声道。
3. **5.1 源 → 6ch 容器**：FL/FR/FC/LFE/SL/SR 直通；side/back 布局必须按权威标签区分。
4. **5.1 源 → 8ch 容器**：映射到对应 5.1 位置，多余 slot 静音；容器 8ch 不改变“源是 5.1”的事实。
5. **7.1 源 → 8ch 容器**：按权威布局直通。
6. **7.1 源 → 6ch 容器**：必须走显式 downmix（如 BL/BR 按系数并入 SL/SR），记录矩阵；不能静默丢声道。
7. **unknown 布局**：拒绝宣称多声道；只允许明确的 stereo/unknown 受限兜底，并报告 `unsupported_layout`。
8. **任意多声道 → 两台 HomePod**：必须显式 downmix 到 stereo（记录矩阵），或只路由 FL/FR；不能把 6/8ch 假装成两台音箱的“原生 5.1”。

## 设备能力方向（待 architect 决策）

候选：

- A. 保留 stereo 设备，新增 5.1 六通道设备与 7.1 八通道设备（两个固定布局，客户端语义最清晰）。
- B. 新增一个八通道设备，用固定 7.1 布局承载 5.1（多余 slot 静音），减少设备数量但 5.1/7.1 语义容易混淆。
- C. 单设备可配置 6/8ch 布局（需停止/重开，属性/revision 复杂）。

无论选哪种，都必须真实实现 6/8 通道、正确 channel layout、逐通道独立 PCM、稳定时钟和延迟 revision；不能只把 2ch 数组改名为 8ch。

## 分工与写权限

- architect：`docs/collaboration/virtual-audio/MULTICHANNEL_CONTRACT.md`（新文件）、必要时 `ARCHITECTURE.md`；不改驱动/测试代码。
- driver：`platforms/macos/VirtualAudioDriver/`；先做不改变现有 stereo 行为的 6/8ch 原型/实验路径与 mock 测试，不安装、不改系统。
- qa：`docs/collaboration/virtual-audio/MULTICHANNEL_ACCEPTANCE.md`（新文件）、`tests/virtual_audio/`；只做离线验收工具/夹具，不播放、不录音、不改设备。
- 总协调：Mac 构建/执行、安装、Git、跨模块整合；agent 不共享 SSH、不自行提交/推送、不出声、不改默认输出。

## 必须区分的三层结果

1. HAL/容器层：设备枚举、6/8ch 格式、channel layout、逐通道 PCM、时钟/延迟属性。
2. 源层：播放器/解码器实际报告并输出的源布局；stereo 是否被播放器先降混/上混。
3. 声学层：实际 HomePod 端点分配、声道方向、音画与音箱间同步。

第 1 层通过不等于第 2/3 层；第 3 层在当前两台 HomePod 上不能宣称完整 5.1，只能验证 downmix/前置路由，或等更多端点。
