# Sourced by build/test scripts. Resolve existing symlink parents before making
# directories; reject paths outside the user home, checkout, or private tmp.
flow_safe_output() {
  local requested="$1" parent suffix='' resolved physical_home physical_source
  case "$requested" in
    /*) ;;
    *) echo 'Output directory must be absolute.' >&2; return 2 ;;
  esac
  case "/$requested/" in
    *'/../'*|*'/./'*) echo 'Dot path components are not allowed.' >&2; return 2 ;;
  esac
  parent="$requested"
  while [[ ! -e "$parent" && ! -L "$parent" ]]; do
    suffix="/$(basename "$parent")$suffix"
    parent="$(dirname "$parent")"
  done
  [[ -d "$parent" ]] || { echo 'Output ancestor is not a directory.' >&2; return 2; }
  resolved="$(cd "$parent" && pwd -P)$suffix"
  case "$resolved/" in
    /Library/*|/System/*|/usr/*|/bin/*|/sbin/*|*/Audio/Plug-Ins/HAL/*)
      echo 'System output destinations are forbidden.' >&2; return 2 ;;
  esac
  physical_home="$(cd "$HOME" && pwd -P)"
  physical_source="$(cd "$source_root" && pwd -P)"
  case "$resolved/" in
    "$physical_home/"*|"$physical_source/"*|/private/tmp/*) ;;
    *) echo 'Output must be under user home, checkout, or /private/tmp; system install destinations are forbidden.' >&2; return 2 ;;
  esac
  printf '%s\n' "$resolved"
}

flow_reject_symlink() {
  local output_path
  for output_path in "$@"; do
    if [[ -L "$output_path" ]]; then
      echo "Refusing existing symlink output: $output_path" >&2; return 2
    fi
  done
}
