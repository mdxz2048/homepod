#!/bin/bash
# Build a complete update and publish artifacts before switching the signed feed.
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd)
[ "$#" -ge 2 ] || { echo "Usage: bash $0 VERSION BUILD [SSH_HOST]" >&2; exit 2; }
version=$1
build=$2
host=${3:-mdxz@192.168.0.100}
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ && "$build" =~ ^[1-9][0-9]*$ ]] || exit 2
export PATH="/opt/homebrew/bin:$PATH"
venv=${FLOW_VENV:-$HOME/Developer/HomePodSpatialRouter/.venv}
output="$repo/build/releases/$version-$build"
helper_build="$repo/build/update-helper"
(cd "$repo/tests/virtual_audio/chrome_latency/hflctl"; swift build -c release --scratch-path "$helper_build")
bash "$repo/platforms/macos/Installer/scripts/build-release.sh" \
    --version "$version" --output "$output" --project "$repo" \
    --venv "$venv" --latency-control "$helper_build/release/hflctl"
control_dir=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/homepodflow-publish.XXXXXX")
control="$control_dir/ssh"
cleanup() { ssh -S "$control" -O exit "$host" >/dev/null 2>&1 || true; /bin/rm -rf "$control_dir"; }
trap cleanup EXIT
ssh -MNf -o ControlMaster=yes -o "ControlPath=$control" -o ControlPersist=300 "$host"
"$venv/bin/python" "$repo/tools/updates/publish.py" \
    --package "$output/Install HomePod Flow.pkg" --dmg "$output/HomePod Flow $version.dmg" \
    --version "$version" --build "$build" --output "$output/publication" \
    --notes "${FLOW_RELEASE_NOTES:-修复与体验改进；安装后请重新启动 Mac。}" \
    --ssh-host "$host" --ssh-control "$control"
echo "Published https://homepodflow.mddxz.top/updates/latest.json"
