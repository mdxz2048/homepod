#!/bin/bash
# Builds a single macOS distribution package and disk image containing:
#   - HomePod Flow.app
#   - HomePodFlowAudioFamily.driver (the product HAL sound card)
#   - a read-only HAL probe used by the postinstall
#
# This script never installs anything, never touches /Library, and never
# changes the default output. It only writes into an explicitly approved
# output directory.
set -euo pipefail

installer_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$installer_root/../../.." && pwd)"
source "$installer_root/scripts/lib.sh"
source "$repo_root/platforms/macos/VirtualAudioDriver/scripts/safe-output.sh"
source_root="$repo_root"

usage() {
    cat <<'EOF'
Usage:
  build-installer.sh --app PATH --driver PATH --output DIR [options]

Required:
  --app PATH        Signed "HomePod Flow.app" with embedded capture hosts.
  --driver PATH     Signed production HAL bundle:
                    HomePodFlowAudioFamily.driver (not the .dev identity).
  --output DIR      Absolute output directory for the .pkg/.dmg and manifest.

Options:
  --version X.Y.Z   Product version. Defaults to the App's CFBundleShortVersionString.
  --identity NAME   "Developer ID Installer" identity for productbuild/hdiutil.
  --no-dmg          Build only the distribution .pkg.
  --allow-missing-hosts
                    Allow a development App without embedded capture hosts.
  --force           Replace existing output files.
  -h, --help        Show this help.

Environment:
  FLOW_ARCHS        Space-separated clang architectures for the probe only,
                    for example "arm64 x86_64". The App, driver and embedded
                    SwiftPM hosts must already contain matching architectures.
EOF
}

fail() {
    /usr/bin/printf 'error: %s\n' "$*" >&2
    exit 1
}

canon_existing() {
    local path="$1" directory base
    [ -e "$path" ] || fail "Path does not exist: $path"
    directory=$(cd "$(/usr/bin/dirname "$path")" && pwd -P) || fail "Cannot resolve: $path"
    base=$(/usr/bin/basename "$path")
    /usr/bin/printf '%s/%s\n' "$directory" "$base"
}

lipo_archs() {
    /usr/bin/lipo -archs "$1" 2>/dev/null |
        /usr/bin/tr ' ' '\n' |
        /usr/bin/grep -v '^$' |
        /usr/bin/sort -u
}

app=""
driver=""
output=""
version=""
identity=""
make_dmg=1
allow_missing_hosts=0
force=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --app) [ "$#" -ge 2 ] || fail "--app needs a value"; app="$2"; shift 2 ;;
        --driver) [ "$#" -ge 2 ] || fail "--driver needs a value"; driver="$2"; shift 2 ;;
        --output) [ "$#" -ge 2 ] || fail "--output needs a value"; output="$2"; shift 2 ;;
        --version) [ "$#" -ge 2 ] || fail "--version needs a value"; version="$2"; shift 2 ;;
        --identity) [ "$#" -ge 2 ] || fail "--identity needs a value"; identity="$2"; shift 2 ;;
        --no-dmg) make_dmg=0; shift ;;
        --allow-missing-hosts) allow_missing_hosts=1; shift ;;
        --force) force=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[ -n "$app" ] || fail "--app is required"
[ -n "$driver" ] || fail "--driver is required"
[ -n "$output" ] || fail "--output is required"

app=$(canon_existing "$app")
driver=$(canon_existing "$driver")
case "$output" in
    /*) ;;
    *) output="$PWD/$output" ;;
esac
output=$(flow_safe_output "$output")

for tool in \
    /usr/bin/pkgbuild /usr/bin/productbuild /usr/bin/hdiutil /usr/bin/ditto \
    /usr/bin/shasum /usr/bin/plutil /usr/bin/codesign /usr/bin/install \
    /usr/bin/xcrun /usr/sbin/pkgutil /usr/bin/find /usr/bin/sed \
    /usr/bin/lipo /usr/bin/tr /usr/bin/sort /usr/bin/grep; do
    [ -x "$tool" ] || fail "Required macOS tool is missing: $tool"
done

[ -d "$app" ] || fail "App bundle not found: $app"
app_id=$(flow_bundle_id "$app" || true)
[ "$app_id" = "$FLOW_APP_BUNDLE_ID" ] || fail "Unexpected App bundle id: $app_id"
app_version=$(flow_bundle_version "$app" || true)
[ -n "$app_version" ] || fail "App has no CFBundleShortVersionString: $app"
if [ -z "$version" ]; then version="$app_version"; fi
/usr/bin/printf '%s' "$version" | /usr/bin/grep -Eq '^[0-9]+(\.[0-9]+){1,3}$' ||
    fail "Invalid version: $version"
[ "$app_version" = "$version" ] ||
    fail "App version $app_version does not match requested product version $version"
[ -x "$app/Contents/MacOS/HomePod Flow" ] || fail "App executable is missing"
usage_text=$(/usr/libexec/PlistBuddy -c 'Print :NSAudioCaptureUsageDescription' \
    "$app/Contents/Info.plist" 2>/dev/null || true)
[ -n "$usage_text" ] || fail "App is missing NSAudioCaptureUsageDescription"
/usr/bin/codesign --verify --deep --strict "$app" ||
    fail "App signature verification failed: $app"

if [ "$allow_missing_hosts" -eq 0 ]; then
    for host in TapCaptureHost.app VirtualCaptureHost.app; do
        [ -d "$app/Contents/Helpers/$host" ] ||
            fail "App is missing embedded helper: $host (use --allow-missing-hosts for a development build)"
        /usr/bin/codesign --verify --deep --strict "$app/Contents/Helpers/$host" ||
            fail "Embedded helper signature verification failed: $host"
    done
fi

[ -d "$driver" ] || fail "Driver bundle not found: $driver"
flow_validate_bundle "$driver"
driver_version=$(flow_bundle_version "$driver" || true)
/usr/bin/codesign --verify --strict "$driver" ||
    fail "Driver signature verification failed: $driver"

work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/homepodflow-installer.XXXXXX")
cleanup() { /bin/rm -rf "$work"; }
trap cleanup EXIT INT TERM

probe="$work/flow-audio-probe"
default_output="$work/flow-default-output"
clang_command=(/usr/bin/xcrun clang -std=c11 -O2 -Wall -Wextra -Werror
    -mmacosx-version-min=14.2)
if [ -n "${FLOW_ARCHS:-}" ]; then
    for arch in $FLOW_ARCHS; do
        clang_command+=(-arch "$arch")
    done
fi
clang_command+=("$installer_root/tools/flow_audio_probe.c"
    -framework CoreAudio -framework CoreFoundation -o "$probe")
"${clang_command[@]}"
default_command=(/usr/bin/xcrun clang -std=c11 -O2 -Wall -Wextra -Werror
    -mmacosx-version-min=14.2)
if [ -n "${FLOW_ARCHS:-}" ]; then
    for arch in $FLOW_ARCHS; do default_command+=(-arch "$arch"); done
fi
default_command+=("$installer_root/tools/flow_default_output.c"
    -framework CoreAudio -framework CoreFoundation -o "$default_output")
"${default_command[@]}"

# The distribution may only advertise architectures that every shipped
# executable supports. This prevents an arm64-only host bundle from being
# offered on an Intel Mac merely because the App itself is universal.
common_archs=""
intersect_archs() {
    local file="$1" archs current next=""
    archs=$(lipo_archs "$file") || return 1
    [ -n "$archs" ] || return 1
    if [ -z "$common_archs" ]; then
        common_archs="$archs"
        return 0
    fi
    for current in $common_archs; do
        if /usr/bin/printf '%s\n' "$archs" | /usr/bin/grep -qx "$current"; then
            next="${next:+$next }$current"
        fi
    done
    common_archs="$next"
    [ -n "$common_archs" ]
}

intersect_archs "$app/Contents/MacOS/HomePod Flow" ||
    fail "Cannot determine App executable architectures"
intersect_archs "$driver/Contents/MacOS/$FLOW_DRIVER_EXECUTABLE" ||
    fail "Cannot determine driver executable architectures"
intersect_archs "$probe" ||
    fail "Cannot determine probe architectures"
intersect_archs "$default_output" ||
    fail "Cannot determine default-output helper architectures"
if [ "$allow_missing_hosts" -eq 0 ]; then
    intersect_archs "$app/Contents/Helpers/TapCaptureHost.app/Contents/MacOS/tap-capture-host" ||
        fail "Cannot determine TapCaptureHost architectures"
    intersect_archs "$app/Contents/Helpers/VirtualCaptureHost.app/Contents/MacOS/virtual-audio-host" ||
        fail "Cannot determine VirtualCaptureHost architectures"
fi
runtime_root="$app/Contents/Resources/Runtime"
if [ -e "$runtime_root" ]; then
    [ -f "$runtime_root/manifest.json" ] ||
        fail "Bundled runtime is missing manifest.json"
    [ -x "$runtime_root/system-worker/system-worker" ] ||
        fail "Bundled runtime is missing the frozen worker"
    intersect_archs "$runtime_root/system-worker/system-worker" ||
        fail "Cannot determine frozen worker architectures"
fi
distribution_archs=""
for arch in arm64 x86_64; do
    if /usr/bin/printf '%s\n' "$common_archs" | /usr/bin/grep -qx "$arch"; then
        distribution_archs="${distribution_archs:+$distribution_archs,}$arch"
    fi
done
[ -n "$distribution_archs" ] ||
    fail "App, driver, probe and embedded hosts have no common architecture"

stage="$work/stage"
app_root="$stage/app-root"
driver_root="$stage/driver-root"
support_root="$stage/support-root"
/bin/mkdir -p "$app_root/Applications" \
    "$driver_root/Library/Audio/Plug-Ins/HAL" \
    "$support_root/Library/Application Support/HomePodFlow/bin"
/usr/bin/ditto --norsrc --noextattr "$app" "$app_root/Applications/HomePod Flow.app"
/usr/bin/ditto --norsrc --noextattr "$driver" \
    "$driver_root/Library/Audio/Plug-Ins/HAL/$FLOW_DRIVER_BUNDLE_NAME"
/usr/bin/install -m 755 "$probe" \
    "$support_root/Library/Application Support/HomePodFlow/bin/flow-audio-probe"
/usr/bin/install -m 755 "$default_output" \
    "$support_root/Library/Application Support/HomePodFlow/bin/flow-default-output"
/usr/bin/find "$stage" -name '._*' -delete
/usr/bin/xattr -cr "$stage" >/dev/null 2>&1 || true
/usr/bin/dot_clean -m "$stage" >/dev/null 2>&1 || true
/bin/chmod -R go-w "$stage"

# Staging must not alter either code signature. pkgbuild only copies bytes.
/usr/bin/codesign --verify --deep --strict "$app_root/Applications/HomePod Flow.app" ||
    fail "Staged App signature verification failed"
/usr/bin/codesign --verify --strict \
    "$driver_root/Library/Audio/Plug-Ins/HAL/$FLOW_DRIVER_BUNDLE_NAME" ||
    fail "Staged driver signature verification failed"

driver_scripts="$work/driver-scripts"
/bin/mkdir -p "$driver_scripts"
/usr/bin/ditto "$installer_root/scripts/pkg/driver/preinstall" "$driver_scripts/preinstall"
/usr/bin/ditto "$installer_root/scripts/lib.sh" "$driver_scripts/lib.sh"
/bin/chmod 755 "$driver_scripts/preinstall"
/bin/chmod 644 "$driver_scripts/lib.sh"

support_scripts="$work/support-scripts"
/bin/mkdir -p "$support_scripts"
/usr/bin/ditto "$installer_root/scripts/pkg/support/postinstall" "$support_scripts/postinstall"
/usr/bin/ditto "$installer_root/scripts/lib.sh" "$support_scripts/lib.sh"
/bin/chmod 755 "$support_scripts/postinstall"
/bin/chmod 644 "$support_scripts/lib.sh"

packages="$work/packages"
/bin/mkdir -p "$packages"

/usr/bin/pkgbuild \
    --root "$driver_root" \
    --identifier "com.homepodflow.audio.driver.pkg" \
    --version "$version" \
    --install-location "/" \
    --scripts "$driver_scripts" \
    --ownership recommended \
    "$packages/Driver.pkg"

/usr/bin/pkgbuild \
    --root "$app_root" \
    --identifier "$FLOW_APP_BUNDLE_ID" \
    --version "$version" \
    --install-location "/" \
    --ownership recommended \
    "$packages/App.pkg"

/usr/bin/pkgbuild \
    --root "$support_root" \
    --identifier "com.homepodflow.support.pkg" \
    --version "$version" \
    --install-location "/" \
    --scripts "$support_scripts" \
    --ownership recommended \
    "$packages/Support.pkg"

distribution="$work/Distribution.xml"
/usr/bin/sed -e "s/@VERSION@/$version/g" -e "s/@ARCHS@/$distribution_archs/g" \
    "$installer_root/Distribution.xml.in" >"$distribution"

/bin/mkdir -p "$output"
out_pkg="$output/$FLOW_INSTALLER_PKG_NAME"
out_dmg="$output/HomePod Flow $version.dmg"
manifest="$output/HomePod Flow $version.manifest.json"
if [ "$force" -eq 0 ]; then
    [ ! -e "$out_pkg" ] || fail "Output exists: $out_pkg (use --force)"
    if [ "$make_dmg" -eq 1 ]; then
        [ ! -e "$out_dmg" ] || fail "Output exists: $out_dmg (use --force)"
    fi
    [ ! -e "$manifest" ] || fail "Output exists: $manifest (use --force)"
fi

productbuild_command=(/usr/bin/productbuild
    --distribution "$distribution"
    --package-path "$packages"
    --resources "$installer_root/resources"
    --version "$version")
if [ -n "$identity" ]; then
    productbuild_command+=(--sign "$identity" --timestamp)
fi
productbuild_command+=("$out_pkg")
"${productbuild_command[@]}"

if [ "$make_dmg" -eq 1 ]; then
    dmg_stage="$work/dmg"
    /bin/mkdir -p "$dmg_stage"
    /usr/bin/ditto --norsrc --noextattr "$out_pkg" "$dmg_stage/$FLOW_INSTALLER_PKG_NAME"
    /usr/bin/ditto --norsrc --noextattr "$installer_root/resources/uninstall.command" \
        "$dmg_stage/Uninstall HomePod Flow.command"
    /usr/bin/ditto --norsrc --noextattr "$installer_root/scripts/uninstall-homepodflow.sh" \
        "$dmg_stage/uninstall-homepodflow.sh"
    /usr/bin/ditto --norsrc --noextattr "$installer_root/scripts/lib.sh" "$dmg_stage/lib.sh"
    /bin/chmod 755 "$dmg_stage/Uninstall HomePod Flow.command" \
        "$dmg_stage/uninstall-homepodflow.sh"
    /bin/chmod 644 "$dmg_stage/lib.sh"
    /bin/cat >"$dmg_stage/README.txt" <<EOF
HomePod Flow $version

1. 双击 “$FLOW_INSTALLER_PKG_NAME”。
2. 安装程序会安装 HomePod Flow.app 和 HomePod Flow Audio 声卡，
   并重新加载系统音频服务。
3. 打开 HomePod Flow，在“设置 → 空间布局”顶部确认“音频组件已就绪”。

卸载：双击 “Uninstall HomePod Flow.command”。

安装程序不会把 HomePod Flow Audio 设为默认输出。
这个包未包含 Python 运行环境和本机 runtime.json；正式签名/公证另行处理。
EOF
    /usr/bin/hdiutil create \
        -volname "HomePod Flow $version" \
        -srcfolder "$dmg_stage" \
        -ov -format UDZO \
        "$out_dmg"
    /usr/bin/hdiutil verify "$out_dmg"
    if [ -n "$identity" ]; then
        /usr/bin/codesign --force --sign "$identity" "$out_dmg"
    fi
fi

app_sha=$(/usr/bin/shasum -a 256 "$app/Contents/MacOS/HomePod Flow" | /usr/bin/awk '{print $1}')
driver_sha=$(/usr/bin/shasum -a 256 \
    "$driver/Contents/MacOS/$FLOW_DRIVER_EXECUTABLE" | /usr/bin/awk '{print $1}')
pkg_sha=$(/usr/bin/shasum -a 256 "$out_pkg" | /usr/bin/awk '{print $1}')
dmg_sha=""
if [ "$make_dmg" -eq 1 ]; then
    dmg_sha=$(/usr/bin/shasum -a 256 "$out_dmg" | /usr/bin/awk '{print $1}')
fi

signed=false
if [ -n "$identity" ]; then signed=true; fi
/bin/cat >"$manifest" <<EOF
{
  "schemaVersion": 1,
  "product": "HomePod Flow",
  "version": "$version",
  "builtAt": "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)",
  "architectures": "$distribution_archs",
  "signed": $signed,
  "signingIdentity": "${identity:-}",
  "app": {
    "bundleIdentifier": "$FLOW_APP_BUNDLE_ID",
    "version": "$app_version",
    "executableSHA256": "$app_sha"
  },
  "driver": {
    "bundleIdentifier": "$FLOW_DRIVER_BUNDLE_ID",
    "version": "${driver_version:-unknown}",
    "executable": "$FLOW_DRIVER_EXECUTABLE",
    "executableSHA256": "$driver_sha"
  },
  "installer": {
    "pkg": "$(/usr/bin/basename "$out_pkg")",
    "sha256": "$pkg_sha"
  },
  "dmg": {
    "file": "$( [ "$make_dmg" -eq 1 ] && /usr/bin/basename "$out_dmg" || true )",
    "sha256": "$dmg_sha"
  }
}
EOF
/usr/bin/python3 -m json.tool "$manifest" >/dev/null

/usr/bin/printf 'PKG=%s\n' "$out_pkg"
if [ "$make_dmg" -eq 1 ]; then /usr/bin/printf 'DMG=%s\n' "$out_dmg"; fi
/usr/bin/printf 'MANIFEST=%s\n' "$manifest"
/usr/bin/printf 'ARCHITECTURES=%s\n' "$distribution_archs"
/usr/bin/printf 'SIGNED=%s\n' "$signed"
