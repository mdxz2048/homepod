# 虚拟音频入口架构与实施边界

日期：2026-11-06。阶段：立体声可证伪原型；正式主路径尚未通过。具体接口见 [CONTRACT.md v0.2](CONTRACT.md)。

## 产品目标与当前事实

用户希望日常声音统一进入、多声道以后可保留、音画尽量自动。已有系统Tap→两台HomePod同步播放和动态音量实测作为兼容底座；新虚拟设备不替换已验证底座的证据，也不改冻结核心。

第一切片只证明两件事：第三方应用 stereo PCM 能从本项目虚拟输出进入现有发送链；准确延迟/时钟能否使受测浏览器自动协调画面。立体声设备出现、属性可读、发送hash均不足以证明这两件事。

## 分层与依赖

```text
第三方播放器 / 浏览器
          ↓ 正常Core Audio output
HomePod Flow Audio（HAL output-only driver）
          ↓ device/stream Tap〔首选，待实测〕
VirtualAudioInput descriptor + timestamp + bounded PCM
          ↓ 现有转换 / HPCM v1 stereo
processing → frozen routing/sync C ABI → AirPlay发送 → HomePod组

App controller → prepare / latency revision / output takeover lease
恢复helper   → owner失联后的默认输出恢复
系统stereo Tap → 无虚拟设备或不兼容来源的兜底输入
```

同一内容一次只用一条输入路线，不能把全局Tap和虚拟设备Tap叠加。driver只处理HAL设备能力与稳定源时钟，不负责网络、HomePod发现或UI。App/worker处理发送预算与会话；延迟预算通过非RT属性配置，不能把网络逻辑放进 coreaudiod。

首选 output-only + stream Tap 是为避免新增loopback输入设备与另一套PCM跨进程协议，但不是已证明可以工作。需要验证tap在output-only驱动的实际读取、原始格式、左右隔离、时间戳和延迟语义；失败要保留结论再评估共享内存/loopback，禁止仅初始化成功就继续宣传可用。

## 自动同步设计

浏览器看见的是虚拟输出端点。driver给真实渲染时钟，stream latency单处给下游预算；发送端须保持真实样本与该预算对应。不能把普通扬声器属性写成2秒，也不能先给hostTime加2秒又上报2秒。

兼容审查已纠正首版scope遗漏：Chromium查询stream latency时保留output scope，故该selector须兼容global/output两scope同值查询与通知；仍只计一次延迟，其余属性保持各自严格scope矩阵。源码依据不替代目标浏览器实测。

现有链路以Python receipt为起点、RAOP协商latency加500ms建立共同呈现。它证明不同音箱计划同步，不自动证明对应源render的端到端延迟。新输入应保留源host clock，量化render→Tap/转换→receipt，再对齐计划呈现；未知误差标注，不拿2秒巧合当校准。

首轮选择固定安全预算，接收端、源格式或延迟revision变化时全组停止重建。动态在播修改latency可能被客户端忽略，故不承诺无缝；客户端仍持有IO则要求重开输出，保留明确busy状态。只有三层验收（属性/采用/声学）通过后，才启用对应应用自动补偿能力。

## 后续多声道

MVP只声明真实2ch。统一输入描述保留格式、channel labels、provenance和转换历史，以后新增真实6/8ch配置和HPCM协商版本，不能静默改旧v1字段。每路媒体都输出到同一设备时，OS可能混音，因此设备8slot不等于原片7.1，无法靠静音自动鉴定。原生多声道路由、立体声空间矩阵和同步复制是不同策略，不互相冒充。

播放器负责解码；本产品仍无文件入口。受保护内容与encoded passthrough不属于承诺的通用PCM。播放器绑定其他设备时可能首次需要选择虚拟设备，自动切系统默认不能强制接管它。

## 交付与风险门槛

1. 源码构建、属性矩阵、RT审查、时钟/越界/错误状态测试；不装系统目录、不改默认输出。
2. 签名、安装/卸载与可操作恢复方案审查后，由总协调统一执行受控Mac安装。保留当前原生HomePod默认输出选择，不静默覆盖。
3. 通过输出Tap实际PCM及无反馈测试，才接入App；保留stereo系统Tap兜底。
4. 比较扬声器、原生HomePod、虚拟转发三条路径的系统参数、浏览器采用与实际音画偏差；含pause/seek和客户端重开。
5. 实现独立恢复helper并验证App崩溃、driver不可用、sleep/wake、用户手动切输出，才允许默认自动接管。
6. 最后扩展六声道与完整独立安装包，仍按统一release验收，不把MVP构建当正式版。

主要风险：驱动在coreaudiod进程内失误会影响系统声音；Tap数据面可能不成立；源时间戳含义和AU延迟重复计数；浏览器仅open读取/不消费属性；App故障后无声；ad-hoc更新破坏TCC身份；源降混不可逆；固定速率不是长期漂移补偿。各项须保留独立失败结果，不用一个“大体能响”覆盖。

实施分工沿用 [工作流](../VIRTUAL_AUDIO_MVP_WORKFLOW.md)：driver、input/app、QA与总协调各有文件所有权，跨模块只依赖CONTRACT；未经协调不改旧核心、不共享SSH、不安装/出声、不自行提交推送。
