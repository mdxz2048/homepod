#!/bin/sh
# HomePod Flow 0 s vs 2 s Chrome A/B: read-only prep + printed runbook.
# This script does NOT launch Chrome, does NOT write HAL properties by default,
# and does NOT play audio. Writes are only executed when BOTH --apply-ms and
# HPF_EXPERIMENT_APPLY=1 are set, and then go through hflctl (guarded, verified,
# fail-closed). Run it on the target Mac.
#
# Usage:
#   bash record_experiment.sh --condition a --ms 0     --output-dir /tmp/hpf-ab/a
#   bash record_experiment.sh --condition b --ms 2000  --output-dir /tmp/hpf-ab/b
set -u

usage() {
  cat <<'EOF'
usage: record_experiment.sh --condition a|b --ms MILLISECONDS
       [--output-dir DIR] [--fixture-dir DIR] [--hflctl PATH]
       [--chrome PATH] [--runs N] [--apply-ms]
EOF
}

CONDITION=""
MS=""
OUT_DIR=""
FIXTURE_DIR=""
HFLCTL=""
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
RUNS=3
APPLY_MS=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --condition) CONDITION="$2"; shift 2 ;;
    --ms) MS="$2"; shift 2 ;;
    --output-dir) OUT_DIR="$2"; shift 2 ;;
    --fixture-dir) FIXTURE_DIR="$2"; shift 2 ;;
    --hflctl) HFLCTL="$2"; shift 2 ;;
    --chrome) CHROME="$2"; shift 2 ;;
    --runs) RUNS="$2"; shift 2 ;;
    --apply-ms) APPLY_MS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$CONDITION" ] || [ -z "$MS" ]; then
  echo "missing --condition or --ms" >&2
  usage
  exit 2
fi

if [ -z "$HFLCTL" ]; then
  HFLCTL="$(cd "$(dirname "$0")/../hflctl" && pwd)/.build/debug/hflctl"
fi
OUT_DIR="${OUT_DIR:-/tmp/hpf-chrome-ab/${CONDITION}-${MS}ms}"
mkdir -p "$OUT_DIR"

cat > "$OUT_DIR/plan.json" <<EOF
{
  "schema": "hpf-chrome-ab-plan.v1",
  "condition": "$CONDITION",
  "requested_ms": $MS,
  "runs": $RUNS,
  "fixture_dir": "$FIXTURE_DIR",
  "output_dir": "$OUT_DIR",
  "chrome": "$CHROME",
  "apply_hal_write": $( [ "$APPLY_MS" = "1" ] && echo true || echo false )
}
EOF

echo "== 1/read-value: current HAL status (read-only) =="
"$HFLCTL" status > "$OUT_DIR/status-before.json" || {
  echo "hflctl status failed; inspect $OUT_DIR/status-before.json" >&2
  exit 1
}
cat "$OUT_DIR/status-before.json"

if [ "$APPLY_MS" = "1" ]; then
  if [ "${HPF_EXPERIMENT_APPLY:-0}" != "1" ]; then
    echo "refusing write: set HPF_EXPERIMENT_APPLY=1 to allow hflctl set-ms $MS" >&2
    exit 1
  fi
  echo "== 2/apply: guarded hflctl set-ms $MS =="
  "$HFLCTL" set-ms "$MS" > "$OUT_DIR/set-ms.json" || {
    cat "$OUT_DIR/set-ms.json"
    echo "set-ms failed closed (see JSON). If device_busy, quit the client holding IO first." >&2
    exit 1
  }
  cat "$OUT_DIR/set-ms.json"
else
  echo "== 2/apply: SKIPPED (no --apply-ms). Run below with HPF_EXPERIMENT_APPLY=1: =="
  echo "  HPF_EXPERIMENT_APPLY=1 \"$HFLCTL\" set-ms $MS"
fi

PROFILE="${OUT_DIR}/chrome-profile"
cat > "$OUT_DIR/runbook.txt" <<EOF
Chrome A/B runbook (condition=$CONDITION, ms=$MS, runs=$RUNS)
=============================================================

PRE-STEP (complete stream reopen contract):
  After the budget is applied (or re-applied) you MUST fully close the
  experimental Chrome using this profile and relaunch it, so AUHAL closes and
  reopens the output stream and re-reads hardware latency. Do not close other
  browsers unless one holds the device IO busy; hflctl reports device_busy only
  when that is the case.

LAUNCH (read-value run, isolated profile):
  "$CHROME" \
    --user-data-dir="$PROFILE" \
    --autoplay-policy=no-user-gesture-required \
    --disable-features=AudioServiceOutOfProcess \
    --enable-logging=stderr \
    --vmodule='*/media/audio/*'=1 \
    "file://$FIXTURE_DIR/player.html"

TRACE CAPTURE (primary, local Chrome UI):
  1. In the same profile open chrome://tracing.
  2. Press Record, keep category "audio" (leave everything else off for a
     small trace; optionally add "blink" if needed later).
  3. In the fixture tab press play and let one full loop finish.
  4. Stop recording, press Save, write:
       $OUT_DIR/trace-${CONDITION}-run<N>.json
  5. On chrome://version record the revision line into:
       $OUT_DIR/chrome_version.json   ({"version": "<full version string>"})
  6. Analyze each trace:
       python3 $(cd "$(dirname "$0")" && pwd)/analyze_latency_trace.py \
         "$OUT_DIR/trace-${CONDITION}-run<N>.json" \
         -o "$OUT_DIR/latency-analysis-${CONDITION}-run<N>.json" \
         --version-file "$OUT_DIR/chrome_version.json"

ALTERNATE STARTUP TRACE (version dependent; verify the file is produced):
  "$CHROME" \
    --user-data-dir="$PROFILE" \
    --autoplay-policy=no-user-gesture-required \
    --trace-startup=audio \
    --trace-startup-duration=40 \
    --trace-startup-file="$OUT_DIR/chrome-startup-trace.json" \
    "file://$FIXTURE_DIR/player.html"
  If the file is absent or empty, fall back to chrome://tracing; never claim a
  trace passed because a flag was accepted.

ACOUSTIC VERIFICATION (separate from read-value):
  1. Start the phone camera recording FIRST.
  2. Click play on the fixture (or rely on autoplay setting) and record one
     full loop.
  3. Stop the camera. Save to:
       $OUT_DIR/camera-${CONDITION}-run<N>.mov
  4. Assist measurement (manual confirmation still required):
       python3 $(cd "$(dirname "$0")" && pwd)/measure_recording.py \
         "$OUT_DIR/camera-${CONDITION}-run<N>.mov" \
         -o "$OUT_DIR/acoustic-${CONDITION}-run<N>.json" \
         --events-file "$FIXTURE_DIR/events.json"
  5. Metric: P95 of per-event |audio_onset - video_onset| across all runs.
     With an A/V-fused fixture, compensation keeps this near the 0 s baseline;
     if Chrome ignores the budget it grows toward the configured 2000 ms.

SANITY RESET for the next condition:
  HPF_EXPERIMENT_APPLY=1 "$HFLCTL" set-ms <next_ms>   # e.g. 0 -> 2000 -> 0
  Quit the profile Chrome before switching conditions.
EOF

echo "== 3/runbook written: $OUT_DIR/runbook.txt =="
cat "$OUT_DIR/runbook.txt"
echo
echo "artifact_dir=$OUT_DIR"
