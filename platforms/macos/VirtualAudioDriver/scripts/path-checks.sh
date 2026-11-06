#!/bin/bash
# Tests only private paths/symlinks; never accesses or creates the system HAL path.
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$source_root/scripts/safe-output.sh"
scratch="$(mktemp -d "$HOME/.homepod-flow-path-tests.XXXXXX")"
cleanup() {
  case "$scratch" in "$HOME"/.homepod-flow-path-tests.*) rm -rf -- "$scratch" ;; esac
}
trap cleanup EXIT
if flow_safe_output /Library/Audio/Plug-Ins/HAL >/dev/null 2>&1; then
  echo 'FAIL: accepted system HAL output' >&2; exit 1
fi
if flow_safe_output relative-path >/dev/null 2>&1; then
  echo 'FAIL: accepted relative output' >&2; exit 1
fi
if flow_safe_output "$scratch/../escape" >/dev/null 2>&1; then
  echo 'FAIL: accepted dot escape' >&2; exit 1
fi
mkdir "$scratch/safe" "$scratch/target"
ln -s "$scratch/target" "$scratch/safe/HomePodFlowAudio.driver"
if flow_reject_symlink "$scratch/safe/HomePodFlowAudio.driver" >/dev/null 2>&1; then
  echo 'FAIL: accepted symlink bundle' >&2; exit 1
fi
ln -s /Library/Audio "$scratch/system-link"
if flow_safe_output "$scratch/system-link/Plug-Ins/HAL" >/dev/null 2>&1; then
  echo 'FAIL: accepted symlink parent to HAL' >&2; exit 1
fi
flow_safe_output "$scratch/safe/review" >/dev/null
echo 'PASS stage path rejection: system HAL, relative/dot paths, symlink bundle and parent'
