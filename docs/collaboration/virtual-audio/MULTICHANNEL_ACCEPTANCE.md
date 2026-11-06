# 多声道输入与路由验收设计（源优先）

日期：2026-11-06。Owner：virtual_qa。状态：**验收设计 + 可运行的离线检查**，不是驱动、播放器、浏览器或 HomePod 声学通过记录。当前产品驱动仍只声明立体声 2ch；本文的多声道容器与路由是下一阶段验收基线。

**重要：architect 的 `MULTICHANNEL_CONTRACT.md` v1 已在本工作区出现并冻结。** 本文的离线模型/夹具是在该契约出现前完成的 provisional 源优先模型；两者仍有未关闭差异，逐项列在 §0.1。离线测试当前验证的是本文与测试彼此一致，**不是**已对齐契约 v1 的验收。

本文把虚拟声卡定位为**输入能力层**：尽量支持更多源布局，按权威标签原样保留源声道，交给 Flow；Flow 再根据“源布局 + 实际音箱布局/数量”选择直通或显式 downmix。**立体声进入 5.1/7.1 只是其中一个 fallback 组，不是本文验收的中心。**

## 0. 必读结论与边界

- 源通道数至少覆盖 **1、2、4、6、8**；**10/12（height）为预留**，不是首轮硬件门槛。3.0 和 4.0 作为 Flow 端点/辅助布局支持。
- 源少于容器：按同名 label **passthrough**，只占对应 slot，其余 slot 必须静音；不能因为容器更宽就宣称源是 5.1/7.1。
- 源多于容器：必须**显式 downmix**，每个源声道都要有去向（LFE 省略必须显式记录），不得静默丢声道。
- 布局未知、6ch 未说明 side/back、8ch 未说明 7.1/5.1.2、10ch 未说明 7.1.2/5.1.4：**拒绝猜测**，返回 `unsupported_layout`/`ambiguous_layout`。静音/活动通道数不能推断布局。
- 两台 HomePod 只能验证 **stereo downmix、FL/FR 前置路由和两台之间的同步**；不能宣称真实 5.1/7.1 声学通过，也不能据此验证 center/surround/LFE 的方向或包围感。
- 本文的矩阵与命名仍是 provisional QA 提案；冻结契约为 `MULTICHANNEL_CONTRACT.md` v1。未关闭差异见 §0.1；在关闭前不得把本文系数/命名当作契约验收证据。

### 0.1 与 MULTICHANNEL_CONTRACT v1 的剩余冲突（必须关闭）

以下差异是当前离线模型/夹具与冻结契约的**明确冲突**，不是已解决项。离线测试通过只证明 provisional 模型自洽，不能关闭这些冲突。

| # | 项目 | 契约 v1 | 当前离线模型/测试 | 状态 |
|---:|---|---|---|---|
| 1 | mono label | `M`（明确不是 FC 别名） | 使用 `FC` | **冲突**；需改模型、夹具 tone、expected JSON、测试 |
| 2 | 7.1 顺序 | `FL FR FC LFE SL SR BL BR`（Apple/HAL，side 在 back 前） | `FL FR FC LFE BL BR SL SR`（WAVE mask 升序） | **冲突**；未显式断言契约 `channelOrder` |
| 3 | 7.1 -> 6ch 系数 | `SL=0.5*SL+0.5*BL`、`SR=0.5*SR+0.5*BR` | 先 `0.7071` 再行 L1 cap，最终输出同为 `0.5/0.5` | 输出值一致；文档/中间过程需改写为契约的 0.5 直接定义 |
| 4 | padded provenance | `source_padded` | 多声道 pad 使用 `discrete_pcm_passthrough` | **冲突**；token 不一致 |
| 5 | height 命名 | `5.1.2`/`7.1.2`/`7.1.4`，顶部后为 `TRL/TRR` | 只有 `7.1.2`/`7.1.4`，顶部后为 `TBL/TBR`，无 `5.1.2` | **冲突**；需补 `5.1.2`、改 `TRL/TRR` |
| 6 | 捕获层 source > container | 捕获层拒绝 `source_exceeds_container`，不 downmix | `build_route` 在同层直接 downmix | **冲突**；需拆 capture（identity/pad/refuse）与 Flow（downmix/remap） |
| 7 | `M_71_2` 系数 | `0.414214*FL + 0.292893*FC + 0.146447*SL + 0.146447*BL` | `0.320377*FL + 0.226541*FC + 0.226541*SL + 0.226541*BL` | **冲突**；需按契约寄存器重算 |
| 8 | stereo 上混 | `FL=.707107L, FR=.707107R, FC=.353553(L+R), LFE=0` | `FL=1L, FR=1R, FC=.5(L+R), LFE=.5(L+R)` | **冲突** |
| 9 | LFE | 到 stereo 一律丢弃；上混 LFE=0；不做 fold | 支持 `lfe_policy=fold`，上混 LFE=.5 | **冲突**；契约无 fold |
| 10 | Flow 能力表 | 3.0/4.0/5.1/7.1 -> 3.0/4.0 等若干格为 `—` 拒绝；5.1S↔5.1B 为 `R` remap | 部分被通用 downmix，5.1S↔5.1B 直接拒绝 | **冲突**；需按 §5.2 表逐格实现 |
| 11 | DoIO 帧数 | 接受 `0..4096` | 接受 `15..4096` | **冲突**；buffer Set 仍 15..4096 |
| 12 | 5.1.2 | RES 8ch，明确命名 | 未支持 | **缺失**（预留，不阻塞首轮硬件） |

结论：本文 §4/§5 的系数与命名只能作为 provisional QA 参考；关闭上表前，不能用 `run_offline_acceptance.py` 的 pass 声称“已符合 MULTICHANNEL_CONTRACT v1”。下一轮应先对齐模型/夹具/测试，再重跑同一套离线检查。

## 1. 分层证据与不可替代关系

| 层级 | 要回答的问题 | 可接受证据 | 不能据此声称 |
|---|---|---|---|
| L0 源/解码层 | 播放器实际解码并报告/输出的源布局是什么？ | 播放器版本、轨道信息、`audio-params`、解码器报告布局、实际输出格式；暂停/seek/切轨记录 | 设备容器有 8 slot 就是 7.1；轨道标签是 5.1 就证明取得了 6 个独立声道 |
| L1 HAL/容器层 | 虚拟设备实际暴露了多少通道、什么 mask/label、逐通道 PCM、时钟/延迟？ | 设备 UID、channel count、mask、label 顺序、逐通道非零独立 PCM、buffer、period、`hfla`/`hflr`、stream latency | 设备枚举/属性可读等于源布局正确、浏览器采用或声学出声 |
| L2 Flow 路由层 | 按源布局和实际端点数选择了 identity/passthrough/downmix 哪条矩阵？ | 路由描述、矩阵系数、provenance、transformations、LFE policy、gain/clip 结果 | 路由矩阵通过等于真实扬声器方向/包围感通过 |
| L3 声学/端点层 | 每个声道实际去了哪个 HomePod/端点、方向、音画与音箱间同步如何？ | 端点 UID/位置、逐端点分配、同录视频/音频、A/V 偏差、音箱间同步、30 分钟漂移 | 发送 hash、离线矩阵、两只前置音箱的 downmix 等于 5.1/7.1 声学 |

L1 通过不等于 L2/L3；L2 矩阵通过也不等于 L3。报告必须分层写“实测/未测/失败/不可观测”，不能用一个“能响”覆盖。

## 2. 规范布局、label 顺序与 mask

canonical 顺序按 WAVE speaker bit 升序；label 是每个 slot 的权威身份。**顺序/重复/缺失不符即拒绝，不做自动重排。**

| 布局 | 通道 | mask | canonical labels（slot 0..N-1） | 首轮状态 | 说明 |
|---|---:|---:|---|---|---|
| `mono` | 1 | `0x0004` | `FC` | 必须 | 单声道/单中心；不是 5.1 的“原生 FC”声明 |
| `stereo` | 2 | `0x0003` | `FL, FR` | 必须 | 基线 |
| `3.0` | 3 | `0x0007` | `FL, FR, FC` | 辅助 | 3 音箱端点；源也可显式使用 |
| `4.0_quad` | 4 | `0x0033` | `FL, FR, BL, BR` | 必须（源 4ch） | quad 使用 back；4.0 side 不在首轮 |
| `5.1_side` | 6 | `0x060F` | `FL, FR, FC, LFE, SL, SR` | 必须 | 6ch 必须显式 side，不能只写 5.1 |
| `5.1_back` | 6 | `0x003F` | `FL, FR, FC, LFE, BL, BR` | 必须 | 与 side 同通道数、不同 slot 身份 |
| `7.1` | 8 | `0x063F` | `FL, FR, FC, LFE, BL, BR, SL, SR` | 必须 | 8ch 必须显式 7.1；5.1.2 不在首轮 |
| `7.1.2` | 10 | `0x363F` | `FL, FR, FC, LFE, BL, BR, SL, SR, TFL, TFR` | 预留 | 10ch 也可被解释为 5.1.4，必须显式命名 |
| `7.1.4` | 12 | `0xF63F` | `FL, FR, FC, LFE, BL, BR, SL, SR, TFL, TFR, TBL, TBR` | 预留 | 12ch height |

明确拒绝：裸 `5.1`/`6ch`、裸 `8ch`、裸 `10ch`、`5.1.4`、未知 label、重复 label、缺失 label、side/back 互换顺序、mask=0。当前 Swift `ChannelLabel` 只有 `FL/FR/FC/LFE/SL/SR/BL/BR/unknown`；10/12 的 `TFL/TFR/TBL/TBR` 需要后续契约/模型扩展，首轮不因此阻塞。

## 3. 源优先路由规则

| 条件 | 模式 | 规则 | 报告要求 |
|---|---|---|---|
| 源布局 == 目标布局 | identity | 同名同 slot，系数 1 | `native_layout_claim` 可为该布局；只有源确实是 5.1/7.1 才可声明原生 |
| 源 label 集合 ⊂ 目标 label 集合 | passthrough | 源 slot 原样复制；目标独有 slot 静音 | `source_layout` 不变；不得把容器宽度写成源布局 |
| 目标通道数 < 源通道数 | downmix | 按 label 角色折叠；每个源声道有去向；LFE 省略/折叠显式 | 记录矩阵、`transformations`、LFE policy、gain |
| 同通道数但 label/顺序不同 | reject | `layout_mismatch` | 例如 5.1 side -> 5.1 back，禁止静默重标 |
| 目标更宽但不包含源 label | reject | 只有 `mono -> stereo` 有定义好的复制 upmix | 不凭空生成缺失布局 |
| 未知/歧义 | reject | `unsupported_layout`/`ambiguous_layout` | 不得从静音/活动通道推断 |

### 3.1 源布局 -> 实际音箱数量（1/2/3/6/8）

`I`=identity，`P`=passthrough，`D`=downmix，`U`=upmix。单元格为 `目标布局/模式/最大真实声学声明`。声学声明不是自动通过，必须另有 L3 测量。

| 源 \ 音箱数 | 1 | 2 | 3 | 6 | 8 |
|---|---|---|---|---|---|
| `mono` | `mono/I/mono` | `stereo/U/stereo_upmix` | `3.0/P/mono` | `5.1_side/P/mono` | `7.1/P/mono` |
| `stereo` | `mono/D/mono_downmix` | `stereo/I/stereo` | `3.0/P/stereo` | `5.1_side/P/stereo` | `7.1/P/stereo` |
| `4.0_quad` | `mono/D/mono_downmix` | `stereo/D/stereo_downmix` | `3.0/D/3.0_downmix` | `5.1_back/P/4.0_quad` | `7.1/P/4.0_quad` |
| `5.1_side` | `mono/D/mono_downmix` | `stereo/D/stereo_downmix` | `3.0/D/3.0_downmix` | `5.1_side/I/5.1_side` | `7.1/P/5.1_side` |
| `5.1_back` | `mono/D/mono_downmix` | `stereo/D/stereo_downmix` | `3.0/D/3.0_downmix` | `5.1_back/I/5.1_back` | `7.1/P/5.1_back` |
| `7.1` | `mono/D/mono_downmix` | `stereo/D/stereo_downmix` | `3.0/D/3.0_downmix` | `5.1_side/D/5.1_side_downmix` | `7.1/I/7.1` |
| `7.1.2`（预留） | `mono/D` | `stereo/D` | `3.0/D` | `5.1_side/D` | `7.1/D`；10 音箱 `7.1.2/I` |
| `7.1.4`（预留） | `mono/D` | `stereo/D` | `3.0/D` | `5.1_side/D` | `7.1/D`；12 音箱 `7.1.4/I` |

关键点：

- 6 音箱时，源是 `5.1_back` 就保留 back；源是 `4.0_quad` 也选 `5.1_back`（FL/FR/BL/BR 直通，FC/LFE 静音）；其他源默认 `5.1_side`。
- `stereo -> 6/8` 是 passthrough：只有 FL/FR 有信号，不能显示“原生 5.1/7.1”。
- `mono -> 2` 是显式复制 upmix（FL/FR 各 `1/√2`），不是立体声源。
- `7.1 -> 6` 必须走 downmix，不能把 BL/BR 静默丢掉。

### 3.2 立体声进入 5.1/7.1（仅 fallback 组）

默认仍是 **passthrough**：`FL=L, FR=R`，FC/LFE/SL/SR/BL/BR 全静音，`provenance=stereo_passthrough_in_multichannel`，`transformations=["stereo_passthrough"]`。显式 `stereo_upmix_v1` 只在用户选择时启用：

```text
FL = L, FR = R
FC = 0.5*(L+R)
SL/BL = 0.5*(L-R)
SR/BR = 0.5*(R-L)
LFE = 0.5*(L+R)        # 仅矩阵馈送，不等于 bass management
```

7.1 容器中 BL/BR 静音；5.1 back 容器中差信号进 BL/BR。两者都必须标 `provenance=stereo_upmix_v1`，`reported_as_native_5_1_or_7_1=false`，不能称 Dolby/DTS/原生多声道。

## 4. 矩阵系数、LFE、增益与削波

### 4.1 通用规则

- 同名 label 直通系数 1。
- 默认折叠系数 `1/√2 ≈ 0.70710678`；例如 7.1 -> 5.1 的 BL/BR 先各 `0.7071` 并入 SL/SR。
- 每个输出行做 **L1 cap**：`g = 1 / Σ|coeff|`（仅当 Σ|coeff| > 1），因此最终每行 `Σ|coeff| ≤ 1`。这就是无内容相关的削波上界；代价是不同源布局的绝对电平不同。实际期望值以生成的 `expected/<case>.json` 为准。
- LFE：
  - 目标有 LFE slot：直通 1.0（5.1/7.1 容器、7.1 -> 5.1、10/12 -> 7.1 等）。
  - 目标没有 LFE（stereo/mono/3.0/4.0）：默认 **omit**，记录 `lfe_omitted`；可选 `fold` 到 FL/FR（系数 0.5 再参与 L1 cap），记录 `lfe_folded`。不允许静默消失且不记录。
- 削波：矩阵 + L1 cap 后 full-scale 所有源声道同时输入，输出峰值必须 `≤ 1.0`；WAV 写入器对 `|x|>1` 直接抛 `ClippingError`。
- 增益不是响度归一化；若产品以后改用 limiter/动态增益，必须重算所有期望值并单独记录 gain reduction。

### 4.2 代表性系数

```text
7.1 -> 5.1_side:
  FL/FR/FC/LFE = 1
  SL = 0.5*SL + 0.5*BL
  SR = 0.5*SR + 0.5*BR

5.1_side -> stereo:
  FL = 0.41421356*FL + 0.29289322*FC + 0.29289322*SL
  FR = 0.41421356*FR + 0.29289322*FC + 0.29289322*SR

7.1 -> stereo:
  FL = 0.32037724*FL + 0.22654092*(FC+SL+BL)
  FR = 0.32037724*FR + 0.22654092*(FC+SR+BR)

stereo -> mono:
  FC = 0.5*FL + 0.5*FR

7.1.2 -> 7.1:
  FL = 0.5*FL + 0.5*TFL;  FR = 0.5*FR + 0.5*TFR
  FC/LFE/BL/BR/SL/SR = 1
```

## 5. 确定性夹具与期望电平

所有源夹具为 48 kHz、1.0 s、16-bit WAVE_FORMAT_EXTENSIBLE，每通道一个不同整数 Hz 正弦，峰幅度 `A=0.25`。1 s 内每个频率整数周期，窄带投影可精确区分通道。

| label | FC | FL | FR | LFE | SL | SR | BL | BR | TFL | TFR | TBL | TBR |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Hz | 557 | 317 | 431 | 61 | 733 | 863 | 977 | 1103 | 1301 | 1451 | 1601 | 1751 |

注意：`mono` 使用 FC=557 Hz；5.1/7.1 的 FC 也是 557 Hz。分析时按“源布局 + 期望 JSON”区分，不能只看频率猜布局。

### 5.1 代表性期望电平（peak amplitude）

| 案例 | 期望 |
|---|---|
| `mono -> 5.1_side` passthrough | FC `0.25@557`；FL/FR/LFE/SL/SR = 0 |
| `stereo -> 5.1_side` passthrough（fallback） | FL `0.25@317`，FR `0.25@431`；其余 = 0 |
| `5.1_side -> 7.1` passthrough | FL/FR/FC/LFE/SL/SR 各 `0.25` 本通道 tone；BL/BR = 0 |
| `4.0_quad -> 5.1_back` passthrough | FL/FR/BL/BR 各 `0.25`；FC/LFE = 0 |
| `7.1 -> 5.1_side` downmix | FL/FR/FC/LFE `0.25`；SL `0.125@733 + 0.125@977`；SR `0.125@863 + 0.125@1103` |
| `5.1_side -> stereo` downmix（LFE omit） | FL `0.10355@317 + 0.07322@557 + 0.07322@733`；FR 对应 431/557/863；61 Hz = 0 |
| `7.1 -> stereo` downmix（LFE omit） | FL `0.08009@317 + 0.05664@557 + 0.05664@733 + 0.05664@977`；FR 对应 431/557/863/1103 |
| `stereo -> mono` downmix | FC `0.125@317 + 0.125@431` |
| `7.1.2 -> 7.1` downmix | FL `0.125@317 + 0.125@1301`；FR `0.125@431 + 0.125@1451`；FC/LFE/BL/BR/SL/SR 各 `0.25` |
| `stereo -> 5.1_side` upmix fallback | FL `0.25@317`，FR `0.25@431`；FC/SL/SR/LFE 各 `0.125@317 + 0.125@431` |

每个 case 的完整 per-slot/per-tone 期望在 `expected/<case>.json`；离线工具按该 JSON 做数值断言，不靠人眼看表。

## 6. 总测试矩阵

生成器共生成 **84 个 case**：A 身份 9、B passthrough 12、C downmix 23、D stereo fallback 2、E LFE 4、F 端点矩阵 30、G 预留 height 4。

### 6.1 源/容器主矩阵

| 组 | 覆盖 | 夹具 | 期望 | 通过判据 | 证据 |
|---|---|---|---|---|---|
| A 身份 | 1/2/3/4/6 side/6 back/8/10/12 -> 同布局 | 对应 `*_source.wav` | 每 slot 本通道 `0.25` tone；无额外通道 | count/mask/labels 完全一致；crosstalk ≤ -50 dB；peak ≤ 1；identity 才允许 native 5.1/7.1 | WAV SHA、expected JSON、analyzer JSON |
| B 源窄于容器 | mono/stereo/quad/5.1/7.1 -> 更宽容器 | 源夹具 + expected | 源 slot `0.25`；目标独有 slot 全 0 | 源 layout 不变；目标独有 slot ≤ -50 dB；`reported_as_native_5_1_or_7_1=false` | 同上；路由描述 |
| C 源宽于容器 | stereo/3.0/quad/5.1/7.1/10/12 -> 更窄容器 | 源夹具 + expected | 按矩阵；例如 7.1->5.1 每 surround 两个 `0.125` | 系数/电平匹配；每源声道有去向（LFE 省略需记录）；L1≤1；无 native 声明 | 矩阵 JSON、expected JSON、analyzer |
| D stereo fallback | stereo -> 5.1 side/7.1，仅显式 upmix | stereo | 见 5.1 表 | `provenance=stereo_upmix_v1`；native=false；矩阵精确 | 同上 |
| E LFE | 5.1/7.1 -> stereo omit/fold；7.1.2 -> 7.1 | 5.1/7.1/10ch | omit 时 61 Hz=0；fold 时 61 Hz>0；目标有 LFE 时 61 Hz=0.25 | policy/transformations 正确；无静默丢 LFE | 同上 |
| F 端点矩阵 | 6 源 × 1/2/3/6/8 音箱 | 6 源 | 见 3.1 表 | mode/target 正确；L1≤1；2 音箱 surround 只允许 `stereo_downmix` | 端点矩阵 JSON、WAV 子集 |
| G 预留 height | 7.1.2/7.1.4 identity、10->8、12->10 | 10/12ch | TFL/TFR/TBL/TBR 折叠 | 预留，不作为首轮硬件门槛；矩阵/L1 仍须通过 | 工具输出 |

### 6.2 负向/拒绝矩阵

| 输入 | 期望错误 | 说明 |
|---|---|---|
| `unknown` 布局 | `unsupported_layout` | 不在白名单 |
| 裸 `5.1`/`6ch` | `ambiguous_layout` | side/back 未说明 |
| 裸 `8ch` | `ambiguous_layout` | 7.1/5.1.2 未说明 |
| 裸 `10ch`/`5.1.4` | `ambiguous_layout`/`unsupported_layout` | 10ch 需显式 7.1.2；5.1.4 首轮不支持 |
| labels `FL,FR,FC,LFE,SR,SL` | `unsupported_layout` | slot 顺序错误，不自动重排 |
| 重复 label | `duplicate_label` | slot 身份不唯一 |
| 5.1 side -> 5.1 back | `layout_mismatch` | 同宽不同身份，禁止静默重标 |
| 3.0 -> 4.0 quad | `layout_mismatch` | 更宽目标不包含 FC；不凭空生成 |
| 6ch 只有 FL/FR 活动 | `silence_does_not_identify_layout` | 静音/活动数不能推断 5.1/立体声 |
| stereo -> 5.1 报 native 5.1 | `false_native_claim` | 容器不是源布局 |
| 5.1 -> 7.1 报 native 7.1 | `false_native_claim` | 8 slot 载体不等于 7.1 源 |
| mask=0/未知 mask | `unsupported_layout` | 无权威布局 |

### 6.3 延迟、revision、buffer

| 检查 | 期望 | 通过判据 |
|---|---|---|
| 每设备 `hfla`/`hflr` | 每 device UID 独立 | 改 A 不影响 B revision；同值幂等不增；有效变更 +1 |
| 重发现 | 旧 revision 失效 | 旧 handle 查询 `latency_revision_changed`；新 epoch |
| rate 变更 | 按秒预算换算帧 | 44100↔48000 后 `frames/rate` 保持；新 epoch/通知 |
| 越界 latency | 拒绝 | `<0` 或 `>10*rate` 不部分应用 |
| buffer | host 管理 15..4096 | 15/16/255/256/512/1024/4096 可设；14/4097 拒绝；不改 revision |
| DoIO 帧数 | 接受 host 可变帧数 | 15..4096 接受；0/负数/>4096 拒绝；不假设 512 |
| zero timestamp period | 16384，独立于 buffer | 改 buffer 不改变 period；时间戳不倒退/不虚构未来 |
| 两 scope stream latency | 同一值 | global/output 均同值；不是两份延迟相加 |

## 7. 首轮必须通过 vs 硬件不足暂不能验

### 7.1 首轮必须通过（离线 + 当前 Mac 两台 HomePod 可覆盖的部分）

1. 虚拟声卡输入层：1/2/4/6/8 源布局可被描述，mask/label 正确；6ch side/back 可区分；10/12 只要求模型/预留检查，不要求硬件。
2. 源少于容器：passthrough 只占同名 slot，目标独有 slot 静音；不得把容器宽度报成源布局。
3. 源多于容器：显式 downmix；每源声道有去向；LFE 省略/折叠有记录；无静默丢声道。
4. 未知/歧义布局拒绝；静音/活动数不推断布局；同宽不同身份拒绝。
5. 逐通道独立标识：不同 tone/通道，crosstalk ≤ -50 dB，peak ≤ 1；LFE/增益/削波按第 4 节。
6. stereo -> 5.1/7.1：默认 passthrough；显式 upmix 只能作为 fallback，且不得报 native。
7. 两台 HomePod：可验证 `5.1/7.1 -> stereo` downmix、FL/FR 前置路由、两台间同步；不得宣称 5.1/7.1 声学。
8. 每设备 latency/revision、buffer 15..4096、DoIO 可变帧数、period 16384 独立、两 scope latency 同值。
9. 三层报告字段分离；L1/L2 通过不得写成 L3 通过。

### 7.2 硬件不足暂不能验（当前只有两台 HomePod）

1. **真实 5.1 声学**：需要至少 6 个可独立分配的输出端点或等效真实多声道端点；两台 HomePod 无法验证 center、SL/SR、LFE 的方向与包围感。
2. **真实 7.1 声学**：需要 8 个独立端点；两台只能验证 downmix/前置。
3. **height 10/12**：需要 10/12 个端点或认证的 height renderer；本文只做预留矩阵。
4. **side vs back 的声学差异**、center 定位、LFE 与主声道的融合、surround envelopment：两台前置无法区分。
5. **6/8 端点间的同步/30 分钟漂移**：当前只能测两台；多端点需要更多设备与录音。
6. **播放器真实解码/源布局报告**：mpv/IINA/VLC 的实际版本、原生 5.1/7.1 输出、暂停/seek/切轨、DRM 兼容均未验。
7. **浏览器采用与 A/V 补偿**：多声道路径的浏览器内部采用值、音画偏差、每端点声学延迟未验。
8. **真实 6/8ch 虚拟 HAL 设备**：当前工作区只有 stereo 设备枚举成功；6/8ch 驱动尚未实现/枚举，本文所有多声道结果均为离线模型。
9. **10/12 label 模型扩展**：当前 Swift `ChannelLabel` 没有 height label；需契约/模型更新。

## 8. 当前 Mac 事实与本文关系

依据 [第六候选运行报告](../reports/VirtualAudio-2026-11-06/Sixth-candidate-runtime-2026-11-06.md)：

- 已枚举 `com.homepodflow.virtual-audio.stereo.v1`，2ch/48000/Virtual；AudioUnit create/bind/initialize 通过。
- `hfla`/`hflr` 真机可读写；同值幂等；revision 单调；global/output 两 scope stream latency 同步。
- TCC 授权 GUI 进程的 device Tap 取得非零、左右独立 PCM（左 440 Hz 时 rmsL=0.169940、rmsR=0）。
- `kAudioDevicePropertyBufferFrameSize` 由 coreaudiod 管理，实测 15..4096，可设 256/1024/4096；驱动自身 512..512 不生效。
- 产品 Input 仍只有 discover；无真实 Tap 采集/转换/HPCM；**没有 6/8ch 虚拟设备**。

因此：本文的 1/2/4/6/8 容器、84 个矩阵 case、L1/L2 结果都是**离线参考模型**；只有 stereo 设备、Tap 非零、属性/缓冲行为有真机证据。多声道最终验收必须等 6/8ch 驱动、Flow 路由和更多端点。

## 9. 离线工具、夹具与运行结果

文件（均在 `tests/virtual_audio/`）：

| 文件 | 作用 |
|---|---|
| `multichannel_model.py` | 布局/label/mask、源优先路由、矩阵/L1/LFE、端点矩阵、latency/buffer 参考模型；无 I/O |
| `multichannel_wav.py` | 16-bit WAVE_FORMAT_EXTENSIBLE 读写、确定性 tone 生成、窄带投影/RMS/peak/DC |
| `make_multichannel_fixtures.py` | 生成 9 个源 WAV + 84 个 `expected/<case>.json` + manifest；拒绝覆盖 |
| `analyze_multichannel_capture.py` | 对实际/生成 WAV 做逐通道 tone/串扰/DC/clip 断言；mask 未知默认失败 |
| `run_offline_acceptance.py` | 一键跑 84 矩阵 case、端点矩阵、20 个 WAV 抽样、拒绝/latency/buffer/layer；不播放 |
| `test_multichannel.py` | 26 项 unittest；覆盖布局、路由、LFE、削波、端点、latency/buffer、三层声明、夹具/分析器 |

命令与本次结果（Windows Python 3.10.0，未播放/未采集/未改设备）：

```text
python -m unittest discover -s tests/virtual_audio -p test_multichannel.py -v
  -> Ran 26 tests ... OK (28.793s)

python tests/virtual_audio/run_offline_acceptance.py
  -> status=pass; fixture_case_count=84; sections matrix/endpoint/latency/
     buffer/layers/wav/clipping/rejections all pass; 20/20 WAV samples pass;
     11/11 rejection checks pass

python -m unittest discover -s tests/virtual_audio -p test_tools.py -v
  -> Ran 6 tests ... OK（既有立体声素材/事件工具回归）
```

生成夹具（需要时）：

```text
python tests/virtual_audio/make_multichannel_fixtures.py --output <不存在的新目录>
```

该命令只写本地 WAV/JSON，不生成 MP4、不启动浏览器、不播放、不联网。实际 capture 检查：

```text
python tests/virtual_audio/analyze_multichannel_capture.py capture.wav \
  --expected <fixtures>/expected/MC-C13.json
```

默认阈值：相对 3% 或绝对 0.002 peak（取较大者）；非期望 tone ≤ -50 dB（相对最大期望）；DC ≤ 0.002；peak > 1 判 clip；WAV 无 mask 默认失败（`--allow-unknown-mask` 仅标记 `pass_unverified_mask`，不能当 label 身份通过）。

## 10. 证据采集清单（每个真实 case）

1. **源**：播放器/版本、文件或流、轨道、`decoderReportedFormat`/`sourceLayout`、实际输出格式、pause/seek/切轨、是否 downmix/upmix、源时钟。
2. **容器**：设备 UID、count、mask、labels、rate、buffer、zero period、`hfla`/`hflr`、device/stream/safety latency、逐通道 PCM 的 RMS/peak/tone。
3. **路由**：目标布局/端点数、identity/passthrough/downmix、矩阵、provenance、transformations、LFE policy、L1/headroom、limiter/clip。
4. **端点/声学**：端点 UID/位置、逐端点分配、同录视频+音频、A/V 偏差、端点间同步、30 分钟漂移。
5. **报告分层**：L0/L1/L2/L3 分别写实测/未测/失败/不可观测；不得用 L1 枚举或 L2 矩阵代替 L3。
6. **不可替代声明**：两台 HomePod 的 5.1/7.1 结果只能写 `stereo_downmix`/`2.0`，不能写 5.1/7.1 声学通过。

## 11. 仍未验证/下一门槛

- architect `MULTICHANNEL_CONTRACT.md` v1 已冻结；当前离线模型仍有 §0.1 所列 12 项冲突，尚未对齐。
- 6/8ch HAL 设备实现、真实 channel layout、逐通道独立 PCM、稳定时钟/延迟 revision。
- Flow 输入目前只有 HPCM v1 stereo；需要 HPCM v2/协商与旧 worker 拒绝未知版本。
- 播放器真实多声道解码/输出；浏览器采用；DRM；真实 6/8/10/12 端点与声学。
- 10/12 height label 的 Swift 模型扩展；5.1.4/5.1.2 首轮不承诺。
- 动态 limiter/真实节目响度策略未定；本文只用静态 L1 cap 作为无削波参考。

## 12. 变更记录

- 2026-11-06：首版源优先验收设计。覆盖 1/2/4/6/8 源、3.0/4.0 辅助、10/12 预留；84 个离线 case；20 个 WAV 抽样；26 项 unittest；明确两台 HomePod 只能验证 downmix/前置，不能宣称 5.1/7.1 声学。
