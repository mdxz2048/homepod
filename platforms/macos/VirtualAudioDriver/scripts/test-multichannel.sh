#!/bin/bash
# Experimental family tests only.  Never installs, changes system audio, or
# loads into coreaudiod.  The production stereo test.sh is unchanged.
set -euo pipefail
source_root="$(cd "$(dirname "$0")/.." && pwd)"
source "$source_root/scripts/safe-output.sh"
bash "$source_root/scripts/path-checks.sh"
test_root="$(flow_safe_output "${1:-$source_root/stage-tests-family}")"
flow_reject_symlink "$test_root/multichannel-map-checks" \
  "$test_root/multichannel-driver-checks" \
  "$test_root/multichannel-driver-checks-production"
mkdir -p "$test_root"

if command -v python3 >/dev/null 2>&1; then
  python3 "$source_root/scripts/check-rt-path.py"
  python3 "$source_root/scripts/check-multichannel-tables.py"
  python3 "$source_root/scripts/check-map-syntax.py"
fi

xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.2 \
  "$source_root/tests/MultichannelMapChecks.c" \
  -o "$test_root/multichannel-map-checks"
"$test_root/multichannel-map-checks"

xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.2 \
  "$source_root/tests/MultichannelChecks.c" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$test_root/multichannel-driver-checks"
"$test_root/multichannel-driver-checks"

# The production identity must also compile; only .dev is opened by default.
xcrun clang -std=c11 -O2 -Wall -Wextra -Werror -mmacosx-version-min=14.2 \
  -DMC_PRODUCTION_IDENTITY=1 \
  "$source_root/tests/MultichannelChecks.c" \
  -framework CoreAudio -framework CoreFoundation \
  -o "$test_root/multichannel-driver-checks-production"
"$test_root/multichannel-driver-checks-production"
