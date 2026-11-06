# Native-core → pyatv finite-session bridge (M1)

This experimental backend is pinned to `pyatv==0.18.0` and
`srptools==1.0.1`. It uses private sender hooks with one scoped patch owner.
It does not import or execute the historical `sync_probe.py` or its adapter.
No command below is run automatically on import or application startup.

Build the native library with the root CMake project. On macOS its path is
normally `build/core/libflow_bridge.dylib`; Windows produces `flow_bridge.dll`
(possibly under a configuration directory), Linux `libflow_bridge.so`.

## Offline first

From the repository root, with project Python dependencies available:

```sh
python -m adapters.airplay_pyatv dry-run --library build/core/libflow_bridge.dylib --seconds 3 --report artifacts/m1-dry-run.json
```

The input has three distinct tone channels. Every float sample goes through
the C ABI and C++ PlaybackEngine. Native output callbacks copy routed blocks
into bounded queues. Their PCM is converted to signed16 big-endian and fed
through the same custom pyatv AudioSource used by the network sender. The dry
run consumes each source and reports its frame count and SHA-256; it never
scans, connects, changes volume or plays audio.

## Explicit network operations

Discover without playing (addresses are examples, not saved defaults):

```sh
python -m adapters.airplay_pyatv scan --host 192.168.0.104 --host 192.168.0.115
```

Play a three-second three-output test with **15% default receiver volume**:

```sh
python -m adapters.airplay_pyatv play --library build/core/libflow_bridge.dylib --seconds 3 --target 0=FRONT_IP --target 1=LEFT_IP --target 2=RIGHT_IP --report artifacts/m1-play.json
```

Replace each IP placeholder with an address from discovery. Explicit maps use
zero-based input channels, e.g. `--route 0=0,0 --route 1=1,1 --route 2=2,2`.
There is no hardcoded room, device IP or three-output engine limit. This finite
bridge currently caps batches at 8 outputs and 30 seconds, with a total routed
sample budget. `--wav path.wav` accepts uncompressed signed16 PCM WAV; actual
AirPlay sessions require 44100Hz and stereo output maps. There is no implicit
decoder, download, resampler or 5.1 downmix. Volume can be explicitly set with
`--volume 0..100`; default is 15 and no previous loud value is reused.

## Actual sender path

1. Validate bounded native routing before network setup.
2. Discover and connect each requested RAOP receiver.
3. Request the configured volume, establish RTSP/ALAC, defer initial sync.
4. At every receiver's prepared barrier, check format/latency agreement, confirm
   requested volume after setup, then create a fresh native common start plan
   and native-routed finite buffers. Preflight timestamps are never reused.
5. Map expected playback origin P to send/sync origin S=P−latency/rate, using
   one frozen host monotonic↔NTP anchor. Set every start_ts/head_ts from S.
6. Reject an expired readiness plan; wait until S, reject excessively late
   release, then start original pyatv sync and paced sender loops.
7. Custom AudioSource returns only the C++-routed PCM; the adapter wraps each
   packet in verbatim ALAC. pyatv retains retransmission and tail padding.
8. Check all input frames were consumed and protocol-latency padding completed.
   Cancel and close the entire group on failure; restore every patched method.

The default 8-second lead includes latency and finite native rendering work.
Rendering that misses the deadline fails the group; it is not silently shifted
to a different timeline. Readiness guard is 50ms, release tolerance 20ms; these
are experimental software thresholds, not acoustic precision guarantees.

## Honest evidence and limitations

Sender success means accepted data, full source consumption and completed
padding; it never means the receiver was audible or acoustically synchronized.
UDP delivery/receiver internal behavior cannot be proven here. Report fields
always include `acoustic_sync_verified=false`. Existing true-device history
belongs to the earlier Python prototype, not to this new bridge.

This is finite pre-rendered playback, not continuous capture. There is no drift
correction, reconnect, native stereo-pair support, video control or general
multiroom interoperability. Mid-session failure can occur after another device
has already emitted sound; cleanup cannot retract that sound. Cleanup waiting
is bounded and incomplete cleanup is explicitly reported as failure. A
dedicated process is required because pyatv hooks are process-global; overlapping
bridge sessions or already patched pyatv methods are refused.
