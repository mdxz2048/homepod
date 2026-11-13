# 统一安装包本机安装与失败修复

日期：2026-11-08。主机：MacBook-Pro.local（macOS 26.5.2，arm64）。

## 第一次安装失败

Installer 日志显示两个独立问题：

1. **App 组件被跳过**

   PackageKit 认为 `com.homepodflow.mac` 1.0.0 已安装在
   `~/HomePodFlow-Backups/uninstall-manual-20261108/UserApplications-HomePod Flow.app`，
   而新包是 0.3.0，因此跳过 App 组件。备份 bundle 不应以 `.app` 形式留在用户目录。

2. **Support postinstall 失败**

   `flow_write_manifest` 写入 JSON 后用 `plutil -lint` 校验，macOS 报
   `Unexpected character { at line 1`，导致 PackageKit 报“运行软件包脚本时出错”。

## 修复

- 旧 App/驱动/Support 备份改为 `.zip`，删除会参与 Spotlight/PackageKit 扫描的
  `.app`/`.driver` bundle；已有备份也已压缩。
- manifest 校验改为 `python3 -m json.tool`。
- 重新构建 `Install HomePod Flow.pkg` / `HomePod Flow 0.3.0.dmg`。

## 第二次安装结果

安装成功：

- `/Applications/HomePod Flow.app` 存在，版本 0.3.0，`codesign --verify --deep --strict` 通过；
- 内置 `Contents/Resources/Runtime` 存在，冻结 worker `hello` 返回 protocol/core ABI 1；
- `/Library/Audio/Plug-Ins/HAL/HomePodFlowAudioFamily.driver` 存在；
- `pkgutil` 写入 `com.homepodflow.mac`、`com.homepodflow.audio.driver.pkg`、
  `com.homepodflow.support.pkg` 三个 receipt；
- `InstalledComponent.json` 写入驱动版本和 SHA256；
- 默认输出仍是 MacBook Pro 扬声器。

## 仍需重启

Support postinstall 无法重启 `coreaudiod`：

```text
150: Operation not permitted while System Integrity Protection is engaged
```

因此写入了 `needs-restart=coreaudiod-reload-failed`。重启 Mac 后新 HAL 驱动才会加载；
之后需要验证 App 状态卡、TCC、实际系统声音到 HomePod 与声学。

## 产物

Mac：

```text
/Users/Shared/HomePodFlow-0.3.0/HomePod Flow 0.3.0.dmg
/Users/Shared/HomePodFlow-0.3.0/Install HomePod Flow.pkg
```

DMG SHA256：`386502c61bb36b0568dc751e6387d333fe3befde5e89d1ce04d5ec0d3652710d`

pkg SHA256：`6d0ef04b1794e70a06269de680995be8becfa648935a93580434a002cec3cbd8`
