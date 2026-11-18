# 变更记录

## 2026-11-18

- 发布流程固化为 Codex skill `homepodflow-release`：覆盖版本递增、构建 pkg/dmg、Ed25519 签名更新源、官网文案/截图、发布验证与回滚；明确 `build-and-publish.sh` 不会修改 `index.html`，网页必须单独更新。
- 官网从 0.3.1 文案更新到 0.3.3：补充应用内更新、延迟与占用修复、安装器不可重定位；修正“不修改系统输出设备”等与实现不符的描述。截图改为 0.3.3 Debug 构建实拍（音频组件、更新卡片、示例布局）。
- DEBUG 截图新增 `--capture-demo-layout`：示例布局同时保留真实的音频组件与更新区块；`AppState.showsProductionSections` 默认值不变，仅影响 DEBUG 截图路径。
- 官网发布验证：公网 DMG 51,543,948 B，SHA256 `ff0bfa7558e2903d85073c9a9be54386f1e76842d310c7973539261945bac64e` 与 `release.json` 一致；源站和公网静态资源均返回 200。浏览器声学同步仍未重新验收。
- 新增采集架构评估 `docs/collaboration/AUDIO_CAPTURE_OPTIONS_2026-11-18.md`：日常立体声可改走 Core Audio Process Tap（无驱动、2 声道、启停更轻）；影院多声道与浏览器音画同步仍需 HAL 虚拟设备注入输出延迟。现有 `ProcessTapCapture` 可作为接线基础。
- **双模式落地**：产品只有音乐/影院两个模式，默认音乐，并把用户上次选择的模式持久化；旧 `synchronized` 原始值只用于兼容解码，加载时迁移为音乐。
- **音乐模式**：走 `tap-capture-host` 的 Process Tap 2ch；固定 `.mutedWhenTapped`，读取期间静音当前默认输出（内置/HDMI/蓝牙均适用），停止或崩溃自动恢复；不写默认输出、无 latency 注入；音量走 HomePod `set_volume`。音乐模式不要求安装 HAL 驱动。
- **影院模式**：走 `virtual-audio-host` 的 Device Tap 8ch；保存并切换默认输出到 Flow，由 worker 写入协商 latency；停止时恢复 previous UID。
- **切换约束**：只有完全关闭（`desiredEnabled=false`、无 session、非 busy、非 routeSwitchInProgress、cleanup 已确认）才允许切换模式；ON/STARTING/STOPPING 时模式选择器禁用。
- **启动始终 OFF**：启用意图不持久化；App 启动后开关一定为关。若默认输出仍停在 Flow（上次崩溃/异常），启动自愈优先恢复记录的 previous UID，没有记录则回退到内置扬声器（否则第一个非 Flow 输出）；无法恢复时明确提示用户手动选择输出。影院开启时若发现 Flow 已是默认，也先恢复真实输出再重新租用，绝不把 Flow 记成自己的 previous。
- **影院占用门禁**：开启前用 `kAudioHardwarePropertyProcessObjectList`、`kAudioProcessPropertyDevices`（output scope）、`kAudioProcessPropertyIsRunningOutput` 找出真正占用 Flow 的进程；NSAlert 列出应用，用户确认后正常退出（`NSRunningApplication.terminate()` / SIGTERM），轮询设备 idle 最多 10 秒后继续。取消或超时保持 OFF，默认输出不变；只列真正使用 Flow 输出的进程，正常播放内置/电视输出的应用不会被要求退出；设备仍在 running 但识别不到可退出应用时提示重启 App/Mac。
- **UI 调整**：音频组件区块只在影院模式显示；音乐模式可以添加/移除/保存音箱，位置拖拽只在影院模式生效。
- **验证**：Debug/Release 构建通过；StateChecks、DefaultOutputRouteChecks、SystemVirtualInputChecks、SystemVolumeChecks、SystemSessionChecks、LatencyControlChecks 通过；ProcessTapCapture 27 项测试通过；`tap-capture-host` release 构建通过。真实 TCC、音乐模式出声、影院占用弹窗与声学同步仍需真机验收；内嵌采集宿主需重新打包安装后才生效。

## 2026-11-13

- 0.3.2/build3：修复 HAL 在 IO running 时的呈现延迟配置事务，移除设备客户端时只清理该 client 的遗留 IO slot；开关改为回读默认输出后再显示状态。清理安装后驱动签名、二进制比对、空闲/占用延迟写入及两 scope 回读通过；浏览器实际对口型未复验。
- 修复 PackageKit 把 App 重定位到开发构建目录的问题（递归关闭 `BundleIsRelocatable`），并保留自包含运行时。
- 0.3.3/build4：接入树莓派签名更新源（Ed25519 清单 + SHA256/大小校验），App 启动检查、设置内一键更新、菜单新版本提示；安装后按 boot-session 提示重启，禁止把旧内存驱动显示为已就绪。首次仍需手动安装 0.3.3。
- 发布 pkg/dmg 与 `updates/latest.json`；应用内完整授权升级、重启后驱动加载与音频仍待端到端验收。

## 2026-11-09

- **音量键打通**：HAL 驱动改为发布标准 Core Audio **control 对象**（`kAudioLevelControlClassID` + `kAudioBooleanControlClassID`，标量 0…1 / -96…0 dB，每设备一对）。macOS 从此把 Flow 当成有硬件音量的设备，音量键、控制中心滑块、静音键都直接作用在它上面；驱动不做 DSP，App 监听 control 值再通过 `set_volume` 下发 AirPlay 组，避免双重衰减。重复写入同值不再发通知，消除"回写—通知"回环。
- **默认输出切换改为"确认后才算成功"**：写 `kAudioHardwarePropertyDefaultOutputDevice` 返回 `noErr` 不再等同于成功。开启时轮询到系统真的把 Flow 报成默认输出（50 ms 一次，上限 3 s）才启动采集；关闭时同样确认 Mac 已回到原设备才停 worker。超时则回滚路由并明确报错。已打开的应用迁移较慢时，状态栏显示"正在等待已打开的应用迁移到 Flow…"，而不是提前宣称完成。
- **异常退出自愈**：`SIGTERM/SIGINT` 改走正常退出流程（先还原默认输出）；启动时若上次异常退出把默认输出留在 Flow 且没有会话，会自动切回当初借用的设备，并清空残留记录——避免"App 被杀 → 整机没声音"。
- **音箱图形改为官方产品图**：从 Apple 商店抓取透明底 PNG（HomePod 白/午夜，mini 白/午夜/黄/橙/蓝/绿/粉），裁掉透明边并按同一像素比例归一化，因此 HomePod 与 mini 的相对大小（168 mm 对 84 mm）是真实的；mini 在画布上取 0.62 比例以免过小。型号下拉默认布局改为"1 台午夜色 HomePod + 2 台白色 mini"；选中光晕只出现在布局编辑页，且改成贴合产品的胶囊/圆形柔光。
- 真机验收：驱动 control 探针（`clst` 2 个 control、`base=levl/vlme`、`base=togl/mute`）、`osascript set volume output volume 37 → scalar 0.37`、`set volume output muted true → mute 1`、App 侧 `SystemOutputVolumeService` 读写/监听全部通过；`DefaultOutputRouteChecks`（含新增的"未发布切换则不得开始采集""未确认恢复则明确报错"两项）、`StateChecks`、`SystemVolumeChecks`、`MultichannelChecks` 全部通过。安装包仍为 0.3.1（CFBundleVersion 2），二进制已更新并安装。

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
