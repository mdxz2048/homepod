# 002 Native mono capture format support

Implement now; no plan-only answer. Keep investigation short (rg + <=100-line windows; never dump whole large files). At most 10 shell calls. Final Chinese report <=250 characters, paths and limitations only. Do not narrate analysis.

Only edit:
- platforms/macos/VirtualAudioInput/Sources/VirtualAudioInput/DeviceTapCapture.swift
- platforms/macos/VirtualAudioInput/Tests/VirtualAudioInputTests/DeviceTapFormatTests.swift (new)

Goal: DeviceTapCapture accepts native mono plus existing stereo..8ch, 44.1/48k interleaved Float32. Existing validation currently requires >=2 at line 243. Extract format validation into an internal static method callable by @testable import; start() must call that same method. Update comment/error wording to 1..8. Leave tap description.isMono=false: it must preserve source/device channels, not request downmix. Do not change this flag without documented evidence. Reject 0/>8ch, wrong byte stride, integer/planar formats, unsupported sample rates. Preserve all cleanup, locking, ABI, real-time callback, playback/routing and device selection behavior.

Add meaningful table-based XCTest coverage of accepted native mono and stereo/6ch/8ch at both rates, and malformed ASBD rejection (zero/excess channels, wrong stride/packet, integer/planar flags, unsupported rate). No HAL calls or permission prompts in unit tests. Import CoreAudio/AudioToolbox explicitly if needed. Swift 6 macOS package. Windows cannot run Swift tests; do not install tooling. Coordinator will run Mac tests and runtime probes. Do not claim full end-to-end mono or live nonzero PCM passed.

No other file edits, credentials, SSH, system changes, commits, agents, or model calls. Do not read prior audit logs. Return when code and test are written.
