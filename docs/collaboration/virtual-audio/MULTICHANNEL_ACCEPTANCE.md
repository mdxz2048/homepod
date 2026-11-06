# 多声道输入与路由验收设计（源优先）

日期：2026-11-06。Owner：virtual_qa。状态：**验收设计 + 可运行的离线检查**，不是驱动、播放器、浏览器或 HomePod 声学通过记录。当前产品驱动仍只声明立体声 2ch；本文的多声道容器与路由是下一阶段验收基线。

**重要：architect 的 `MULTICHANNEL_CONTRACT.md` v1 已冻结，本文的离线模型/夹具/测试已按 v1 对齐。** §0.1 的 12 项原冲突已逐项关闭，并给出对应测试证据；离线通过仍只证明**模型/矩阵/夹具**一致，不是驱动、播放器、端点或声学通过。

本文把虚拟声卡定位为**输入能力层**：尽量支持更多源布局，按权威标签原样保留源声道，交给 Flow；Flow 再根据“源布局 + 实际音箱布局/数量”选择直通或显式 downmix。**立体声进入 5.1/7.1 只是其中一个 fallback 组，不是本文验收的中心。**

## 0. 必读结论与边界

- 源通道数至少覆盖 **1、2、4、6、8**；**10/12（height）为预留**，不是首轮硬件门槛。3.0 和 4.0 作为 Flow 端点/辅助布局支持。
- 源少于容器：按同名 label **passthrough**，只占对应 slot，其余 slot 必须静音；不能因为容器更宽就宣称源是 5.1/7.1。
- 源多于容器：**捕获层拒绝** `source_exceeds_container`，不得在同一层 downmix；改用更大的容器后，才由 Flow 按显式矩阵 downmix，并记录 `losses`。
- 布局未知、6ch 未说明 side/back、8ch 未说明 7.1/5.1.2、10ch 未说明 7.1.2/5.1.4：**拒绝猜测**，返回 `unsupported_layout` / `source_layout_ambiguous`。静音/活动通道数不能推断布局。
- 两台 HomePod 只能验证 **stereo downmix、FL/FR 前置路由和两台之间的同步**；不能宣称真实 5.1/7.1 声学通过，也不能据此验证 center/surround/LFE 的方向或包围感。
- 本文矩阵/命名/夹具已对齐 `MULTICHANNEL_CONTRACT.md` v1；契约仍是唯一接口依据。离线证据不能替代 Gate 1/2/3 的真机证据。

### 0.1 与 MULTICHANNEL_CONTRACT v1 的冲突关闭记录

本节原列 12 项冲突，现全部关闭。每项给出契约值、当前实现和离线证据；证据只覆盖离线模型/夹具，不覆盖真机驱动、端点或声学。

| # | 项目 | 契约 v1 | 当前实现 | 状态 / 离线证据 |
|---:|---|---|---|---|
| 1 | mono label | `M`（不是 FC 别名） | `LAYOUTS["mono"]=("M",)`；`mono` 夹具/expected 使用 `M`；mask `0x0004` 只作 WAV 载体 | 已关闭；`LayoutTests.test_canonical_layouts_masks_and_channel_order` |
| 2 | 7.1 顺序 | `FL FR FC LFE SL SR BL BR`（side 在 back 前） | `LAYOUTS["7.1"]` 与 `RoutePlan.channel_order` 均按契约顺序；analyzer 断言 `channelOrder` | 已关闭；`test_side_precedes_back_in_7_1_and_512_is_not_7_1`、`GainClipTests` |
| 3 | 7.1 -> 6ch 系数 | `SL=0.5*SL+0.5*BL`、`SR=0.5*SR+0.5*BR` | `M_71_6` 直接写 `0.5/0.5`；`M_71_6B` 为 back 变体 | 已关闭；`test_flow_7_1_to_6_uses_contract_coefficients` |
| 4 | padded provenance | `source_padded` | 捕获 pad 统一 `source_padded`；stereo 例外仍为 `stereo_passthrough_in_multichannel` | 已关闭；`test_capture_is_identity_pad_or_refused_only` |
| 5 | height 命名 | `5.1.2`/`7.1.2`/`7.1.4`，顶部后 `TRL/TRR` | 三种 layout 均存在；`TBL/TBR` 已从 `ALLOWED_LABELS` 移除；`5.1.2` 为 8ch 与 7.1 区分 | 已关闭；`test_reserved_height_uses_trl_trr_and_512` |
| 6 | 捕获层 source > container | 捕获层拒绝 `source_exceeds_container`，不 downmix | `plan_capture` 只返回 identity/pad_silent/refused；`build_route` 只做 Flow | 已关闭；`test_capture_is_identity_pad_or_refused_only` |
| 7 | `M_71_2` 系数 | `0.414214*FL + 0.292893*FC + 0.146447*SL + 0.146447*BL` | `M_71_2` 用精确 `a/b/c` 公式；行 L1=1 | 已关闭；`test_downmix_losses_cover_every_source_label`、`Fixture` 矩阵 |
| 8 | stereo 上混 | `FL=.707107L, FR=.707107R, FC=.353553(L+R), LFE=0` | `M_ST_51S`/`M_ST_71`，`LFE` 空行（精确 0） | 已关闭；`test_stereo_upmix_matches_contract_matrix` |
| 9 | LFE | 到 stereo 一律丢弃；上混 LFE=0；不做 fold | `M_*_2` 丢弃 LFE 并写入 `losses.discarded`；无 fold 分支 | 已关闭；`test_lfe_is_discarded_to_stereo_and_never_folded` |
| 10 | Flow 能力表 | §5.2 的 N/P/D/R/M/— 逐格；5.1S↔5.1B 为 `R` | `ROUTE_TABLE` 逐格实现；未定义格返回 `route_unsupported` | 已关闭；`test_contract_endpoint_capability_cells` |
| 11 | DoIO 帧数 | 接受 `0..4096`；buffer Set 仍 `15..4096` | `accept_io_frames` 允许 0；`set_buffer` 仍 15..4096 | 已关闭；`test_host_buffer_range_and_io_frames` |
| 12 | 5.1.2 | RES 8ch，明确命名 | `LAYOUTS["5.1.2"]`、`M_512_71`/`M_512_51S` 预留矩阵；不声明 R1 硬件 | 已关闭（RES 仅命名/模型，不阻塞首轮硬件） |

结论：模型/夹具/测试已对齐契约 v1，`run_offline_acceptance.py` 的 pass 表示**离线计划与夹具一致**；它仍不能证明 6/8ch device tap、真实端点分配或 5.1/7.1 声学。

## 1. 分层证据与不可替代关系

| 层级 | 要回答的问题 | 可接受证据 | 不能据此声称 |
|---|---|---|---|
| L0 源/解码层 | 播放器实际解码并报告/输出的源布局是什么？ | 播放器版本、轨道信息、`audio-params`、解码器报告布局、实际输出格式；暂停/seek/切轨记录 | 设备容器有 8 slot 就是 7.1；轨道标签是 5.1 就证明取得了 6 个独立声道 |
| L1 HAL/容器层 | 虚拟设备实际暴露了多少通道、什么 mask/label、逐通道 PCM、时钟/延迟？ | 设备 UID、channel count、mask、label 顺序、逐通道非零独立 PCM、buffer、period、`hfla`/`hflr`、stream latency | 设备枚举/属性可读等于源布局正确、浏览器采用或声学出声 |
| L2 Flow 路由层 | 按源布局和实际端点数选择了 identity/passthrough/downmix 哪条矩阵？ | 路由描述、矩阵系数、provenance、transformations、LFE policy、gain/clip 结果 | 路由矩阵通过等于真实扬声器方向/包围感通过 |
| L3 声学/端点层 | 每个声道实际去了哪个 HomePod/端点、方向、音画与音箱间同步如何？ | 端点 UID/位置、逐端点分配、同录视频/音频、A/V 偏差、音箱间同步、30 分钟漂移 | 发送 hash、离线矩阵、两只前置音箱的 downmix 等于 5.1/7.1 声学 |

L1 通过不等于 L2/L3；L2 矩阵通过也不等于 L3。报告必须分层写“实测/未测/失败/不可观测”，不能用一个“能响”覆盖。

## 2. 规范布局、label 顺序与 mask

canonical 顺序按 **契约 §3.1 / Apple HAL 语义**（不是 WAVE mask bit 升序）；label 是每个 slot 的权威身份。离线 WAV 的 mask 只是夹具载体，程序必须读 layout/UID 并断言 `channelOrder`。**顺序/重复/缺失不符即拒绝，不做自动重排。**

| 布局 | 通道 | 夹具 mask | `channelOrder`（slot 0..N-1） | 首轮状态 | 说明 |
|---|---:|---:|---|---|---|
| `mono` | 1 | `0x0004` | `M` | 必须 | `M` 不是 FC 别名；HAL 身份为 `kAudioChannelLayoutTag_Mono`，`0x0004` 仅离线载体 |
| `stereo` | 2 | `0x0003` | `FL, FR` | 必须 | 基线 |
| `3.0` | 3 | `0x0007` | `FL, FR, FC` | R1 | 3 音箱端点；源也可显式使用 |
| `4.0_quad` | 4 | `0x0033` | `FL, FR, BL, BR` | R1 | quad 使用 back；4.0 side 不在 R1 |
| `5.1_side` | 6 | `0x060F` | `FL, FR, FC, LFE, SL, SR` | R1 | 6ch 必须显式 side，不能只写 5.1 |
| `5.1_back` | 6 | `0x003F` | `FL, FR, FC, LFE, BL, BR` | R1 | 与 side 同通道数、不同 slot 身份 |
| `7.1` | 8 | `0x063F` | `FL, FR, FC, LFE, SL, SR, BL, BR` | R1 | **side 在 back 前**；8ch 必须显式 7.1 |
| `5.1.2` | 8 | `0x560F` | `FL, FR, FC, LFE, SL, SR, TFL, TFR` | RES | 与 7.1 同为 8ch，必须显式命名 |
| `7.1.2` | 10 | `0x563F` | `FL, FR, FC, LFE, SL, SR, BL, BR, TFL, TFR` | RES | 10ch 不得写成 5.1.4 |
| `7.1.4` | 12 | `0x2D63F` | `FL, FR, FC, LFE, SL, SR, BL, BR, TFL, TFR, TRL, TRR` | RES | 顶部后为 **TRL/TRR**，不是 TBL/TBR |

明确拒绝：裸 `5.1`/`6ch`、裸 `8ch`、裸 `10ch`、裸 `12ch`、`5.1.4`、`TBL/TBR`、未知 label、重复 label、缺失 label、side/back 互换顺序、mask=0。当前 Swift `ChannelLabel` 只有 `FL/FR/FC/LFE/SL/SR/BL/BR/unknown`；`M` 与 10/12 的 `TFL/TFR/TRL/TRR` 需要后续驱动模型扩展，首轮不因此阻塞离线验收。

## 3. 源优先路由规则

| 层 | 条件 | 结果 | 报告要求 |
|---|---|---|---|
| 捕获 | 源布局 == 容器布局 | `identity`，同名同 slot | `source_native`；`nativeClaim` 仅 decoder/device+verified |
| 捕获 | 源 label 集合 ⊂ 容器 label 集合 | `pad_silent`，目标独有 slot 精确 `+0.0` | `source_padded`；stereo 例外 `stereo_passthrough_in_multichannel` |
| 捕获 | 源通道数 > 容器 | `refused` | `source_exceeds_container`；不 downmix |
| 捕获 | 同通道数不同 label / 目标缺源 label | `refused` | `container_layout_mismatch`；不 remap |
| 捕获 | 未知/歧义 | `refused` | `unsupported_layout` / `source_layout_ambiguous` |
| Flow | 同布局且端点足够 | `native` | 不改通道 |
| Flow | 源是端点精确子集 | `padded` | 未用通道静音 |
| Flow | 有注册 downmix 矩阵 | `downmix` | `losses` 列出折叠/丢弃 |
| Flow | 5.1S↔5.1B / 4.0→5.1S | `layout_remap` | 显示“位置重映射”，不是原生 |
| Flow | mono 目标 | `mono_map` | 不是影院上混 |
| Flow | 无注册矩阵 | `route_unsupported` | 不得临时发明 |

### 3.1 Flow 源布局 × 端点布局能力表（契约 §5.2）

`N`=native，`P`=padded，`P/U`=默认 padded、仅显式 upmix 时 U，`D`=downmix，`R`=layout remap，`M`=mono map，`—`=拒绝 `route_unsupported`。这是 Flow 端点表，不是捕获表；捕获容器必须先完整承载源。

| 源 \ 端点 | ST(2) | 3.0(3) | 4.0(4) | 5.1S(6) | 5.1B(6) | 7.1(8) |
|---|---|---|---|---|---|---|
| `mono` | `M` | `M`(FC) | `M`(FL/FR/BL/BR) | `M`(FC) | `M`(FC) | `M`(FC) |
| `stereo` | `N` | `P` | `P` | `P/U` | `P/U`* | `P/U` |
| `3.0` | `D` | `N` | `—` | `P` | `P` | `P` |
| `4.0` | `D` | `—` | `N` | `R` | `P` | `P` |
| `5.1S` | `D` | `—` | `—` | `N` | `R` | `P` |
| `5.1B` | `D` | `—` | `—` | `R` | `N` | `P` |
| `7.1` | `D` | `—` | `—` | `D` | `D` | `N` |

\* 契约只注册 `M_ST_51S`/`M_ST_71`；5.1B 的 `U` 没有注册矩阵，模型按 `P` 或 `transform_unavailable` 处理。

关键点：

- `mono` 的 `M`：到 stereo `L=R=0.707107*M`；到 3.0/5.1/7.1 只进 FC；到 4.0 四个端点各 `0.5*M`。不是原生多声道。
- 6 端点时，源 `5.1B` 选 back、`4.0` 也选 `5.1B`（`P`）；其他源选 `5.1S`。
- `7.1 -> 6` 是 `D`，`losses.downmixed=[BL,BR]`（或 back 端点的 `[SL,SR]`），LFE 保留。
- `4.0 -> 5.1S` / `5.1S↔5.1B` 是 `R`；必须先进入 7.1 容器提供缺失标签，再由 Flow remap。
- `3.0 -> 4.0`、`4.0 -> 3.0`、`5.1 -> 3.0/4.0` 在 R1 为 `—`，拒绝。

### 3.2 立体声进入 5.1/7.1（仅 fallback 组）

捕获层默认是 **pad_silent**：`FL=L, FR=R`，FC/LFE/SL/SR/BL/BR 精确 `+0.0`，`provenance=stereo_passthrough_in_multichannel`。Flow 的 `provenance=upmix` 只在 `mode=upmix` 时启用，使用契约 `M_ST_51S`/`M_ST_71`：

```text
FL  = 0.707107*L
FR  = 0.707107*R
FC  = 0.353553*(L+R)
SL  = 0.5*(L-R)
SR  = 0.5*(R-L)
LFE = 0
```

`M_ST_71` 另将 `BL/BR` 保持 0。两者都不是 Dolby/DTS/原生多声道，必须显示“上混（非原生）”。

## 4. 矩阵系数、LFE、增益与削波

### 4.1 通用规则

- 同名 label 直通系数 1。
- 所有矩阵按契约 §5.3 注册表；**不再使用通用 1/√2 角色折叠**。例如 7.1 -> 5.1 直接定义 `SL=0.5*SL+0.5*BL`。
- 每行 `Σ|coeff| ≤ 1`（精确公式保证；`M_MONO_2` 为 `1/√2`）。不额外乘安全增益，不做 limiter/响度归一化。
- LFE：
  - 目标有 LFE slot：`M_71_6`/`M_71_6B` 等按 1.0 保留。
  - 任何到 stereo 的 downmix：**丢弃 LFE**，写入 `losses.discarded=["LFE"]`，不折入 L/R。
  - stereo 上混：`LFE=0`，不合成。
  - 不做低音管理、分频、LFE+10dB 或 LFE fold。
- 数字静音：未使用 slot 精确 `+0.0`；真实路径要求 ≤ `-120 dBFS`。
- 削波：矩阵后 full-scale 所有源声道同时输入，输出峰值必须 `≤ 1.0`；WAV 写入器对 `|x|>1` 抛 `ClippingError`。

### 4.2 代表性系数

```text
7.1 -> 5.1_side (M_71_6):
  FL/FR/FC/LFE = 1
  SL = 0.5*SL + 0.5*BL
  SR = 0.5*SR + 0.5*BR

7.1 -> 5.1_back (M_71_6B):
  BL = 0.5*BL + 0.5*SL;  BR = 0.5*BR + 0.5*SR

3.0 -> stereo (M_30_2):
  FL = 0.585786*FL + 0.414214*FC
  FR = 0.585786*FR + 0.414214*FC

4.0 -> stereo (M_40_2):
  FL = 0.585786*FL + 0.414214*BL
  FR = 0.585786*FR + 0.414214*BR

5.1_side -> stereo (M_51S_2):
  FL = 0.414214*FL + 0.292893*FC + 0.292893*SL
  FR = 0.414214*FR + 0.292893*FC + 0.292893*SR

7.1 -> stereo (M_71_2):
  FL = 0.414214*FL + 0.292893*FC + 0.146447*SL + 0.146447*BL
  FR = 0.414214*FR + 0.292893*FC + 0.146447*SR + 0.146447*BR

mono -> stereo (M_MONO_2):  L = R = 0.707107*M
mono -> 4.0 (M_MONO_40):    FL=FR=BL=BR = 0.5*M

4.0 -> 5.1_side (M_40_51S): FL=FL; FR=FR; SL=BL; SR=BR; FC=LFE=0
5.1_side -> 5.1_back (M_51S_6B): BL=SL; BR=SR
5.1_back -> 5.1_side (M_51B_6):  SL=BL; SR=BR

7.1.2 -> 7.1 (RES): FL = 0.5*FL + 0.5*TFL; FR = 0.5*FR + 0.5*TFR
7.1.4 -> 7.1.2 (RES): TFL = 0.5*TFL + 0.5*TRL; TFR = 0.5*TFR + 0.5*TRR
```

## 5. 确定性夹具与期望电平

所有源夹具为 48 kHz、1.0 s、16-bit WAVE_FORMAT_EXTENSIBLE，每通道一个不同整数 Hz 正弦，峰幅度 `A=0.25`。1 s 内每个频率整数周期，窄带投影可精确区分通道。

| label | M | FL | FR | FC | LFE | SL | SR | BL | BR | TFL | TFR | TRL | TRR |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Hz | 557 | 317 | 431 | 557 | 61 | 733 | 863 | 977 | 1103 | 1301 | 1451 | 1601 | 1751 |

注意：`mono` 的 `M` 与 5.1/7.1 的 `FC` 都是 557 Hz，但二者不会出现在同一 layout；分析时按“源布局 + 期望 JSON + `channelOrder`”区分，不能只看频率猜布局。顶部后是 `TRL/TRR`（1601/1751），不存在 `TBL/TBR`。

### 5.1 代表性期望电平（peak amplitude）

| 案例 | 期望 |
|---|---|
| `mono -> stereo` mono map | FL/FR 各 `0.176777@557`；其余 = 0 |
| `mono -> 4.0` mono map | FL/FR/BL/BR 各 `0.125@557`；其余 = 0 |
| `stereo -> 5.1_side` padded（fallback） | FL `0.25@317`，FR `0.25@431`；其余 = 0 |
| `5.1_side -> 7.1` passthrough | FL/FR/FC/LFE/SL/SR 各 `0.25` 本通道 tone；BL/BR = 0 |
| `4.0_quad -> 5.1_back` passthrough | FL/FR/BL/BR 各 `0.25`；FC/LFE = 0 |
| `4.0_quad -> 5.1_side` remap | FL `0.25@317`、FR `0.25@431`、SL `0.25@977`、SR `0.25@1103`；FC/LFE = 0 |
| `7.1 -> 5.1_side` downmix | FL/FR/FC/LFE `0.25`；SL `0.125@733 + 0.125@977`；SR `0.125@863 + 0.125@1103` |
| `5.1_side -> stereo` downmix（LFE 丢弃） | FL `0.103553@317 + 0.073223@557 + 0.073223@733`；FR 对应 431/557/863；61 Hz = 0 |
| `7.1 -> stereo` downmix（LFE 丢弃） | FL `0.103553@317 + 0.073223@557 + 0.036612@733 + 0.036612@977`；FR 对应 431/557/863/1103 |
| `7.1.2 -> 7.1` downmix | FL `0.125@317 + 0.125@1301`；FR `0.125@431 + 0.125@1451`；FC/LFE/BL/BR/SL/SR 各 `0.25` |
| `stereo -> 5.1_side` upmix fallback | FL `0.176777@317`，FR `0.176777@431`；FC `0.088388@317 + 0.088388@431`；SL/SR 各 `0.125@317 + 0.125@431`；LFE = 0 |

每个 case 的完整 per-slot/per-tone 期望在 `expected/<case>.json`；离线工具按该 JSON 做数值断言，不靠人眼看表。

## 6. 总测试矩阵

生成器共生成 **84 个 case**：A 身份 10、B `source_padded` 20、C Flow downmix 11、D layout remap 3、E mono map 6、F stereo upmix 2、G 端点能力 28、H 预留 height 端点 4。捕获拒绝（`source_exceeds_container` / `container_layout_mismatch`）是负向检查，不生成可渲染 expected。

### 6.1 源/容器主矩阵

| 组 | 覆盖 | 夹具 | 期望 | 通过判据 | 证据 |
|---|---|---|---|---|---|
| A 身份 | mono/stereo/3.0/4.0/5.1S/5.1B/7.1/5.1.2/7.1.2/7.1.4 -> 同布局 | 对应 `*_source.wav` | 每 slot 本通道 `0.25` tone；无额外通道 | count/mask/`channelOrder` 一致；crosstalk ≤ -50 dB；peak ≤ 1；只有 identity 才是 native | WAV SHA、expected JSON、analyzer JSON |
| B `source_padded` | stereo/3.0/4.0/5.1/7.1/height -> 含全部源标签的更大容器 | 源夹具 + expected | 源 slot `0.25`；目标独有 slot 精确 0 | `provenance=source_padded`（stereo 例外）；目标独有 slot ≤ -50 dB；native=false（stereo） | 同上；capture 描述 |
| C Flow downmix | 3.0/4.0/5.1S/5.1B/7.1 -> stereo；7.1 -> 5.1S/5.1B；RES height folds | 源夹具 + expected | 按 §4.2 矩阵；例如 7.1->5.1 每 surround 两个 `0.125` | 系数/电平匹配；`losses` 完整；L1≤1；无 native 声明 | 矩阵 JSON、expected JSON、analyzer |
| D layout remap | 4.0 -> 5.1S；5.1S <-> 5.1B | 源夹具 | `M_40_51S` / `M_51S_6B` / `M_51B_6` | `provenance=layout_remap`；显示“非原生”；L1≤1 | 同上 |
| E mono map | mono -> stereo/3.0/4.0/5.1/7.1 | mono | `M_MONO_2` / `M_MONO_FC` / `M_MONO_40` | `provenance=mono_map`；不是影院上混；L1≤1 | 同上 |
| F stereo upmix | stereo -> 5.1S/7.1，仅显式 `mode=upmix` | stereo | 见 §3.2 | `provenance=upmix`；LFE=0；native=false | 同上 |
| G 端点能力 | 契约 §5.2 的有效格（7 源 × 2/3/4/6/8） | 7 源 | 见 §3.1 | mode/target 正确；L1≤1；2 端点 surround 只允许 `stereo_downmix` | 端点矩阵 JSON、WAV 子集 |
| H 预留 height | 7.1.2/7.1.4 identity、10->8、12->10 | 10/12ch | TFL/TFR/TRL/TRR 折叠 | RES；不作为首轮硬件门槛；矩阵/L1 仍须通过 | 工具输出 |

### 6.2 负向/拒绝矩阵

| 输入 | 期望错误 | 说明 |
|---|---|---|
| `unknown` 布局 | `unsupported_layout` | 不在白名单 |
| 裸 `5.1`/`6ch` | `source_layout_ambiguous` | side/back 未说明 |
| 裸 `8ch` | `source_layout_ambiguous` | 7.1/5.1.2 未说明 |
| 裸 `10ch`/`12ch` | `source_layout_ambiguous` | 必须显式 7.1.2 / 7.1.4 |
| `5.1.4` | `unsupported_layout` | 首轮不支持；10ch 是 7.1.2 |
| labels `FL,FR,FC,LFE,SR,SL` | `unsupported_layout` | slot 顺序错误，不自动重排 |
| 重复 label | `duplicate_label` | slot 身份不唯一 |
| 捕获 5.1S -> 5.1B / 5.1B -> 5.1S | `container_layout_mismatch` | 同宽不同身份，捕获层禁止静默重标 |
| 捕获 4.0 -> 5.1S | `container_layout_mismatch` | 5.1S 容器无 BL/BR；不 remap |
| 捕获 7.1 -> 5.1S/5.1B | `source_exceeds_container` | 捕获层不 downmix；改用 7.1 容器 |
| 捕获 mono -> 任意多声道 | `container_layout_mismatch` | M 无同名 slot |
| Flow 3.0 -> 4.0 / 4.0 -> 3.0 / 5.1 -> 3.0/4.0 | `route_unsupported` | 契约 §5.2 为 `—`，不得临时发明 |
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
| DoIO 帧数 | 接受 host 可变帧数 | **0..4096 接受**；负数/>4096 拒绝；不假设 512 |
| zero timestamp period | 16384，独立于 buffer | 改 buffer 不改变 period；时间戳不倒退/不虚构未来 |
| 两 scope stream latency | 同一值 | global/output 均同值；不是两份延迟相加 |

## 7. 首轮必须通过 vs 硬件不足暂不能验

### 7.1 首轮必须通过（离线 + 当前 Mac 两台 HomePod 可覆盖的部分）

1. 虚拟声卡输入层：1/2/4/6/8 源布局可被描述，mask/label 正确；6ch side/back 可区分；10/12 只要求模型/预留检查，不要求硬件。
2. 源少于容器：捕获 `pad_silent` 只占同名 slot，目标独有 slot 精确 `+0.0`；provenance `source_padded`；不得把容器宽度报成源布局。
3. 源多于容器：捕获拒绝 `source_exceeds_container`；Flow 才按注册矩阵 downmix，`losses` 记录折叠/丢弃；无静默丢声道。
4. 未知/歧义布局拒绝；静音/活动数不推断布局；同宽不同身份拒绝。
5. 逐通道独立标识：不同 tone/通道，crosstalk ≤ -50 dB，peak ≤ 1；LFE/增益/削波按第 4 节。
6. stereo -> 5.1/7.1：捕获默认 `pad_silent`（`stereo_passthrough_in_multichannel`）；Flow 显式 `mode=upmix` 才用 `M_ST_51S`/`M_ST_71`，且不得报 native。
7. 两台 HomePod：可验证 `5.1/7.1 -> stereo` downmix、FL/FR 前置路由、两台间同步；不得宣称 5.1/7.1 声学。
8. 每设备 latency/revision、buffer Set 15..4096、**DoIO 0..4096**、period 16384 独立、两 scope latency 同值。
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
| `multichannel_model.py` | 契约 v1 布局/`channelOrder`、捕获 identity/pad/refuse、Flow 路由表/矩阵/losses、端点矩阵、latency/buffer；无 I/O |
| `multichannel_wav.py` | 16-bit WAVE_FORMAT_EXTENSIBLE 读写、确定性 tone 生成、窄带投影/RMS/peak/DC |
| `make_multichannel_fixtures.py` | 生成 10 个源 WAV（含 5.1.2）+ 84 个 `expected/<case>.json` + manifest；拒绝覆盖 |
| `analyze_multichannel_capture.py` | 逐通道 tone/串扰/DC/clip，并断言 `channelOrder`；mask 未知默认失败 |
| `run_offline_acceptance.py` | 一键跑 84 case、捕获/端点/拒绝/latency/buffer/layer、20 个 WAV 抽样；不播放 |
| `test_multichannel.py` | 26 项 unittest；覆盖 M/7.1 顺序/height、捕获拆分、Flow 表、LFE、削波、端点、DoIO、三层声明、夹具/分析器 |

命令与本次结果（Windows Python 3.10.0，未播放/未采集/未改设备）：

```text
python -m unittest discover -s tests/virtual_audio -p test_multichannel.py -v
  -> Ran 26 tests ... OK

python tests/virtual_audio/run_offline_acceptance.py
  -> status=pass; fixture_case_count=84; sections matrix/capture/endpoint/
     latency/buffer/layers/wav/clipping/rejections all pass; 20/20 WAV samples;
     20/20 rejection checks

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
  --expected <fixtures>/expected/MC-C06.json
```

默认阈值：相对 3% 或绝对 0.002 peak（取较大者）；非期望 tone ≤ -50 dB（相对最大期望）；DC ≤ 0.002；peak > 1 判 clip；WAV 无 mask 默认失败（`--allow-unknown-mask` 仅标记 `pass_unverified_mask`，不能当 label 身份通过）。

## 10. 证据采集清单（每个真实 case）

1. **源**：播放器/版本、文件或流、轨道、`decoderReportedFormat`/`sourceLayout`、实际输出格式、pause/seek/切轨、是否 downmix/upmix、源时钟。
2. **容器**：设备 UID、count、mask、labels、rate、buffer、zero period、`hfla`/`hflr`、device/stream/safety latency、逐通道 PCM 的 RMS/peak/tone。
3. **路由**：目标布局/端点数、native/padded/downmix/layout_remap/mono_map/upmix、矩阵 ID/系数、`losses`、provenance、L1/headroom、limiter/clip。
4. **端点/声学**：端点 UID/位置、逐端点分配、同录视频+音频、A/V 偏差、端点间同步、30 分钟漂移。
5. **报告分层**：L0/L1/L2/L3 分别写实测/未测/失败/不可观测；不得用 L1 枚举或 L2 矩阵代替 L3。
6. **不可替代声明**：两台 HomePod 的 5.1/7.1 结果只能写 `stereo_downmix`/`2.0`，不能写 5.1/7.1 声学通过。

## 11. 仍未验证/下一门槛

- architect `MULTICHANNEL_CONTRACT.md` v1 已冻结；离线模型/夹具/测试已按 §0.1 逐项对齐，但**尚未**做真机 6/8ch 验证。
- 6/8ch HAL 设备实现、真实 channel layout、逐通道独立 PCM、稳定时钟/延迟 revision。
- Flow 输入目前只有 HPCM v1 stereo；需要 HPCM v2/协商与旧 worker 拒绝未知版本。
- 播放器真实多声道解码/输出；浏览器采用；DRM；真实 6/8/10/12 端点与声学。
- 10/12 height label 的 Swift 模型扩展；5.1.4/5.1.2 首轮不承诺。
- 动态 limiter/真实节目响度策略未定；本文只用静态 L1 cap 作为无削波参考。

## 12. 变更记录

- 2026-11-06：首版源优先验收设计。覆盖 1/2/4/6/8 源、3.0/4.0 辅助、10/12 预留；84 个离线 case；20 个 WAV 抽样；26 项 unittest；明确两台 HomePod 只能验证 downmix/前置，不能宣称 5.1/7.1 声学。
- 2026-11-06（契约 v1 对齐）：mono 改 `M`；7.1 改 `FL FR FC LFE SL SR BL BR` 并断言 `channelOrder`；捕获拆为 identity/pad_silent/refused，downmix/remap/upmix 移入 Flow；pad provenance 改 `source_padded`；height 补 5.1.2 并改 `TRL/TRR`；矩阵按契约 §5.3 重算；能力表按 §5.2 逐格实现；DoIO 放宽到 0..4096。84 case 与 26 tests 重跑通过。
