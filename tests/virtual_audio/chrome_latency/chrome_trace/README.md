# 017 Chrome latency trace runbook (read-value and acoustic verification are separate)

Owner scope: prepare instructions and tooling only. Nothing here launches
Chrome, writes HAL properties, plays audio, or claims a trace/sound result.
The real Chrome run is performed by the coordinator/GPT on the target Mac.

## Principle

1. **Read-value layer** proves what the HAL and Chrome *adopt*:
   - `hflctl status` before/after (device `hfla`/`hflr`, stream latency both
     scopes, running IO, rate, buffer, zero-timestamp period).
   - A Chrome trace captured from `chrome://tracing` with the `audio` category;
     `analyze_latency_trace.py` extracts any `hardware_latency_us` /
     playout-delay samples. Empty output means **evidence missing**, never a pass.
2. **Acoustic layer** proves the *actual* flash↔beep skew with a single camera:
   the fixture MP4 has the flashes and beeps in one encoded asset on one media
   timeline, so any measured skew comes from the playback chain, not the file.
   - At 0 ms budget: small steady skew.
   - At 2000 ms budget: compensation keeps the skew near the baseline; if
     Chrome ignores the budget the skew grows toward ~2000 ms.
   - Metric: **P95 of per-event |audio_onset − video_onset|** over all runs.

## Card of commands (target Mac)

```sh
# Build the CLI once (offline, no device writes):
cd .../tests/virtual_audio/chrome_latency/hflctl
xcrun swift test           # 8 offline arithmetic tests
xcrun swift build -c release

# Read-only status (safe to run at any time):
.build/release/hflctl status

# Generate the fixture (media is on-demand, never committed):
python3 .../tests/virtual_audio/chrome_latency/fixture/make_fixture.py \
  --out-dir /tmp/hpf-fixture

# Plan a condition (writes nothing by default; prints a runbook):
bash .../tests/virtual_audio/chrome_latency/chrome_trace/record_experiment.sh \
  --condition b --ms 2000 --output-dir /tmp/hpf-ab/b --fixture-dir /tmp/hpf-fixture
```

## Applying the budget (coordinator only)

`hflctl set-ms 0|2000` is a real HAL write. It fails closed unless:

- the exact device `com.homepodflow.virtual-audio.surround71.v1` exists,
- no running IO (`device_busy` otherwise; quit only the client holding IO),
- `--expect-revision N` matches the current `hflr` when supplied,
- the value is in `0...3000` ms,
- read-back of `hfla`, stream latency (global/output), and revision all verify.

```sh
REV=$(.../hflctl status | python3 -c 'import sys,json;print(json.load(sys.stdin)["device"]["hflr"])')
HPF_EXPERIMENT_APPLY=1 .../hflctl set-ms 2000 --expect-revision "$REV"
```

If verification fails after a write, the tool attempts a pre-snapshot rollback
(explicit previous frames/rate) and re-verifies; it never reports success
without verification and never invents a result. A no-op write of the current
value succeeds idempotently with `applied:false`.

## Complete stream reopen contract

The budget is read when the client opens the output stream. After every
`set-ms` change:

1. Quit the experimental Chrome (the one using the isolated profile).
2. Relaunch it with the **same** `--user-data-dir` so AUHAL closes and reopens
   the stream and re-reads `GetHardwareLatency`.

Other browsers do **not** need to close unless `hflctl` returns `device_busy`;
in that case exactly the client holding the device IO must be quit.

## Chrome launch (isolated profile)

```sh
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
PROFILE="/tmp/hpf-ab/b/chrome-profile"
"$CHROME" \
  --user-data-dir="$PROFILE" \
  --autoplay-policy=no-user-gesture-required \
  --disable-features=AudioServiceOutOfProcess \
  --enable-logging=stderr \
  --vmodule='*/media/audio/*'=1 \
  "file:///tmp/hpf-fixture/player.html"
```

`--disable-features=AudioServiceOutOfProcess` keeps audio tracing in-process for
much Chrome lineage; if your local build rejects it, drop that line and use
`chrome://tracing` (category `audio`), which is the primary supported path.

## Trace capture (primary: chrome://tracing)

1. Launch the isolated-profile Chrome above.
2. Open `chrome://tracing` in that profile.
3. Press **Record**; choose category **audio** only (small trace, deterministic).
4. In the fixture tab press play and let one full loop finish.
5. Stop, press **Save**, write `trace-<condition>-run<N>.json`.
6. On `chrome://version`, copy the exact version into `chrome_version.json`:
   `{"version": "..."}`.
7. Analyze:

```sh
python3 .../chrome_trace/analyze_latency_trace.py \
  trace-b-run1.json -o latency-analysis-b-run1.json \
  --version-file chrome_version.json
# Exit code 1 and evidence_found=false => no proof; do not claim a pass.
```

### Optional startup-trace flags (verify output exists before trusting)

```sh
"$CHROME" \
  --user-data-dir="$PROFILE" \
  --trace-startup=audio \
  --trace-startup-duration=40 \
  --trace-startup-file="/tmp/hpf-ab/b/chrome-startup-trace.json" \
  "file:///tmp/hpf-fixture/player.html"
```

Newer Chrome writes a binary tracing file, not JSON; if the file is absent,
empty, or unreadable, fall back to `chrome://tracing`. Never claim a capture
passed merely because a command-line flag was accepted.

## Acoustic verification (single camera)

1. Put the phone on a stand, frame the whole screen, start recording **first**.
2. Click play; record one full fixture loop.
3. Stop and save `camera-<condition>-run<N>.mov`.
4. Assist measurement (manual spot-check still required):

```sh
python3 .../chrome_trace/measure_recording.py \
  camera-b-run1.mov \
  -o acoustic-b-run1.json \
  --events-file /tmp/hpf-fixture/events.json
```

The helper detects beep onsets from the audio track and flash onsets from video
brightness, then reports per-event deltas plus P95. Camera A/V muxing, room
acoustics and compression add error; confirm several onsets by hand in an editor
before using the P95 as the experiment result.

## Result artifact layout (per condition)

```text
/tmp/hpf-ab/<condition>-<ms>ms/
  plan.json
  status-before.json
  set-ms.json                      # only when --apply-ms executed
  trace-<condition>-run<N>.json
  latency-analysis-<condition>-run<N>.json
  camera-<condition>-run<N>.mov
  acoustic-<condition>-run<N>.json
  chrome_version.json
```

Summary: report the read-value P95 of `hardware_latency_us` (when present) from
`latency-analysis-*.json`, and the acoustic P95 of |flash→beep skew| from
`acoustic-*.json`. Neither substitutes for the other; both must be present
before claiming the A/B passed.
