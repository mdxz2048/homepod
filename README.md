# 变更记录

## 2026-11-08

- 新增统一安装镜像流程 `platforms/macos/Installer`：一个 `.pkg` 同时安装 HomePod Flow.app、生产 HAL 虚拟声卡和只读设备探针，`.dmg` 承载安装包与卸载入口；preinstall 备份旧 Flow 驱动并拒绝无关 bundle/symlink，postinstall 校验签名、写清单、重载 `coreaudiod` 并探测固定设备 UID，不改默认输出。
- App 新增“音频组件”状态与首次安装入口：未安装、等待系统加载、已就绪、重复副本、文件无效分别显示；未就绪时禁用系统声音开关，并把安装按钮指向同目录或 `HOMEPODFLOW_INSTALLER_PKG` 的签名 pkg。
- 新增 `AudioComponentChecks`、安装脚本静态检查、可选 universal 驱动/probe 构建参数和 VirtualCaptureHost 打包脚本。
- 已在 Mac（macOS 26.5.2、Xcode 26.6）通过安装脚本静态检查、`AudioComponentChecks`、`StateChecks`、App Debug 构建、驱动多声道测试、生产单设备驱动构建，以及 `build-release.sh` 的 `pkgbuild/productbuild/hdiutil` 全流程；产物为 arm64 的 `HomePod Flow 0.3.0.dmg` 与 `Install HomePod Flow.pkg`，App/驱动签名校验和 DMG 校验通过。
- 旧版卸载真机验证：App、HAL 驱动、系统 Support、receipts 和进程均移除，旧 App/驱动备份到 `~/HomePodFlow-Backups/`；macOS 26 SIP 拒绝 `launchctl kickstart` 重启 coreaudiod，残留设备需要再次重启才消失。安装/卸载流程已改为明确提示“可能需要重启 Mac”，不宣称自动重载成功。
- 新增自包含运行环境：`build-bundled-runtime.sh` 用 PyInstaller 冻结 Python worker，把 runtime 项目、`libflow_bridge.dylib`、`hflctl` 和 worker 放进 App 的 `Contents/Resources/Runtime`；App 优先使用内置 manifest，不再要求 Homebrew Python 或外部 `runtime.json`。冻结 worker 已通过 `hello`、真实 mDNS `scan` 与无音频 `start` 失败清理检查，且 Mach-O 无 `/opt/homebrew`/`/usr/local` 依赖；整包当前为 arm64。
- 统一安装包已在本机成功安装：`pkgutil` 写入 App/驱动/Support 三个 receipt，App 0.3.0、HAL 驱动、内置 Runtime 和冻结 worker 均落盘并通过签名/hello 检查。首次安装失败的两个根因已修复：旧 App 备份以 `.app` 形式留在用户目录，被 Installer 当作 1.0.0 已安装而跳过 App 组件；Support postinstall 用 `plutil -lint` 校验 JSON 失败。现在旧 App/驱动备份改为 zip，manifest 改用 `python3 -m json.tool`。因 macOS 26 SIP 拒绝重启 coreaudiod，仍需重启 Mac 才能加载新声卡；TCC、实际出声、声学尚未验证。
- 发布 0.3.1 升级包（CFBundleVersion 2）：同一个 pkg 可覆盖升级 App/驱动并保留用户偏好；Installer 使用 `onConclusion="Restart"` 在完成后提示重启。App 组件卡显示 App/驱动版本和“升级/重装…”入口，会优先找到 `/Users/Shared/HomePodFlow-*` 中最新的 pkg。空间布局支持在同步模式移除已保存/断电音箱。0.3.1 构建、pkg 查找和脚本检查通过；实际覆盖安装/重启/升级后状态待验收。

## 2026-11-06

- 多声道采集格式支持原生 mono；新增独立 1/2/3/4/6/8ch 转换器与 Swift HPCM v2 编码器。Mac35项单测、Release及跨语言14组合/220052帧验收通过；尚未接入产品 host/worker，实际多声道取声与声学未验。

- 保存当前开发与声卡安装状态、原始日志和会话交接入口 docs/collaboration/SESSION_HANDOFF.md。

- 当前开发基线已备份到 GitHub main（4331d3b）；这是开发进度快照，尚未通过完整正式版验收。
- 在独立开发分支新增立体声虚拟音频驱动、输入模块及验收工具；Mac 驱动检查/暂存包签名、输入模块13项与工具6项检查通过。
- 虚拟声卡第六候选真机验证：系统枚举、AudioUnit 初始化、`hfla`/`hflr`（CFPropertyList）、`--discover`、TCC 授权 GUI 进程的 device Tap 左右独立非零 PCM 均通过；同时实测 buffer size 由 coreaudiod 管理（15..4096），产品 Input 接入、浏览器采用与声学测量仍未完成。
- 虚拟驱动首版安装后HAL设备初始化失败；已补兼容属性、通过Mac测试并安装修正版，用户已再次重启，待读取新枚举结果；真实采集和浏览器音画补偿尚未验证。
- 跑通 Mac 系统声音到两台 HomePod 的真实链路，完成短时持续播放和多轮启停，用户确认听感同步。
- 接入播放中动态音量，实际两台音箱完成 25%→静音→15% 调节及正常停止；Mac 状态检查、音量检查与 Debug/Release 构建通过。
- 读取原生输出的系统延迟属性：Mac 扬声器按 Chromium 静态口径约 16.2ms，AirPlay/HomePod 音频流 2000ms；不是实际声学或浏览器音画偏差测量。
- 新增独立影院处理库及多声道/虚拟声卡/延迟上报方案；影院库尚未接入实际播放，虚拟声卡尚未完整接通。
- 正式输入改为 Mac 系统声音，移除文件播放入口；只保留影院模式与同步播放。
- 设置收敛为单个空间布局页，集成音箱发现、添加、型号确认、位置调整、保存和取消。
- 状态栏按保存的实际设备布局绘制；型号来自发现结果，不根据用户命名猜测。未配置时显示空态。
- 新增实时 HPCM 采集桥、有界持续路由、受管系统音频服务和退出清理；真机全链路仍在验收。

## 2026-11-05

- 新增独立的 macOS Process Tap 采集库和有限采集探针；Mac 编译、15 项离线测试及探针打包通过。真实采集和实时发送尚未接通验收。
- 新增 0.2.0 受管文件服务预览：Swift → Python worker → C++ 核心；支持文件检查、声道分配、播放及停止。Mac/Windows 各 30 项协议测试、原生离线链路及 Debug/Release 构建通过；本轮未通过 App 实际播放音箱。
- 新增菜单栏、设置窗口、房间布局及偏好设置界面；主菜单当前使用明确标示的演示服务。
- 冻结核心 C ABI v1；实现逐块路由与有界缓冲。42 项 Python 测试、旧客户端加载新库及两台音箱发送检查通过；声学量化、长期稳定和断线恢复尚未验收。
- 新核心驱动两台音箱播放不同内容，用户确认短时听感基本同步。
- 确定首次可用版本验收后备份至 GitHub mdxz2048/homepod 的 main 分支。

## 2026-11-04

- 完成早期 AirPlay 原型：分配真实 5.1 音源声道，三台独立 HomePod 播放不同内容，用户反馈听感基本同步。
- 保存实现方案、测试记录、依赖版本和历史源码证据；上述听感结果不等同于毫秒级同步测量。
