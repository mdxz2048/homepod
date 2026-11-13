#!/bin/bash
# Removes the HomePod Flow App and its HAL audio component.
#
# By default it backs up the App, driver and support data under
# ~/HomePodFlow-Backups/uninstall-<timestamp>/ before removing them. It never
# touches other vendors' HAL bundles and never changes the default output.
#
# Usage: sudo ./uninstall-homepodflow.sh [--purge] [--keep-driver]
#                                        [--backup-dir DIR] [--no-backup]
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$script_dir/lib.sh" ]; then
    # shellcheck source=lib.sh
    source "$script_dir/lib.sh"
else
    # shellcheck source=../lib.sh
    source "$script_dir/../lib.sh"
fi

purge_user_data=0
keep_driver=0
make_backup=1
backup_dir=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --purge) purge_user_data=1; shift ;;
        --keep-driver) keep_driver=1; shift ;;
        --no-backup) make_backup=0; shift ;;
        --backup-dir)
            [ "$#" -ge 2 ] || flow_fail "--backup-dir needs a value"
            backup_dir="$2"
            shift 2
            ;;
        -h|--help)
            /usr/bin/printf '%s\n' \
                "Usage: sudo $0 [--purge] [--keep-driver] [--backup-dir DIR] [--no-backup]" \
                "" \
                "  --purge        Also remove this user's HomePod Flow preferences and caches." \
                "  --keep-driver  Leave the HAL audio component installed." \
                "  --backup-dir   Backup destination (default: ~/HomePodFlow-Backups/uninstall-<timestamp>)." \
                "  --no-backup    Remove without making a backup."
            exit 0
            ;;
        *) flow_fail "Unknown argument: $1" ;;
    esac
done

flow_require_root

target_user="${SUDO_USER:-$(/usr/bin/id -un)}"
target_home=$(/usr/bin/dscl . -read "/Users/$target_user" NFSHomeDirectory 2>/dev/null |
    /usr/bin/awk '{print $2}')
if [ -z "$target_home" ] || [ ! -d "$target_home" ]; then
    target_home="$HOME"
fi
target_group=$(/usr/bin/id -gn "$target_user" 2>/dev/null || /usr/bin/printf 'staff')

stamp=$(/bin/date -u +%Y%m%d-%H%M%S)
if [ "$make_backup" -eq 1 ] && [ -z "$backup_dir" ]; then
    backup_dir="$target_home/HomePodFlow-Backups/uninstall-$stamp"
fi
if [ -n "$backup_dir" ]; then
    case "$backup_dir" in
        /*) ;;
        *) flow_fail "--backup-dir must be an absolute path" ;;
    esac
    [ "$backup_dir" != "/" ] || flow_fail "Refusing to use / as the backup directory"
    case "/$backup_dir/" in
        *'/../'*) flow_fail "Dot path components are not allowed in --backup-dir" ;;
    esac
    /bin/mkdir -p "$backup_dir"
    /usr/sbin/chown "$target_user:$target_group" "$backup_dir" 2>/dev/null || true
    /bin/chmod 700 "$backup_dir"
fi

/usr/bin/touch "$FLOW_INSTALL_LOG"
/bin/chmod 644 "$FLOW_INSTALL_LOG"
flow_log "=== uninstall $(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) ==="
[ -z "$backup_dir" ] || flow_log "Backup directory: $backup_dir"

flow_quit_app
for helper in tap-capture-host virtual-audio-host; do
    /usr/bin/pkill -TERM -x "$helper" >/dev/null 2>&1 || true
done

flow_restore_default_output || flow_log "No bundled default-output helper; reboot may be required"

backup_item() {
    local path="$1" name="$2"
    [ -e "$path" ] || return 0
    [ ! -L "$path" ] || flow_fail "Refusing symlink during uninstall: $path"
    if [ "$make_backup" -eq 1 ]; then
        # Zip bundles/directories instead of leaving a second .app/.driver
        # in the home directory. A scanned backup bundle can make Installer
        # think an older App/driver version is still installed and skip the
        # new component.
        /usr/bin/ditto -c -k --sequesterRsrc --keepParent "$path" "$backup_dir/$name.zip"
        flow_log "Backed up $path -> $backup_dir/$name.zip"
    fi
}

remove_app() {
    local app="$1" identifier backup_name
    [ -d "$app" ] || return 0
    identifier=$(flow_bundle_id "$app" || true)
    [ "$identifier" = "$FLOW_APP_BUNDLE_ID" ] ||
        flow_fail "Refusing to remove App with unexpected bundle id: $app ($identifier)"
    backup_name="UserApplications-$FLOW_APP_NAME"
    [ "$app" = "/Applications/$FLOW_APP_NAME" ] && backup_name="Applications-$FLOW_APP_NAME"
    backup_item "$app" "$backup_name"
    /bin/rm -rf "$app"
    flow_log "Removed $app"
}

remove_app "/Applications/$FLOW_APP_NAME"
remove_app "$target_home/Applications/$FLOW_APP_NAME"

remove_driver() {
    local path="$1" name identifier
    [ -e "$path" ] || return 0
    [ ! -L "$path" ] || flow_fail "Refusing symlink in HAL directory: $path"
    name=$(/usr/bin/basename "$path")
    identifier=$(flow_bundle_id "$path" || true)
    case "$identifier" in
        "$FLOW_DRIVER_BUNDLE_ID"|"$FLOW_DRIVER_DEV_BUNDLE_ID") ;;
        *) flow_fail "Refusing to remove unrelated HAL bundle: $path ($identifier)" ;;
    esac
    backup_item "$path" "HAL-$name"
    /bin/rm -rf "$path"
    flow_log "Removed $path"
}

if [ "$keep_driver" -eq 0 ]; then
    remove_driver "$FLOW_HAL_DIR/HomePodFlowAudio.driver"
    remove_driver "$FLOW_HAL_DIR/$FLOW_DRIVER_BUNDLE_NAME"
    for path in "$FLOW_HAL_DIR"/*.driver; do
        [ -e "$path" ] || continue
        [ ! -L "$path" ] || continue
        case "$(/usr/bin/basename "$path")" in
            "HomePodFlowAudio.driver"|"$FLOW_DRIVER_BUNDLE_NAME") continue ;;
        esac
        identifier=$(flow_bundle_id "$path" || true)
        case "$identifier" in
            "$FLOW_DRIVER_BUNDLE_ID"|"$FLOW_DRIVER_DEV_BUNDLE_ID") remove_driver "$path" ;;
        esac
    done
fi

if [ -d "$FLOW_SUPPORT_DIR" ]; then
    backup_item "$FLOW_SUPPORT_DIR" "ApplicationSupport-HomePodFlow"
    /bin/rm -rf "$FLOW_SUPPORT_DIR"
    flow_log "Removed $FLOW_SUPPORT_DIR"
fi

for receipt in \
    "com.homepodflow.mac" \
    "com.homepodflow.audio.driver.pkg" \
    "com.homepodflow.support.pkg" \
    "com.homepodflow.installer"; do
    /usr/sbin/pkgutil --forget "$receipt" >/dev/null 2>&1 || true
done

if [ "$purge_user_data" -eq 1 ]; then
    if [ -n "$target_home" ] && [ -d "$target_home" ]; then
        /bin/rm -rf "$target_home/Library/Application Support/HomePod Flow"
        /bin/rm -rf "$target_home/Library/Caches/com.homepodflow.mac"
        /bin/rm -rf "$target_home/Library/Saved Application State/com.homepodflow.mac.savedState"
        /bin/rm -f "$target_home/Library/Preferences/com.homepodflow.mac.plist"
        flow_log "Purged user preferences under $target_home"
    fi
fi

if flow_reload_coreaudiod; then
    flow_log "coreaudiod reloaded after uninstall"
else
    flow_log "coreaudiod reload failed; a Mac restart is required"
fi

if [ -n "$backup_dir" ] && [ -d "$backup_dir" ]; then
    /bin/cp "$FLOW_INSTALL_LOG" "$backup_dir/uninstall.log" 2>/dev/null || true
    /usr/sbin/chown -R "$target_user:$target_group" "$backup_dir" 2>/dev/null || true
fi

/usr/bin/printf '%s\n' "HomePod Flow was removed."
if [ -n "$backup_dir" ]; then
    /usr/bin/printf 'Backup: %s\n' "$backup_dir"
fi
/usr/bin/printf '%s\n' \
    "If the audio device is still listed, restart the Mac to finish unloading the HAL plug-in."
exit 0
