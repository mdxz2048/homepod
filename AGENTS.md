# HomePod Flow 项目约定

先读 docs/MACBOOK_START_HERE.md 和 docs/collaboration/PROGRESS.md 的最新记录；历史交接内容不能覆盖当前源码与最新实测。

## 用户确定的更新流程

- 用户要求电脑始终只保留 HomePod Flow 最新版本。每次本机安装成功并核验后，清理旧版 App、独立测试版副本、旧 pkg/dmg 与安装临时备份/缓存；保留源码、测试证据、音箱布局和偏好设置。

完成应用发布任务时，不只保存源码：通过 tools/updates/build-and-publish.sh 构建完整 pkg/dmg 并发布到树莓派网站，更新网页 release.json 和带签名的 updates/latest.json。先完成相关检查、递增 apps/macos/project.yml 的版本/build，再发布；未完成的实验不得冒充正式可用更新。

- 网站：https://homepodflow.mddxz.top；根目录 /opt/sites/homepodflow。
- 树莓派 rpi3 管理/上传优先局域网 mdxz@192.168.0.100；Tailscale 100.116.204.31 是备用。实际操作前核实目标身份与连接，不要求用户为 App 下载更新开启 Tailscale。
- 密码不写入仓库、脚本、日志或发布制品。SSH 使用正常登录/agent/短期控制连接。Ed25519 发布私钥只在发布 Mac 的 ~/.config/homepodflow/update-signing-key.pem，不能上传服务器或提交 Git；App 只内置公钥。
- 制品先完整上传并原子改名，最后切换版本指针。校验网络下载的清单签名及 pkg SHA256/大小。
- App 更新先下载验证，再停止播放并确认默认输出恢复，经 macOS 管理员授权替换旧 App、Flow 驱动和运行环境。用户音箱布局和偏好保留。
- 安装成功并验证后清理旧组件备份和更新下载缓存。安装完提示用户重启；不得擅自重启电脑。
- 同次系统启动期间，磁盘替换不代表内存驱动已更新。使用 boot-session 标记等待重启，不能把旧驱动枚举成功当成新版加载完成。
- 不自动播放或以软件检查代替声学同步验收。代码测试、实际安装、驱动加载、最终浏览器音画效果分开报告。

详情：docs/collaboration/APP_UPDATES.md。冻结的核心 C ABI v1 与 baselines/M2-core-source.json 对应文件不得被更新流程顺带改动。
