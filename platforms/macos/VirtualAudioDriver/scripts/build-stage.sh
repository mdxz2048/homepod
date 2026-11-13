#!/bin/bash
# Produces a reviewable local bundle ONLY. Never installs, changes output or restarts services.
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$source_root/scripts/safe-output.sh"
stage_root="$(flow_safe_output "${1:-$source_root/stage}")"
bundle="$stage_root/HomePodFlowAudio.driver"
flow_reject_symlink "$bundle" "$bundle/Contents" "$bundle/Contents/MacOS" \
  "$bundle/Contents/MacOS/HomePodFlowAudio" "$bundle/Contents/Info.plist"
mkdir -p "$bundle/Contents/MacOS"
compile=(xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.2 \
  -fvisibility=hidden -bundle)
if [[ -n "${FLOW_ARCHS:-}" ]]; then
  for arch in $FLOW_ARCHS; do
    compile+=(-arch "$arch")
  done
fi
compile+=("$source_root/src/FlowVirtualAudio.c" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$bundle/Contents/MacOS/HomePodFlowAudio")
"${compile[@]}"
cp "$source_root/Info.plist" "$bundle/Contents/Info.plist"
plutil -lint "$bundle/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
shasum -a 256 "$source_root/src/FlowVirtualAudio.c" "$source_root/src/FlowVirtualAudio.h" \
  "$bundle/Contents/MacOS/HomePodFlowAudio"
echo "STAGE_ONLY=$bundle"
