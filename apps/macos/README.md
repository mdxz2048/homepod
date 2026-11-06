# HomePod Flow macOS App

正式输入为 Mac 系统声音，播放仅有影院模式与同步播放两个模式。文件播放与手工声道选择不出现在产品界面中。实时链路正在真机验收，不能将本构建视为已验收的首次可用版本。

设置仅保留空间布局页：查找实际设备、添加到草稿、选择未识别的型号、拖动位置、保存或取消。设备型号来自发现结果的 model 标识，不根据用户命名猜测；已保存的型号校正和坐标在重新发现时保留。状态栏和设置共用 RoomCanvas，状态栏读取保存后的 layout，不显示未保存草稿。默认没有示例设备。

主开关显式开启系统声音，自动连接本机服务、重新发现并核对保存的全部音箱；有音箱不可用时报告错误，不自行缩减输出。启动不会自动采集或播放。音量本轮仅启动时生效；音画偏移未接入，控件禁用。当前 tap 为立体声，影院模式按同声播放退化，不假装原生环绕声。原生 mini 立体声对尚未验收。

## 构建

```sh
cd apps/macos
xcodegen generate
xcodebuild -scheme HomePodFlow -configuration Debug -derivedDataPath build CODE_SIGN_IDENTITY=- build
```

本机部署配置位于 Application Support/HomePod Flow/runtime.json，包含 python、project、library、capture_host 四个绝对路径。capture_host 为单独签名的 TapCaptureHost.app 内可执行文件。正式安装包尚未封装运行环境；配置不应提交到 Git。

## 验证

```sh
swiftc -swift-version 6 -parse-as-library HomePodFlow/Models/*.swift HomePodFlow/Services/*.swift HomePodFlow/State/*.swift Tests/StateChecks.swift -o /tmp/homepod-flow-state-checks
/tmp/homepod-flow-state-checks
```

DEBUG 专用 --show-settings 打开同一布局视图的检查窗口。--capture-directory /absolute/path 用于本进程窗口截图；默认明确使用视觉测试样例，追加 --capture-empty-layout 则使用生产空态。截图方法写入文件，不将 AppKit 缓存图当作实际系统 popover。Release 不开放这些测试入口。
