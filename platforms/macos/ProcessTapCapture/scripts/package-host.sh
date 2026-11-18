#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release --product tap-capture-host
# The silence keep-alive is built from the sibling capture package and
# shipped next to this host so it can be spawned as a child process.
keepalive_dir="../VirtualAudioInput"
( cd "$keepalive_dir" && swift build -c release --product silence-keepalive ) >/dev/null
bin_dir=$(swift build -c release --show-bin-path)
bundle="${1:-$PWD/dist/TapCaptureHost.app}"
identity="${CODE_SIGN_IDENTITY:--}"
mkdir -p "$bundle/Contents/MacOS"
cp "$bin_dir/tap-capture-host" "$bundle/Contents/MacOS/tap-capture-host"
cp "$( cd "$keepalive_dir" && swift build -c release --show-bin-path )/silence-keepalive" \
   "$bundle/Contents/MacOS/silence-keepalive"
cp scripts/Host-Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign "$identity" "$bundle"
printf '%s\n' "Built $bundle; no capture was started."
