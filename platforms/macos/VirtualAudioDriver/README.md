# HomePod Flow Audio — output-only HAL prototype

This is an independent, original C implementation of the public AudioServerPlugIn ABI.
The only declared format is native-endian packed Float32 **interleaved stereo**, at
44100 or 48000 Hz (initial 48000). One output stream, no input or microphone,
no volume controls, no network, no shared-memory transport, no PCM storage.
Buffer size is fixed at 512 frames. Zero timestamp period is independently 16384.

The device **silently consumes output**. It does not send anything to HomePods by
itself. Whether a device/stream Core Audio Tap can retrieve nonzero, independent
left/right PCM from this sink is an unpassed integration gate. Do not select it as
the normal system output before a verified receiver and output recovery exist.

## Build and inspect on the target Mac

Requires Xcode Command Line Tools. Run from any directory, with absolute output paths:

```bash
bash /absolute/repo/platforms/macos/VirtualAudioDriver/scripts/test.sh /absolute/review/tests
bash /absolute/repo/platforms/macos/VirtualAudioDriver/scripts/build-stage.sh /absolute/review/stage
```

Both commands operate on review directories only. Neither copies to HAL, changes
the selected output, sends audio, requests TCC, or restarts a service. The build
uses `-Wall -Wextra -Werror` and ad-hoc signing. A stage bundle is not a signed,
notarized installer or proof of runtime Core Audio compatibility. The default
architecture is the target Mac's native architecture, not a universal release.

The test includes the implementation in a standalone process and exercises factory,
property scopes, latency validation, two-client lifecycle, current-time clock,
mock-host notifications/request failure/abort, stopped rate conversion, malformed
ASBD rejection, and non-mutating WriteMix sink. Stage path tests reject system HAL
and existing symlinks before writes. It never loads into
coreaudiod. HAL enumeration, AudioUnit open/start, actual Tap PCM, browsers,
sleep/wake, and acoustic delay remain separate real-system tests.

## Contract and latency

Source of truth: `docs/collaboration/virtual-audio/CONTRACT.md` v0.2.
Device UID: `com.homepodflow.virtual-audio.stereo.v1`.
Plug-in bundle ID: `com.homepodflow.audio.driver`.

- Device latency and safety offset: 0 frames. The **single stream** holds the
  downstream latency budget, initially 0 **uncalibrated**, not zero-latency playback.
- Device global/main `'hfla'`: UInt32 latency frames, 0..10×current sample rate;
  only writable with no running clients and no pending format change.
- Device global/main `'hflr'`: read-only UInt64 revision, initially 1.
- Stream latency is readable with global/main and output/main, one value. Input
  scope and non-main elements are rejected. Both latency scopes are notified.
- Sample-rate requests use the host configuration request/perform/abort protocol.
  Active IO rejects them. A committed change preserves the original rational
  seconds budget and derives the rounded new frame count, avoiding repeated-rate
  rounding accumulation. A new clock seed and revision invalidate old sessions.
- The clock reflects **current** `mach_absolute_time`, with no latency added to
  timestamps. GetZeroTimeStamp uses a bounded atomic snapshot and integer 128-bit
  tick/frame arithmetic. Its RT path has no mutex, allocation, logs or IO.
- Running clients are bounded to 64; duplicate StartIO/StopIO fails without
  decrementing another client's reference. Configuration/StartIO/StopIO use a
  non-RT control mutex; property notifications occur after unlocking.
- Any local audio client can set a public custom property: this is not a security
  boundary or proof of App ownership/calibration. App must monitor revision.
- Configuration is intentionally not persisted by the driver. On coreaudiod
  reload, zero uncalibrated latency must not trigger automatic output takeover.

No claim of browser compensation follows from returning latency properties.
The actual render→capture→HomePod time must match the reported budget, and
Chrome/Safari adoption and acoustic/video error must be measured independently.

## Installation / rollback review — instructions only

There is intentionally **no install/uninstall shell script** in this prototype.
The coordinator must first review the staged bundle, tests, signature, source
manifest, and current default output. Installation is a separate controlled step.

1. Confirm the normal output UID, stop HomePod Flow, and preserve any existing
   `HomePodFlowAudio.driver` bundle before replacement. Do not overwrite unrelated
   HAL plug-ins. Ensure recovery steps remain accessible without audio.
2. The administrator-approved system destination is exactly
   `/Library/Audio/Plug-Ins/HAL/HomePodFlowAudio.driver`, with system-appropriate
   ownership/permissions. Driver should contain only the reviewed executable and
   Info.plist; do not bundle Python or user-writable runtime configuration there.
3. Use a scheduled user-approved restart to load/unload, following Apple's sample
   installation guidance. Do not terminate coreaudiod from a development script.
4. Enumerate without selecting the device, then inspect all declared properties
   and open an AudioUnit. Only after those pass, explicitly test this silent sink
   with a verified capture path. Report and handle failure without false ready.
5. Before uninstall, restore an available normal output and stop every client.
   Remove **only the exact reviewed bundle** above, or restore the saved previous
   version; use another approved restart. Verify it disappears and normal playback
   works. Never remove the enclosing HAL directory or other vendors' bundles.

Ad-hoc identity is for local development only. Formal release requires stable
signing, installation/update/rollback design, and App crash-recovery helper.

## Primary references

- [Apple minimal driver sample and installation guidance](https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in)
- [Apple AudioServerPlugInDriverInterface ABI](https://developer.apple.com/documentation/coreaudio/audioserverplugindriverinterface)
- [Apple DoIOOperation contract](https://developer.apple.com/documentation/coreaudio/audioserverplugindriverinterface/doiooperation)

No Apple sample source or third-party driver implementation is copied into this
directory. API names and ABI declarations come from the target SDK headers.
