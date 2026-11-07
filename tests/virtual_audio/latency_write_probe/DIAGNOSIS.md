# 020 latency_write_probe — determination

Date: 2026-11-07 (Asia/Shanghai). Target: homepod-mac (macOS 26.5.2, Apple M1 Pro).

## Question

`hflctl set-ms 2000 --expect-revision 1` on the installed single Flow 8ch device
(`com.homepodflow.virtual-audio.surround71.v1`, default media output, 48k) returns
OSStatus `kAudioHardwareIllegalOperationError` (1852797029 / 0x6E6F7065), which
hflctl maps to `device_busy`, while `hflctl status` reports running=false,
hfla=0, hflr=1.

## Evidence

1. Installed bundle == this source. `/Library/Audio/Plug-Ins/HAL/HomePodFlowAudioFamily.driver`
   binary SHA256 `031d36674485de0bb7d39da34a7b6be18bdb0eca7e0cc90ca413b88407070825`
   equals live-validation/single-device-stage binary. `single-device-stage.log`
   records `PRODUCTION_IDENTITY=1 SINGLE_DEVICE=1` and the source hashes below,
   identical to the local/Mac working tree:
   - FlowVirtualAudioMultichannel.c `770c6de4…`
   - FlowVirtualAudioMultichannel.h `4a46ef54…`
   - FlowMultichannelMap.c      `8150ce24…`
   - FlowMultichannelMap.h      `b34aae91…`
   Bundle id `com.homepodflow.audio.driver`; only this driver + Apple ParrotAudio.
   `system_profiler` shows the exact device as Default Output (object 73), not a
   virtual aggregate.

2. Read path and settability are healthy. `hflctl status` decodes hfla/hflr as
   CFNumber (8-byte `CFNumberRef`/CFPropertyList transport, per
   `kAudioObjectPropertyCustomPropertyInfoList`), both stream latency scopes
   match hfla=0, `AudioObjectIsPropertySettable('hfla')` returns true. The
   historical sixth-candidate and dev-family runs wrote hfla=4800 successfully
   with the identical CFNumber marshalling, so CFNumber marshalling is not the
   cause of this rejection.

3. `latency_write_probe` (zero-mutation): writing the CURRENTLY READ hfla value
   (0) — an effective no-op — through `AudioObjectSetPropertyData` returned
   `kAudioHardwareIllegalOperationError` on 3/3 attempts, with
   DeviceIsRunning=0 and DeviceIsRunningSomewhere=0 both immediately before and
   after every attempt, hfla=0/hflr=1 unchanged throughout.

4. Driver guard in the installed source (`FlowVirtualAudioMultichannel.c`,
   SetData `'hfla'`) returns `kAudioHardwareIllegalOperationError` for exactly:
   `CFNumberGetValue` failure / out-of-range, `state->running != 0`,
   `state->ratePending == true`, or `frames > 10*rate`. For frames=0 none of the
   value/range/ceiling paths can fire.

5. `RatePendingFingerprint` (in-process, links the production single-device
   source through the supplied mock host) proves, on the exact installed source:
   - idle + no pending: no-op hfla write -> noErr, no revision bump;
   - running client -> no-op hfla write -> `kAudioHardwareIllegalOperationError`;
   - `ratePending`, running=0 -> no-op hfla write -> `kAudioHardwareIllegalOperationError`.

## Conclusion

The rejection is a real driver-side guard, not server-side pre-rejection and not
CFNumber marshalling. With running=0 surrounding every attempt and frames=0,
the only remaining path that emits `kAudioHardwareIllegalOperationError` is
`state->ratePending == true`: the installed driver is holding an outstanding
sample-rate/format configuration change that coreaudiod has not completed
(PerformChange) or aborted (AbortChange). This is a pending state, not verified
busy. It is either a stale driver-side pending request or a server-level pending
configuration change; both are indistinguishable from user space without a
driver re-instrumentation or coreaudiod log with elevated privilege.

Secondary defect (017-owned, not edited here): hflctl `writeNumber` maps every
`kAudioHardwareIllegalOperationError` to `device_busy`
(`CoreAudioClient.swift`), which conflates running, pending, and range. From the
outside this makes a pending configuration change look like verified busy.

## Minimal next action (coordinator/user, not this worker)

- This worker must not write hfla while the guard is pending, and should not
  weaken the guard or guess-retry.
- To clear the pending state, one of (a) temporarily switch default output to the
  built-in speaker and let any outstanding rate change complete/abort, or
  (b) restart coreaudiod / reboot, then re-run `hflctl status` and a single
  guarded `set-ms` probe. Both are system changes outside this worker's scope.
- Have 017 expose `pending_change` distinctly from `device_busy` in hflctl
  (preferably by probing set with the current value, as this probe does, before
  reporting busy), so future failures are not mislabelled.
