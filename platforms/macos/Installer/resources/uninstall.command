#!/bin/bash
set -euo pipefail
script_dir="$(cd "$(dirname "$0")" && pwd)"

cat <<'EOF'
HomePod Flow 卸载

这会删除：
  • /Applications/HomePod Flow.app
  • /Library/Audio/Plug-Ins/HAL 中的 HomePod Flow 声卡
  • /Library/Application Support/HomePodFlow 组件数据

不会删除其他应用的音频组件。
用户偏好默认保留；彻底清理请运行带 --purge 的脚本。

如果当前有声音在播放，会被中断。
EOF

/usr/bin/printf '\n输入 UNINSTALL 继续：'
read -r answer
[ "$answer" = "UNINSTALL" ] || { /usr/bin/printf '已取消。\n'; exit 1; }

sudo "$script_dir/uninstall-homepodflow.sh"
/usr/bin/printf '\n完成。按回车关闭窗口。'
read -r _
