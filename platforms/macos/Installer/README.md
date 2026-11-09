# HomePod Flow 统一安装镜像

这个目录把 **HomePod Flow.app** 和 **HomePod Flow Audio 虚拟声卡** 放进同一个
macOS 安装流程：一个 `.pkg` 安装在 `.dmg` 里，用户只需要双击一次安装程序。

结论：是的，应该做统一镜像；但不是做一个“只拖 App”的 DMG。HAL 声卡必须写入
`/Library/Audio/Plug-Ins/HAL`，还要重载 `coreaudiod`，因此发行载体应是签名
`.pkg`，`.dmg` 只负责承载和说明。

## 安装内容

| 路径 | 内容 |
|---|---|
| `/Applications/HomePod Flow.app` | 主 App |
| `HomePod Flow.app/Contents/Resources/Runtime/` | 冻结的 Python worker、runtime 项目、core dylib、hflctl |
| `/Library/Audio/Plug-Ins/HAL/HomePodFlowAudioFamily.driver` | 产品 HAL 声卡，显示名 `HomePod Flow Audio` |
| `/Library/Application Support/HomePodFlow/bin/flow-audio-probe` | 只读设备枚举检查 |
| `/Library/Application Support/HomePodFlow/InstalledComponent.json` | 安装清单、版本、可执行文件 SHA256 |
| `/Library/Application Support/HomePodFlow/InstallerBackup/<时间>/` | 安装前旧 Flow 声卡备份 |
| `/var/log/homepodflow-install.log` | 安装/卸载日志 |

安装程序**不会**：

- 把 `HomePod Flow Audio` 设为默认输出；如果安装前默认输出已经是 Flow，
  postinstall 会用内置 helper 恢复为内置扬声器，其他输出不动；
- 删除其他厂商的 HAL 组件；
- 请求麦克风/TCC 权限；
- 删除用户音箱布局或偏好设置；
- 写入外部 `runtime.json`；发布 App 优先使用内置 `Contents/Resources/Runtime`。

## 自包含运行环境

`Contents/Resources/Runtime` 由 `build-bundled-runtime.sh` 生成：

| 内容 | 说明 |
|---|---|
| `system-worker/system-worker` | PyInstaller `--onedir` 冻结的 Python worker |
| `system-worker/_internal/` | Python 3.12、pyatv、av/FFmpeg、numpy、scipy、cryptography 等 |
| `project/` | `runtime-negotiated-v1` 的 adapters/bindings/processing 源码 |
| `lib/libflow_bridge.dylib` | 冻结的 C ABI v1 核心 |
| `bin/hflctl` | 延迟校准 helper |
| `manifest.json` | 相对路径清单 |

App 启动时优先读取内置 manifest；只有设置
`HOMEPODFLOW_USE_EXTERNAL_RUNTIME=1` 才回退到
`~/Library/Application Support/HomePod Flow/runtime.json`。因此正式安装不再要求
用户安装 Homebrew Python 或手工写 runtime.json。

## 构建

### 一键构建（Mac）

要求：macOS 14.2+、Xcode 26.6、XcodeGen、Swift 6、Python 3.12 venv（含
`pyinstaller` 和运行依赖）、runtime 项目、`libflow_bridge.dylib`、`hflctl`。

```bash
bash platforms/macos/Installer/scripts/build-release.sh \
  --output build/release \
  --venv "$HOME/Developer/HomePodSpatialRouter/.venv" \
  --project "$HOME/Library/Application Support/HomePod Flow/runtime-negotiated-v1" \
  --library "$HOME/Developer/HomePodSpatialRouter/core-m2-validation/build/core/libflow_bridge.dylib" \
  --latency-control "$HOME/Library/Application Support/HomePod Flow/bin/hflctl"
```

默认 ad-hoc 签名，适合内部验收。输出：

```text
build/release/Install HomePod Flow.pkg
build/release/HomePod Flow <version>.dmg
build/release/HomePod Flow <version>.manifest.json
```

默认按当前机器架构构建。`FLOW_ARCHS` 只控制 App/驱动/probe 的 clang 架构；
两个 SwiftPM capture hosts 仍按本机架构构建。要宣称整包 universal，必须先让
两个 host 和冻结 worker 也完成 arm64+x86_64 合成并通过验证。

正式 Developer ID 构建需要同时具备
`Developer ID Application`（App/驱动/hosts）和
`Developer ID Installer`（pkg）身份；当前仓库只提供流程和校验，不宣称已公证。

### 分步构建（已有预构建 App/驱动）

```bash
bash platforms/macos/Installer/scripts/build-installer.sh \
  --app "/path/to/HomePod Flow.app" \
  --driver "/path/to/HomePodFlowAudioFamily.driver" \
  --output build/release \
  --version 0.3.0
```

App 必须包含
`Contents/Helpers/{TapCaptureHost.app,VirtualCaptureHost.app}`；开发阶段可加
`--allow-missing-hosts`，但该产物不能作为发布包。

驱动必须是生产身份
`com.homepodflow.audio.driver` + 可执行文件 `HomePodFlowAudioFamily`，不是
`.family.dev` 调试验证包。

## 安装流程

1. 用户打开 `.dmg`，双击 `Install HomePod Flow.pkg`。
2. Installer 显示 `Welcome.html` / `ReadMe.html`，要求管理员权限。
3. `preinstall`：
   - 尝试退出正在运行的 HomePod Flow；
   - 扫描 HAL 目录，把 bundle id 为
     `com.homepodflow.audio.driver` 或
     `com.homepodflow.audio.driver.family.dev` 的 Flow 组件打成 zip 后移走；
   - 遇到 symlink 或无关 bundle id 直接失败，不覆盖。
4. 安装驱动、App、只读探针。
5. `support` 包最后执行 `postinstall`：
   - 校验 bundle id/可执行文件/签名；
   - 修正 `root:wheel` 和权限；
   - 写安装清单；
   - `launchctl kickstart -k system/com.apple.audio.coreaudiod`；
   - 以控制台用户身份运行 `flow-audio-probe` 检查
     `com.homepodflow.virtual-audio.surround71.v1`；
   - 如果重载或枚举失败，写
     `/Library/Application Support/HomePodFlow/Installer/needs-restart`，
     安装继续成功，App 会提示重启。
   - **macOS 26 + SIP 实测**：`launchctl kickstart -k system/com.apple.audio.coreaudiod`
     返回 `Operation not permitted while System Integrity Protection is engaged`。
     因此安装后通常需要重启 Mac 才能让新 HAL 设备出现；这不是安装失败。
6. 打开 App，设置页顶部显示“音频组件已就绪”。

## 升级

- 新包必须递增 `apps/macos/project.yml` 的 `MARKETING_VERSION`（以及需要时
  `CURRENT_PROJECT_VERSION`）。`build-release.sh` 用 App 版本生成 pkg/DMG 版本。
- 覆盖安装时，preinstall 把旧驱动打成 zip 备份，App/驱动/Support 一起更新，用户
  音箱布局和偏好保留。
- Installer Distribution 设置 `onConclusion="Restart"`，安装完成后会提示重启；
  macOS 26 的 SIP 不允许安装脚本重启 `coreaudiod`。
- App 的“升级/重装…”会搜索 `/Users/Shared/HomePodFlow-*`（按修改时间最新）、
  `/Applications`、Downloads、Desktop 和 App 同目录下的 `Install HomePod Flow.pkg`。
- 相同版本重复安装可能被 PackageKit 跳过；发布升级包时请 bump 版本。

## App 内的首次运行状态

`AudioComponentService` 只读检查：

- `/Library/Audio/Plug-Ins/HAL/*.driver` 中是否有唯一且完整的
  `com.homepodflow.audio.driver`；
- 当前 CoreAudio 是否枚举到
  `com.homepodflow.virtual-audio.surround71.v1`。

状态与动作：

| 状态 | 文案 | 动作 |
|---|---|---|
| `notInstalled` | 还没有安装 HomePod Flow 声卡 | 安装音频组件… |
| `installedNeedsReload` | 已安装，系统尚未加载 | 重新检查 / 声音设置 / 日志 |
| `ready` | HomePod Flow Audio 已就绪 | 重新检查 |
| `conflict` | 发现多个 Flow 声卡副本 | 重新安装 |
| `invalid` | 文件不完整或签名无效 | 重新安装 / 日志 |

App 不会自己执行 root 写入。安装按钮只打开同目录或
`HOMEPODFLOW_INSTALLER_PKG` 指定的 `.pkg`；这样不需要引入未签名的
privileged helper。

## 卸载

```bash
sudo platforms/macos/Installer/scripts/uninstall-homepodflow.sh
sudo platforms/macos/Installer/scripts/uninstall-homepodflow.sh --purge
```

DMG 内也提供 `Uninstall HomePod Flow.command`。卸载只移除精确路径和 Flow
bundle id，不删除 `/Library/Audio/Plug-Ins/HAL` 本身或其他厂商组件。

旧 App/驱动/Support 目录以 `.zip` 备份。不要把备份保留成 `.app`/`.driver`
bundle，否则 Installer/PackageKit 可能把它当成已安装的旧版本并跳过新组件。

## 静态检查

```bash
bash platforms/macos/Installer/scripts/check-installer.sh
```

检查项包括 shell 语法、Distribution XML、plist、危险路径、驱动备份逻辑、
`coreaudiod` 重载、设备探针、Flow 默认输出安全恢复和 receipts。

## 已验证 / 仍未完成

已在 Mac（macOS 26.5.2、Xcode 26.6）完成：

- `check-installer.sh` 全部通过；
- `AudioComponentChecks`、`StateChecks` 通过；
- App Debug 构建通过；
- 驱动多声道测试与生产单设备驱动构建通过；
- `build-release.sh` 完整构建 pkg/dmg，`hdiutil verify` 通过；
- 冻结 worker 通过 `hello`、真实 mDNS `scan`、以及无音频 `start` 失败清理检查；
- 冻结运行环境中没有 `/opt/homebrew` 或 `/usr/local` 的 Mach-O 依赖；
- App/驱动签名校验通过，payload 无 AppleDouble 文件；
- `Distribution` 的 `hostArchitectures` 按实际公共架构生成（本次 arm64）。

仍未完成：

- 已在本机成功安装 pkg（三个 receipt 写入，App/驱动/Runtime 落盘）；由于 SIP 仍需重启加载声卡；
- 未验证安装后 App 启动、TCC、真实出声或声学；
- 未做 Developer ID 签名、公证、Gatekeeper 新机验证；
- 内置 Runtime 目前是 arm64；整包不宣称 universal。
- 未验证安装后真实系统声音 → 虚拟声卡 → HomePod 全链路、TCC、声学同步。
- 未实现自动更新、增量安装、安装失败自动回滚（旧驱动会保留备份，但需要人工恢复）。
