# HomePod Flow 安装与自动升级

更新：2026-11-13。网站为 https://homepodflow.mddxz.top，树莓派 rpi3，局域网 192.168.0.100，Tailscale 100.116.204.31；网站根目录 `/opt/sites/homepodflow`。上传/管理优先局域网，外出可用 Tailscale；App 总是访问固定 HTTPS 域名，不要求用户安装 Tailscale。

## 用户流程

0.3.3/build4 起加入更新入口。旧版0.3.2需要先从网站手动安装一次0.3.3，完成后重启Mac；之后启动App自动检查，菜单“设置 · 有新版本…”及设置中的“一键更新”提供入口。

点击更新后：下载完整pkg → 验证签名清单、包大小与SHA256 → 停止声音并确认默认输出恢复 → macOS管理员授权 → 独立安装进程替换App、虚拟声卡和内置运行时 → 验证新App/驱动 → 清理旧组件备份及下载缓存 → 提示重启。安装器不会自动重启机器。

升级保留音箱布局与偏好。只有Flow自己拥有的App/驱动和更新缓存参与清理；不遍历删除用户其他下载文件。安装失败时不会显示成功；用于恢复的临时备份只在最终postinstall成功验证后删除。App/driver位于固定系统路径，禁止PackageKit重定位到开发目录。

HAL插件的磁盘替换不证明内存版本已更新。postinstall记录当前boot-session并要求重启；同一次启动期间App显示“更新已安装，请重新启动Mac”，禁止继续使用旧内存驱动。重启后boot-session改变，再核对设备枚举。

## 发布结构

- `release.json`：兼容现有网页下载与版本展示。
- `downloads/HomePodFlow-<version>-<build>-arm64-<hash>.pkg`：App使用的完整包。
- `downloads/HomePodFlow-<version>-<build>-<hash>.dmg`：首次安装的网页下载。
- `updates/latest.json`：`{payload, signature}`，两项均为base64；payload是UTF-8 JSON原始字节，signature为Ed25519签名。

payload字段：schemaVersion=1、version、build整数、minimumSystemVersion、architecture、packageURL、sha256、bytes、notes。App内固定公钥；网络侧不能仅修改SHA256就替换安装包。校验通过后，管理员进程再把pkg复制到root独占临时目录并重复校验，随后调用系统installer，避免用户可写文件的校验/安装竞态。

发布密钥只在发布Mac的 `~/.config/homepodflow/update-signing-key.pem`，权限600，**不能提交Git或上传树莓派**。需要安全备份它；更换公钥需要经过现有受信更新链发布。App内公钥与网站域名位于 `apps/macos/project.yml`，都是公开信息。

## 每次发布

先更新project.yml中的版本/build并完成代码检查，然后：

```sh
bash tools/updates/build-and-publish.sh 0.3.3 4 mdxz@192.168.0.100
```

局域网不可用时显式换成 `mdxz@100.116.204.31`。SSH使用系统正常登录方式或agent，脚本不保存密码。完整安装包会先上传到临时文件，原子改名；下载制品全部上传完成后才更新网页和签名版本指针，避免App看到尚未上传完的安装包。

单独发布已有制品：

```sh
~/Developer/HomePodSpatialRouter/.venv/bin/python tools/updates/publish.py \
  --package 'build/releases/0.3.3-4/Install HomePod Flow.pkg' \
  --dmg 'build/releases/0.3.3-4/HomePod Flow 0.3.3.dmg' \
  --version 0.3.3 --build 4 --output build/publication \
  --ssh-host mdxz@192.168.0.100
```

目前为arm64内部预览构建，ad-hoc代码签名，未公证；Ed25519更新信任链不等同于Apple Developer ID签名/公证。首次安装仍走macOS正常安装授权。

## 验证边界

AppUpdateChecks覆盖清单签名/篡改、版本/build/降级、主机/架构/macOS、包大小与哈希、命令转义；publish测试覆盖签名和网页指针与制品一致；installer静态检查及Release构建必须通过。实际授权升级、失败恢复和重启后的组件就绪仍需端到端验证，不能仅凭编译宣称所有升级场景通过。

本次0.3.3已在当前Mac完成首次手动安装；安装后同boot-session的重启提示与生产配置的在线更新检查均通过。下一次完整应用内授权升级和重启后音频仍需真实验收。
