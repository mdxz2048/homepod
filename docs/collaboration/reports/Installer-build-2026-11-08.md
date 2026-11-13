# 统一安装镜像构建验证

日期：2026-11-08。主机：MacBook-Pro.local（macOS 26.5.2，Xcode 26.6，arm64）。

## 范围

验证 `platforms/macos/Installer` 的构建链路：App + HAL 声卡 + 只读探针 → 组件 pkg → distribution pkg → DMG。**没有安装 pkg，没有重载 coreaudiod，没有改默认输出，没有请求 TCC，没有播放声音。**

源码在 Mac 临时目录 `/tmp/homepod-installer-check`，不覆盖用户 `~/Developer/homepodflow` 或已安装 App。

## 通过项

1. `check-installer.sh`：shell 语法、Distribution XML、plist、危险路径、驱动备份、`coreaudiod` 重载、设备探针、默认输出禁写、receipts 全部通过。
2. Swift 离线检查：
   - `AudioComponentChecks` 通过：未安装 / 等待加载 / 已就绪 / 重复副本 / 无效文件。
   - `StateChecks` 通过：原有偏好、布局、发现、模型、空启动安全未回归。
3. App Debug 构建：`xcodebuild` 成功；Info.plist 版本为 `0.3.0`。
4. 驱动：
   - `test-multichannel.sh` 通过（多声道 map、HAL 属性、7.1 顺序、2ch 拒绝等）。
   - `MC_PRODUCTION_IDENTITY=1 MC_SINGLE_DEVICE=1` 生产身份构建通过。
5. `build-release.sh` 全流程通过：
   - 生产驱动、两个 capture host、App、嵌入 hosts、pkg、DMG；
   - `hdiutil verify` 通过；
   - `codesign --verify --deep --strict` 对 App 通过；
   - `codesign --verify --strict` 对驱动通过；
   - payload 无 `._*` AppleDouble 文件；
   - `Distribution` 的 `hostArchitectures` 由实际公共架构生成，本次为 `arm64`。

## 产物

Mac 临时目录：

```text
/tmp/homepod-release-native2/Install HomePod Flow.pkg
/tmp/homepod-release-native2/HomePod Flow 0.3.0.dmg
/tmp/homepod-release-native2/HomePod Flow 0.3.0.manifest.json
```

Windows 工作区副本：

```text
build/release-20261108/Install HomePod Flow.pkg
build/release-20261108/HomePod Flow 0.3.0.dmg
build/release-20261108/HomePod Flow 0.3.0.manifest.json
```

manifest 记录 App/驱动可执行文件、pkg、DMG 的 SHA256；本次 `signed=false`。

## 未验证

- 未执行 `installer -pkg`、未运行 preinstall/postinstall 的真实 root 流程；
- 未验证旧驱动备份/替换、无关 HAL 拒绝、symlink 拒绝的真机行为；
- 未验证 `launchctl kickstart -k system/com.apple.audio.coreaudiod` 与 `flow-audio-probe` 的实际结果；
- 未验证 App 安装后的音频组件状态卡、默认输出恢复、TCC、系统采集、HomePod 出声/声学；
- 未做 Developer ID Application/Installer 签名、公证和 Gatekeeper 新机；
- 两个 SwiftPM capture host 当前为 arm64，整包不宣称 universal；
- Python runtime、core dylib、`runtime.json` 未封装。
