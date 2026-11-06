# Portable stereo spatial processing ABI 1

Independent C++17 shared library. It does not modify or replace the frozen
`core/include/flow/bridge.h` nine-symbol ABI. No platform, network, codec,
capture or device objects enter this library. Calls are serialized by the
owner. C processing and gain scheduling allocate no memory; the Python wrapper
allocates input/output views and an output array off the capture callback.

## Build and checks

```sh
cmake -S processing -B build/processing -DCMAKE_BUILD_TYPE=Release
cmake --build build/processing
ctest --test-dir build/processing --output-on-failure
FLOW_PROCESSING_LIBRARY="$PWD/build/processing/libflow_processing.dylib" python -m unittest discover -s tests -p processing_binding_checks.py -v
```

Linux uses `.so`, Windows `.dll` (multi-configuration generators may place the
DLL under `Release/`). CMake only builds this library and independent behavior
checks; no legacy core files are modified.

## Host integration

```python
from array import array
from processing.python import Processor

with Processor(library_path, [
    {"x": .5, "y": .1}, {"x": .1, "y": 1}, {"x": .9, "y": 1},
], mode="cinema", listener=(.5, .7), initial_master_gain=0) as dsp:
    dsp.set_gain(.25, effective_frame=0, ramp_frames=882)
    buses = dsp.process(array('f', [0, 0] * 352))
    # buses are frame-major 6-channel PCM, not three concatenated buffers.
    # Existing core gets channels=6, output maps [0,1], [2,3], [4,5].
```

`Processor.process(stereo, first_frame=None)` starts at frame zero and requires
continuous media frames. Live bridge owns epoch, host timestamps, resampling
and the audio clock. There is no total-duration limit or per-device delay.
Creating a new processor for a new epoch resets frame zero. No method resets
an active timeline silently. Initial master gain defaults to **zero**; callers
schedule a ramp to the intended user gain before forwarding audible samples.
Hardware protocol volume and software scaling are coordinated by the owner;
this library never sends a device volume command.

`set_gain(target, output_index=-1, effective_frame=None, ramp_frames=882)` takes
linear 0..1 gain, not user volume percentages. Index -1 changes the common
master; 0..N-1 changes relative gain. Minimum ramp is 882 frames (20ms at
44100Hz); maximum is 441000 frames (10s). A scheduled update applies to all
output buses at the same media frame. Ramp sample one advances 1/length and
the last reaches the target. Interrupted ramps start from the previous
sample's exact current value. Future commands occupy a 64-slot bounded queue;
same index and effective frame replace the last target even if full. Host
coalesces high-frequency UI changes, handles queue-full explicitly and never
reports acceptance as audible confirmation.

## Inspectable matrices and format boundary

Fixed input: native 32-bit finite float stereo, 44100Hz, range [-1,1]. One to
eight devices, each two output channels; output is `2*N` channels. Blocks
contain 1..max_frames (configured 1..65536). Finite gains and room coordinates
are 0..1; screen is y=0 and listener faces screen. Model/ID routing belongs to
host; ordered device list defines ordered output buses.

Sync copies input L/R to every device before gain. Cinema is stereo spatial
allocation, **not native 5.1/Atmos, independent dialog or source separation**.
For device delta (dx,dy) from listener:

- r = clamp(dy / max(1-listener_y, .05), 0, 1).
- p = dx / hypot(dx,dy), or zero for coincident coordinates.
- M=(L+R)/2, S=(L-R)/2, Q=.25*M-.70*p*S.
- Yl=(1-r)*L+r*Q; Yr=(1-r)*R+r*Q.
- Each matrix row is normalized if its L1 sum exceeds one.

If no device has r<=.1, the device with minimum r (stable input-order tie
break) is assigned r=0, preserving full stereo content. Co-located layouts
are well-defined. Mono rear content remains .25 of the original at r=1;
opposite stereo content gives different left/right rear responses. Positions
change matrices, not just illustrations. `matrix` exposes pre-gain
coefficients `[LL,LR,RL,RR]` per device for diagnostics and independent checks.

All frame bounds, buffers, output capacity and input values are prevalidated
before writing output or advancing ramp/timeline state. Input/output overlap
is rejected; foreign C pointers must still refer to actual valid allocations
(a C ABI cannot inspect arbitrary caller memory). Status 0=OK, 1=invalid
argument, 2=media discontinuity, 3=queue full. Borrowed last_error remains
valid until the next mutating call or destruction. Null destroy is safe.

These offline contracts do not prove measured speaker synchronization,
long-term clock stability or live-capture performance. Those need independent
end-to-end acceptance against the integrated release package.
