# 播放中动态音量

日期：2026-11-06。状态：实现、离线检查、Mac Debug 构建安装及两台 HomePod 动态音量初筛通过；用户确认两台音量变化并正常停止。不代表正式版全部验收通过。

用户要求开启后仍能直接调音量。当前新增 system_worker `set_volume` 命令，参数 session UUID、volume 0..100；只允许活动且已经 streaming 的会话，未就绪或过期返回明确错误。协议 hello 能力 realtime_volume=true。成功回复 state=volume_applied、volume_percent、applied_outputs，只有全部音箱指令确认才返回成功。

LiveVolumeControl 由每个 session 独立持有，对已连接 pyatv connection.audio.set_volume 并发发送，单路最多3秒等待；部分失败停止整组并确认清理，不能让 UI 误以为全部更新。该轮使用设备协议音量，未引入尚未集成的 processing 库，不声称逐样本平滑、各台绝对同时变化或响度完全一致。硬件音量与 PCM 时间线独立，不重建采集会话。

Swift Store 对用户拖动只保留一个在途请求、一个最新待发值；准备期等待 streaming；Stop 清除待发并更换 generation/volume epoch，旧回复不能确认新会话。回复校验目标音量、全部输出数及关联会话。音量请求超时20秒，覆盖最坏3秒指令与12秒清理上限并留余量。界面解除音量滑块的运行时禁用，布局和模式仍按会话锁定，显示更新失败而不是假装成功。当前音画延迟仍不可用。

新增 SystemVolumeChecks.swift 覆盖准备期最后值、合并、单在途请求、停止撤销及旧 ACK 隔离、错误保留最后确认值；等待 Mac 实际编译执行。DEBUG 显式路由验收可传 --route-check-volume，调用实际 worker，按25%→0%→15%各保持3秒；默认启动不执行诊断。

独立 QA 新增 tests/test_live_volume.py 九项，覆盖数值、全组ACK、串行、关闭竞争、3秒超时、被动hello、会话门禁和部分失败清理。追加超大整数回归曾发现两处 OverflowError，已在新 volume 类和 system_worker 的解析边界修复，不修改冻结旧协议；修后 Windows 完整9项通过，QA独立复验受影响2项通过。原有限 worker30项也通过。

尚未进行本轮 Mac 编译和实际音量验证的原因：原 SSH 会话被重置，192.168.0.100:22 连接超时；局域网发现仅找到音箱。已请用户保持 Mac 唤醒、连原网络，并提供录屏所在 code 目录路径。录屏尚未下载：桌面和下载目录分别返回 Operation not permitted，没有绕过系统隐私保护。

## 后续完成情况

重新定位 Mac 为192.168.0.102，以原已信任主机密钥确认身份后连接成功。发现 `/Users/lvzhipeng/Code/录屏2026-11-06 11.30.15.mov`，复制完成，82227918字节；用户随后表示已经拿到视频并要求停止传输，不再执行视频操作。前述网络/文件阻断为历史过程，已解除。

Mac 新增 SystemVolumeChecks 编译和运行均退出0，既有 StateChecks、SystemSessionChecks 同样0；Debug App构建0；Python九项动态音量检查0。新App安装到用户 Applications固定路径，codesign严格校验通过。没有宣称真实GUI拖动动作已自动验收；状态层fake与实际worker/设备控制分别验证。

前两次volume-real-1/2在采集阶段失败，尚无动态音量确认。自己的TCC日志明确报告 Failed to match existing code requirement for subject com.homepodflow.mac and service kTCCServiceAudioCapture。重新构建的ad-hoc App导致旧授权代码要求不匹配；没有据此认定音量后端失败，也没有绕过TCC。用户在隐私面板手动重新允许后，保持同一安装构建不变，执行volume-real-3成功。固定开发/发布签名身份仍是后续需解决的发布问题。

原始证据：`T021-macos/volume-real-3/route.json`、空route.stderr、exit-code.txt。两轮新UUID会话，播放中各依次发25%、0%、15%；六次ACK均state=volume_applied、applied_outputs=2且volume_percent符合请求。两轮terminal.cleanup_complete=true，errors=[]、control_path_verified=true、worker正常退出0。用户针对这次明确回复“两台音量都有变化，最后已停止”。记录为真实动态音量与短时听感初筛，不将ACK称声学同时变化或逐样本平滑。

验收后退出诊断实例，并正常打开同一安装App，不替换签名、不自动启动采集/播放。现在播放中可直接拖动主音量；布局/模式仍有会话保护，音画滑块仍禁用。

Release构建随后也退出0，未用Release产物替换当前已授权安装，避免再次改变签名。构建/状态/后端测试日志、三次原始检查及实际源文件SHA清单保存为 `T021-macos/volume-evidence.zip`，不含录屏视频或PCM。最终检查未见采集宿主及route验收helper残留。
