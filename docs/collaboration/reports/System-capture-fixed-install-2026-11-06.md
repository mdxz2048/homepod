# 系统声音采集：固定安装与手动授权准备

日期：2026-11-06。状态：固定安装与真实非零系统 PCM 基础检查通过（见后续实测）；不代表正式产品完整验收通过。以下准备过程按当时状态记录。

用户反馈在隐私设置的添加窗口中找不到 HomePod Flow。此前 App 位于开发构建目录，没有安装到用户 Applications。本次将内部验收构建安装至 `/Users/lvzhipeng/Applications/HomePod Flow.app`，以 Finder 显示该路径，启动 App，并打开录屏/系统音频隐私面板。

检查另发现原先 `GENERATE_INFOPLIST_FILE` 配合自定义 `INFOPLIST_KEY_NSAudioCaptureUsageDescription` 设置未在已构建 App 中产生对应字段。改为 XcodeGen 显式生成 Info.plist（`info.path` 与 `info.properties`），关闭 Xcode 的隐式生成；包括录音用途、本地网络用途、菜单栏与显示名称。没有把此字段缺失认定为全部静音问题的唯一原因。

Mac staged candidate 使用 `xcodegen generate` 后以 `xcodebuild -project HomePodFlow.xcodeproj -scheme HomePodFlow -configuration Debug -derivedDataPath ../../../PermissionDerivedData CODE_SIGN_IDENTITY=- build` 构建，退出码 0。日志位于远端 live-validation 的 `app-project-permission.log`、`app-permission-build.log`。构建产物及固定安装 App 均通过 `codesign --verify --deep --strict`，两者 PlistBuddy 读取录音用途字段均返回预期中文说明。签名为内部 ad-hoc，不代表公证发布包。

未修改 TCC 数据库，未自动操作权限开关，未启动本轮录音或音箱播放。已请用户在隐私面板加号窗口用 Cmd+Shift+G 输入完整 App 路径并手动授权。授权后通过 GUI App 归属启动有限系统采集检查，统计实际 PCM 非零样本/能量、时间戳与清理结果；零样本不算采集通过。此安装用于权限和兜底链路验收，尚非正式版交付。

## 后续实测：真实非零系统 PCM 已获得

用户再次反馈找不到后，核验固定安装 App 文件及 bundle ID 确实存在，且 GUI 进程从上述路径运行。随后通过该 GUI App 显式启动有限 `--check-system-capture` 检查，Mac 本机以低电平播放系统 Glass 提示音两次；未向 HomePod 发送。用户随后回复“应该已经可以了”。未读取或修改 TCC 数据库，也未据此推断具体授权面板状态。

原始证据：`T021-macos/capture-installed-1/capture.json`、`capture.stderr`、`exit-code.txt`；远端同名目录位于 live-validation。结果：源 48000Hz / 2ch，转为 44100Hz，284 个音频块 / 133593 帧（约 3.03 秒），168017 个非零样本，peak 0.0101655442，RMS 0.0013742016；errors 空，capture_verified=true，capture_cleanup_complete=true，capture_host_exited=true，input_closed=true，零报告丢块，检查进程退出码 0。

结论：固定安装 GUI 归属下，系统声音→Tap→转换→HPCM→Python 接收的非零音频及正常停止初步验证通过。此前只有零样本，不能算通过；此次有实际非零证据。尚未验证发布包独立运行、长时稳定、5.1、Mac 本机静音恢复、真实系统声音→多 HomePod 整体播放或声学同步。报告中的 capture_permission=not_inferred 保留，不把音频成功伪装为权限状态查询结果。
