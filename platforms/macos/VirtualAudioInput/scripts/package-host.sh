#!/bin/sh
# Builds and ad-hoc signs the managed virtual-audio capture host only.
# It does not install anything, touch the HAL, request TCC, or start capture.
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product virtual-audio-host
bin_dir=$(swift build -c release --show-bin-path)
bundle="${1:-$PWD/dist/VirtualCaptureHost.app}"
identity="${CODE_SIGN_IDENTITY:--}"

mkdir -p "$bundle/Contents/MacOS"
cp "$bin_dir/virtual-audio-host" "$bundle/Contents/MacOS/virtual-audio-host"
cp scripts/Host-Info.plist "$bundle/Contents/Info.plist"
codesign --force --sign "$identity" "$bundle"
codesign --verify --deep --strict "$bundle"
printf '%s\n' "Built $bundle; no capture was started."
