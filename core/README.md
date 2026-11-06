# HomePod Flow core — M0

Dependency-free C++17 library for independent N-output routing with one common
media timeline. M0 is the offline foundation. The M1 finite-session adapter
uses the native library through C ABI v1; its actual-device validation is tracked
separately. The existing historical Python AirPlay prototype is unchanged.

## Build and run

From the repository root, with CMake 3.16+ and a C++17 compiler:

```sh
cmake -S . -B build -DFLOW_BUILD_TESTS=ON
cmake --build build
ctest --test-dir build --output-on-failure
./build/flow_offline_demo
```

For multi-configuration generators, specify `--config Debug` for build and
`-C Debug` for CTest; the example will be in the generator's Debug directory.
Without CMake:

```sh
clang++ -std=c++17 -Wall -Wextra -Wpedantic -Icore/include core/src/core.cpp examples/offline_demo.cpp -o flow_offline_demo
./flow_offline_demo
clang++ -std=c++17 -Wall -Wextra -Wpedantic -Icore/include core/src/core.cpp tests/core_contract_tests.cpp -o flow_core_tests
./flow_core_tests
```

The demo uses a fixed injected clock and three in-memory outputs. It prints
different channel samples with the same epoch, first frame and presentation
time. Each fake output has capacity two. A third block explicitly returns
`WouldBlock`, closes the entire group and leaves it Faulted. No networking,
audio hardware or HomePod is accessed.

## Lifecycle and ownership

The public source-level contract is `include/flow/core.hpp`. A caller supplies a
Clock and Output implementations, then invokes prepare → start → submit → stop.
Calls must be serialized externally; this M0 API is not thread-safe or suitable
for use directly on a real-time audio callback. It allocates and copies samples.

prepare validates every route, unique output ID/instance and scheduled-start
capability before touching any output. Output prepare failure closes all
attempted outputs, including the failed one, and leaves the engine Idle.
start creates a checked nonnegative clock origin plus a positive lead time.
submit accepts finite normalized interleaved float32 samples, matching format
and epoch, beginning at frame zero and continuing without gaps. Routing copies
selected channels; repeated channel indices duplicate samples. No mixing,
resampling, gain or codec is applied.

All output blocks are constructed before any enqueue call. Presentation time
is `origin + floor(first_frame * 1e9 / sample_rate)`, calculated using integer
division with overflow checks. Malformed input is rejected without changing
the expected frame or calling outputs. Allocation exceptions during fanout
construction can propagate before enqueue, also without advancing the timeline.

Any backend enqueue failure, including bounded-queue WouldBlock, closes the
whole group and enters Faulted. Some earlier outputs might have accepted data;
the engine never retries this block. close must discard pending work, but cannot
undo sound already physically emitted. Backend exceptions map to status errors
and run the same cleanup. stop is idempotent and resets the timeline to Idle;
destruction also stops the engine.

## Evidence boundary and next work

Accepted scheduled timestamps prove only the software plan. A backend declaring
scheduled-start support must actually implement the supplied clock-domain
semantics. There is no deadline enforcement, device clock conversion, network
buffering, drift correction, reconnection or acoustic synchrony measurement in
M0. Future timestamps can become late if callers submit too slowly. A real
AirPlay adapter and real-device recordings are required for M1 validation.

The C++ API remains source-level. `include/flow/bridge.h` defines the separately
versioned C ABI v1 and builds as shared target `flow_bridge`; exceptions are
contained at that boundary. `bindings/python/flow_core.py` owns ctypes callbacks
until native destruction completes. Host monotonic time is explicitly supplied
to start rather than assuming Python and std::chrono share a clock epoch.
There is no Swift binding yet. Finite AirPlay integration and explicit CLI are
documented in `adapters/airplay_pyatv/README.md` at the repository root.
Windows, macOS and Linux portability is an architecture goal; build evidence
must name the actual platforms tested and must not imply untested platforms
have passed.
