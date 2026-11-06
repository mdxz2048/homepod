#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
bin_dir=$(swift build -c release --show-bin-path)
bundle="${1:-$PWD/dist/TapCaptureProbe.app}"
mkdir -p "$bundle/Contents/MacOS"
cp "$bin_dir/tap-capture-probe" "$bundle/Contents/MacOS/tap-capture-probe"
cp scripts/Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle"
printf '%s\n' "Built $bundle; packaging did not start capture."
