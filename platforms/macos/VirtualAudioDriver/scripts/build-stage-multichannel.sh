#!/bin/bash
# Produces a reviewable local family bundle ONLY.  Never installs, changes
# output, or restarts services.  Default is the safe .dev staging identity.
# MC_PRODUCTION_IDENTITY=1 selects the contract production UID/bundle identity.
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$source_root/scripts/safe-output.sh"
stage_root="$(flow_safe_output "${1:-$source_root/stage-family}")"
bundle="$stage_root/HomePodFlowAudioFamily.driver"
flow_reject_symlink "$bundle" "$bundle/Contents" "$bundle/Contents/MacOS" \
  "$bundle/Contents/MacOS/HomePodFlowAudioFamily" "$bundle/Contents/Info.plist"
mkdir -p "$bundle/Contents/MacOS"

if [[ "${MC_PRODUCTION_IDENTITY:-0}" == "1" ]]; then
  info_plist="$source_root/Info-Multichannel-Production.plist"
else
  info_plist="$source_root/Info-Multichannel.plist"
fi

compile=(xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.2 \
  -fvisibility=hidden -bundle)
if [[ -n "${FLOW_ARCHS:-}" ]]; then
  for arch in $FLOW_ARCHS; do
    compile+=(-arch "$arch")
  done
fi
if [[ "${MC_PRODUCTION_IDENTITY:-0}" == "1" ]]; then
  compile+=(-DMC_PRODUCTION_IDENTITY=1)
fi
if [[ "${MC_SINGLE_DEVICE:-0}" == "1" ]]; then
  compile+=(-DMC_SINGLE_DEVICE=1)
fi
compile+=("$source_root/src/FlowVirtualAudioMultichannel.c" \
  "$source_root/src/FlowMultichannelMap.c" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$bundle/Contents/MacOS/HomePodFlowAudioFamily")
"${compile[@]}"
cp "$info_plist" "$bundle/Contents/Info.plist"
plutil -lint "$bundle/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$bundle"
codesign --verify --strict --verbose=2 "$bundle"
shasum -a 256 "$source_root/src/FlowVirtualAudioMultichannel.c" \
  "$source_root/src/FlowVirtualAudioMultichannel.h" \
  "$source_root/src/FlowMultichannelMap.c" \
  "$source_root/src/FlowMultichannelMap.h" \
  "$bundle/Contents/MacOS/HomePodFlowAudioFamily"
echo "STAGE_ONLY=$bundle"
echo "PRODUCTION_IDENTITY=${MC_PRODUCTION_IDENTITY:-0}"
echo "SINGLE_DEVICE=${MC_SINGLE_DEVICE:-0}"
