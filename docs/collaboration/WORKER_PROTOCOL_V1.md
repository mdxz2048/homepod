# HomePod Flow 受管 Worker 协议 v1

日期：2026-11-05。状态：T018 实现契约；App 与 worker 共同遵守。此为应用进程边界，不修改 `docs/api/v1` 冻结的 C ABI。入口：`python -u -m adapters.worker`，工作目录为部署项目目录；仅显式 start 可以启动指定音频任务，本轮开发验收不自动播放音箱。

## 传输与资源边界

stdin/stdout 为 UTF-8 JSON Lines，单行一个对象，以 LF 结束。请求和事件均最多 65,536 字节（包括 LF），禁止多行 JSON、NaN/Infinity 和stdout诊断。stderr仅诊断；消息文本截短到1024字符，App保留最多128KiB诊断尾部，不无限追加内存日志。App增量读取、按换行组包，不能假定一次Pipe读取等于一条事件。

超长行、无效UTF-8或无效JSON不执行任何命令，发协议错误；可完整跳过该行才继续，否则停止清理并退出，不能把被截断的后半行当新命令。超过上限的最终报告须产生错误而非截断成无效JSON。有效请求ID本进程内不得复用；worker需检测重复且不重复执行。ID集合允许最多4096项，达上限拒绝新业务并要求重启；stop/shutdown仍可执行完成清理。App使用UUID请求ID，不依赖配额恢复。

## 请求与事件

```json
{"v":1,"id":"request-uuid","command":"inspect","params":{"wav":"/absolute/audio.wav"}}
```

请求仅含 v/id/command/params。v必须为整数1；id为1..128字符非空字符串；params为对象；未知命令返回错误，不猜测意图。参数类型和值严格校验，bool不能代替数字；路径必须绝对路径。未知参数拒绝，以免拼写错了却假成功。

```json
{"v":1,"id":"request-uuid","event":"result","session":null,"payload":{"sample_rate":44100,"channels":6,"frames":441000,"duration_seconds":10.0}}
```

事件固定含 v/id/event/session/payload。event为accepted/state/result/error。正常id回显请求id；session为相关start的原样UUID字符串或null。UUID允许常见大小写，但必须原样回显，不能规范化后破坏Swift的关联。所有事件在stdout顺序写入，不能交错拼行。App可忽略未来新增payload字段，但未知版本或无效必要字段应报协议异常。

每个有效请求至多一个终态result或error；start另有必需accepted和零到多个state。其它命令可直接终态，无需accepted。无法可信关联的坏消息及重复id使用id:null、session:null；duplicate_id的payload带offending_id，原请求继续，不能把重复请求错误当作原start失败。

error.payload为`{code:string,message:string}`，可附offending_id/details；使用code判定，不能解析文案。标准码：invalid_request、invalid_params、unsupported_version、unknown_command、duplicate_id、busy、stale_session、worker_poisoned、operation_failed、cleanup_failed、resource_limit。原生错误可放details，但不替代协议code。

## 命令

| command | params | result.payload |
|---|---|---|
| hello | `{}` | `{protocol_version:1,core_abi_version:1,commands:[...],capabilities:{offline:true,airplay:true,capture:false,stereo_pair:false,realtime_volume:false,av_offset:false}}` |
| inspect | `{wav:absolutePath}` | `{sample_rate:int,channels:int,frames:int,duration_seconds:number}`；复用WavReader只读校验，关闭文件，不加载／发送音频 |
| scan | 可选`hosts:[string]`、`timeout_seconds:1..15`，默认8 | `{devices:[{name:string,address:string,model:string}]}`；只发现，绝不自动选择目标或播放 |
| start | 见下节 | 完成／停止时`{state:"completed"或"stopped",cleanup_complete:true,report:{cleanup_complete:true,...}}`；失败error |
| stop | `{session:UUID}` | `{stopped:true,cleanup_complete:true,state:"stopped",already_stopped:bool}`，仅清理完成后返回 |
| shutdown | `{}` | `{shutdown:true,cleanup_complete:true,state:"shutdown"}`，先停止清理，再flush结果并正常退出 |

hello的capabilities表示此worker支持的命令路径，不表示已连接设备、已获权限或已加载动态库；core_abi_version表示可接入的接口版本。scan结果无可靠稳定设备ID时不伪造；App不把address当永久身份。扫描最多返回64台，每个名称/地址/型号限制合理长度，保证行预算。运行音频任务时允许hello/stop/shutdown；scan/inspect/start均返回busy，避免共享协议环境和本地验证互相干扰。

## start 参数与生命周期

```json
{"session":"app-generated-uuid","library":"/absolute/libflow_bridge.dylib","wav":"/absolute/audio.wav","execution":"offline","routes":[{"output_id":0,"channels":[0,0]}],"volume":15,"lead_seconds":8}
```

session是每次新start独立生成的UUID，不得重用；library与wav是绝对路径。execution显式必填offline或airplay，不提供隐式默认。routes为1..8项，output_id为唯一uint32，channels恰好两个非负输入索引，依据inspect得到的真实通道数校验。offline禁止任何host字段及网络路径；airplay每项必需非空host且目标互异，用户明确选中才发送。只支持独立输出，不接受立体声对伪拆分。

volume为有限0..100，缺省15；lead_seconds为有限正数不超过60，缺省8；过短计划仍须按底层guard拒绝。字段是启动参数，不承诺运行中音量修改。WAV条件由WavReader检验：当前有限的signed16 PCM、帧完整；AirPlay要求44100Hz，每个输出双声道；不自动下载、重采样、捕获或混音。App明确提供通道映射，坐标不会自动产生声道算法。验收offline无网络、不出声；airplay只由显式请求开启。

worker先完成结构与本地文件/映射校验，再accepted。accepted仅表示接受任务，不表示连接或出声。随后state.payload为`{state:"preparing"|"streaming"|"completed"|"stopped"|"failed"}`，可加execution及有限进度字段。state和start终态沿原start id/session，不改成stop id。

preparing包括连接与原生准备；streaming为可选，AirPlay须观察共同计划并到达发送时刻后才发，仅表示协议发送阶段。offline允许preparing直接completed，不能以加速消费假装按真实时钟播放。终态state之后，成功或停止发result；失败发error。所有报告保留acoustic_sync_verified:false；日志、帧数和协议完成不能证明声学同步。

每次仅一个活跃start；并发start返回busy且不触碰原任务。stop匹配当前session才可取消；旧session不得停止新session，返回stale_session。没有活跃任务时对已结束session的stop幂等；未知session返回stale_session。stop的result等原任务与native、reader、队列、连接、源清理完成，随后发出；原start也收到自己的stopped/result。自然完成竞态已完成则stop仍幂等，不把completed改写成stopped。

清理结果无可靠完成证据或仍有pending任务时标记worker_poisoned，拒绝后续start；不能在同一worker内继续复用全局pyatv补丁。stop/shutdown仍可尝试收尾，App必要时终止该专用worker并重新创建，不能报告正常停止成功。

## EOF、关闭和App约束

stdin EOF视为shutdown：停止活跃任务，等待有界底层清理并退出；已有start可发终态，但不伪造不存在的shutdown请求ID。正常shutdown退出码0；不可完成清理/协议致命错误退出非0。App先发stop/shutdown并等待有限时间，超时升级终止专用子进程；进程退出不等于音箱已完成播放，失败须如实呈现。EOF/取消不得遗留reader或后台发送任务。

部署器写`Application Support/HomePod Flow/runtime.json`：`{python:absolutePath,project:absolutePath,library:absolutePath}`。App内部校验可执行文件/目录/库；日常界面不暴露工程路径。通过Process参数数组启动，不拼shell命令；不把密码或凭据放日志。配置可保存，running/connected不可保存；启动App绝不自动start。App按session过滤旧事件，用命令id关联答复；null协议错误只告警，不覆盖活跃会话。仍无捕获、立体声对、实时音量或音画偏移生效承诺。

## 本轮App过渡结构审核

允许首轮使用 `AppState.worker: WorkerStore -> ManagedWorkerClient -> JSONL worker`，并在通用设置放独立「文件服务测试」入口：连接、选WAV、inspect、离线检查、scan、明确选择目标／通道、显式播放／停止。View只调用Store动作，不能启动Process。WorkerStore独立持有请求/session与清理状态，不由旧Demo开关发start。

主菜单和布局暂时保持明确Demo，示例房间不是扫描所得真实设备；真实文件测试面板必须显示其自己的execution、目标与状态。这个分离是短期验收入口，不是长期两套全局running：后续主播放改接统一异步RouterService时，应把Demo实现和Worker实现作为可替换后端，以单一状态源选择当前后端；不能让两个开关同时争用同一真实会话，或把worker的成功状态写回旧Demo示例设备。


清理确认字段为强制成功条件：stop/shutdown的result.payload.cleanup_complete必须为true，兼容既有stopped:true/shutdown:true。start completed/stopped也必须在可靠清理后返回，payload及report的cleanup_complete均为true；App保留原始report，不能仅凭state推断成功。缺少/false时按清理未确认处理，不能显示正常停止。

