# 原生UI首版整合记录

日期2026-11-05。用户交付UI包并明确授权多Agent评估开发；不再处理音频，仅交付已有音乐与原始录音。本文为协调执行记录，独立结论见UI-qa-review-2026-11-05.md。

## 交付与分工

架构负责产品/能力边界审查，UI负责Views与Style，App负责模型/状态/服务/入口/工程，QA独立复核。交接文档作为设计输入，包内AGENTS另存reference，不覆盖既有指令。品牌沿用HomePod Flow。

apps/macos新增原生MenuBarExtra、唯一设置Scene、五页设置、共享RoomCanvas、标准化坐标、位置选择/拖动/微调、应用/取消/重置、同步模式只读、参数本机持久化。DemoRouterService不联网、不捕获或播放；运行开关仅演示。真实worker未接入，未支持项明确说明。界面与核心架构见../APP_ARCHITECTURE.md。

## 实际验证

Mac arm64 macOS26.5.2，Xcode26.6。源码12文件与回传manifest完全一致，UI-app-source.json保存基线。M2保护35文件全部SHA匹配，未改核心/绑定/发送适配器及冻结头，故未重复无关音箱播放。

| 项目 | 结果 | 证据 |
|---|---|---|
| Debug原生clean build | Pass | UI-macos/build-debug.log |
| 最终DEBUG验收工具增量build | Pass | UI-macos/build-debug-final.log |
| Release构建 | Pass | UI-macos/build-release.log |
| 真实Swift状态程序 | Pass | UI-macos/state-build.log、state-checks.log |
| 参数 | 范围/NaN/Inf规整，负偏移保存但不称实际生效 | StateChecks.swift |
| 草稿与恢复 | 预览/取消/应用、同步模式方法guard、参数/布局重启恢复、坏JSON/未知version回退、运行不恢复 | 同上 |
| 状态视觉 | 9场景18张缓存快照成功，部分可视检查 | UI-macos/final、capture-results.json |
| 发布预览包 | 生成，SHA与metadata一致；Mac已启动Release进程 | artifacts/HomePod-Flow-UI-preview-macOS.zip、UI-macos/metadata.json |

首轮真实执行发现SceneBuilder条件场景编译失败，及Observation didSet自赋值造成setter递归、状态测试exit139。已修复为单Window、独立存储/计算属性，二轮构建与状态执行均通过。保留失败日志。DEBUG自动打开设置的launch行为不可靠，后改显式NSWindow验收fixture并强持有，最终构建通过；正常产品仍用唯一Window(id:settings)，不引入常驻主控制台。

## 视觉证据限制与剩余验收

每个设置截图都有capture-method记录。本机SCK currentProcess路径未成功采集，9场景均回退AppKit缓存。侧栏vibrancy留白、灰色控件/材质不能作为完整外观通过证据；不推断具体系统权限原因。另一次screencapture返回could not create image from window，原始错误保留。

菜单图片是临时host中同一MenuPopoverView的缓存；设置图片是DEBUG原生窗口fixture的同一SettingsRootView。不是点击MenuBarExtra系统弹窗的截图；选择/移动由启动参数注入，不代表真实鼠标手势已执行。整体只标演示预览交付，不标完整P0/P1验收。

参考中的P2写实家具已简化矢量。完整系统popover/侧栏外观、实际点击聚焦唯一窗口、真实鼠标拖动、文本提交失焦等待补。真实AirPlay服务接UI、系统捕获、立体声对、音画补偿及声学量化仍未通过，不能由本UI记录推定。

下一任务为受管音频worker和App服务契约/事件接入；保持C ABI v1不变，先文件源与已验证独立输出，再引入平台捕获。未获实际后端确认前，UI保持Demo或不支持状态。
