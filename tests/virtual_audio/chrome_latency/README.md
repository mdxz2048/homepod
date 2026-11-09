# 017 Chrome/Flow 0 s vs 2 s AV compensation — preparation

Scope: **new files under `tests/virtual_audio/chrome_latency/**` only.** No
production code, driver, HAL property, default device, browser, or system
setting was changed. No media is committed. No Chrome launch, no playback, no
trace capture, and no write command was executed by the implementation owner.
The only real-system action performed was reading HAL status on `homepod-mac`
(read-only) and building/testing the offline tooling.

## What is here

| Path | Purpose |
|---|---|
| `hflctl/` | Swift CLI. Read-only `status` + guarded `set-ms`/`rollback` for the exact UID `com.homepodflow.virtual-audio.surround71.v1`. JSON output, fail-closed. |
| `fixture/make_fixture.py` | Generates one MP4 (H.264+AAC) with simultaneous 4-quadrant flashes and short beeps on one media timeline + an ordinary `<video>` page. No WebAudio / JS timers. |
| `chrome_trace/` | Read-value vs acoustic verification runbook, trace analysis (`analyze_latency_trace.py`), camera measurement helper (`measure_recording.py`), and a safe prep script (`record_experiment.sh`). |

## hflctl

```sh
cd tests/virtual_audio/chrome_latency/hflctl
xcrun swift test            # 8 offline arithmetic tests (no HAL)
xcrun swift build -c release

.build/release/hflctl status                 # read-only, JSON, exit 0 only when contract holds
.build/release/hflctl self-check             # offline, no CoreAudio calls
.build/release/hflctl set-ms 2000            # guarded write + verify + auto-rollback on failure
.build/release/hflctl rollback --to-ms 0     # explicit previous-frames restore path
```

Properties read: UID/model UID, alive, `DeviceIsRunning` and
`DeviceIsRunningSomewhere` (running IO), nominal rate and available rates,
buffer size + range, device latency/safety (both scopes, must be 0),
zero-timestamp period (16384), output/input stream counts, channel count,
custom `hfla` (CFPropertyList/CFNumber) and `hflr`, and
`kAudioStreamPropertyLatency` in **both** global/main and output/main scopes.

Write behavior (`set-ms`, `rollback`):

1. require exact UID, alive, single output stream, idle IO,
2. optional `--expect-revision` guard against concurrent writes,
3. convert `0...3000` ms to frames at the current rate,
4. write `hfla` as CFPropertyList/CFNumber exactly like
   `HALVirtualDeviceBackend.setLatencyFrames`,
5. read back and verify `hfla`, both stream latency scopes, revision
   increment (or unchanged for an idempotent value),
6. on post-write verification failure, roll back to the pre-snapshot
   frames/rate and re-verify; report `rollback:{attempted,restored}`,
7. exit 0 only on a verified result; every other path exits 1 (2 = usage).

No `--uid` override exists: the tool cannot be redirected to another UID or the
system default. See `hflctl/schema` or `hflctl --help`.

## Fixture

```sh
python3 tests/virtual_audio/chrome_latency/fixture/make_fixture.py --out-dir /tmp/hpf-fixture
# -> /tmp/hpf-fixture/{fixture.mp4,player.html,events.json,beeps.wav}
```

The generator is stdlib-only plus `ffmpeg`. Default output goes to a fresh temp
directory unless `--out-dir` is given, so media is never written into the repo
by accident. The MP4 contains 8 events (configurable) at known onsets; each
event flashes all four quadrants simultaneously and plays an 80 ms 1 kHz beep
whose onset equals the flash onset in media time. `events.json` records the
exact onsets.

## Chrome trace / acoustic verification

See `chrome_trace/README.md` for the full runbook. Key points:

- Read-value proof = `hflctl status`/`set-ms` JSON + Chrome `audio`-category
  trace analyzed by `analyze_latency_trace.py` (searches for
  `hardware_latency_us`; empty output = proof missing).
- Acoustic proof = single camera recording of the fixture, measured by
  `measure_recording.py` as per-event |flash→beep| skew, reported as P95.
- Complete stream reopen after each budget change; other browsers close only if
  `hflctl` returns `device_busy`.
- No claim of "trace passed" or "sound passed" without the actual files.

## Evidence recorded (implementation owner)

- Local: `artifacts/mac-status-20261107.json` — real read-only `hflctl status`
  from `homepod-mac` (device surround71.v1, 8ch, 48 kHz, hfla=0, hflr=1).
- Mac: `live-validation/017-chrome-latency/` — build/test/status logs.

## Not performed (coordinator/GPT)

`set-ms`/`rollback` real writes, Chrome launch/trace capture, camera recording,
and acoustic measurement. They remain explicit, separately-verified steps.
