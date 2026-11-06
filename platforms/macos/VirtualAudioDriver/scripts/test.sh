#!/bin/bash
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$source_root/scripts/safe-output.sh"
bash "$source_root/scripts/path-checks.sh"
test_root="$(flow_safe_output "${1:-$source_root/stage-tests}")"
flow_reject_symlink "$test_root/driver-checks"
mkdir -p "$test_root"
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.2 \
  "$source_root/tests/DriverChecks.c" -framework CoreAudio -framework CoreFoundation \
  -o "$test_root/driver-checks"
"$test_root/driver-checks"
