# 应用内更新与树莓派发布（2026-11-13）

## 已完成

网站确认 https://homepodflow.mddxz.top，树莓派rpi3位于局域网192.168.0.100（Tailscale备用100.116.204.31），部署目录/opt/sites/homepodflow，由网站账号拥有。网站访问仍走固定公网HTTPS域名，Mac无需Tailscale。已用局域网SSH上传；调查时临时启用的本机Tailscale已恢复停止。

0.3.3/build4自包含arm64预览构建已发布：
- pkg: downloads/HomePodFlow-0.3.3-4-arm64.pkg，50547811字节，SHA256 abc526a2953e62590bbe6964092907e785b836e1f07ba58bf1b0f70f5a14e4d6。
- dmg: downloads/HomePodFlow-0.3.3-4.dmg，51543611字节，SHA256 7d4cb59405c7e955cc8401c2361592fb63160119cd7c0f962970d03c5711a1b0。
- release.json与签名updates/latest.json指针更新在全部制品上传完成后原子切换；网页已增加支持应用内更新说明。

App更新链：固定Ed25519公钥验证清单，HTTPS同源pkg，版本/build/最低系统/架构校验，下载大小与SHA256验证；停止播放并确认默认输出恢复后调用独立osascript系统授权安装。管理员进程将pkg复制到root独占临时目录，重复SHA验证后调用installer；成功后校验App签名/build并清理下载。新版本安装时会退出旧App，安装器成功后清理旧App/driver临时备份。安装结束记录boot-session并要求用户重启，不主动重启系统。

首次手动bootstrap后可使用应用内更新。源码发布工具tools/updates/build-and-publish.sh完成构建→版本化下载制品→签名清单发布，不保存SSH密码。Ed25519发布私钥仅存发布Mac用户.config目录，权限600，未上传服务器/未提交Git。

## 验证

- Swift AppUpdateChecks：有效签名、错误key/篡改、版本build与降级、同源、OS/架构、包大小与SHA、命令转义通过。
- Python发布测试2项通过；安装器静态检查通过。
- StateChecks、DefaultOutputRouteChecks、AudioComponentChecks通过；Release构建成功。
- pkg展开验证App.pkg relocatable=false，App版本0.3.3/build4，包含固定feed URL及公钥。
- 公网重新下载latest.json与完整pkg，经生产Swift校验代码确认签名、字节数和SHA256一致。

## 尚待实际安装验收

0.3.3安装器已通过Finder打开，停在许可页面，等待用户自行阅读并确认许可和管理员授权，到重启提示先保留用于核验。尚未验证真实应用内下一版本安装、取消授权、失败恢复和重启后的组件就绪。代码/网络校验通过不代表这些端到端场景全部通过。安装器的说明资源仍有旧热重载文字，实际0.3.3 postinstall已按要求改为重启生效，以实际状态和重启提示为准。

## 最终安装与发布复核

用户已完成0.3.3/build4首次安装。系统安装器显示成功，App签名通过；旧App/驱动临时备份已清理；needs-restart=upgrade-requires-reboot，boot-session与当前一致。生产代码实机检查返回installedNeedsReload并提示重新启动Mac；使用已安装App的feed URL/公钥在线检查返回“当前已是最新版本”。未擅自重启或播放。

安装模板原先把onConclusion=Restart放在根元素，系统忽略。已按Apple Distribution XML Reference修正为Support pkg-ref的onConclusion=RequireRestart，并更新Welcome/ReadMe说明。首次已安装App本体不变；网站重新发布同版本的安装资源修正，制品名称包含内容哈希避免缓存冲突。

参考：https://developer.apple.com/library/archive/documentation/DeveloperTools/Reference/DistributionDefinitionRef/Chapters/Distribution_XML_Ref.html

最终pkg：downloads/HomePodFlow-0.3.3-4-arm64-8b4355c1f426.pkg，50547696字节，SHA256 8b4355c1f4263044e26f06e32565b370e3a24a94c8e43fa8a4738cedf05cfc4f。公网重新下载后经生产Swift签名/大小/哈希校验通过。

最终网页DMG：{"arch": "arm64", "available": true, "build": "4", "bytes": 51543948, "date": "2026-11-13", "file": "HomePodFlow-0.3.3-4-ff0bfa7558e2.dmg", "min_macos": "15.0", "name": "HomePod Flow", "preview": true, "sha256": "ff0bfa7558e2903d85073c9a9be54386f1e76842d310c7973539261945bac64e", "version": "0.3.3"}。

bootstrap实际安装已验证，下一次完整应用内授权升级/取消授权/失败恢复和重启后的音频未宣称通过。上述早期“待bootstrap”条目由本段覆盖。

本机bootstrap安装及服务端最终制品验证后，已删除本轮本地pkg/dmg、版本发布目录、生成App/driver/runtime、pkg展开目录及过期手工安装/清理脚本；正式安装与服务端最新制品保留。
