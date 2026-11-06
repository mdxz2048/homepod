# 多声道源优先离线验收报告

日期：2026-11-06。Owner：virtual_qa。范围：仅共享工作区内的文档、Python 夹具与离线测试；**未 SSH、未播放/录音、未改系统设备、未安装、未提交/推送 Git**。本报告证明的是离线矩阵/夹具/拒绝逻辑，不是真实 5.1/7.1 播放或声学结果。

对应设计：[MULTICHANNEL_ACCEPTANCE.md](../../virtual-audio/MULTICHANNEL_ACCEPTANCE.md)

**契约状态：** architect `MULTICHANNEL_CONTRACT.md` v1 已冻结。本报告与离线模型是在该契约出现前完成的 provisional 源优先实现；与契约的 12 项明确冲突列在验收文档 §0.1。离线 pass 只证明 provisional 模型自洽，**不代表已对齐契约 v1**。

## 1. 本次边界

- 虚拟声卡按**输入能力层**验收：支持 1/2/4/6/8 源布局（3.0/4.0 辅助，10/12 height 预留），按权威 label 保留源声道，交给 Flow 路由。
- Flow 按“源布局 + 实际音箱数量/布局”做 identity/passthrough/downmix；两台 HomePod 只能验证 stereo downmix / FL/FR 前置 / 两音箱同步。
- **stereo -> 5.1/7.1 只是 D 组 fallback**，不是验收中心；默认仍是 passthrough（仅 FL/FR），显式 upmix 才生成 FC/SL/SR/LFE。
- 当前工作区只有 stereo 虚拟设备真机枚举/属性/Tap 证据；6/8ch 驱动、Flow HPCM v2、播放器/浏览器/声学均未实现或未验。

## 2. 交付文件

新增：

- `docs/collaboration/virtual-audio/MULTICHANNEL_ACCEPTANCE.md`
- `docs/collaboration/reports/VirtualAudio-2026-11-06/Multichannel-offline-acceptance-2026-11-06.md`（本文件）
- `docs/collaboration/reports/VirtualAudio-2026-11-06/multichannel-offline-acceptance.json`
- `tests/virtual_audio/multichannel_model.py`
- `tests/virtual_audio/multichannel_wav.py`
- `tests/virtual_audio/make_multichannel_fixtures.py`
- `tests/virtual_audio/analyze_multichannel_capture.py`
- `tests/virtual_audio/run_offline_acceptance.py`
- `tests/virtual_audio/test_multichannel.py`

修改：

- `docs/collaboration/virtual-audio/ACCEPTANCE.md`：增加指向多声道验收设计的链接，并注明当前驱动仍只声明 stereo 2ch。

未修改：driver、VirtualAudioInput、Flow/processing 生产代码、冻结核心 ABI、现有 `test_tools.py`。

## 3. 命令与结果

环境：Windows，Python 3.10.0。所有命令仅读写临时目录/测试输出，不播放、不采集、不联网。

```text
python -m unittest discover -s tests/virtual_audio -p test_multichannel.py -v
```

结果：`Ran 26 tests in 28.793s`，`OK`。

覆盖：

- canonical 布局/mask：mono、stereo、3.0、4.0 quad、5.1 side/back、7.1、7.1.2、7.1.4；
- label 顺序、重复/缺失、side/back 互换拒绝；
- 源窄于容器 passthrough、源宽于容器 downmix、无静默丢声道；
- LFE omit/fold/passthrough；
- L1 cap、full-scale 12ch -> 2 不削波、WAV 写入器拒绝 >1；
- 6 源 × 1/2/3/6/8 音箱端点矩阵；
- 每设备 latency/revision、buffer 15..4096、DoIO 可变帧数、period 16384；
- 三层声明门禁、false native claim；
- 夹具确定性、分析器能检出通道互换/串扰。

```text
python tests/virtual_audio/run_offline_acceptance.py
```

结果：`status=pass`，`fixture_case_count=84`；`matrix/endpoint/latency/buffer/layers/wav/clipping/rejections` 全部 pass；20/20 个抽样 WAV 通过；11/11 个拒绝检查通过。完整 JSON 见 `multichannel-offline-acceptance.json`。

```text
python -m unittest discover -s tests/virtual_audio -p test_tools.py -v
```

结果：`Ran 6 tests ... OK`（既有立体声素材/事件分析工具回归，未改代码）。

可选夹具命令（本次由验收工具在临时目录内部执行，未额外写仓库输出）：

```text
python tests/virtual_audio/make_multichannel_fixtures.py --output <不存在的新目录>
```

生成 9 个源 WAV（mono/stereo/3.0/quad/5.1 side/5.1 back/7.1/7.1.2/7.1.4）和 84 个 `expected/<case>.json`；不生成 MP4、不播放。

## 4. 离线已验证

| 项目 | 结果 | 证据 |
|---|---|---|
| 1/2/3/4/6/8/10/12 布局与 mask | PASS | `test_multichannel.LayoutTests`、manifest |
| side vs back slot 身份 | PASS | 5.1 side `SL/SR` 与 back `BL/BR` 分开；互换顺序拒绝 |
| 源窄于容器 passthrough | PASS | mono/stereo/quad/5.1/7.1 -> 更宽容器；目标独有 slot 静音 |
| 源宽于容器显式 downmix | PASS | 7.1->5.1、7.1->stereo、5.1->stereo、quad->3.0 等；无静默丢声道（LFE 省略记录） |
| 未知/歧义布局拒绝 | PASS | `unsupported_layout`/`ambiguous_layout`；静音推断单独拒绝 |
| 逐通道独立标识 | PASS | 12 个不同 tone；窄带投影；串扰阈值 -50 dB |
| LFE/增益/削波 | PASS | omit/fold/passthrough；每行 L1≤1；full-scale stress peak≤1 |
| 源 -> 1/2/3/6/8 音箱 | PASS | 6 源 × 5 数量端点矩阵；2 音箱 surround 只声明 `stereo_downmix` |
| 每设备 latency/revision | PASS（模型） | 改 A 不影响 B；同值幂等；重发现旧 revision 失效 |
| buffer 15..4096 / DoIO 可变帧数 / period 16384 | PASS（模型） | 15/16/255/256/512/1024/4096 接受；buffer 不改 revision；period 独立 |
| 三层声明分离 | PASS | stereo/5.1 容器不 native；两台 HomePod 的 5.1 只能 `stereo_downmix`；6 端点也需 measured 才能声学声明 |
| stereo fallback 仅一组 | PASS | D01/D02；默认 passthrough，upmix 标 `stereo_upmix_v1` 且 native=false |

## 5. 首轮必须通过 vs 硬件不足暂不能验

### 5.1 首轮必须通过（离线 + 当前 Mac 两台 HomePod 可覆盖部分）

1. 输入层 1/2/4/6/8 布局、mask/label、side/back 区分；10/12 只要求预留模型。
2. 源窄 passthrough、源宽 downmix、无静默丢声道、未知/歧义拒绝。
3. 逐通道独立 PCM、不同 tone、串扰 ≤ -50 dB、peak ≤ 1。
4. LFE omit/fold/passthrough 显式记录；L1 cap/削波保护。
5. stereo -> 5.1/7.1 默认 passthrough；显式 upmix 仅 fallback 且不得 native。
6. 两台 HomePod 的 downmix/FL-FR/两音箱同步；不得宣称 5.1/7.1 声学。
7. 每设备 latency/revision、buffer 15..4096、DoIO 可变帧数、两 scope latency 同值。
8. 三层报告分离。

### 5.2 硬件不足暂不能验

1. 真实 5.1 声学：需要 ≥6 个独立端点；当前只有两台 HomePod。
2. 真实 7.1 声学：需要 8 个独立端点。
3. 10/12 height：需要 10/12 端点或认证 height renderer。
4. side vs back 的声学方向、center 定位、LFE 融合、surround envelopment。
5. 6/8 端点间同步与 30 分钟漂移（当前只能测两台）。
6. 播放器真实 5.1/7.1 解码/输出、暂停/seek/切轨、DRM 兼容。
7. 浏览器采用与多声道 A/V 补偿、每端点声学延迟。
8. 真实 6/8ch HAL 设备枚举/逐通道 PCM；当前仅 stereo 设备。
9. 10/12 `TFL/TFR/TBL/TBR` 的 Swift `ChannelLabel` 模型扩展。

## 6. 仍未验证/下一门槛

- architect `MULTICHANNEL_CONTRACT.md` v1 已冻结；当前离线模型仍有验收文档 §0.1 的 12 项冲突（mono `M`、7.1 顺序、provenance、height 命名、捕获层 refuse、矩阵系数、LFE、DoIO 0..4096 等），未对齐。
- 6/8ch 驱动未实现；无真实多声道容器枚举、channel layout、逐通道 PCM、时钟/延迟 revision。
- Flow 输入仍 HPCM v1 stereo；需要 HPCM v2/协商和旧 worker 拒绝未知版本。
- 播放器适配（mpv/IINA/VLC 实际版本）与浏览器采用未验。
- 真实 6/8/10/12 端点、声学方向、30 分钟同步、DRM 未验。
- 动态 limiter/节目响度策略未定；本文只定义静态 L1 cap 作为无削波参考。

## 7. 结论

离线层已把“源优先”验收矩阵、确定性夹具、通道/label/矩阵/LFE/削波/端点/latency/buffer/三层声明门禁落地并可重复运行。它不能替代真实 6/8ch HAL、Flow 路由、播放器/浏览器或更多 HomePod 端点的验收；尤其两台 HomePod 只能证明 downmix/前置与两音箱同步，不能证明真实 5.1/7.1 声学。
