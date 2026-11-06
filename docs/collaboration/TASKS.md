# 任务与里程碑

## 当前调度：2026-11-06

当前能力以PROGRESS.md为准，下方11月5日记录为历史阶段。用户最新要求先备份当前代码，再启动虚拟声卡下一阶段，立即备份覆盖旧的“等正式验收”条件。

| ID | 任务 | 状态 |
|---|---|---|
| T025 | 当前系统声音/动态音量开发基线Git备份 | 完成：远端main与本地main均4331d3b92cc2330e58dcf28ab50ffd4b7d6d283d |
| T026 | 虚拟入口产品/架构及共享接口冻结 | 已派virtual_architect，契约待冻结 |
| T027 | 最小立体声虚拟输出驱动 | 已派virtual_driver，先准备框架并等契约；不得自行安装HAL驱动/重启 |
| T028 | 原生输出/虚拟输出音画对照验收 | 已派virtual_qa；系统上报属性读取已有，浏览器实际采用及音画偏差未测 |
| T029 | 虚拟输入到现有实时核心的适配 | 待T026接口/驱动能力；保留Tap兜底，不改冻结ABI |

统一入口：[虚拟音频MVP工作流](VIRTUAL_AUDIO_MVP_WORKFLOW.md)。本轮备份不代表正式版验收通过。

状态：2026-11-05 C ABI v1头与行为已冻结。Mac构建、42项Python测试、旧客户端只换新库、60秒两台实际发送和同进程两次3秒重启通过。Agent额度限制后由总协调完成执行，独立终审待补；三台、量化、小时级稳定和断线恢复未验收。

| ID | 任务 | 责任角色 | 依赖 | 状态 |
|---|---|---|---|---|
| T001 | 固定历史源码基线与本轮路径隔离 | 协调 | 无 | Integrated：见 tasks/T001-baseline.md |
| T002 | 核心优先范围；UI 流程推迟 | 协调代产品 | 用户明确要求 | Integrated：见 PRODUCT.md |
| T003 | 当前切片公共契约及架构决策 | architect | PRODUCT | Integrated：M0 C++ 源级契约；C ABI后续 |
| T004 | 独立验收矩阵与测试环境方案 | qa | PRODUCT、T003 | Integrated：M0 21组通过 |
| T005 | 菜单栏与独立设置窗口、共享布局画布 | ui_swift | 用户UI交接包；App状态契约 | Review：原生视图已实现，编译通过，视觉/真实交互分项验收 |
| T006 | App壳、演示服务、状态及持久化 | app_dev | T015冻结接口；UI状态契约 | Review：状态逻辑运行通过，显式演示与真实音频隔离 |
| T007 | M0 核心库基础与离线例子；AirPlay桥接另行派工 | core_dev | T001、T003 | Integrated：Mac构建与独立验收通过 |
| T008 | M1 无界面真机链路集成，按用户要求先两台 | 协调及底层 | T013、设备可达 | Integrated两台实际发送；小黑供电恢复后补三台 |
| T009 | 不同内容播放与同步独立验证 | qa | T008、T004 | Integrated两台短时初筛；定量/长时/三台待补，见tasks/T009-two-device-acceptance.md |
| T010 | 应用捕获、持续流、恢复能力 | App/底层，实施前拆成独立任务 | T008、所需契约批准 | Backlog |
| T011 | 视频时间线与多声道保留可行性研究 | 架构，按实验拆分 | T002；可早期研究 | Backlog |
| T012 | M1 AirPlay适配设计：核心时间域与协议时间映射、Python桥接、准备/清理语义 | architect | M0通过 | Integrated：ABI v1/时间映射及契约 |
| T013 | M1 版本化 C 接口、Python绑定、真实音频路由与AirPlay发送适配 | core_dev | T012 | Integrated：软件桥接离线通过；真机待T008 |
| T014 | M1 独立跨语言、时钟与发送桥接验收 | qa | T012、T013 | Integrated：Mac32 Python/原生2测试程序及dry-run通过 |
| T015 | 固定公共头、C ABI v1契约和兼容性策略 | architect | 两台M1初筛通过，用户要求接口不变 | Integrated：快照/兼容门禁通过 |
| T016 | 不改接口的逐块持续路由、全路有界缓冲及显式stream命令 | core_dev，协调接手 | T015规则；已有Engine.submit | Review：执行通过，待独立终审 |
| T017 | 接口冻结、旧客户端加载新库、持续流与清理独立验收 | qa用例，协调执行 | T015、T016 | Review：42项和真机执行通过，终审因额度待补 |
| T018 | App受管worker服务契约、事件与真实文件源播放接入 | 架构/App/底层 | T005/T006演示切片；v1冻结 | Integrated：0.2.0执行与独立终审通过；真实音箱UI另验，见reports/T018-integration-2026-11-05.md |
| T019 | 正常菜单/窗口实际交互与完整外观验收 | UI/QA | T005/T006 | Backlog：补系统popover、侧栏、真实手势 |
| T020 | Process Tap独立平台库/有限probe/离线生命周期 | App/架构/QA | 用户选择Tap；Mac SDK | Integrated：15项与独立终审；真实采集未验 |
| T021 | Tap实时PCM桥、后台转换/时钟映射与发送 | App/底层 | T020、T022 | In progress：HPCM/LiveHub/SystemWorker/App接入已落，Mac真实核心离线通过；真实系统采集到音箱未验，不改核心v1 |
| T022 | 系统授权与真实有限有声采集、设备变化 | 协调/QA | T020 | In progress：实际probe无可消费块；host诊断定位纯网络worker无音频对象的排除阻断，正在修正 |
| T023 | 首次可用版本提交并备份 GitHub main；README 仅变更记录 | 协调 | 首次可用版本验收 | Waiting：用户已授权，按 RELEASE.md 执行；当前预览不触发推送 |
| T024 | 正式系统音频UI：仅单布局设置、实际型号/保存布局驱动状态栏 | App/协调/QA | 用户2026-11-06要求 | Review：无文件/音效入口，型号/草稿/保存状态测试通过；最终构建和视觉在验 |

里程碑 M1：Mac 上可重复运行三台不同内容播放，具备独立测试报告。M2：应用实时声音接入与自动恢复。M3：明确视频支持范围并形成可安装版本。

下一次执行入口：读取 docs/api/v1/README.md、reports/M2-stream-acceptance-2026-11-05.md、T016/T017。先补独立终审，再验证真实中途停止/恢复、录音量化和更长时播放；保持冻结头/v1行为不变。Mac当前100，代码core-m2-validation/source、库core-m2-validation/build/core/libflow_bridge.dylib。新增stream支持逐块读取的有限长源（至3600秒），不等于系统捕获/无限输入。IP以发现为准，小黑供电后补三台。用户最新交付UI并授权开始评估开发，T005/T006现并行实施，未接入音频的交互明确标为演示。

## UI新阶段：2026-11-05

交接包只作为设计输入，原AGENTS.md保存为design/ui-handoff-v1/AGENTS.reference.md，不作为工作区上级指令。architect负责产品/架构映射报告；ui_swift独占apps/macos/HomePodFlow/Views及Style.swift；app_dev独占该App其余模型/服务/入口/工程；协调负责整合、Mac编译与证据，完成后交qa独立复核。现有C/C++公开头与v1行为冻结。

App分层恢复入口：[APP_ARCHITECTURE.md](APP_ARCHITECTURE.md)。UI范围是可运行演示切片，未接入真实worker，不消除核心/音频剩余验收。

## 新的采集优先级

用户明确选择Core Audio Process Tap作Mac兜底。T020：独立ProcessTapCapture平台库/显式有限probe/生命周期测试（平台离线首切片Integrated：Mac15项、打包及独立终审通过；未真实采集）；T021：Tap PCM到持续worker的实时桥与音箱验证（待T020/T022，Backlog）；T022：系统授权与真实有限有声采集、设备变化/进程排除验收（Backlog，尚未录制）。不把有限WAV文件服务当实时系统捕获，核心v1不变。
