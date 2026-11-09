#!/bin/bash
# Shared helpers for the HomePod Flow installer package scripts.
# Sourced, never executed directly.
set -euo pipefail

FLOW_DRIVER_BUNDLE_NAME="HomePodFlowAudioFamily.driver"
FLOW_DRIVER_BUNDLE_ID="com.homepodflow.audio.driver"
FLOW_DRIVER_DEV_BUNDLE_ID="com.homepodflow.audio.driver.family.dev"
FLOW_DRIVER_EXECUTABLE="HomePodFlowAudioFamily"
FLOW_DEVICE_UID="com.homepodflow.virtual-audio.surround71.v1"
FLOW_APP_BUNDLE_ID="com.homepodflow.mac"
FLOW_APP_NAME="HomePod Flow.app"
FLOW_INSTALLER_PKG_NAME="Install HomePod Flow.pkg"
FLOW_HAL_DIR="/Library/Audio/Plug-Ins/HAL"
FLOW_SUPPORT_DIR="/Library/Application Support/HomePodFlow"
FLOW_BACKUP_DIR="$FLOW_SUPPORT_DIR/InstallerBackup"
FLOW_INSTALL_LOG="/var/log/homepodflow-install.log"

flow_log() {
    /usr/bin/printf '%s %s\n' "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$FLOW_INSTALL_LOG" 2>/dev/null || true
}

flow_fail() {
    flow_log "ERROR: $*"
    /usr/bin/printf 'HomePod Flow installer: %s\n' "$*" >&2
    exit 1
}

flow_require_root() {
    [ "$(/usr/bin/id -u)" -eq 0 ] || flow_fail "This operation must run as root."
}

flow_bundle_id() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$1/Contents/Info.plist" 2>/dev/null
}

flow_bundle_executable() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$1/Contents/Info.plist" 2>/dev/null
}

flow_bundle_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null
}

flow_validate_bundle() {
    local bundle="$1" identifier executable
    [ -d "$bundle" ] || flow_fail "Missing audio component bundle: $bundle"
    [ ! -L "$bundle" ] || flow_fail "Refusing symlink audio component bundle: $bundle"
    identifier=$(flow_bundle_id "$bundle" || true)
    executable=$(flow_bundle_executable "$bundle" || true)
    [ "$identifier" = "$FLOW_DRIVER_BUNDLE_ID" ] ||
        flow_fail "Unexpected bundle id '$identifier' in $bundle"
    [ "$executable" = "$FLOW_DRIVER_EXECUTABLE" ] ||
        flow_fail "Unexpected executable '$executable' in $bundle"
    [ -x "$bundle/Contents/MacOS/$FLOW_DRIVER_EXECUTABLE" ] ||
        flow_fail "Missing executable in $bundle"
}

flow_quit_app() {
    /usr/bin/pgrep -x "HomePod Flow" >/dev/null 2>&1 || return 0
    flow_log "Stopping HomePod Flow before replacing the audio component"
    /usr/bin/osascript -e 'tell application id "com.homepodflow.mac" to quit' >/dev/null 2>&1 || true
    local i=0
    while [ "$i" -lt 10 ]; do
        /usr/bin/pgrep -x "HomePod Flow" >/dev/null 2>&1 || return 0
        /bin/sleep 0.5
        i=$((i + 1))
    done
    /usr/bin/pkill -TERM -x "HomePod Flow" >/dev/null 2>&1 || true
    i=0
    while [ "$i" -lt 10 ]; do
        /usr/bin/pgrep -x "HomePod Flow" >/dev/null 2>&1 || return 0
        /bin/sleep 0.5
        i=$((i + 1))
    done
    # A running App must not abort the package midway. Replacing files is safe;
    # the user can reopen the App after installation.
    flow_log "HomePod Flow is still running; continuing with file installation"
    return 0
}

flow_reload_coreaudiod() {
    flow_log "Reloading coreaudiod"
    /bin/launchctl kickstart -k system/com.apple.audio.coreaudiod >>"$FLOW_INSTALL_LOG" 2>&1 || return 1
    local i=0
    while [ "$i" -lt 40 ]; do
        if /usr/bin/pgrep -x coreaudiod >/dev/null 2>&1; then
            /bin/sleep 1
            return 0
        fi
        /bin/sleep 0.25
        i=$((i + 1))
    done
    return 1
}

flow_probe_device() {
    local probe="$FLOW_SUPPORT_DIR/bin/flow-audio-probe"
    [ -x "$probe" ] || return 1
    local console_uid
    console_uid=$(/usr/bin/stat -f '%u' /dev/console 2>/dev/null || /usr/bin/printf '0')
    if [ "$(/usr/bin/id -u)" -eq 0 ] && [ "$console_uid" -ne 0 ]; then
        /bin/launchctl asuser "$console_uid" "$probe" "$FLOW_DEVICE_UID" >/dev/null 2>&1
    else
        "$probe" "$FLOW_DEVICE_UID" >/dev/null 2>&1
    fi
}

flow_restore_default_output() {
    local helper="$FLOW_SUPPORT_DIR/bin/flow-default-output"
    [ -x "$helper" ] || return 1
    local console_uid
    console_uid=$(/usr/bin/stat -f '%u' /dev/console 2>/dev/null || /usr/bin/printf '0')
    if [ "$(/usr/bin/id -u)" -eq 0 ] && [ "$console_uid" -ne 0 ]; then
        /bin/launchctl asuser "$console_uid" "$helper" --restore-builtin >>"$FLOW_INSTALL_LOG" 2>&1
    else
        "$helper" --restore-builtin >>"$FLOW_INSTALL_LOG" 2>&1
    fi
}

flow_write_needs_restart() {
    local reason="$1"
    /bin/mkdir -p "$FLOW_SUPPORT_DIR/Installer"
    /usr/bin/printf '%s\n' "$reason" >"$FLOW_SUPPORT_DIR/Installer/needs-restart"
    /usr/sbin/chown root:wheel "$FLOW_SUPPORT_DIR/Installer/needs-restart"
    /bin/chmod 644 "$FLOW_SUPPORT_DIR/Installer/needs-restart"
    flow_log "Restart required: $reason"
}

flow_clear_needs_restart() {
    /bin/rm -f "$FLOW_SUPPORT_DIR/Installer/needs-restart"
}

flow_write_manifest() {
    local bundle="$1" version="$2" sha="$3" now manifest
    /bin/mkdir -p "$FLOW_SUPPORT_DIR"
    manifest="$FLOW_SUPPORT_DIR/InstalledComponent.json"
    now=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)
    /bin/cat >"$manifest" <<EOF
{
  "schemaVersion": 1,
  "bundleIdentifier": "$FLOW_DRIVER_BUNDLE_ID",
  "bundleVersion": "$version",
  "bundlePath": "$bundle",
  "executableSHA256": "$sha",
  "installedAt": "$now"
}
EOF
    /usr/bin/python3 -m json.tool "$manifest" >/dev/null
    /usr/sbin/chown root:wheel "$manifest"
    /bin/chmod 644 "$manifest"
}
