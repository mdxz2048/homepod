"""Bounded pull-driven native routing; no pre-rendering or repeated play calls.

One event loop serializes callbacks and queue admission. Public C ABI v1 stays
unchanged. Importing this module never opens a receiver or plays audio.
"""
from __future__ import annotations

import array
import asyncio
from collections import deque
import hashlib
import math
import struct
import time
import wave

from bindings.python.flow_core import Engine, OK, TRANSPORT_FAILED, WOULD_BLOCK
from .render import pcm16be
from .source import CoreAudioSource
from .timing import LateStartError


class StreamFailure(RuntimeError):
    pass


class ToneReader:
    """Finite signal generated only for the next requested block."""
    def __init__(self, seconds=60.0, channels=3, sample_rate=44100):
        if (not math.isfinite(seconds) or not 0 < seconds <= 3600
                or not 1 <= channels <= 16 or not 1 <= sample_rate <= 192000):
            raise ValueError("bounded finite duration, channel count and rate required")
        self.sample_rate, self.channels = sample_rate, channels
        self.total_frames = int(seconds * sample_rate)
        if not self.total_frames:
            raise ValueError("input must contain at least one frame")
        self.frames_read = self.read_calls = self.max_read_frames = 0
        self.closed = False

    def read(self, nframes):
        if self.closed or nframes <= 0:
            raise StreamFailure("reader closed or invalid read size")
        count = min(nframes, self.total_frames - self.frames_read)
        result = array.array("f")
        for frame in range(self.frames_read, self.frames_read + count):
            t = frame / self.sample_rate
            end = (self.total_frames - frame) / self.sample_rate
            fade = min(1.0, t / .02, end / .02)
            for channel in range(self.channels):
                result.append(.12 * fade * math.sin(2 * math.pi * (440 + 220 * channel) * t))
        self.frames_read += count
        self.read_calls += 1
        self.max_read_frames = max(self.max_read_frames, count)
        return result

    def close(self):
        self.closed = True


class WavReader:
    """Signed16 PCM WAV reader retaining only the currently requested block."""
    def __init__(self, path):
        self.file = wave.open(str(path), "rb")
        self.closed = False
        try:
            self.sample_rate = self.file.getframerate()
            self.channels = self.file.getnchannels()
            self.total_frames = self.file.getnframes()
            if (self.file.getsampwidth() != 2 or self.file.getcomptype() != "NONE"
                    or not 1 <= self.sample_rate <= 192000 or not 1 <= self.channels <= 16
                    or not 0 < self.total_frames <= self.sample_rate * 3600):
                raise ValueError("stream requires 0..3600s uncompressed signed16 PCM WAV")
        except BaseException:
            self.close()
            raise
        self.frames_read = self.read_calls = self.max_read_frames = 0

    def read(self, nframes):
        if self.closed or nframes <= 0:
            raise StreamFailure("reader closed or invalid read size")
        count = min(nframes, self.total_frames - self.frames_read)
        data = self.file.readframes(count)
        if len(data) != count * self.channels * 2:
            raise StreamFailure("truncated WAV stream")
        self.frames_read += count
        self.read_calls += 1
        self.max_read_frames = max(self.max_read_frames, count)
        return array.array("f", (item[0] / 32768 for item in struct.iter_unpack("<h", data)))

    def close(self):
        if not self.closed:
            self.file.close()
            self.closed = True


class _QueueOutput:
    def __init__(self, capacity_frames):
        self.capacity_frames = capacity_frames
        self.queue = deque()
        self.offset_frames = 0
        self.queued_frames = self.buffer_frames = self.peak_frames = self.native_frames = 0
        self.native_callbacks = self.consumed_frames = self.eof_reads = 0
        self.first_presentation_ns = self.last_presentation_ns = None
        self.native_hash = hashlib.sha256()
        self.consumed_hash = hashlib.sha256()
        self.open = False

    def prepare(self, rate, channels):
        if channels != 2:
            return TRANSPORT_FAILED
        self.sample_rate = rate
        self.open = True
        return OK

    def enqueue(self, block):
        frames = len(block.samples) // block.channels
        if not self.open or block.first_frame != self.native_frames or block.channels != 2:
            return TRANSPORT_FAILED
        if self.buffer_frames + frames > self.capacity_frames:
            return WOULD_BLOCK
        pcm = pcm16be(block.samples)
        self.queue.append((block.first_frame, block.presentation_ns, pcm))
        self.native_hash.update(pcm)
        self.native_callbacks += 1
        self.native_frames += frames
        self.queued_frames += frames
        self.buffer_frames += frames
        self.peak_frames = max(self.peak_frames, self.buffer_frames)
        if self.first_presentation_ns is None:
            self.first_presentation_ns = block.presentation_ns
        self.last_presentation_ns = block.presentation_ns
        return OK

    def close(self):
        self.open = False
        self.queue.clear()
        self.queued_frames = self.buffer_frames = self.offset_frames = 0


class BoundedHub:
    """One native timeline with all-route admission before every input read.

    read() may yield while another output is full; no producer thread or busy
    wait is used. A stalled route, cancellation or late presentation faults the
    group and wakes every waiter. No native WouldBlock is retried.
    """
    def __init__(self, library, reader, routes, block_frames=352, capacity_blocks=4,
                 stall_timeout=2.0, clock_ns=time.monotonic_ns, deadline_guard_ns=50_000_000):
        self.engine = None
        self.reader = reader
        self.stopped = False
        try:
            if (not 1 <= len(routes) <= 8 or not 1 <= block_frames <= 4096
                    or not 1 <= capacity_blocks <= 64 or not math.isfinite(stall_timeout)
                    or stall_timeout <= 0 or deadline_guard_ns < 0
                    or not 1 <= reader.channels <= 16 or not 1 <= reader.sample_rate <= 192000
                    or reader.total_frames <= 0 or any(len(route) != 2 for route in routes.values())):
                raise ValueError("invalid bounded streaming configuration")
            self.routes = {key: list(route) for key, route in routes.items()}
            self.block_frames, self.capacity_blocks = block_frames, capacity_blocks
            self.stall_timeout, self.clock_ns = stall_timeout, clock_ns
            self.deadline_guard_ns = deadline_guard_ns
            self.outputs = {key: _QueueOutput(block_frames * capacity_blocks) for key in routes}
            self.condition = asyncio.Condition()
            self.reading = set()
            self.failure = None
            self.started = self.input_eof = False
            self.next_frame = self.submit_calls = self.capacity_waits = 0
            self.origin_ns = self.epoch = 0
            self.engine = Engine(library, reader.sample_rate, reader.channels)
            for key, mapping in self.routes.items():
                self.engine.add_output(key, mapping, self.outputs[key])
        except BaseException:
            if self.engine:
                self.engine.close()
            reader.close()
            raise

    def start(self, now_ns, lead_ns, epoch=1):
        if self.started or self.stopped:
            raise StreamFailure("hub starts once")
        try:
            self.engine.prepare()
            self.origin_ns = self.engine.start(epoch, now_ns, lead_ns)
            self.epoch = epoch
            self.started = True
            return self.origin_ns
        except BaseException:
            self.engine.close()
            self.reader.close()
            self.stopped = True
            raise

    def _can_produce(self):
        count = min(self.block_frames, self.reader.total_frames - self.next_frame)
        return all(output.buffer_frames + count <= output.capacity_frames for output in self.outputs.values())

    def _produce(self):
        if not self._can_produce():
            raise StreamFailure("admission required before input read")
        count = min(self.block_frames, self.reader.total_frames - self.next_frame)
        samples = self.reader.read(count)
        if len(samples) != count * self.reader.channels or not count:
            raise StreamFailure("reader returned incomplete or unexpected frames")
        self.engine.submit(self.epoch, self.next_frame, samples)
        self.next_frame += count
        self.submit_calls += 1
        if self.next_frame == self.reader.total_frames:
            self.input_eof = True
            self.reader.close()

    def _fail_locked(self, exc):
        if self.failure is None:
            self.failure = exc
        try:
            self.engine.close()
            self.reader.close()
        finally:
            self.stopped = True
            self.condition.notify_all()

    async def read(self, output_id, nframes):
        if output_id not in self.outputs or not isinstance(nframes, int) or not 1 <= nframes <= 65536:
            raise ValueError("valid output and bounded positive read required")
        if output_id in self.reading:
            raise StreamFailure("concurrent reads of one output are unsupported")
        self.reading.add(output_id)
        result = bytearray()
        loop = asyncio.get_running_loop()
        deadline = loop.time() + self.stall_timeout
        try:
            async with self.condition:
                try:
                    if not self.started:
                        raise StreamFailure("hub is not started")
                    output = self.outputs[output_id]
                    while len(result) < nframes * 4:
                        if self.failure:
                            raise StreamFailure("stream group failed") from self.failure
                        if self.stopped:
                            raise StreamFailure("stream group stopped")
                        if output.queue:
                            _first, presentation, pcm = output.queue[0]
                            target = presentation + output.offset_frames * 1_000_000_000 // self.reader.sample_rate
                            if self.clock_ns() + self.deadline_guard_ns > target:
                                raise LateStartError("queued audio missed expected playback deadline")
                            available = len(pcm) // 4 - output.offset_frames
                            count = min(available, nframes - len(result) // 4)
                            offset = output.offset_frames * 4
                            part = pcm[offset:offset + count * 4]
                            result.extend(part)
                            output.consumed_hash.update(part)
                            output.consumed_frames += count
                            output.queued_frames -= count
                            output.offset_frames += count
                            if output.offset_frames == len(pcm) // 4:
                                output.queue.popleft()
                                output.buffer_frames -= len(pcm) // 4
                                output.offset_frames = 0
                            deadline = loop.time() + self.stall_timeout
                            self.condition.notify_all()
                        elif self.input_eof:
                            output.eof_reads += 1
                            break
                        elif self._can_produce():
                            self._produce()
                            self.condition.notify_all()
                        else:
                            self.capacity_waits += 1
                            remaining = deadline - loop.time()
                            if remaining <= 0:
                                raise TimeoutError("stream consumer stalled with a full peer queue")
                            try:
                                await asyncio.wait_for(self.condition.wait(), remaining)
                            except asyncio.TimeoutError as exc:
                                raise TimeoutError("stream consumer stalled with a full peer queue") from exc
                    return bytes(result)
                except BaseException as exc:
                    self._fail_locked(exc)
                    raise
        except asyncio.CancelledError as exc:
            # Cancellation can happen while acquiring the Condition, before the
            # inner handler is entered. It must still wake and fault the group.
            if self.failure is None:
                async with self.condition:
                    self._fail_locked(exc)
            raise
        finally:
            self.reading.discard(output_id)

    async def stop(self):
        async with self.condition:
            try:
                self.engine.close()
                self.reader.close()
            finally:
                self.stopped = True
                self.condition.notify_all()

    def report(self):
        return {
            "native_core_used": self.submit_calls > 0,
            "streaming": True,
            "playback_origin_ns": self.origin_ns,
            "epoch": self.epoch,
            "input_frames": self.reader.total_frames,
            "input_frames_read": self.reader.frames_read,
            "input_read_calls": self.reader.read_calls,
            "input_peak_read_frames": self.reader.max_read_frames,
            "input_closed": self.reader.closed,
            "input_eof": self.input_eof,
            "native_submit_calls": self.submit_calls,
            "native_submitted_frames": self.next_frame,
            "block_frames": self.block_frames,
            "queue_capacity_frames": self.block_frames * self.capacity_blocks,
            "capacity_waits": self.capacity_waits,
            "hub_stopped": self.stopped,
            "group_failed": self.failure is not None,
            "group_error": repr(self.failure) if self.failure else None,
            "acoustic_sync_verified": False,
            "outputs": [{"output_id": key, "native_frames": output.native_frames,
                         "native_callbacks": output.native_callbacks,
                         "consumed_frames": output.consumed_frames,
                         "queue_peak_frames": output.peak_frames,
                         "queue_current_frames": output.queued_frames,
                         "buffer_current_frames": output.buffer_frames,
                         "eof_reads": output.eof_reads,
                         "first_presentation_ns": output.first_presentation_ns,
                         "last_presentation_ns": output.last_presentation_ns,
                         "native_pcm_sha256": output.native_hash.hexdigest(),
                         "consumed_pcm_sha256": output.consumed_hash.hexdigest()}
                        for key, output in self.outputs.items()],
        }


class StreamingSource(CoreAudioSource):
    def __init__(self, hub, output_id):
        super().__init__(output_id, hub.reader.sample_rate, hub.reader.total_frames)
        self.hub = hub

    async def readframes(self, nframes):
        if self.closed:
            return b""
        data = await self.hub.read(self.output_id, nframes)
        self.frames_read += len(data) // 4
        return data

    async def close(self):
        self.closed = True
        if self.frames_read < self.frames and not self.hub.stopped:
            async with self.hub.condition:
                self.hub._fail_locked(StreamFailure("source closed before consuming all frames"))


# The finite-session patch owner is reused unchanged: custom sources inherit
# CoreAudioSource and retain its format/duration/frames-consumed contract.
from .session import SessionPatches, check_versions, cleanup_session, scan
from .timing import build_timing_plan, ntp_from_unix_ns


class StreamingPatches(SessionPatches):
    def __init__(self, hub, report, lead_ns=8_000_000_000, barrier_timeout=30):
        self.hub = hub
        self.library = None
        self.sample_rate, self.channels = hub.reader.sample_rate, hub.reader.channels
        self.routes, self.report = hub.routes, report
        self.lead_ns, self.barrier_timeout = lead_ns, barrier_timeout
        self.sources = {key: StreamingSource(hub, key) for key in self.routes}
        self.clients = []
        self.ready = asyncio.Event()
        self.failure = self.plan = self.rendered = None
        self._originals = []
        self._installed = False

    def _prepare_plan(self):
        formats = {(client.context.sample_rate, client.context.channels,
                    client.context.bytes_per_channel, client.context.latency) for client, _ in self.clients}
        if len(formats) != 1:
            raise ValueError("all receivers must use identical streaming formats and latency")
        rate, channels, width, latency = next(iter(formats))
        if (rate, channels, width) != (self.sample_rate, 2, 2):
            raise ValueError("stream receiver must match input rate and signed16 stereo")
        before = time.monotonic_ns()
        ntp = ntp_from_unix_ns(time.time_ns())
        after = time.monotonic_ns()
        origin = self.hub.start(after, self.lead_ns)
        self.plan = build_timing_plan(origin, (before + after) // 2, ntp, rate, latency)
        for client, _source in self.clients:
            client.context.start_ts = self.plan.start_ts
            client.context.head_ts = self.plan.start_ts
        self.plan.assert_ready(time.monotonic_ns())
        self.report.update({"streaming": True, "playback_origin_ns": origin,
                            "send_origin_ns": self.plan.send_origin_ns,
                            "shared_start_ts": self.plan.start_ts,
                            "protocol_latency_samples": latency,
                            "protocol_sample_rate": rate,
                            "prepared_receivers": len(self.clients),
                            "anchor_uncertainty_ns": after - before,
                            "acoustic_sync_verified": False})


async def stream_dry_run(library, reader, routes, lead_ns=8_000_000_000,
                         block_frames=352, capacity_blocks=4, stall_timeout=2.0, report=None):
    """Accelerated offline consumption of the same bounded hub and sources."""
    hub = BoundedHub(library, reader, routes, block_frames, capacity_blocks, stall_timeout)
    sources = {key: StreamingSource(hub, key) for key in routes}
    report = report if report is not None else {}
    report.update({"status": "offline_stream_preparing", "network_used": False})
    tasks = []

    async def consume(source):
        while await source.readframes(352):
            pass

    try:
        hub.start(time.monotonic_ns(), lead_ns)
        tasks = [asyncio.create_task(consume(source)) for source in sources.values()]
        await asyncio.gather(*tasks)
        if not hub.input_eof or any(source.frames_read != reader.total_frames for source in sources.values()):
            raise StreamFailure("offline stream ended without complete input and output EOF")
        report["status"] = "offline_stream_completed"
    except BaseException as exc:
        report.update({"status": "failed", "error": f"{type(exc).__name__}: {exc}"})
        raise
    finally:
        cleaned = await cleanup_session([], tasks, sources.values(), report)
        await hub.stop()
        report.update(hub.report())
        if not cleaned:
            raise StreamFailure("offline stream cleanup incomplete")
    return report


async def stream_play(library, reader, routes, hosts, volume=15.0,
                      lead_ns=8_000_000_000, block_frames=352, capacity_blocks=4,
                      stall_timeout=2.0, report=None):
    """Explicit audible streaming operation, using one continuous core timeline."""
    report = report if report is not None else {}
    report.update({"status": "stream_initializing", "volume_percent": volume,
                   "streaming": True, "acoustic_sync_verified": False})
    hub = None
    try:
        check_versions()
        if (not math.isfinite(volume) or not 0 <= volume <= 100 or reader.sample_rate != 44100
                or not routes or set(routes) != set(hosts) or len(set(hosts.values())) != len(hosts)):
            raise ValueError("valid volume, 44100Hz and unique targets matching routes required")
        hub = BoundedHub(library, reader, routes, block_frames, capacity_blocks, stall_timeout)
        report["status"] = "discovering"
        devices = await scan(list(hosts.values()))
        by_host = {str(device.address): device for device in devices}
        missing = [host for host in hosts.values() if host not in by_host]
        if missing:
            raise StreamFailure("RAOP receiver not discovered: " + ", ".join(missing))
        import pyatv
        from pyatv.const import Protocol
        connections, tasks = [], []
        with StreamingPatches(hub, report, lead_ns) as patch:
            try:
                report["status"] = "connecting"
                for key, host in hosts.items():
                    connection = await asyncio.wait_for(pyatv.connect(
                        by_host[host], asyncio.get_running_loop(), protocol=Protocol.RAOP), 20)
                    connections.append(connection)
                    await connection.audio.set_volume(volume)
                report["status"] = "preparing"
                tasks = [asyncio.create_task(connection.stream.stream_file(patch.sources[key]))
                         for (key, _host), connection in zip(hosts.items(), connections)]
                duration = reader.total_frames / reader.sample_rate
                done, pending = await asyncio.wait(tasks, timeout=duration + lead_ns / 1e9 + 60,
                                                    return_when=asyncio.FIRST_EXCEPTION)
                for task in done:
                    task.result()
                if pending:
                    raise TimeoutError("continuous stream exceeded finite-session deadline")
                if not hub.input_eof or any(source.frames_read != reader.total_frames for source in patch.sources.values()):
                    raise StreamFailure("stream ended before full native output consumption")
                report["status"] = "stream_sender_completed_unverified_acoustically"
            finally:
                cleaned = await cleanup_session(connections, tasks, patch.sources.values(), report)
                if not cleaned:
                    raise StreamFailure("stream group cleanup incomplete")
    except BaseException as exc:
        report.update({"status": "failed", "error": f"{type(exc).__name__}: {exc}"})
        raise
    finally:
        if hub:
            await hub.stop()
            report.update(hub.report())
        else:
            reader.close()
    return report
