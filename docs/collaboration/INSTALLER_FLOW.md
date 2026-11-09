# 安装镜像与声卡安装流程

日期：2026-11-08。状态：**实现、Mac 构建与本机安装完成；重启加载与声学未验证**。

## 1. 决定

用户要求把 HomePod Flow 做成镜像版本，并把声卡安装合到一起。采用：

> **一个 `.dmg` → 一个 `Install HomePod Flow.pkg` → App + HAL 声卡 + 只读探针。**

不使用“只拖 App”的 DMG，也不在 App 内用未签名 privileged helper 写
`/Library`。原因是：

- HAL 声卡必须写入系统目录并由 `coreaudiod` 加载；
- 安装需要管理员权限和明确的备份/回滚；
- 当前 App 是 ad-hoc/开发签名，不能安全地声称 `SMJobBless` 或特权 helper 已验收；
- `.pkg` 的 `preinstall/postinstall` 是 macOS 上可审计、可卸载、可记 receipt 的路径。

## 2. 用户流程

| 步骤 | 用户看到 | 系统行为 | 失败分支 |
|---|---|---|---|
| 1 打开 DMG | `Install HomePod Flow.pkg`、卸载说明、README | 不执行任何安装 | — |
| 2 双击 pkg | 欢迎/说明/许可，管理员授权 | Installer 启动 | 取消 → 无修改 |
| 3 安装 | 进度条 | 退出 App、备份旧 Flow 驱动、安装 App/驱动/探针、重载 coreaudiod、探测设备 | 无关 HAL bundle/symlink → 失败且不覆盖 |
| 4 完成 | 安装成功 | 写 `InstalledComponent.json`；若未加载则写 `needs-restart` | 重载失败 → 安装仍成功，提示重启 |
| 5 打开 App | 设置页“音频组件”卡 | 只读检查 bundle + CoreAudio UID | 未安装 → “安装音频组件…” |
| 6 选择输出 | 播放器/系统设置中的 `HomePod Flow Audio` | 用户手动选择 | 不改默认输出 |

## 3. App 状态机

`AudioComponentService` 只读检查，不执行 root 操作：

```text
checking
  ├─ no bundle + no device        → notInstalled
  ├─ one valid bundle + device    → ready
  ├─ one valid bundle, no device  → installedNeedsReload
  ├─ one invalid bundle           → invalid
  └─ multiple expected bundles    → conflict
```

启动系统声音的门禁：

- `ready`：允许；
- `checking`：等待检查完成；不启动；
- `notInstalled` / `installedNeedsReload` / `invalid` / `conflict`：禁止，
  菜单开关禁用并显示安装/修复提示。

`installedNeedsReload` 不推断“权限失败”或“声卡损坏”；它只表示 bundle 存在但
CoreAudio 尚未枚举到 UID。

## 4. 安装脚本的安全约束

### preinstall

- 只接受启动卷；
- 只退出 `HomePod Flow` 进程，不杀其他音频进程；
- 只处理 bundle id 为
  `com.homepodflow.audio.driver` /
  `com.homepodflow.audio.driver.family.dev` 的 bundle；
- 遇到 symlink 或无关 bundle id 直接失败；
- 先 `ditto` 到
  `/Library/Application Support/HomePodFlow/InstallerBackup/<timestamp>/`，
  再移除旧路径。

### postinstall

- 在 Support 包中最后执行，保证驱动和探针都已落盘；
- 校验 bundle id、可执行文件名、`codesign --verify --strict`；
- `root:wheel`，目录 755，文件 644，可执行文件 755；
- 写 SHA256/版本/时间清单；
- `launchctl kickstart -k system/com.apple.audio.coreaudiod`；
- 用 `launchctl asuser <console-uid>` 运行只读探针；
- 失败时写 `needs-restart`，不把安装标成失败；如果默认输出是 Flow，则用内置
  `flow-default-output` helper 恢复为内置扬声器。

macOS 26 真机实测：SIP 会拒绝 `launchctl kickstart -k system/com.apple.audio.coreaudiod`，
返回 `150: Operation not permitted while System Integrity Protection is engaged`。
因此安装/卸载后可能需要重启 Mac 才能加载或卸载 HAL 设备；App 状态卡和安装日志必须
明确显示这个结果，不能宣称自动重载已成功。

### 默认输出

安装/卸载脚本本身不直接写
`kAudioHardwarePropertyDefaultOutputDevice`、`defaults write` 或
`SwitchAudioSource`。Support 包内的 `flow-default-output` helper 只在
“当前默认是 Flow”时切回内置扬声器；非 Flow 输出不动。正常播放会话仍由 App
在显式开始/停止时切换和恢复。

备份约定：旧 App、HAL 驱动和 Support 目录都以 zip 保存，不能以 `.app`/`.driver`
bundle 形式留在用户目录。否则 Spotlight/PackageKit 可能把备份当成已安装的旧版本，
在版本比较时跳过新组件。

## 4.1 自包含 Runtime

发布 App 的 `Contents/Resources/Runtime` 包含：

```text
system-worker/system-worker      PyInstaller 冻结的 Python 3.12 worker
system-worker/_internal/         pyatv/av/numpy/scipy/cryptography 等
project/                         runtime-negotiated-v1
lib/libflow_bridge.dylib         C ABI v1 核心
bin/hflctl                       延迟校准 helper
manifest.json                    相对路径清单
```

`SystemRouterService.installed()` 优先解析内置 `manifest.json`；只有
`HOMEPODFLOW_USE_EXTERNAL_RUNTIME=1` 时才读外部 `runtime.json`。冻结 worker
启动时直接执行，不再 `python -m adapters.system_worker`。

验证要求：

- `hello` 返回 protocol/core ABI 1；
- 真实 mDNS `scan` 能找到 HomePod；
- 无效 host 的 `start` 在播放前失败并 `cleanup_complete=true`；
- 冻结目录内 Mach-O 不得引用 `/opt/homebrew` 或 `/usr/local`。

## 4.2 升级

- 新包递增 `MARKETING_VERSION`；pkg 覆盖安装 App、驱动和 Support，preinstall
  以 zip 备份旧驱动，用户偏好和布局保留。
- Distribution 使用 `onConclusion="Restart"`，安装完成后提示重启；SIP 仍阻止
  脚本直接重启 `coreaudiod`。
- App 的“升级/重装…”搜索 `/Users/Shared/HomePodFlow-*` 最新 pkg 以及
  `/Applications`、Downloads、Desktop、App 同目录。同版本重复安装可能被
  PackageKit 跳过，因此升级必须 bump 版本。

## 5. 版本与身份

| 项 | 值 |
|---|---|
| App bundle id | `com.homepodflow.mac` |
| 驱动 bundle id | `com.homepodflow.audio.driver` |
| 驱动可执行文件 | `HomePodFlowAudioFamily` |
| 驱动安装名 | `HomePodFlowAudioFamily.driver` |
| 设备 UID | `com.homepodflow.virtual-audio.surround71.v1` |
| 产品 pkg id | `com.homepodflow.audio.driver.pkg` / `com.homepodflow.mac` / `com.homepodflow.support.pkg` |

App 版本与 pkg 版本必须一致；驱动版本单独显示，不强制等于 App 版本。

## 6. 验收清单（Mac）

构建：

- [ ] `build-release.sh` 退出 0；
- [ ] `pkgutil --check-signature` 对 pkg 通过（签名构建）；
- [ ] `hdiutil verify` 对 DMG 通过；
- [ ] manifest 中 App/驱动/pkg/DMG SHA256 与实际文件一致。

安装：

- [ ] 新机无旧驱动：安装后只出现一个 `HomePod Flow Audio`；
- [ ] 旧 stereo `HomePodFlowAudio.driver`：被备份并替换；
- [ ] 旧 `HomePodFlowAudioFamily.driver`：只保留一个生产身份；
- [ ] 无关 HAL bundle 存在时安装不删除它；
- [ ] symlink 场景安装失败且不跟随；
- [ ] 安装日志包含 bundle id、版本、SHA256；
- [ ] `coreaudiod` 重载成功或明确写 `needs-restart`；
- [ ] 默认输出未被改成 `HomePod Flow Audio`。

App：

- [ ] 未安装 → 菜单禁用 + 设置页“安装音频组件…”；
- [ ] 已安装未加载 → “重新检查 / 声音设置 / 日志”；
- [ ] 已加载 → “音频组件已就绪”，允许开启系统声音；
- [ ] 重复 bundle → “有冲突”，禁止开始；
- [ ] 无效 bundle → “需要修复”，禁止开始。

卸载：

- [ ] App/驱动/Support 数据被移除；
- [ ] 其他 HAL 组件保留；
- [ ] receipts 被清理；
- [ ] `--purge` 只清当前用户偏好；
- [ ] 卸载后默认输出仍可用（必要时重启）。

## 7. 仍未完成

- 已通过 Mac 上的 `pkgbuild/productbuild/hdiutil/codesign` 构建，并已在本机安装；
- Developer ID 签名、公证、Gatekeeper 新机；
- 自动更新、安装失败自动回滚、安装前低电量/播放中提示；
- TCC、真实系统采集、声道/声学验收。

在这些完成前，安装镜像只能称为“内部统一安装流程”，不能称为正式发布包。
