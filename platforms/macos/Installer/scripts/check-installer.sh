#!/bin/bash
# Static checks for the installer scripts. Safe on any machine with bash;
# plist/XML checks run when the macOS tools are available.
set -euo pipefail

installer_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$installer_root/../../.." && pwd)"
failures=0

check() {
    local description="$1"
    shift
    if "$@"; then
        /usr/bin/printf 'PASS %s\n' "$description"
    else
        /usr/bin/printf 'FAIL %s\n' "$description" >&2
        failures=$((failures + 1))
    fi
}

for script in \
    "$installer_root/scripts/lib.sh" \
    "$installer_root/scripts/build-installer.sh" \
    "$installer_root/scripts/build-release.sh" \
    "$installer_root/scripts/build-bundled-runtime.sh" \
    "$installer_root/scripts/uninstall-homepodflow.sh" \
    "$installer_root/scripts/pkg/driver/preinstall" \
    "$installer_root/scripts/pkg/support/postinstall" \
    "$installer_root/resources/uninstall.command" \
    "$repo_root/apps/macos/scripts/package-embedded-hosts.sh" \
    "$repo_root/platforms/macos/ProcessTapCapture/scripts/package-host.sh" \
    "$repo_root/platforms/macos/VirtualAudioInput/scripts/package-host.sh" \
    "$repo_root/platforms/macos/VirtualAudioDriver/scripts/build-stage.sh" \
    "$repo_root/platforms/macos/VirtualAudioDriver/scripts/build-stage-multichannel.sh"; do
    check "bash syntax: ${script#$repo_root/}" bash -n "$script"
done

check "installer help exits 0" bash "$installer_root/scripts/build-installer.sh" --help
check "uninstall help exits 0" bash "$installer_root/scripts/uninstall-homepodflow.sh" --help
check "release help exits 0" bash "$installer_root/scripts/build-release.sh" --help

if command -v xmllint >/dev/null 2>&1; then
    check "Distribution template is XML" xmllint --noout "$installer_root/Distribution.xml.in"
else
    /usr/bin/printf 'SKIP Distribution XML check (xmllint not available)\n'
fi
if command -v plutil >/dev/null 2>&1; then
    check "driver Info.plist is valid" plutil -lint \
        "$repo_root/platforms/macos/VirtualAudioDriver/Info-Multichannel-Production.plist"
    check "virtual host Info.plist is valid" plutil -lint \
        "$repo_root/platforms/macos/VirtualAudioInput/scripts/Host-Info.plist"
else
    /usr/bin/printf 'SKIP plist checks (plutil not available)\n'
fi

check "preinstall backs up and refuses unrelated HAL bundles" sh -c \
    "grep -q 'Refusing to replace unrelated HAL bundle' '$installer_root/scripts/pkg/driver/preinstall'"
check "postinstall probes the exact Flow UID" sh -c \
    "grep -q 'flow_probe_device' '$installer_root/scripts/pkg/support/postinstall' && grep -q 'surround71.v1' '$installer_root/scripts/lib.sh'"
check "postinstall reloads coreaudiod" sh -c \
    "grep -q 'launchctl kickstart -k system/com.apple.audio.coreaudiod' '$installer_root/scripts/lib.sh'"
check "installer only restores Flow-as-default via helper" sh -c \
    "! grep -R -n -E 'kAudioHardwarePropertyDefaultOutputDevice|defaults write|SwitchAudioSource' --exclude='check-installer.sh' '$installer_root/scripts' '$installer_root/resources' >/dev/null 2>&1"
check "default-output helper is in the support payload" sh -c \
    "grep -q 'flow-default-output' '$installer_root/scripts/build-installer.sh' && grep -q 'flow_restore_default_output' '$installer_root/scripts/pkg/support/postinstall' && grep -q 'flow_restore_default_output' '$installer_root/scripts/uninstall-homepodflow.sh'"
check "uninstall is receipt-aware" sh -c \
    "grep -q 'pkgutil --forget' '$installer_root/scripts/uninstall-homepodflow.sh'"
check "installer requires one product version" sh -c \
    "grep -q 'does not match requested product version' '$installer_root/scripts/build-installer.sh'"
check "Distribution derives host architectures" sh -c \
    "grep -q 'hostArchitectures=\"@ARCHS@\"' '$installer_root/Distribution.xml.in' && grep -q 'lipo_archs' '$installer_root/scripts/build-installer.sh'"
check "payload strips AppleDouble and xattrs" sh -c \
    "grep -q 'xattr -cr' '$installer_root/scripts/build-installer.sh' && grep -q 'dot_clean' '$installer_root/scripts/build-installer.sh'"
check "release bundles the frozen runtime" sh -c \
    "grep -q 'build-bundled-runtime.sh' '$installer_root/scripts/build-release.sh' && grep -q 'system-worker/system-worker' '$installer_root/scripts/build-release.sh'"
check "frozen runtime is checked for build-machine dylibs" sh -c \
    "grep -q -E '/opt/homebrew|/usr/local' '$installer_root/scripts/build-bundled-runtime.sh'"
check "manifest validation uses JSON parser" sh -c \
    "grep -q 'python3 -m json.tool' '$installer_root/scripts/lib.sh'"
check "old App/driver backups are zipped" sh -c \
    "grep -q 'ditto -c -k' '$installer_root/scripts/pkg/driver/preinstall' && grep -q 'ditto -c -k' '$installer_root/scripts/uninstall-homepodflow.sh'"
check "installer prompts restart after install" sh -c \
    "grep -q 'onConclusion=\"Restart\"' '$installer_root/Distribution.xml.in'"

if [ "$failures" -ne 0 ]; then
    /usr/bin/printf '%d installer check(s) failed\n' "$failures" >&2
    exit 1
fi
/usr/bin/printf 'PASS: installer static checks\n'
