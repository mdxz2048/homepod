# Swift → Python transport acceptance

Offline integration probe: generates deterministic per-channel PCM, streams it
through the real Swift resampler and HPCM v2 encoder, then independently checks
the resulting bytes with the existing Python decoder. Does not capture audio,
open devices, change defaults or play sound. This is software transport evidence,
not permission, live source-layout or acoustic evidence.

Run on macOS from the repository root (Debug is required for `@testable`):

```sh
swift run --package-path tests/virtual_audio/swift_transport_probe -c debug VirtualTransportCheck /tmp/flow-transport-fixtures
python3 tests/virtual_audio/check_swift_transport.py /tmp/flow-transport-fixtures
```

Covers seven canonical layouts at 44.1/48kHz, 32 successive blocks per case,
unchanged channel order, cumulative frame ratio (unflushed converter tail tolerance
128 frames), wire continuity, and conservative device-mix provenance. Fixtures
are generated locally and need not be committed.
