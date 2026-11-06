# 003 Multichannel resampler slice (independent file ownership)

Implement, do not return a plan. Keep reasoning/tool use brief: rg and <=100-line windows, no full-file dumps; <=10 shell calls. Final report <=250 Chinese characters. Do not read other agent logs/history.

You own ONLY these NEW files:
- platforms/macos/VirtualAudioInput/Sources/VirtualAudioInput/VirtualPCMResampler.swift
- platforms/macos/VirtualAudioInput/Tests/VirtualAudioInputTests/VirtualPCMResamplerTests.swift
Another worker edits DeviceTapCapture.swift and DeviceTapFormatTests.swift. Do not touch them or Package.swift, existing v1 code, Models.swift or other files.

Implement an independent streaming Float32 interleaved -> 44100Hz Float32 little endian resampler for native 1/2/3/4/6/8 channels. Public API suitable for future HPCM v2 producer:
VirtualConvertedPCM { frames:Int, bytes:Data, clippedSamples:UInt64 }
VirtualPCMResampler init(sourceRate:Double, channels:Int) throws
convert(samples:[Float], frames:Int) throws -> [VirtualConvertedPCM]

Use AVAudioConverter, @preconcurrency import AVFAudio, no process/device/TCC APIs. Source rates exactly 44100 or 48000. Preserve channel order, never mix/remap. Output packets 1...4096 frames, interleaved f32 little-endian. converter.primeMethod=.none, output count follows converter; streaming converter retained across calls. Confine converter access with NSLock or equivalent, no allocations on RT callback (this API is non-RT). Bound input to 1...4096 frames and work/allocations. Validate exact samples.count, finite input before consuming any sample; fail closed for malformed blocks. Bound/clamp converted finite values to [-1,1], count clipped. Expose leading/trailing frame counts and explicit delay-known=false if useful. No silent dropping/tail flush claims. Avoid AVFoundation automatic channel-layout remix: input/output identical channel count at different rates. A direct 44100 passthrough path with identical bounds is acceptable.

Reference only if needed: existing stereo implementation platforms/macos/ProcessTapCapture/Sources/TapCaptureHostSupport/FloatResampler.swift (do not edit).

Meaningful XCTest tests: all supported counts at both rates, >1 successive block per converter, per-channel distinct constants/one-hot signals to detect mixing/reordering; at 48k accumulated frame count near ratio with documented tolerance for unflushed tail, not exact per block; payload strides and finite bounded floats; invalid channels/rates/input lengths/NaN/Inf rejection; rejection before input consumption. 44.1k samples should preserve identity except explicit clipping. No runtime capture/playback. Windows has no Swift toolchain; coordinator will compile/test on Mac. No credentials/SSH/system edits/commits/model calls. Stop after two files are complete.
