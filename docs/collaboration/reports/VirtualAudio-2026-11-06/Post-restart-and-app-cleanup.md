# 重启验证与 App 副本清理

日期：2026-11-06（Asia/Shanghai）。用户授权密码登录、配置 SSH 公钥登录及只保留一个最新 Flow App。凭据不记录。

- 通过已知主机密钥校验连接 Mac，配置专用公钥及本机 `homepod-mac` SSH 别名；无密码登录实测成功。
- Mac uptime 约 11 分钟；`system_profiler SPAudioDataType` 显示 HomePod Flow Audio（2ch）、5.1 Side（6ch）、7.1（8ch），均为 48kHz。默认媒体/系统输出均为内置扬声器。此检查只证明重启后可见设备枚举，不证明隐藏设备属性、逐通道非零 PCM 或完整播放链路。
- 找到 12 份主 App。保留 `/Users/lvzhipeng/Applications/HomePod Flow.app`，其 executable SHA256 为 `506cb0ed4d388bd653fd771fdeb622a931a73d7eedb6b98139bdd5ac40f3630c`，与最新 VolumeDerivedData Debug 构建相同，为此前已验证音量能力的安装身份。另有稍晚构建的 Release，但未替换既有签名/权限身份。
- 检查 runtime 配置未引用任何待清理主 App；辅助采集程序、源码、配置和驱动均保留。
- 将开发目录内 11 份重复主 App 从 LaunchServices 注销并移至 `/Users/lvzhipeng/.Trash/HomePod-Flow-duplicates-20261106-195853`，含 `restore-manifest.json`；未永久删除。再次注册保留 App。
- 清理后开发目录主 App 副本数为 0；保留 App 严格签名验证通过。未启动采集或播放。
- 代码评估发现 `DeviceTapCapture.validate` 当前限制 2..8ch；虽然 family 定义 mono 设备，原生 1ch 采集仍被拒绝，需补齐端到端实现与测试。
