# Experimental fixed-layout HAL family

Status: **development prototype only**. Nothing here is installed, selected as
an output, or verified on a Mac. The production stereo implementation
(`src/FlowVirtualAudio.c`, UID `com.homepodflow.virtual-audio.stereo.v1`) and
`scripts/test.sh` are untouched.

Source of truth: `docs/collaboration/virtual-audio/MULTICHANNEL_CONTRACT.md`.
This implementation follows its seven-device R1 family, object IDs, ordering,
`source_padded` token, and height RES names. It is table-driven, not a renamed
2ch buffer.

## Device family (contract order)

Default build uses the safe `.dev` identity (distinct UIDs/bundle ID) so it can
be staged beside an installed production stereo bundle. `MC_PRODUCTION_IDENTITY=1`
selects the contract production UIDs/model UIDs for review; it is still only a
staged bundle.

| Order | Device | Layout token | Ch | Slots (canonical order) | Object IDs |
|---|---|---|---:|---|---|
| 1 | stereo | `stereo` | 2 | `FL FR` | `2 / 3` |
| 2 | mono | `mono` | 1 | `M` | `4 / 5` |
| 3 | 3.0 | `3_0` | 3 | `FL FR FC` | `6 / 7` |
| 4 | 4.0 quad back | `4_0` | 4 | `FL FR BL BR` | `8 / 9` |
| 5 | 5.1 side | `5_1_side` | 6 | `FL FR FC LFE SL SR` | `10 / 11` |
| 6 | 5.1 back | `5_1_back` | 6 | `FL FR FC LFE BL BR` | `12 / 13` |
| 7 | 7.1 | `7_1` | 8 | `FL FR FC LFE SL SR BL BR` | `14 / 15` |

`7_1` uses the Apple/HAL order: side before back. It is not WAVE
`BL BR SL SR`.

Height RES layouts are model-only and not enumerated: `5_1_2` (8ch,
`FL FR FC LFE SL SR TFL TFR`), `7_1_2` (10ch, adds `BL BR`), and `7_1_4`
(12ch, adds `TRL TRR`). The old `5.1.4`/`TBL`/`TBR` naming is not used.

## Format, layout, and buffer matrix

- Each device has exactly one output stream, no input stream.
- ASBD: native-endian packed interleaved Float32, 44100/48000 Hz,
  `mBytesPerFrame = mBytesPerPacket = 4 * C`, `mFramesPerPacket = 1`,
  `mBitsPerChannel = 32`.
- `kAudioDevicePropertyStreamConfiguration`: output one buffer with `C`
  channels and `mDataByteSize=0`; input zero buffers.
- `kAudioDevicePropertyPreferredChannelLayout` uses
  `kAudioChannelLayoutTag_UseChannelDescriptions` with explicit labels.
- `SL/SR` use `kAudioChannelLabel_LeftSurroundDirect` /
  `RightSurroundDirect` (side, ±90°). `BL/BR` use
  `kAudioChannelLabel_LeftSurround` / `RightSurround` (back, ±135°).
- `PreferredChannelsForStereo`: mono `{1,1}`, all others `{1,2}`.
- `BufferFrameSizeRange` is `{15,4096}`; Set accepts 15..4096; Get returns
  preferred 512. DoIO accepts host frames 0..4096; it does not assume 512.
- `CanBeDefaultSystemDevice` is true only for stereo; all other devices false.
- `CanBeDefaultDevice` is true for every output.
- A 2ch ASBD is rejected on any non-2ch stream with
  `kAudioDeviceUnsupportedFormatError`; it is never relabelled as 5.1/7.1.

## Capture/source policy

`src/FlowMultichannelMap.c` implements the contract's capture layer:

- `identity`: source labels equal container labels.
- `pad_silent`: source labels are a subset; unmatched container slots are
  exactly silent. No upmix.
- `refuse`: source exceeds container (`source_exceeds_container`) or a source
  label has no same-named slot (`container_layout_mismatch`).
- No downmix/upmix/remap/gain/delay is applied by capture.
- `source_padded` is the provenance token for a subset source.
- `stereo_passthrough_in_multichannel` is used for stereo into 5.1/7.1 and is
  never a native multichannel claim.
- `nativeClaim` follows the contract: exact identity with device+verified or
  decoder+verified; padded with decoder+verified; false for stereo passthrough
  and upstream-mapped sources.

Examples:

| Source | Container | Result |
|---|---|---|
| 3.0 | 5.1 side | `FL FR FC` in slots 0..2; 3..5 silent; `source_padded` |
| 4.0 | 5.1 back | `FL FR BL BR` in slots 0,1,4,5; 2,3 silent |
| 4.0 | 5.1 side | **refused** (`container_layout_mismatch`) |
| 5.1 side | 7.1 | slots 0..5 filled; 6/7 silent; `pad_5_1_side_to_7_1` |
| 5.1 back | 7.1 | slots 0..3 and 6/7 filled; 4/5 silent; `pad_5_1_back_to_7_1` |
| 7.1 | 5.1 side/back | **refused** (`source_exceeds_container`); explicit Flow downmix only |
| stereo | 5.1/7.1 | slots 0/1 only; `stereo_passthrough_in_multichannel` |

## Latency, clock, and RT discipline

- Each device has independent `hfla`, `hflr`, rate, running count, anchor,
  seed, and 16384-frame zero-timestamp period.
- `hfla`/`hflr` are per-device CFPropertyList/CFNumber, global/main only.
- Rate changes use host request/perform/abort and reject active IO; pending
  state is per device.
- `ZeroTimeStamp` uses `mach_absolute_time`, a bounded atomic snapshot, and
  128-bit arithmetic; no mutex.
- `ZeroTimeStamp`, `WillIO`, `BeginIO`, `DoIO` do no allocation, locking,
  logging, file/network, or CF work; `scripts/check-rt-path.py` enforces this.
- Property-read diagnostics are bounded and never on the IO thread.

## Build and test (Mac coordinator)

```bash
bash /absolute/repo/platforms/macos/VirtualAudioDriver/scripts/test-multichannel.sh \
  /absolute/review/family-tests
bash /absolute/repo/platforms/macos/VirtualAudioDriver/scripts/build-stage-multichannel.sh \
  /absolute/review/family-stage
# optional contract production-identity review build:
MC_PRODUCTION_IDENTITY=1 bash \
  /absolute/repo/platforms/macos/VirtualAudioDriver/scripts/build-stage-multichannel.sh \
  /absolute/review/family-stage-production
```

The test script runs pure map checks, the HAL property/format/clock checks in
both `.dev` and production identity, and the existing stereo regression is
unchanged:

```bash
bash /absolute/repo/platforms/macos/VirtualAudioDriver/scripts/test.sh \
  /absolute/review/stereo-tests
```

No script installs to `/Library/Audio/Plug-Ins/HAL`, changes output, plays
audio, or restarts coreaudiod.

## Mac coordinator checks that remain

1. Real HAL enumeration of all seven R1 devices in contract order; height RES
   must not appear.
2. Per-device StreamConfiguration, ASBD, preferred layout, element names, and
   `hfla`/`hflr`; 2ch ASBD rejection on wide streams.
3. Device/stream Tap with mixdown disabled: verify the tap retains `C` channels
   and labels. A 2ch tap result must be reported as mixdown, not native.
4. Per-slot PCM identity: unique signal per slot, side/back distinct, silent
   extra slots exact `+0.0`, no implicit matrix.
5. Buffer 256/512/1024/4096 and 8ch×4096; clock monotonicity and rate
   request/abort per device.
6. Production identity and bundle/signing/install/rollback are a separate
   controlled step; this prototype does not install.

## Known limitations / adaptations

- Default staging identity is `.dev`; production UIDs/model UIDs are behind
  `-DMC_PRODUCTION_IDENTITY=1`. The coordinator must review which identity to
  install and must not install the `.dev` bundle as a product identity.
- Height layouts are model-only RES; no height device is enumerated.
- The HAL family has no runtime configurable N-channel device (contract
  rejected that for R1).
- Actual device/stream Tap multichannel support, player output layout, and
  acoustic 5.1/7.1 remain unverified. Two HomePods cannot prove true 5.1/7.1.
