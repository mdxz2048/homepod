# HomePod Flow managed worker (protocol v1)

Run from the repository root using the project's Python environment:

```sh
python -u -m adapters.worker
```

The supervising App owns stdin/stdout. Each request and event is one UTF-8 JSON
line terminated by LF, at most 64 KiB including LF. stdout contains only NDJSON;
third-party prints and bounded worker diagnostics use stderr. Importing or
issuing `hello` never scans, loads the native core, changes volume or plays audio.

The authority for fields is `docs/collaboration/WORKER_PROTOCOL_V1.md`. Requests
contain exactly `v`, `id`, `command`, `params`. Events contain exactly `v`, `id`,
`event`, `session`, `payload`. Unsupported fields, NaN/Infinity, repeated object
keys, invalid UTF-8 and EOF without a final LF are rejected. IDs have at most
128 characters; business ID/session histories are capped at 4096 per process.
Restart the worker at capacity; stop/shutdown remain available for cleanup.

## Commands

| Command | Parameters | Behavior |
|---|---|---|
| hello | `{}` | Supported protocol, commands and capabilities; ABI version means supported interface, not a loaded or verified library |
| inspect | `{wav:absolute_path}` | Reads WAV metadata, closes reader; no audio session |
| scan | Optional `hosts`, `timeout_seconds` | Explicit RAOP discovery only; returns up to 64 `{name,address,model}` devices |
| start | See below | Local preflight, accepted, asynchronous states and one terminal result/error |
| stop | `{session:UUID}` | Stops matching active session and waits for confirmed cleanup |
| shutdown | `{}` | Stops active work, confirms cleanup, exits even if stdin stays open |

`start.params` requires `session`, `library`, `wav`, `execution`, `routes`.
`library` and `wav` must be absolute existing local files. `execution` must be
explicitly `offline` or `airplay`. Each route has an integer `output_id` and two
zero-based `channels`; airplay additionally requires a unique `host`. Offline
rejects hosts. Optional `volume` defaults to 15%; `lead_seconds` defaults to 8
and supports positive nanosecond-resolution values up to 60 seconds.

Before accepted, the worker validates file availability, WAV metadata and real
channel mapping. AirPlay additionally requires 44100Hz WAV. It then calls the
existing `WavReader` + `stream_dry_run`/`stream_play` implementation. There is
no fake native implementation or alternative DSP path in the production runner.

Offline processing emits preparing then completed; it does not invent a network
streaming state. AirPlay streaming state requires an actual shared timing plan
and its send origin to have arrived; it still does not prove audible playback.
Every successful completed/stopped terminal includes `cleanup_complete:true`
and the genuine native report. Acoustic synchronization remains unverified.

## Lifecycle and failure handling

Only one session can be active. Scan and inspect are busy during playback.
Session UUIDs are never reused within a worker; preserve the App-provided UUID
case in all related events. A stale stop cannot cancel a newer session. Every
accepted start receives one terminal result/error on its original ID; stop and
shutdown have their own response IDs.

Cleanup requires actual adapter evidence for native hub stopped, input closed,
and cleanup complete. Missing evidence or timeout poisons the process; further
start commands are refused and the supervisor must replace the worker. No
fallback manufactures a stopped hub after stream invocation. stdin EOF cancels
active work and waits for the same cleanup protocol. Cancellation arriving
during terminal finalization cannot interrupt its reporting.

Malformed requests with a trusted unique ID get a related error. Valid session
UUIDs on start/stop are echoed even when parameters or worker state reject the
request. Duplicate IDs use null ID/session and `offending_id`, avoiding an error
that could accidentally terminate an existing start request.

The stdin reader is a daemon thread feeding a queue capped at 16 messages;
shutdown does not depend on closing stdin or a default-executor read finishing.
An uncertain process exits with nonzero status and cannot host a new session.

## Validation

```sh
python -m unittest tests.test_worker_protocol -v
```

These tests inject runners solely for control-plane cancellation/failure cases
and exercise actual worker subprocesses for NDJSON-only stdout, stop/restart,
EOF and shutdown with stdin held open. They do not claim native playback proof.
The coordinator separately runs the production worker with a real compiled
native library and PCM WAV on macOS; see collaboration integration evidence.
