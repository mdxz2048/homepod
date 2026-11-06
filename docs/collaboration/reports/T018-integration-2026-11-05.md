# T018：受管文件音频服务整合

2026-11-05，版本0.2.0。执行及独立终审通过。QA恢复后已直接核对最终Mac日志、原生结果、源码和产物哈希，结论仅覆盖0.2文件服务预览，详见T018-worker-qa-2026-11-05.md。

## 完成范围

SwiftUI通用设置的独立文件测试入口 -> WorkerStore -> WorkerRouterService/ManagedWorkerClient -> JSONL专用Python进程 -> 既有C ABI v1/有界流/AirPlay适配器。主菜单房间和Toggle仍明确Demo；真实文件会话没有复用示例音箱连接状态。后续主播放入口需统一异步服务，不长期保留两套running语义。

支持hello、WAV只读inspect、显式scan、offline/airplay start、按session stop、shutdown；有限行/日志、相关ID、旧进程/会话过滤、失败受控退出、不自动重启或播放。运行配置已部署到Mac Application Support，日常不输入Python路径。当前Mac已启动0.2.0 Release，仅菜单栏；没有自动扫描或发声。

核心35保护文件未改，63个本轮部署源文件回传SHA与工作区完全一致。复用已验M2动态库c5cdd4e058c2a702a715c6cacf4710629b43f81da35445dfd19b107ff48c8fbe，未重编或改变核心。

## 实际检查

| 检查 | 结果及证据 |
|---|---|
| Windows协议/生命周期 | 30/30（底层19+独立QA11），使用项目venv；T018-windows-tests.log |
| Mac协议/生命周期 | 30/30，T018-macos/python-worker-tests.log |
| Mac App Debug及最终增量构建 | Pass，build-debug.log/build-debug-final.log |
| Mac Release | Pass，build-release.log；metadata版本0.2.0 |
| 原有Swift状态检查 | Pass，state-checks.log |
| 真实子进程Swift管道测试 | Pass，managed-checks.log；覆盖碎片、有限日志、严格异常分类、超时、显式重连、旧session与stop竞态 |
| Swift Store真核心集成 | Pass，native-store.json/native-store-run.log；两次同worker各1秒、44100帧、三路 |
| native中途stop及EOF | Pass，native-stop-eof.json/native-stop-eof.log；60秒源各消费4224/2646000帧后停止，真实native参与、清理确认、退出0 |
| 源码/产物对应 | source-manifest.json 63文件0漂移；Release zip SHA与metadata一致 |

真Store集成先选三声道WAV，影院显式各取一路复制为双声道，三路PCM哈希不同且首帧共同时间一致；同步模式再将相同立体声映射送三路，三路哈希相同。每路native/消费帧数与内容哈希对应，network_used=false、acoustic_sync_verified=false；并非声学测试。两次自然结束后shutdown确认。stop/EOF由另一真实worker/native执行，无网络。

首轮Mac子进程测试出现-6：stdin daemon持BufferedReader锁参与CPython析构。修复为确认会话、任务与loop清理后flush并退出0，最终30项通过。保留python-worker-tests-first-failed.log。首次误用Windows系统Python缺依赖造成fixture预检失败，改项目venv后全通过，不以此算代码回归。另一次SSH PTY长输入破坏编译命令，重发单条命令后Native测试构建成功，不修改源码掩盖问题。

## 当前能力限制

本轮没有扫描或播放音箱，airplay start入口只复用已有已验适配器，UI驱动真实音箱这一轮未验收。没有系统捕获、Tap实时桥、实时音量/音画偏移、立体声对、自动重连、声学量化或长时漂移结论。当前输入为有限PCM WAV，界面按44.1kHz/16位说明；坐标不产生自动空间算法。

service-ui快照为DEBUG窗口组件缓存，仍受侧栏/材质缺失影响；不是实际鼠标操作或完整外观验收。新版预览包artifacts/HomePod-Flow-0.2-file-service-macOS.zip是本机开发产物，依赖已部署本机runtime，不是完整独立安装器。

## 用户最新选择

后续采用Core Audio Process Tap作为Mac采集兜底。首先新增独立平台采集库/有限probe/生命周期测试，保留真实格式、hostTime与sampleTime，显式启动并由系统请求录音权限；不会把立体声混合流声称为5.1。Tap到持续播放worker的实时桥另设任务，冻结核心保持不变。
