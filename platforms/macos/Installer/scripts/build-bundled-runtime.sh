#!/bin/bash
# Builds the App's self-contained Python runtime:
#   - a frozen PyInstaller worker (Python + pyatv/av/numpy/scipy/... included)
#   - the small runtime project (adapters/bindings/processing)
#   - libflow_bridge.dylib and the hflctl latency helper
#
# The result is a directory that build-release.sh copies into
# HomePod Flow.app/Contents/Resources/Runtime. This script never installs
# anything, touches the HAL, changes the default output, or plays audio.
set -euo pipefail

installer_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="$(cd "$installer_root/../../.." && pwd)"
source "$installer_root/scripts/lib.sh"
source "$repo_root/platforms/macos/VirtualAudioDriver/scripts/safe-output.sh"
source_root="$repo_root"

usage() {
    cat <<'EOF'
Usage:
  build-bundled-runtime.sh --venv DIR --project DIR --library FILE \
    --latency-control FILE --output DIR [--force]

Required:
  --venv DIR            Python venv containing all runtime packages and PyInstaller.
  --project DIR         Runtime project (adapters/, bindings/, processing/).
  --library FILE        libflow_bridge.dylib (ABI v1).
  --latency-control FILE hflctl executable.
  --output DIR          Absolute output directory for the Runtime bundle.

Options:
  --name NAME           PyInstaller worker name (default: system-worker).
  --force               Replace existing output.
  -h, --help            Show this help.

Environment:
  PYINSTALLER           PyInstaller executable/module override (optional).
EOF
}

fail() { /usr/bin/printf 'error: %s\n' "$*" >&2; exit 1; }

venv=""
project=""
library=""
latency_control=""
output=""
name="system-worker"
force=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --venv) [ "$#" -ge 2 ] || fail "--venv needs a value"; venv="$2"; shift 2 ;;
        --project) [ "$#" -ge 2 ] || fail "--project needs a value"; project="$2"; shift 2 ;;
        --library) [ "$#" -ge 2 ] || fail "--library needs a value"; library="$2"; shift 2 ;;
        --latency-control)
            [ "$#" -ge 2 ] || fail "--latency-control needs a value"; latency_control="$2"; shift 2 ;;
        --output) [ "$#" -ge 2 ] || fail "--output needs a value"; output="$2"; shift 2 ;;
        --name) [ "$#" -ge 2 ] || fail "--name needs a value"; name="$2"; shift 2 ;;
        --force) force=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) fail "Unknown argument: $1" ;;
    esac
done

[ -n "$venv" ] || fail "--venv is required"
[ -n "$project" ] || fail "--project is required"
[ -n "$library" ] || fail "--library is required"
[ -n "$latency_control" ] || fail "--latency-control is required"
[ -n "$output" ] || fail "--output is required"

venv=$(cd "$venv" && pwd -P) || fail "venv not found: $venv"
project=$(cd "$project" && pwd -P) || fail "project not found: $project"
library=$(cd "$(/usr/bin/dirname "$library")" && pwd -P)/$(/usr/bin/basename "$library") ||
    fail "library not found: $library"
latency_control=$(cd "$(/usr/bin/dirname "$latency_control")" && pwd -P)/$(/usr/bin/basename "$latency_control") ||
    fail "latency control not found: $latency_control"
case "$output" in
    /*) ;;
    *) output="$PWD/$output" ;;
esac
output=$(flow_safe_output "$output")

python="$venv/bin/python"
[ -x "$python" ] || fail "venv python is missing: $python"
[ -f "$project/adapters/system_worker.py" ] || fail "runtime project lacks adapters/system_worker.py"
[ -d "$project/bindings" ] || fail "runtime project lacks bindings/"
[ -d "$project/processing" ] || fail "runtime project lacks processing/"
[ -f "$library" ] || fail "core library is missing: $library"
[ -x "$latency_control" ] || fail "latency control is missing/not executable: $latency_control"
"$python" -m PyInstaller --version >/dev/null 2>&1 ||
    fail "PyInstaller is not installed in $venv (pip install pyinstaller)"

if [ -e "$output" ] && [ "$force" -eq 0 ]; then
    fail "Output exists: $output (use --force)"
fi

work=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/homepod-runtime.XXXXXX")
cleanup() { /bin/rm -rf "$work"; }
trap cleanup EXIT INT TERM

dist="$work/dist"
build="$work/build"
spec="$work/spec"
/bin/mkdir -p "$dist" "$build" "$spec"

(
    cd "$project"
    "$python" -m PyInstaller \
        --noconfirm --clean --onedir --log-level WARN \
        --name "$name" \
        --paths "$project" \
        --collect-submodules adapters \
        --collect-submodules bindings \
        --collect-submodules processing \
        --collect-all pyatv \
        --collect-all av \
        --collect-all zeroconf \
        --distpath "$dist" \
        --workpath "$build" \
        --specpath "$spec" \
        "$project/adapters/system_worker.py"
)

[ -x "$dist/$name/$name" ] || fail "PyInstaller did not produce $dist/$name/$name"

/bin/mkdir -p "$output/lib" "$output/bin"
/usr/bin/ditto --norsrc --noextattr "$dist/$name" "$output/$name"
/usr/bin/ditto --norsrc --noextattr "$project" "$output/project"
/usr/bin/ditto --norsrc --noextattr "$library" "$output/lib/libflow_bridge.dylib"
/usr/bin/ditto --norsrc --noextattr "$latency_control" "$output/bin/hflctl"
/usr/bin/find "$output" -type d -exec /bin/chmod 755 {} +
/usr/bin/find "$output" -type f -exec /bin/chmod 644 {} +
/bin/chmod 755 "$output/$name/$name" "$output/bin/hflctl"
/usr/bin/find "$output" -name '._*' -delete

/bin/cat >"$output/manifest.json" <<EOF
{
  "schemaVersion": 1,
  "name": "$name",
  "workerExecutable": "$name/$name",
  "project": "project",
  "library": "lib/libflow_bridge.dylib",
  "latencyControl": "bin/hflctl",
  "builtAt": "$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
/usr/bin/python3 -m json.tool "$output/manifest.json" >/dev/null

# Smoke test: the frozen worker must answer hello without importing an
# external Python installation.
hello='{"v":1,"id":"runtime-check","command":"hello","params":{}}'
reply=$(/usr/bin/printf '%s\n' "$hello" | "$output/$name/$name")
/usr/bin/printf '%s' "$reply" | /usr/bin/grep -q '"protocol_version":1' ||
    fail "Frozen worker hello check failed"

# Every shipped Mach-O must resolve only system libs or files inside the
# runtime directory. An absolute /opt/homebrew or /usr/local dependency would
# make the one-click package depend on the build machine.
homebrew_refs=$(/usr/bin/find "$output" -type f \
    \( -name '*.so' -o -name '*.dylib' -o -perm -111 \) -print0 |
    /usr/bin/xargs -0 /usr/bin/otool -L 2>/dev/null |
    /usr/bin/grep -E '/opt/homebrew|/usr/local' || true)
[ -z "$homebrew_refs" ] ||
    fail "Frozen runtime still references build-machine libraries: $homebrew_refs"

/usr/bin/printf 'RUNTIME=%s\n' "$output"
/usr/bin/printf 'WORKER=%s\n' "$output/$name/$name"
/usr/bin/printf 'SIZE=%s\n' "$(/usr/bin/du -sh "$output" | /usr/bin/awk '{print $1}')"
