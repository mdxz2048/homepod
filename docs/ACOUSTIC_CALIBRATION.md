# HomePod Flow 声学延迟测量方案与算法

本文描述影院模式下逐台测量 HomePod 延迟、写入 Flow 声卡的完整方案。目标是：不要求房间安静、不依赖人耳试听，用一段已知测试音在真实房间中稳定找到直达声到达时刻，并给出可复验的毫秒级延迟。

## 1. 目标与约束

- 测的是 **Mac 注入测试音 → AirPlay 接收器 → 房间 → 麦克风** 的整条链路延迟，而不是链路中某个软件缓冲区。
- 测试音是**已知信号**，分析端持有同一份原始 WAV 及其逆滤波；定位靠匹配滤波，不靠“房间安静”或“峰值最大”。
- 一次测量必须给出：直达声到达时间、六段之间的一致性（波动/漂移）、置信度，以及失败时的可复现录音。
- 多台音箱分别测量，再用相对残差做补偿；不复用同一段录音测多台，避免互相污染。
- 绝对延迟含麦克风路径（内置麦克风或 iPhone Continuity）的固定偏移；多台之间的**相对差**不受该固定偏移影响。

## 2. 测试信号

外部 WAV，不在运行时合成。播放与分析读取同一组文件。

| 项目 | 值 |
|---|---|
| 默认信号 | 对数扫频 `log-sweep`（Farina 风格） |
| 单元长度 | 1.0 s |
| 重复次数 | 6 |
| 单元间隔 | 0.6 s |
| 单元周期 | 1.6 s |
| 连续测试音总长 | 6×1.0 + 5×0.6 = **9.0 s** |
| 注入后起始偏移 | 1.0 s（`CONTINUOUS_START`） |
| 采样率 | 44.1 kHz / 48 kHz 两套独立文件 |
| 峰值 | 0.5（约 −6 dBFS） |
| 边界处理 | 每段 10 ms 余弦淡入淡出 |
| 分析频带 | 300–6000 Hz |

可选信号：线性扫频、粉红噪声。默认使用对数扫频，因为它对扬声器/房间的相位失真最稳健，且有配套逆滤波。

来源、许可证与 SHA-256 记录在 `adapters/calibration/assets/SOURCES.md`；Swift 播放与 Python 分析对同一文件逐样本一致。

## 3. 播放路径

1. 系统默认输出临时切到 `HomePod Flow Audio`（8 声道虚拟设备）。
2. 每次只选一台目标音箱；测试音通过虚拟设备进入 AirPlay 发送链路。
3. 播放端按约定时间注入，记录 `injection_ns`（宿主 monotonic 时钟）。
4. 名义呈现延迟 `nominal_ms` 默认 2000 ms；实际计划呈现时刻由协商的 latency samples 决定。
5. 播放结束后停止该路流，再测下一台。

音量在整轮测试中固定；UI 明确提示“需要调整时先停止再重测”。

## 4. 采集与时钟

- 麦克风：Mac 内置麦克风或 iPhone Continuity 麦克风。
- 采集端按 512 帧记录一次 `(frame, ns)`，形成 `clock.json`。
- `first_sample_ns` 是录音第一帧的宿主时间；`frame ↔ ns` 用分段线性映射：
  - `frame_at_time(ns)`：找到 ns 所在的 clock 区间，线性插值到帧号。
  - `time_at_frame(frame)`：找到 frame 所在的 clock 区间，线性插值到 ns。
- **时钟连续性检查只覆盖测试音窗口**：`injection_ns − 0.25 s` 到 `injection_ns + 12 s`。
  - 对每个 clock 步长计算 `Δns − Δframe/rate × 1e9`；
  - 与该窗口内中位数偏差超过 **3 ms** 才判失败。
  - 目的：Continuity 麦克风在录音开始时常见的几毫秒重同步不应误伤后面 3 秒才开始的测试音。

## 5. 定位算法

对每一段 1 s 单元、每一个候选播放速率：

1. 取该段原始模板，按 `speed` 重采样到 `len(unit) × speed`。
2. 计算期望到达时刻：
   `expected = injection_ns + (1.0×speed + index×1.6×speed + target/1000) × 1e9`
   其中 `target` 首测时为 `nominal_ms`，复验时为上一轮校准目标。
3. 在 `expected ± 550 ms` 内取录音窗口（`MATCH_RADIUS_MS = 550`）。
4. 用与扫频配套的**逆滤波**做卷积（匹配滤波），得到脉冲响应。
5. 以至少 2 ms 间隔找峰；只保留残差在 ±550 ms 内的峰。
6. 取最强峰；把所有幅度 ≥ 最强峰 **85%** 的峰按时间排序，取**最早**的一个作为直达声。
   - 房间反射常常达到直达声的 81%–99%，不能因为“次峰很强”就把整段判废。
   - 直达声通常是最强峰或略弱于最强反射，因此“最早达到 85%”比“直接取最强”更接近真实到达。
7. 计算该峰的：
   - `score`：录音段与模板的归一化波形相关（0–1），作为置信度；
   - `psr`：峰值 / 逆滤波输出中位数；
   - `second_ratio`：次强峰 / 最强峰；
   - `direct_ratio`：所选直达峰 / 最强峰；
   - `residual_ms`：到达时刻 − 期望时刻。

## 6. 速度搜索

AirPlay 接收端、采样率转换和接收器时钟会让实际播放速率相对模板有约 ±0.5% 的偏差。逐段独立搜索会过拟合，因此用**整组六段共享一个 speed**，并要求六段几何一致。

粗搜索候选：

`1.0, 0.995, 0.9975, 1.0025, 1.005, 0.99, 1.01, 44100/48000, 48000/44100, 0.96, 1.04`

再以最优候选为锚点，按 `±0.4%` 内 14 个步长细化。

每个候选的评分：

```
spread = max(residuals) − min(residuals)
drift  = polyfit(index × 1.6 s, residuals, 1).slope
confidence = min(score of accepted units)
utility = 20×n − spread − 4×|drift| + 5×confidence
```

选 `utility` 最大者。这样“六段都能找到但每段晚 6 ms”的错误速度会因 drift/spread 惩罚而输给“残差平直”的正确速度。

## 7. 有效性判据与弱信号回退

常规路径（保持原有严格标准）：

- `|residual| ≤ 552 ms`
- `score ≥ 0.15`
- `psr ≥ 3`
- 至少 4/6 段有效
- 最终 `spread ≤ 12 ms` 且 `|drift| ≤ 1.5 ms/s`

弱信号回退（仅当常规路径失败或最终几何不一致时启用）：

- `|residual| ≤ 552 ms`
- `score ≥ 0.05`
- `psr ≥ 20`
- 至少 5/6 段有效
- 最终 `spread ≤ 10 ms`、`|drift| ≤ 1.0 ms/s`、`confidence ≥ 0.05`
- 报告中标记 `fallback = "weak-signal"`

设计理由：在强反射、远距离或麦克风增益较低时，直达+反射叠加会让**波形相关系数**降到 0.1 左右，但逆滤波峰仍然非常尖锐（PSR 可达数百）。此时应相信“已知测试音的匹配峰 + 六段几何一致性”，而不是波形相似度。回退要求 5/6 段且几何更严，噪声不会因为阈值放宽而通过。

## 8. 延迟计算

对六段 `(t_i, residual_i)` 做一次线性拟合：

```
residual_i ≈ start_delay + drift × t_i
```

- `start_delay`：拟合线在 t=0 的截距，即第一段单元的残差。
- `drift`：每秒漂移，用于判断接收端/麦克风时钟是否稳定。
- 最终残差：`residual = start_delay + target − nominal_ms`
- 最终测得：`measured_ms = nominal_ms + residual_ms`

首测时 `target = nominal_ms`，因此 `measured_ms` 就是“注入 → 麦克风到达”的绝对时间。复验时 `target` 是已写入声卡的补偿目标，测得值应与目标一致。

单台结果有效性（`SpeakerLatencyMeasurement.isValid`）：

- `measured_ms`、`nominal_ms` 在 0–3000 ms；
- `residual_ms` 在 −250–750 ms；
- 单次六段 `spread_ms` 在 0–12 ms；
- `confidence` 在 0.12–1.001；
- `measured ≈ nominal + residual`（误差 <0.1 ms）。

## 9. 多台补偿与逐台复验

- 每台独立测量，得到各自的 `residual_ms`。
- 取所有音箱的最大残差作为公共基准：
  `common = max(residual_i)`
- 每台补偿量：
  `compensation_i = common − residual_i`
  即到达较早的音箱被额外延迟，最终对齐到最慢的一台。
- 首测完成后进行**逐台复验**：把补偿后的目标写入声卡，再逐台重测一次，确认实际到达与目标一致。
- 验收容忍度：音箱间差异与目标误差都允许 **100 ms**（`CalibrationVerification.toleranceMS`）。
  单台两次测量因 AirPlay 新建流的缓冲差异通常有 10–25 ms 漂移，属于该范围内正常现象；单次测量内部的六段波动仍限制在 12 ms。

## 10. 失败诊断与录音保留

任何一段失败或整轮失败都会保留：

- `failed-probe-<时间>-<code>.f32`：原始麦克风 PCM；
- `.clock.json`：帧/时间戳；
- `.json`：`first_sample_ns`、`injection_ns`、`nominal_ms`、`probe_kind`、`probe_rate`、`signal_version`、每段 matches（score、PSR、second/direct ratio、residual、speed）与最终 metrics。

最多保留最近 **6 组**失败录音，避免重复失败把第一台的有效证据删掉。报告写入 `~/Library/Application Support/HomePod Flow/Diagnostics/calibration-last-run.json`。

## 11. 隐私与文件访问

App 只访问以下位置：

- `~/Library/Application Support/HomePod Flow/`：校准结果、诊断报告、Runtime 配置；
- 系统临时目录：测试录音与时钟文件，分析后删除（失败时按上限保留）；
- `/Library/Audio/Plug-Ins/HAL/`：检查音频组件是否安装；
- 显式的安装包路径：环境变量、App 内置资源、App 同目录、`/Users/Shared` 或 `/Applications` 下的固定文件名。

**不再扫描 Downloads、Desktop、Documents，也不枚举用户目录。** 此前“安装音频组件”按钮为寻找 `HomePodFlow-*` 安装包会列目录，触发 macOS 的“访问下载/桌面”提示；该逻辑已删除。

## 12. 测试

- `tests/test_acoustic_calibration.py`、`tests/test_continuous_calibration.py`：27 项，覆盖合成直达/反射、噪声、削波、时钟断裂、单段缺失、速度偏移、外部 WAV 一致性。
- 真实录音回归：2026-11-21 两份失败录音（小白/小黑）在修复后分别得到 2444.3 ms / 1.43 ms 与 2418.1 ms / 2.58 ms。
- 实机多台：客厅、小白、小黑单轮波动 0.07–4.1 ms；复验因 AirPlay 缓冲差异出现 17–22 ms 漂移，按 100 ms 容忍度通过。

## 13. 已知边界与后续

- 单次测量仍可能被一声突发噪声污染一段；当前策略是判失败而不是给出错误值。后续可在“次大偏差 <4 ms 且最大偏差 >8 ms”时只剔除该孤立段。
- AirPlay 每次新建流的缓冲起点不同，单台重复测量有 10–25 ms 漂移；需要更紧的音画同步时，可增加第三轮取中位数，或锁定接收端缓冲后再测。
- 绝对延迟包含麦克风路径固定偏移；跨麦克风比较前需要用同一支麦克风复测。
