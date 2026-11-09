# HomePod Flow macOS App

正式输入为 Mac 系统声音，播放仅有影院模式与同步播放两个模式。文件播放与手工声道选择不出现在产品界面中。实时链路正在真机验收，不能将本构建视为已验收的首次可用版本。

设置仅保留空间布局页：查找实际设备、添加到草稿、选择未识别的型号、拖动位置、保存或取消。设备型号来自发现结果的 model 标识，不根据用户命名猜测；已保存的型号校正和坐标在重新发现时保留。状态栏和设置共用 RoomCanvas，状态栏读取保存后的 layout，不显示未保存草稿。默认没有示例设备。

主开关显式开启系统声音，自动连接本机服务、重新发现并核对保存的全部音箱；有音箱不可用时报告错误，不自行缩减输出。启动不会自动采集或播放。默认输出在 worker 收到 `start` **之前**切到 Flow 并回读校验；Core Audio 属性写入是同步的，但已打开的播放器会异步迁移，因此应用只等待一个很短的稳定窗口，再异步观察客户端是否真正迁移，不用长等待阻塞采集（长等待会让虚拟设备先进入 running，导致延迟协商写入被推迟）。关闭时先把默认输出还给原设备并短暂稳定，再停止 worker，避免 Mac 在清理期间保持静音。

音量走系统标准通道：HAL 驱动为每台设备发布 Volume + Mute **control** 对象（`kAudioLevelControlClassID` / `kAudioBooleanControlClassID`，-96…0 dB 曲线），因此 macOS 音量键、控制中心滑块和静音键都直接作用在 Flow 设备上；App 监听 control 的标量值，再通过 `set_volume` 下发给 AirPlay 组。驱动本身不做 DSP 衰减，避免双重衰减。菜单滑块与系统音量双向同步，重复写入同值不会产生通知，避免回写—通知回环。音画偏移未接入，控件禁用。当前 tap 为立体声，影院模式按同声播放退化，不假装原生环绕声。原生 mini 立体声对尚未验收。

空间布局的音箱型号包含 HomePod（白色、午夜色）和 HomePod mini（白色、午夜色、黄色、橙色、蓝色、绿色、粉色）。画布直接用 Apple 官网商店的透明产品图（已裁掉透明边、按同一像素比例归一化），因此 HomePod 与 mini 的相对大小（168 mm 对 84 mm）是真实的；渲染时 mini 取 0.62 的真实比例，避免在 40 多点的高度下小到看不清。颜色只影响外观，不参与路由或型号识别。旧布局里的 `homePod` / `mini` 原始值继续按白色型号解码。

## 构建

```sh
cd apps/macos
xcodegen generate
xcodebuild -scheme HomePodFlow -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build
```

开发构建使用 Application Support/HomePod Flow/runtime.json，包含 python、project、library、capture_host 等绝对路径；配置不应提交到 Git。正式安装包优先使用
`Contents/Resources/Runtime` 内的冻结 worker、runtime 项目、core dylib 和 hflctl，
不再依赖 Homebrew Python 或外部 runtime.json。

## 安装镜像

统一安装流程在 `platforms/macos/Installer`。它把 App 和 HAL 声卡放进同一个
`.pkg`，再由 `.dmg` 承载：

```sh
bash platforms/macos/Installer/scripts/build-release.sh --output build/release
```

产物为 `Install HomePod Flow.pkg`、`HomePod Flow <version>.dmg` 和 manifest。
安装脚本只处理 bundle id 为 `com.homepodflow.audio.driver` 的 HAL 组件，备份旧
驱动后安装，重载 `coreaudiod`，不会把虚拟声卡设为默认输出。App 设置页会显示
“音频组件”状态；未就绪时系统声音开关禁用。

`build-release.sh` 会调用 `build-bundled-runtime.sh`，用 PyInstaller 冻结
Python worker，并把 runtime 项目、`libflow_bridge.dylib`、`hflctl` 一起放进
App 的 `Contents/Resources/Runtime`。已在 Mac 构建 pkg/dmg 并通过签名校验，
但尚未实际安装、Developer ID 公证、TCC 或实际出声验证。

发布升级包时递增 `project.yml` 的 `MARKETING_VERSION`。安装包可覆盖升级
App/驱动并保留布局偏好；Installer 会提示重启。空间布局页在同步模式下也允许
移除已保存的音箱，断电或搬走的设备不需要先切到影院模式。

## 验证

```sh
swiftc -swift-version 6 -parse-as-library HomePodFlow/Models/*.swift HomePodFlow/Services/*.swift HomePodFlow/State/*.swift Tests/StateChecks.swift -o /tmp/homepod-flow-state-checks
/tmp/homepod-flow-state-checks

swiftc -swift-version 6 -parse-as-library HomePodFlow/Models/*.swift HomePodFlow/Services/*.swift HomePodFlow/State/*.swift Tests/AudioComponentChecks.swift -o /tmp/homepod-flow-audio-component-checks
/tmp/homepod-flow-audio-component-checks

swiftc -swift-version 6 -parse-as-library HomePodFlow/Models/*.swift HomePodFlow/Services/*.swift HomePodFlow/State/*.swift Tests/DefaultOutputRouteChecks.swift -o /tmp/homepod-flow-default-output-checks
/tmp/homepod-flow-default-output-checks
```

DEBUG 专用 --show-settings 打开同一布局视图的检查窗口。--capture-directory /absolute/path 用于本进程窗口截图；默认明确使用视觉测试样例，追加 --capture-empty-layout 则使用生产空态。截图方法写入文件，不将 AppKit 缓存图当作实际系统 popover。Release 不开放这些测试入口。
