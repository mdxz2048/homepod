# LIVE PCM 协议 v1：系统采集到受管发送服务

日期：2026-11-05。状态：T021/T022 首个live切片契约，运行验收尚未完成。正式App主体验仅「影院模式／同步播放」与系统音频启停；不保留文件选择、音效选择或手工声道选择作为正式使用流程。WAV和tone保留为内部回归工具。核心C ABI v1和M2保护基线不变。

## 进程与启动门控

App通过既有NDJSON控制受管Python worker；worker再启动签名／打包的独立Swift `TapCaptureHost`。host复用ProcessTapCapture库，其stdout专用于下述HPCM帧，stderr仅有限诊断。host默认help、不启动采集；收到明确start才创建／启动tap，遵守公开TCC流程。worker必须把App、worker及已知发送进程PID加入排除集合，host自动排除自己；缺失／冲突不能扩大捕获范围兜底。

次序固定：用户显式开启 -> 选定且准备所有接收端 -> 全部到RAOP barrier -> 发host start -> 等实际首PCM -> 建共同核心计划及有界pre-roll -> 验证全组可发送 -> 同时release。ready只表示host启动资源与格式已准备，不能表示权限granted、非静音或音箱出声。

不得在准备接收端前持续采集，或用旧8秒lead配几块缓冲导致必溢出。首PCM到达Python的receipt monotonic记R0，协议延迟记L：`P0=R0+L+500ms`，`S0=P0-L=R0+500ms`。输入队列硬上限2秒；到S0须有足够预缓冲且所有输出就绪，否则全组失败停止，不丢帧／更改单路起点补救。采集授权等待发生在选择R0和P0之前。

## stdout 二进制帧

```text
4 bytes ASCII "HPCM"
uint32 little-endian headerLength (1..16384)
uint32 little-endian payloadLength (0..65536)
headerLength bytes UTF-8 JSON object
payloadLength bytes payload
```

控制状态和PCM一律使用同一种framing，不混JSONL、不跨stderr做状态关联。消费者须readexactly处理分包／合包；先检查magic和两个长度，超限、无效UTF-8/JSON、截断或未知版本即全组失败，不能重新搜索magic静默跳过坏音频。JSON拒绝NaN/Infinity。stderr保留有限尾部，不上传采集内容。

统一header：`{v:1,id:string|null,session:string|null,kind:"ready"|"pcm"|"stopped"|"error",...}`。id关联host控制命令，session原样回显App生成UUID；旧session帧不进入新队列。ready/pcm沿start id；显式stop后的stopped沿stop id；EOF清理可为null id。ready/stopped/error的payloadLength必须0。

### PCM header（camelCase为固定字段）

```json
{
  "v":1,"id":"start-id","session":"session-uuid","kind":"pcm",
  "sequence":0,
  "outputRate":44100,"outputChannels":2,
  "outputFrameStart":0,"outputFrames":441,
  "source":{
    "sourceRate":48000,"sourceChannels":2,
    "sourceFrameStart":0,"sourceFrames":480,"sourceSequence":0,
    "hostTime":123456789,"sampleTime":"0.0","flags":3,
    "nowHostTime":123456999,"nowSampleTime":"0.0","nowFlags":3,
    "timebaseNumerator":1,"timebaseDenominator":1,"droppedBlocksBefore":0
  },
  "inputFramesConsumedTotal":480,
  "converterLeadingFrames":0,"converterTrailingFrames":0,
  "primeMethod":"none","converterDelayKnown":false,
  "timestampRelation":"input_block_metadata"
}
```

payload为Float32 little-endian交错立体声，必须有限，`payloadLength=outputFrames*2*4`，outputFrames为1..4096。sequence从0严格连续；outputFrameStart从0严格按前块帧数连续，与core epoch的媒体帧同义。不能把原始sampleTime或hostTime直接代入first_frame。数字字段按对应非负整数范围校验，不能接受bool充数。

source对象保留关联输入块的实际采样率、声道、原生回调序号、input及now原始host/sample/flags、mach时基和丢块累计。sampleTime以Double字符串保留（包括无效值），有效性需flags及finite共同判断；hostTime为原始ticks，不是纳秒。sourceFrameStart是本session送入转换器的输入帧累计索引，不是原生sampleTime；sourceFrames为关联输入块帧数。

AVAudioConverter有内部历史，一块输入可能产生多块输出；这些输出可重复同一source元数据，sourceSequence因此只要求非递减，不能强求每个输出块加一。timestampRelation明确仅输入块元数据，不声称是该输出首样本的精确时间。converterLeadingFrames/TrailingFrames为converter公开primeInfo报告，不是实测端到端延迟；converterDelayKnown默认false，不能据primeMethod.none伪称零延迟。需要其它字段可增量附加，不能改上述含义。

### 控制状态header

ready至少包含session/id、outputRate44100、outputChannels2及实际sourceFormat。若实际源不是立体声或格式不支持则error，不暗中丢声道或做未批准混音。error含code/message与cleanupComplete（尚未完成则false），不能同时声称ready。

stopped含`cleanupComplete:bool,drainComplete:false,discardedConverterTail:bool`及有限统计。显式停止本轮取消转换并释放资源，不flush潜在converter尾音；用过转换器时discardedConverterTail为true（尾样本数量未知，不能编造0）。cleanupComplete只代表资源清理，不代表完整音频无损送达。

## stdin host控制（UTF-8 JSONL，64KiB单行上限）

```json
{"v":1,"id":"start-id","command":"start","params":{"session":"session-uuid","excludedProcessIDs":[123,456]}}
{"v":1,"id":"stop-id","command":"stop","params":{"session":"session-uuid"}}
```

start每次一个session，已有采集拒绝新start；stop只匹配当前session，旧stop不能停新采集，已停同session幂等。首版系统全局输出、自动排除自身及给定名单；不通过用户UI暴露未验证的进程／声道组合。stdin EOF执行同样有界停止，不继续采集。

PCM stdout意外EOF、意外stopped、host崩溃或错误都不是live正常结束：**只有controller已经发出显式stop／shutdown时，匹配的stopped才能作为清理确认。** 未显式结束的live没有自然EOF，也没有completed-by-total-frames。

## 转换、时钟、背压

host在非实时消费者将真实Float32立体声按需转换为44100Hz；44100源可直通，48000等使用AVAudioConverter，primeMethod.none并报告primeInfo。所有去交错、转换、分帧、JSON编码与pipe写在非RT路径；RT回调仍只预分配复制。stdout写不得阻塞MainActor的stop处理；用独立有界writer／超时，不能因worker不读而永久卡控制。overflow、丢块、格式变化、无效PCM均全组fail-stop，不静默补零或跳帧。

Python首receipt只是保守锚，绝不假设host ticks与Python monotonic相同历元。原生时间元数据保留并报告IPC/转换时延未知量；后续相对host时间与receipt/媒体时间偏离超预算时fail-stop，本轮不承诺长期漂移补偿或精确采集到播放延迟。NTP仍使用冻结mono/wall锚和现有build_timing_plan，P0减协议L后才是发送起点。

新增独立LiveHub／LiveSource，不复用伪超长total_frames reader：push有界PCM输入；严格帧序，输入≤2秒，每输出队列≤4x352帧；全路容量允许才同一次native submit，任一路enqueue失败仍沿v1全组Faulted。空队列等待并设绝对超时，不作为EOF。LiveSource duration=0明确unknown；复用pyatv钩子时必须替换有限帧完成断言，不能设巨大frames绕过。

当前Tap实际为2声道，影院模式本轮同声立体声退化，所有独立输出映射[0,1]；同步播放也发同一立体声。不得伪造后环绕、丢弃左右声道或增加音效选择／手工声道picker。以后原生多声道来源另立验收。

## 清理与第一轮验收

显式停止：禁止新输入 -> 发host stop并停止／取消live消费者 -> native stop、关闭全路RAOP/source -> 确认host停止及private资源释放 -> 检查任务、句柄和补丁 -> 返回App cleanup_complete。host不响应则有界终止专用进程，标清理未确认／失败，不能假干净；App退出同一路径。采集PID或sender PID变化先停止并重建排除集，不能后台无声重启继续捕获。

首轮：分包／合包／坏长度／EOF／错session的解析测试；fake host逐块输入到真实核心并验证N路不同映射与同一timeline；2秒与4x352队列上限、临时空队列不EOF、stall/late/取消清理；48k→44.1k转换帧数与非静音证据；App默认不开采集／不出声，只有显式用户启用才触发系统权限。真实Tap/live/AirPlay全链路、音画同步和长时漂移均需后续真机证据，不从原有限WAV测试继承通过结论。
