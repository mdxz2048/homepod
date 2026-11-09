# MacBook 开发接续入口

迁移日期：2026-11-07（Asia/Shanghai）。

## 开发目录与版本

Mac 开发目录：`/Users/lvzhipeng/Developer/homepodflow`。
来自 Windows 当前工作区，包含 Git 历史及未提交文件。迁移时 HEAD 为 `b343216`，分支 `codex/virtual-audio-mvp`；请用 `git status` 和 `git log -1` 核实，迁移不代表正式发布。
GitHub：`https://github.com/mdxz2048/homepod.git`。

先读本文，再读 `docs/collaboration/SESSION_HANDOFF.md`、`PROGRESS.md`、`INTEGRATION_SINGLE_DEVICE.md`、`LATENCY_PRODUCT_PLAN.md`，以及 `apps/macos/README.md`。历史文档包含早期状态，当前源码、最近提交和最新实测优先。

## 现有 Mac 环境

- Xcode：`/Applications/Xcode-26.6.0.app`。
- 原 Python 环境：`/Users/lvzhipeng/Developer/HomePodSpatialRouter/.venv/bin/python`。不要复制 Windows 的虚拟环境。
- 原部署源码：`/Users/lvzhipeng/Developer/HomePodSpatialRouter/live-validation/source`。
- 已安装 App：`/Users/lvzhipeng/Applications/HomePod Flow.app`。
- 原配置：`~/Library/Application Support/HomePod Flow/runtime.json`，包含私有本机配置，不提交仓库。

新开发目录与旧运行目录独立。编辑新目录不会自动更新已安装 App，运行配置仍指向原部署目录。完成编译验收后再按用户任务处理部署和路径调整，勿批量替换旧目录。

## 接续开发

在 Mac ChatGPT 的 `homepodflow` 项目中附加本开发目录，然后发送：

> 请读取 docs/MACBOOK_START_HERE.md，再核对 git status、最近提交和交接文档，接续 HomePod Flow 的开发。先确认当前状态，保留未提交改动，不自动播放、重启音频服务或安装驱动。

该项目有 SwiftUI App、C/C++ 核心、Python worker/AirPlay 适配、macOS 音频采集及虚拟声卡。离线构建与实际出声验收要区分；目前不能宣称正式发布、原生环绕声或浏览器音画补偿完成。

App 构建入口见 `apps/macos/README.md`；Homebrew 工具可位于 `/opt/homebrew/bin`，非交互 shell 需设置 PATH。

安装镜像入口见 `platforms/macos/Installer/README.md`。它把 App 与 HAL 声卡放进
同一个 pkg/dmg，preinstall 备份旧 Flow 驱动，postinstall 重载 coreaudiod 并
检查固定设备 UID。先在 Mac 运行
`bash platforms/macos/Installer/scripts/check-installer.sh`，再构建
`build-release.sh`；安装/卸载会改系统音频目录，必须由用户明确批准后执行。
发布包会在 App 的 `Contents/Resources/Runtime` 内包含 PyInstaller 冻结的
Python worker、runtime 项目、core dylib 和 hflctl，不再依赖 Homebrew Python 或
外部 runtime.json；仍需在 Mac 上实际安装、签名/公证和声学验收。

双机开发前先核对分支与工作区，通过 Git 提交和拉取交换更改；未提交文件不会随 Git 自动同步。本次迁移只是一次完整快照，并未启用持续同步。
