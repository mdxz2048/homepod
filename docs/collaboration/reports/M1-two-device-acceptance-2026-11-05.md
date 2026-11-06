# M1 两设备真机阶段独立验收

日期：2026-11-05。结论：新核心链路的两设备发送通过；用户确认两台实际出声、短时主观同步初筛通过。未进行录音测量，不代表量化同步、长期稳定或三台验收通过。

## 范围与基线

用户确认小黑 mini 未通电，明确授权先测试两台；这是本轮主动收敛范围，不是软件故障。前方“客厅”192.168.0.104 使用输入通道 0（440 Hz），右后“小白”192.168.0.115 使用通道 1（660 Hz），每路复制为双单声道。

链路为实际 C++ 核心 -> 版本化 C ABI -> Python ctypes -> native routed batch -> 自定义 CoreAudioSource -> pyatv AirPlay2/ALAC。未以旧原型独立播放代替正式核心。

验收 Agent 独立对比本轮 source-manifest.json、持久化 baselines/M1-core-source.json 及当前 27 个文件，全部一致，0 漂移。动态库 SHA-256：`cf0c342e9eae808765bb7d8f4f217ebf9e790228cffbf4077da24275e609173e`。实际发送使用 Mac Python 3.12.16 venv、pyatv 0.18.0、srptools 1.0.1。RTSP setup 后的音量确认补丁存在。

## 两次执行证据

播放由总协调执行，验收 Agent 未自行播放或修改代码。第一轮为用户授权低音量试验；第二轮按用户明确要求使用 100% 音量、10 秒。

| 检查 | 第一轮 | 第二轮 |
|---|---|---|
| 时长 / 音量 | 3 秒 / 15% | 10 秒 / 100% |
| native_core_used | true | true |
| prepared_receivers | 2 | 2 |
| 每路输入/消费帧 | 132300 / 132300 | 441000 / 441000 |
| 两路 PCM SHA-256 | 不同 | 不同 |
| 两路第一 presentation | 17376331798208 ns | 17466605308625 ns |
| 两路 shared start_ts | 176525048878660 | 176525052859756 |
| 每路首包 RTP | 66150 | 66150 |
| presentation-send origin | 1500000000 ns | 1500000000 ns |
| 音频包总数 / 非零包 | 1128 / 752 | 2882 / 2506 |
| cleanup_complete | true | true |
| 最终发送状态 | sender_completed_unverified_acoustically | sender_completed_unverified_acoustically |

独立审核确认：共同计划、两路不同内容、完整帧消费和清理均符合契约。每路协议 latency 为 66150 帧，44100 Hz，即 1.5 秒；core presentation 与 send origin 的差值正确。原始报告未逐设备记录最终 padding_sent，因此不虚构该数值；成功状态路径代码要求每台 padding_sent>=latency，且总包数与两路各 188 个尾部补零包（66176 帧）一致。此为发送证据，不是尾声实际出声的声学测量。

第一轮两路释放时刻差约 1.025 ms，第二轮约 0.923 ms，均为发送器调度记录，不能当作音箱实际声学误差。两轮释放均处于实现规定的 20 ms 容忍窗口内。

## 用户听感与结论

第一轮没有独立听感确认；用户要求加音量、加时长不能解释为已确认出声。

第二轮用户明确反馈：“两台都响，听起来基本同步”。据此记录两台实际出声及 10 秒短时主观同步初筛 Pass。两路不同内容由路由、不同 PCM 哈希及真实发送链路证明，未声称用户逐台进行了频率识别。

原始字段 acoustic_sync_verified=false 保持正确，因为没有录音或量化测量。M1 三台目标、小黑加入、定量声学偏差、长时间漂移、重复启停稳健性、掉线恢复仍未通过本轮验收。

## 原始证据

- [3 秒发送报告](M1-two-device/two-device-play.json)
- [10 秒发送报告](M1-two-device/two-device-play-10s.json)
- [环境、用户反馈与范围](M1-two-device/two-device-metadata.json)
- [本轮源码清单](M1-two-device/source-manifest.json)

CLI stdout 仅为 JSON；未启用单独 debug log，无抓包和声学录音。证据元数据最初误用系统 Python 导入版本失败，随后使用 venv 成功生成；实际两轮播放均使用 venv，此记录生成问题不改变发送结果。
