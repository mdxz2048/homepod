#!/bin/sh
# Run the offline/read-only verification battery inside THIS directory on the
# target Mac. Writes no HAL properties, plays no audio, launches no browser.
# Logs go to ${HPF_MAC_LOG_DIR:-/tmp/hpf-chrome-latency-verify}.
#
# Usage on the Mac:
#   bash tests/virtual_audio/chrome_latency/verify_on_mac.sh
set -u

here="$(cd "$(dirname "$0")" && pwd)"
log="${HPF_MAC_LOG_DIR:-/tmp/hpf-chrome-latency-verify}"
mkdir -p "$log"
PY="${HPF_PYTHON:-python3}"
FFMPEG="${HPF_FFMPEG:-ffmpeg}"
export PATH="$PATH:/opt/homebrew/bin"

echo "verify script dir: $here"
echo "logs: $log"

echo "== build cwd: $here/hflctl =="
cd "$here/hflctl" || exit 1

xcrun swift build -c debug > "$log/build.txt" 2>&1 || {
  cat "$log/build.txt"; echo "BUILD FAILED"; exit 1; }
echo "build: OK"

xcrun swift build -c release >> "$log/build.txt" 2>&1 || {
  tail -40 "$log/build.txt"; echo "RELEASE BUILD FAILED"; exit 1; }
echo "release build: OK"

xcrun swift test > "$log/test.txt" 2>&1 || {
  cat "$log/test.txt"; echo "TEST FAILED"; exit 1; }
echo "swift test: OK ($(grep -c 'Test Case.*passed' "$log/test.txt") passed cases)"

.build/debug/hflctl self-check > "$log/self-check.json" || {
  cat "$log/self-check.json"; echo "SELF-CHECK FAILED"; exit 1; }
echo "self-check: OK"

.build/debug/hflctl --help > "$log/help.txt"
echo "help: OK"

# The only real HAL touch: a read-only status query.
.build/debug/hflctl status > "$log/status.json" 2> "$log/status.stderr" || {
  cat "$log/status.json"; cat "$log/status.stderr" >&2
  echo "STATUS FAILED (read-only; no writes were attempted)"; exit 1; }
echo "status (read-only): OK"

echo "== fixture smoke test (media goes to /tmp, never committed) =="
fixdir="${HPF_FIXTURE_DIR:-/tmp/hpf-fixture-smoke}"
rm -rf "$fixdir"
$PY "$here/fixture/make_fixture.py" --out-dir "$fixdir" --ffmpeg "$FFMPEG" \
  --events 3 --event-interval 1.5 --tail 0.5 --quiet \
  > "$log/fixture.txt" 2>&1 || {
    cat "$log/fixture.txt"; echo "FIXTURE GENERATION FAILED"; exit 1; }
ls -l "$fixdir" >> "$log/fixture.txt"
echo "fixture: OK ($fixdir)"

echo "== trace analyzer: synthetic missing-evidence check =="
$PY - <<'PY' > "$log/synthetic-trace.json"
import json
print(json.dumps([
  {"name": "AUHAL::OpenDevice", "cat": "audio", "ph": "X", "ts": 1000, "args": {"buffer_size_frames": 512}},
  {"name": "SomeRenderer", "cat": "audio", "ph": "i", "ts": 2000, "args": {"frames": 480}}
]))
PY
$PY "$here/chrome_trace/analyze_latency_trace.py" \
  "$log/synthetic-trace.json" -o "$log/latency-analysis.json" \
  > "$log/analyzer.txt" 2> "$log/analyzer.stderr"
analyzer_exit=$?
if [ "$analyzer_exit" != "1" ]; then
  cat "$log/analyzer.txt"; cat "$log/analyzer.stderr" >&2
  echo "ANALYZER SHOULD HAVE REPORTED MISSING EVIDENCE (exit 1), got $analyzer_exit"; exit 1
fi
echo "analyzer missing-evidence path: OK (exit 1 as designed)"

echo
echo "ALL VERIFY STEPS PASSED"
echo "log_dir=$log"
echo "fixture_dir=$fixdir"
