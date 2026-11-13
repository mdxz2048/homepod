# 延迟与开关修复候选（2026-11-13）

## 现场

已安装 /Applications/HomePod Flow.app（0.3.1）。hflctl 连续只读读到 hfla=0、hflr=1、48000Hz；播放时 running=true，退出 Chrome 和停止采集后两个 HAL running 标志为0，但 hfls 仍 busy。这能证明上报异常，不能单凭该状态证明最初遗留客户端的身份。

## 修复

- 驱动原先 Add/RemoveDeviceClient 共用空回调；现移除客户端时仅释放该 client 的遗留 IO slot，重复移除不重复扣计数，保留其他客户端。
- 延迟请求允许从 running 状态进入 host 配置事务，PerformChange 仍要求 IO 已停。依据本机 SDK AudioServerPlugIn.h 的 AudioDevice 状态变更约定：host 停 IO 后调用 PerformDeviceConfigurationChange，返回后恢复 IO。采样率变更仍要求空闲。
- helper/worker 不再在提交 host 事务前因为 running 就放弃；仍保留 revision、采样率、目标值、两 scope 回读、超时和取消门禁。
- App 开关 getter 与开启意图分离，显示已回读的默认输出状态；切换中禁用按钮，恢复失败保留恢复目标、保持未关闭状态。

## 验证

- test-multichannel.sh：dev/production family、实时路径、格式/布局/属性/时钟检查通过。
- 新回归场景：运行中请求不提前提交；host 停稳后 commit/revision 正确；移除遗留 client 不影响同设备其他 client，重复移除无下溢。
- Python test_latency*.py：27 项通过。
- Swift helper：8 项通过。
- DefaultOutputRouteChecks、SystemVirtualInputChecks、SystemSessionChecks 通过；包含切换未发布不显示开启、恢复失败不显示关闭。
- Release 构建通过，单设备 production driver staging 签名验证通过；SingleDeviceChecks 和 installer 静态检查通过。
- 关闭延迟回读时保持 on，成功后才转 off 的异步回归检查通过。
- 自包含运行时脚本改为只收录 adapters/bindings/processing，防止输出在仓库 build/ 下时递归复制整个仓库。

## 安装制品与清理

版本0.3.2/build3，arm64，ad-hoc，未公证。pkg/dmg已生成于 build/latency-fix-20261113，内嵌运行时约105MB，worker hello smoke通过。打包同时修复脚本非执行权限的调用方式及DMG文案变量边界问题。

用户要求在当前Mac彻底替换旧版并删除安装包。已准备清理安装脚本 build/clean-install-20261113.sh：无备份卸载旧App/驱动（保留个人布局）→安装pkg→签名、版本、App/driver二进制比对。电脑工具禁止操作Terminal，等待用户执行sudo；不收集密码。成功后再核对真实延迟并删除新旧安装包及本轮构建产物。

## 尚需真机验证

sudo -n 检查显示需要密码，尚未替换系统 App/驱动或重启 coreaudiod。安装候选后须验证 occupied→host stop→commit→restart、浏览器设备重新打开、默认输出失败处理及声画同步。源码测试不能替代这些验收。不要保证所有浏览器会热更新已打开的旧音频流。

## 首次安装发现（22:18）

用户已执行清理安装。旧App/驱动已卸载，新driver磁盘SHA256正确。PackageKit日志证实把App重定位至开发构建目录，导致 /Applications 缺失；已修改component plist，递归关闭BundleIsRelocatable。launchctl kickstart被本机SIP拒绝，内存旧驱动尚未重载。

补装脚本会在driver hash一致时跳过重复卸载，将验证过的staged App精确复制到 /Applications，然后请求coreaudiod正常终止/由launchd重新启动并核对PID变化。无需改动SIP。等待用户再次sudo执行；此期间不删除唯一安装制品。

## 真机安装与HAL验证结果（22:21后，覆盖上文待安装状态）

- 用户执行补装成功：/Applications/HomePod Flow.app 0.3.2/build3，App/driver签名及二进制比对通过。coreaudiod PID417→22848，已加载新驱动。
- 空闲hfla=0/hflr=1/hfls=idle，写2000ms后96000帧、revision2，两个stream latency scope一致。
- 建立静音AudioDevice IO客户端，before running=true/hfls=busy/2000ms/revision4；真实host事务写1500ms成功，after仍running=true/1500ms/revision5，两scope72000帧且verified全部true。未向HomePod播放声音。
- 恢复2000ms/revision6；另一个静音客户端被终止后running=false/hfls=idle，没有遗留busy。
- 已启动安装路径App（PID22997），未自动采集/播放。本轮未验证真实菜单开关或最终浏览器声学同步。
- 删除Downloads旧pkg、Desktop旧dmg、本次pkg/dmg、生成运行时/driver/host/Xcode构建及历史旧bundle共21项；剩5个root旧目录通过finish-cleanup脚本等待用户完成。不删除源码和个人布局配置。
