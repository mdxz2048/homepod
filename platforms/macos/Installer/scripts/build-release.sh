#!/bin/bash
# Mac-only release orchestration for an internal HomePod Flow image.
#
# It builds the driver, both capture hosts, the App, embeds the hosts, then
# calls build-installer.sh. It never installs the result or changes the
# default output. Formal Developer ID notarization still requires the project's
# signing/CI process; this script defaults to ad-hoc signing.
set -euo pipefail

installer_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$installer_root/../../.." && pwd)"
source "$installer_root/scripts/lib.sh"

usage() {
    cat <<'EOF'
Usage:
  build-release.sh [--output DIR] [--version X.Y.Z] [--runtime DIR]
                   [--venv DIR] [--project DIR] [--library FILE]
                   [--latency-control FILE] [--no-bundled-runtime]

Environment:
  CODE_SIGN_IDENTITY  Defaults to "-" (ad-hoc). Use a Developer ID Application
                      identity for a signed App; the installer also needs a
                      Developer ID Installer identity for productbuild.
  FLOW_ARCHS          Defaults to the current machine architecture. The App,
                      driver and probe can be universal, but the two SwiftPM
                      capture hosts are currently built native; do not claim a
                      universal image until both hosts are universal too.
  FLOW_VENV           Python 3.12 venv with runtime packages and PyInstaller.
  FLOW_PROJECT        runtime-negotiated-v1 project directory.
  FLOW_CORE_LIBRARY   libflow_bridge.dylib.
  FLOW_LATENCY_CONTROL hflctl executable.

This script is macOS-only and expects Xcode, XcodeGen, and Swift 6.
EOF
}

fail() { /usr/bin/printf 'error: %s\n' "$*" >&2; exit 1; }

output="$repo_root/build/release"
version=""
runtime_input=""
venv="${FLOW_VENV:-$HOME/Developer/HomePodSpatialRouter/.venv}"
project_dir="${FLOW_PROJECT:-$HOME/Library/Application Support/HomePod Flow/runtime-negotiated-v1}"
core_library="${FLOW_CORE_LIBRARY:-$HOME/Developer/HomePodSpatialRouter/core-m2-validation/build/core/libflow_bridge.dylib}"
latency_control="${FLOW_LATENCY_CONTROL:-$HOME/Library/Application Support/HomePod Flow/bin/hflctl}"
bundle_runtime=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) [ "$#" -ge 2 ] || fail "--output needs a value"; output="$2"; shift 2 ;;
        --version) [ "$#" -ge 2 ] || fail "--version needs a value"; version="$2"; shift 2 ;;
        --runtime) [ "$#" -ge 2 ] || fail "--runtime needs a value"; runtime_input="$2"; shift 2 ;;
        --venv) [ "$#" -ge 2 ] || fail "--venv needs a value"; venv="$2"; shift 2 ;;
        --project) [ "$#" -ge 2 ] || fail "--project needs a value"; project_dir="$2"; shift 2 ;;
        --library) [ "$#" -ge 2 ] || fail "--library needs a value"; core_library="$2"; shift 2 ;;
        --latency-control)
            [ "$#" -ge 2 ] || fail "--latency-control needs a value"; latency_control="$2"; shift 2 ;;
        --no-bundled-runtime) bundle_runtime=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

for tool in /usr/bin/xcrun /usr/bin/xcodebuild /usr/bin/xcodegen /usr/bin/ditto; do
    [ -x "$tool" ] || command -v "$(basename "$tool")" >/dev/null 2>&1 ||
        fail "Required build tool is missing: $tool"
done

case "$output" in
    /*) ;;
    *) output="$repo_root/$output" ;;
esac

identity="${CODE_SIGN_IDENTITY:--}"
archs="${FLOW_ARCHS:-$(/usr/bin/uname -m)}"
build_root="$repo_root/build/homepodflow-release"
/bin/mkdir -p "$build_root"

flow_log "Building release with identity=$identity archs=$archs"

driver_stage="$build_root/driver"
FLOW_ARCHS="$archs" MC_PRODUCTION_IDENTITY=1 MC_SINGLE_DEVICE=1 \
    bash "$repo_root/platforms/macos/VirtualAudioDriver/scripts/build-stage-multichannel.sh" \
    "$driver_stage"
driver="$driver_stage/HomePodFlowAudioFamily.driver"

hosts_root="$build_root/hosts"
/bin/mkdir -p "$hosts_root"
(
    cd "$repo_root/platforms/macos/ProcessTapCapture"
    CODE_SIGN_IDENTITY="$identity" sh scripts/package-host.sh \
        "$hosts_root/TapCaptureHost.app"
)
(
    cd "$repo_root/platforms/macos/VirtualAudioInput"
    CODE_SIGN_IDENTITY="$identity" sh scripts/package-host.sh \
        "$hosts_root/VirtualCaptureHost.app"
)

(
    cd "$repo_root/apps/macos"
    xcodegen generate
    xcodebuild \
        -project HomePodFlow.xcodeproj \
        -scheme HomePodFlow \
        -configuration Release \
        -derivedDataPath "$build_root/derived" \
        ARCHS="$archs" \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_IDENTITY="$identity" \
        build
)

built_app="$build_root/derived/Build/Products/Release/HomePod Flow.app"
[ -d "$built_app" ] || fail "Xcode did not produce $built_app"
case "$built_app" in
    */"HomePod Flow.app") ;;
    *) fail "Unexpected built App path: $built_app" ;;
esac

runtime_dir=""
if [ "$bundle_runtime" -eq 1 ]; then
    if [ -n "$runtime_input" ]; then
        runtime_dir=$(cd "$runtime_input" && pwd -P) || fail "Runtime not found: $runtime_input"
    else
        runtime_dir="$build_root/Runtime"
        /bin/rm -rf "$runtime_dir"
        bash "$installer_root/scripts/build-bundled-runtime.sh" \
            --venv "$venv" \
            --project "$project_dir" \
            --library "$core_library" \
            --latency-control "$latency_control" \
            --output "$runtime_dir" \
            --force
    fi
    [ -f "$runtime_dir/manifest.json" ] ||
        fail "Runtime manifest is missing: $runtime_dir/manifest.json"
    [ -x "$runtime_dir/system-worker/system-worker" ] ||
        fail "Runtime worker is missing: $runtime_dir/system-worker/system-worker"
    /bin/rm -rf "$built_app/Contents/Resources/Runtime"
    /bin/mkdir -p "$built_app/Contents/Resources"
    /usr/bin/ditto --norsrc --noextattr "$runtime_dir" \
        "$built_app/Contents/Resources/Runtime"
fi

packaged_app="$build_root/HomePod Flow.app"
/bin/rm -rf "$packaged_app"
CODE_SIGN_IDENTITY="$identity" \
    "$repo_root/apps/macos/scripts/package-embedded-hosts.sh" \
    "$built_app" \
    "$hosts_root/TapCaptureHost.app" \
    "$hosts_root/VirtualCaptureHost.app" \
    "$packaged_app"

installer_identity=""
if [ "$identity" != "-" ]; then
    installer_identity="$identity"
fi

installer_args=(--app "$packaged_app" --driver "$driver" --output "$output")
if [ -n "$version" ]; then installer_args+=(--version "$version"); fi
if [ -n "$installer_identity" ]; then installer_args+=(--identity "$installer_identity"); fi

bash "$installer_root/scripts/build-installer.sh" "${installer_args[@]}"
if [ -n "$runtime_dir" ]; then
    /usr/bin/printf 'RUNTIME=%s\n' "$runtime_dir"
fi
