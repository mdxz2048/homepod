# LIVE PCM 协议 v2：解析器落地细节

日期：2026-11-06。状态：HPCM v2 离线校验器已实现并测试；未改 HPCM v1、core C ABI v1、driver/input/App，也未做任何采集或播放。规范字段与拒绝语义以 [MULTICHANNEL_CONTRACT.md](virtual-audio/MULTICHANNEL_CONTRACT.md) §6 为准；本文只记录 §6 未展开的 framer 细节与本地错误码。

## 范围

- 实现：`adapters/live/pcm_v2.py`，独立 `read_frame_v2()` 与 `PCMV2Validator`。
- 测试：`tests/test_live_pcm_v2.py`。
- v1 文件 `adapters/live/pcm.py` 未改动；v1 消费者继续拒绝 v2，v2 消费者拒绝 v1 与未知版本。

## Framing

```text
4 bytes ASCII "HPCM"
uint32 LE headerLength   (1..16384)
uint32 LE payloadLength  (0..196608)
headerLength bytes UTF-8 JSON object
payloadLength bytes payload
```

- `MAX_HEADER_V2=16384`、`MAX_PAYLOAD_V2=196608`、`MAX_FRAMES=4096`。
- 只用 `readexactly`；prefix、header 或 payload 任一处短读均为失败，不重新搜索 magic、不跳过坏帧。
- JSON 拒绝重复键、NaN/Infinity、非 UTF-8；`v` 必须是整数且严格等于 2。
- 控制帧 `ready`/`stopped`/`error` 的 `payloadLength` 必须为 0；v2 解析器不在此层校验 `ready` 的布局字段，完整 ready 校验仍由控制层负责。

## 校验顺序

1. framing / magic / 长度 / 严格 JSON / 版本 / kind；
2. `id`、`session` 关联；
3. `outputRate=44100`、`outputChannels ∈ {1,2,3,4,6,8}`、layout token、`outputChannelOrder` 等于 §3.1 canonical 顺序；
4. `container` 的 UID/channels/layout/order 与 output 一致；
5. `source` 布局/顺序/声道数、v1 源时钟字段、`droppedBlocksBefore=0`、flags；
6. `captureTransform` 的 `placed`/`silentSlots` 必须精确分区容器，标签必须同名同 slot；
7. `provenance` 与 transform、authority、`nativeClaim` 的一致性；
8. session 内 layout/container/source/transform 不变；
9. `sequence`、`outputFrameStart`、`inputFramesConsumedTotal`、`sourceSequence` 连续性；
10. `payloadLength=frames*channels*4`；
11. Float32 LE 解码，逐样本有限且 `abs(x)≤1`，`pad_silent` 的 `silentSlots` 必须为数值零。

## 本地错误码

| code | 触发 |
|---|---|
| `truncated_frame` | prefix/header/payload 短读或 EOF |
| `invalid_framing` | magic 错误、headerLength=0 |
| `payload_too_large` | headerLength>16384 或 payloadLength>196608 |
| `invalid_header` | 严格 JSON、字段类型、枚举、bool 充整数等 |
| `unsupported_version` | `v` 非 2（含 v1 与 >2） |
| `stale_session` | id/session 不匹配 |
| `unsupported_format` | `outputRate≠44100` |
| `unsupported_channels` | 非 R1 声道集合 |
| `unsupported_layout` | 未知布局或 RES height |
| `source_layout_ambiguous` | `5_1_ambiguous` |
| `channel_map_mismatch` | 标签/顺序/placed/silentSlots 不一致 |
| `container_layout_mismatch` | container 与 output 不符，或源标签无同名 slot |
| `device_mismatch` | 已知规范 UID 与 layout 不符，或 session 内 UID 变化 |
| `source_layout_changed` | session 内 output/source/transform 变化 |
| `payload_mismatch` | 长度≠frames×channels×4；控制帧带 payload |
| `frame_continuity` | sequence/outputFrameStart 不连续 |
| `input_discontinuity` | droppedBlocks、源时钟/序号回退、source 元数据异常 |
| `invalid_pcm_range` | 非有限或 `abs(sample)>1` |
| `silent_slot_nonzero` | `pad_silent` 槽出现非零样本（本地细化码） |
| `transform_unavailable` | `captureTransform.kind=refused` 却带 PCM |

## 契约未写明、由本实现固定的细节

- `identity` 的 `placed` 为空表示隐式 same-label/same-slot 全映射；非空时必须逐项等于同名槽。
- `pad_silent` 必须映射全部源标签，`silentSlots` 必须是未占用槽的精确补集；`placed`/`silentSlots` 不要求排序，但不允许重复。
- `silentSlots` 的“精确 +0.0”按数值零校验；目前接受 IEEE `-0.0`，因为它是静音。若产品要求位模式严格 `0x00000000`，需另行收紧。
- 已知规范 deviceUID 必须匹配对应 layout；未知 UID（如 `.dev.` bundle）只做非空/长度校验，避免离线解析器绑定试验身份。
- `sourceLayoutVerified=true` 时要求 `source.evidence` 为非空有界字符串；解析器无法验证证据内容。
- `unknown_restricted` 未实现：`sourceLayout=unknown` 直接按 `unsupported_layout` 拒绝。这是 R1 的保守选择，不声称支持“仅前置 L/R”受限路径。
- 高度布局 5.1.2/7.1.2/7.1.4 与 10/12ch 一律拒绝（RES）。
- 不沿用 v1 的 250ms receipt/media 偏差预算；v2 解析器只验源字段合法性、序号/输入索引不回退。端到端时钟策略由会话层另行执行，避免把 v1 的单一 stereo 假设带入多声道。
- `nativeClaim=true` 仅在 `source_native`（decoder，或 device 且布局相同）或 `source_padded`（decoder）且 verified 时允许；`false` 不被视为错误。

## 已知歧义

1. §6 没有为 JSON/字段类型失败分配 contract 错误码；本地使用 `invalid_header`。
2. §6 说 `silentSlots` 必须“精确 +0.0”，未说明 `-0.0` 是否合法。
3. §6 未规定 `placed`/`silentSlots` 的排序是否规范，本地只要求集合精确、无重复。
4. §6 未说明 `sourceLayoutVerified=true` 是否必须携带 `evidence`，本地要求非空。
5. §6 未定义 `unknown_restricted` 的 header 细节（unknown_1..n 与容器 slot 关系），本地 R1 直接拒绝。
