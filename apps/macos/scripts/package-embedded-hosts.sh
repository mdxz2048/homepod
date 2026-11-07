#!/bin/sh
# Single-app packaging for HomePod Flow: embed the two signed capture hosts into
# HomePod Flow.app/Contents/Helpers/{TapCaptureHost,VirtualCaptureHost}.app, set
# LSUIElement for them, and re-sign children first then the parent last with the
# same ad-hoc default. Never uses codesign --deep as a signing strategy; verification
# uses codesign --verify --deep --strict on the staged result.
#
# Usage:
#   apps/macos/scripts/package-embedded-hosts.sh \
#     "/path/to/HomePod Flow.app" \
#     "/path/to/TapCaptureHost.app" \
#     "/path/to/VirtualCaptureHost.app" \
#     ["/path/to/output/HomePod Flow.app"]
#
# The main app input is read-only: a fresh bundle is staged in a temporary directory
# and only moved to the output path after verification passes. When output-app is
# omitted the result is "<main-app>.packaged.app" next to the input.
set -eu

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
    echo "usage: $0 <main-app> <tap-capture-host.app> <virtual-capture-host.app> [output-app]" >&2
    exit 64
fi

canon() {
    dir=$(cd "$(dirname "$1")" && pwd) || return 1
    printf '%s/%s\n' "$dir" "$(basename "$1")"
}

main_input=$(canon "$1")
tap_input=$(canon "$2")
virtual_input=$(canon "$3")
if [ "$#" -eq 4 ]; then
    output=$(canon "$4")
else
    output="$(dirname "$main_input")/$(basename "$main_input" .app).packaged.app"
fi

require_dir() { [ -d "$1" ] || { echo "error: bundle not found: $1" >&2; exit 2; }; }
require_dir "$main_input"
require_dir "$tap_input"
require_dir "$virtual_input"
[ ! -e "$output" ] || { echo "error: output already exists: $output" >&2; exit 2; }

check_host() {
    host_input=$1
    app_name=$2
    exe_name=$3
    bundle_id=$4
    host_exe=$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$host_input/Contents/Info.plist" 2>/dev/null || true)
    host_id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$host_input/Contents/Info.plist" 2>/dev/null || true)
    host_usage=$(/usr/libexec/PlistBuddy -c "Print :NSAudioCaptureUsageDescription" "$host_input/Contents/Info.plist" 2>/dev/null || true)
    [ "$host_exe" = "$exe_name" ] ||
        { echo "error: $app_name executable is '$host_exe', expected '$exe_name'" >&2; exit 2; }
    [ "$host_id" = "$bundle_id" ] ||
        { echo "error: $app_name bundle id is '$host_id', expected '$bundle_id'" >&2; exit 2; }
    [ -n "$host_usage" ] ||
        { echo "error: $app_name missing NSAudioCaptureUsageDescription" >&2; exit 2; }
    [ -x "$host_input/Contents/MacOS/$exe_name" ] ||
        { echo "error: $app_name executable is not runnable: $exe_name" >&2; exit 2; }
}

check_host "$tap_input" "TapCaptureHost.app" "tap-capture-host" "com.homepodflow.tap-capture-host"
check_host "$virtual_input" "VirtualCaptureHost.app" "virtual-audio-host" "com.homepodflow.virtual-capture-host"

stage=$(mktemp -d "${TMPDIR:-/tmp}/homepodflow-embed.XXXXXX")
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT INT TERM

staged_app="$stage/$(basename "$main_input")"
cp -R "$main_input" "$staged_app"
helpers="$staged_app/Contents/Helpers"
mkdir -p "$helpers"
rm -rf "$helpers/TapCaptureHost.app" "$helpers/VirtualCaptureHost.app"
cp -R "$tap_input" "$helpers/TapCaptureHost.app"
cp -R "$virtual_input" "$helpers/VirtualCaptureHost.app"

set_lsui_element() {
    /usr/libexec/PlistBuddy -c "Delete :LSUIElement" "$1" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$1"
}
set_lsui_element "$helpers/TapCaptureHost.app/Contents/Info.plist"
set_lsui_element "$helpers/VirtualCaptureHost.app/Contents/Info.plist"

codesign --force --sign - "$helpers/TapCaptureHost.app"
codesign --force --sign - "$helpers/VirtualCaptureHost.app"
codesign --force --sign - "$staged_app"

codesign --verify --deep --strict "$staged_app"

[ "$output" != "$main_input" ] || { echo "error: output must differ from main app input" >&2; exit 2; }
[ "$output" != "/" ] || { echo "error: refusing to replace root" >&2; exit 2; }
mv "$staged_app" "$output"

printf '%s\n' "Packaged $output with embedded TapCaptureHost/VirtualCaptureHost; codesign --verify --deep --strict passed."
