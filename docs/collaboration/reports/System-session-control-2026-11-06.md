# 系统音频会话意图与恢复

负责范围：原生 App 的系统音频会话状态、受管服务边界和环境通知。未修改冻结 core、Python 发送链路、Tap、界面或音箱；本轮没有 SSH、录音或播放。

## 行为

- `desiredEnabled` 表示本次应用运行中用户的开启意图，`isRunning` 表示 worker 已报告 streaming。开启意图不持久化，重新启动应用不能自动播放。
- 显式 `stop()`、`disconnect()`、`prepareForTermination()` 先同步撤销意图、取消计时并更换意图 token。旧恢复任务即使收到迟到结果，也不能启动新会话。
- 明确可重试且清理成功的暂时网络/设备错误，采用 1、2、4、8、16 秒最多五次恢复；仅连续 streaming 60 秒后重置预算。短暂成功不会无限刷新预算。
- 每次恢复重新发现全部目标，按显式启动时保存的稳定 identifier 精确匹配；使用发现的新地址，保持原 route 顺序。任何目标缺失、标识重复、映射不唯一都不允许只播放部分音箱。
- 重建使用新 session UUID、新捕获任务，没有缓存音频重播。没有稳定 identifier 的旧发现结果只能用于显式启动，不能自动恢复。
- worker 意外退出、协议故障、超时或清理未确认将阻止恢复；不会假称音箱已清理。权限、格式和内部错误不进入自动重试。
- 睡眠/断网先停止并等待 start 的终态清理报告；唤醒/网络恢复才重新发现。网络路径改变但仍可用也触发受控重建。重复停止同一 session 合并，迟到环境任务不能停止新 session。

## worker v1 扩展

与 release_architect 对齐：scan 设备增加 `identifier:string`，必须来自设备稳定身份，不能使用 IP 或名称伪造。DiscoveredDevice.identifier 与 RoomDevice.stableIdentifier 贯通；旧 host-only 布局可解码，只有用户显式启动后的新发现能补入真实 identifier。已有 identifier 缺失时绝不按旧 IP 或名称回退。

start 错误 payload 新增 `failure_kind:string`、`retryable:boolean`、`cleanup_complete:boolean`。仅 `network_transient`、`device_offline`、`device_address_changed` 三种 failure_kind，且后两布尔均为 true，允许恢复。任何缺失字段按禁止恢复处理。start 正常停止仍要求外层 cleanup_complete 及 report 的 cleanup_complete/input_closed/hub_stopped 全部 true。

## App 集成要求

菜单开关已绑定 `desiredEnabled`，恢复等待期也能关闭。布局、模式、音量在意图开启时受状态层与界面双重门禁。显式启动通过 preparation token 覆盖连接与发现过程；Stop 后迟到发现结果不再启动捕获。菜单同步 requestStop 撤销意图，排队中的停止仅针对旧 session，不会撤销后来的新意图。

FlowApplicationDelegate 在退出请求中同步撤销意图，再等待 `prepareForTermination()`；willTerminate 另做同步撤销兜底。清理失败保留 cleanupRequiresAttention 与真实日志，不将强制退出表述为正常清理。

AppState 根据保存的 stableIdentifier 唯一匹配新地址，保留用户 UUID、位置、型号；未知型号需确认，离线保存设备不会因新发现缺席而被移除。画布草稿仍与正式保存布局隔离，状态栏读取保存布局。

`SystemAudioRouting` 可注入静默服务用于独立状态检查，不改变生产默认服务或 runtime.json。环境控制器只监听通知，不申请捕获权限，不执行首次开启或选音箱。

## 验证状态

新增 `apps/macos/Tests/SystemSessionChecks.swift`：预算耗尽/重置、取消 token、拒绝清理不明、身份地址变更/缺目标/重复身份、真实 Store 经静默服务恢复为新 UUID、Stop 后唤醒不复活、权限错误禁止重试、清理不明禁止新 start。所有输入均为内存假服务，不启动外部进程。

Windows 当前没有 Swift 工具链，尚未声称编译或测试通过。总协调在 Mac 执行：

```sh
cd apps/macos
swiftc -swift-version 6 -parse-as-library HomePodFlow/Models/*.swift HomePodFlow/Services/*.swift HomePodFlow/State/*.swift Tests/SystemSessionChecks.swift -o /tmp/homepod-flow-session-checks
/tmp/homepod-flow-session-checks
```

应一并保持 StateChecks、Debug/Release 构建通过。真实网络恢复和声学连续效果仍需要获授权后的真机验收，不能由静默状态测试代替。

## 本轮变更路径

- `apps/macos/HomePodFlow/Services/SystemRouterService.swift`
- `apps/macos/HomePodFlow/State/SystemAudioStore.swift`
- `apps/macos/HomePodFlow/State/SystemSessionRecovery.swift`（新增）
- `apps/macos/HomePodFlow/State/SystemAudioEnvironmentController.swift`（新增）
- `apps/macos/HomePodFlow/State/AppState.swift`
- `apps/macos/HomePodFlow/Models/RoomLayout.swift`
- `apps/macos/HomePodFlow/Models/WorkerProtocol.swift`
- `apps/macos/HomePodFlow/Views/MenuPopoverView.swift`
- `apps/macos/HomePodFlow/Views/SettingsRootView.swift`
- `apps/macos/HomePodFlow/FlowApplicationDelegate.swift`
- `apps/macos/Tests/SystemSessionChecks.swift`（新增）
- `apps/macos/Tests/StateChecks.swift`
- 本报告。
