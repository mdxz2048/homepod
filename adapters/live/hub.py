"""Unbounded-duration media timeline with bounded memory, using frozen C ABI v1.

No file reader, fabricated duration, clock epoch equivalence or EOF padding.
The producer pushes actual capture frames. A slow peer faults the whole group.
"""
from __future__ import annotations

import array
import asyncio
from collections import deque
import hashlib
import math
import time

from bindings.python.flow_core import Engine, OK, TRANSPORT_FAILED, WOULD_BLOCK
from adapters.airplay_pyatv.render import pcm16be


class LiveFailure(RuntimeError):
    pass


class LiveOutput:
    def __init__(self, capacity):
        self.capacity = capacity
        self.queue = deque()
        self.buffered = self.offset = self.native_frames = self.consumed_frames = self.peak = 0
        self.first_presentation_ns = None
        self.native_hash = hashlib.sha256()
        self.consumed_hash = hashlib.sha256()
        self.open = False

    def prepare(self, rate, channels):
        if (rate, channels) != (44100, 2):
            return TRANSPORT_FAILED
        self.open = True
        return OK

    def enqueue(self, block):
        frames = len(block.samples) // 2
        if not self.open or block.channels != 2 or block.first_frame != self.native_frames:
            return TRANSPORT_FAILED
        if self.buffered + frames > self.capacity:
            return WOULD_BLOCK
        pcm = pcm16be(block.samples)
        self.queue.append((block.presentation_ns, pcm))
        self.native_hash.update(pcm)
        self.native_frames += frames
        self.buffered += frames
        self.peak = max(self.peak, self.buffered)
        if self.first_presentation_ns is None:
            self.first_presentation_ns = block.presentation_ns
        return OK

    def close(self):
        self.open = False
        self.queue.clear()
        self.buffered = self.offset = 0


class LiveHub:
    sample_rate = 44100
    channels = 2

    def __init__(self, library, routes, *, input_capacity_frames=88200,
                 block_frames=352, output_capacity_blocks=4, stall_timeout=2.0,
                 clock_ns=time.monotonic_ns, engine_factory=Engine):
        if (not routes or len(routes) > 8
                or any(type(key) is not int or not 0 <= key < 2**32 for key in routes)
                or any(len(mapping) != 2 or any(type(c) is not int or c not in (0, 1) for c in mapping)
                       for mapping in routes.values())
                or type(block_frames) is not int or not 1 <= block_frames <= 4096
                or type(input_capacity_frames) is not int or not block_frames <= input_capacity_frames <= 88200
                or type(output_capacity_blocks) is not int or not 1 <= output_capacity_blocks <= 16
                or not math.isfinite(stall_timeout) or not 0 < stall_timeout <= 10):
            raise ValueError("invalid live routes or queue budgets")
        self.routes = {key: list(value) for key, value in routes.items()}
        self.block_frames = block_frames
        self.input_capacity_frames = input_capacity_frames
        self.stall_timeout, self.clock_ns = stall_timeout, clock_ns
        self.outputs = {key: LiveOutput(block_frames * output_capacity_blocks) for key in routes}
        self.input_queue = deque()
        self.input_buffered = self.input_resident = self.input_peak = self.input_frames = self.next_frame = self.submit_calls = 0
        self.input_offset = 0
        self.first_receipt_ns = self.origin_ns = None
        self.condition = asyncio.Condition()
        self.first_block = asyncio.Event()
        self.reading = set()
        self.started = self.stopped = False
        self.failure = None
        self.engine = engine_factory(library, self.sample_rate, self.channels)
        try:
            for key, mapping in self.routes.items():
                self.engine.add_output(key, mapping, self.outputs[key])
            self.engine.prepare()
        except BaseException:
            self.engine.close()
            raise

    async def push(self, samples, receipt_ns=None):
        # PCM validation remains outside the HAL callback and before native ABI.
        if (not samples or len(samples) % 2 or len(samples) > 16384
                or any(not math.isfinite(v) or abs(v) > 1 for v in samples)):
            await self.fail(LiveFailure("invalid live PCM block"))
            raise self.failure
        owned = array.array("f", samples)
        frames = len(owned) // 2
        async with self.condition:
            self._require_live()
            if self.input_resident + frames > self.input_capacity_frames:
                self._fail_locked(LiveFailure("live input exceeded bounded queue budget"))
                raise self.failure
            if self.first_receipt_ns is None:
                self.first_receipt_ns = self.clock_ns() if receipt_ns is None else receipt_ns
            self.input_queue.append(owned)
            self.input_buffered += frames
            self.input_resident += frames
            self.input_frames += frames
            self.input_peak = max(self.input_peak, self.input_resident)
            self.first_block.set()
            self.condition.notify_all()

    def start(self, playback_lead_ns):
        if self.first_receipt_ns is None or self.started or self.stopped:
            raise LiveFailure("first capture block required before starting a new live timeline")
        self.origin_ns = self.engine.start(1, self.first_receipt_ns, playback_lead_ns)
        self.started = True
        return self.origin_ns

    def _require_live(self):
        if self.failure:
            raise LiveFailure("live group failed") from self.failure
        if self.stopped:
            raise LiveFailure("live group stopped")

    def _fail_locked(self, exc):
        if self.failure is None:
            self.failure = exc
        self.engine.close()
        self.stopped = True
        self.input_queue.clear()
        self.input_buffered = self.input_resident = self.input_offset = 0
        self.first_block.set()
        self.condition.notify_all()

    async def fail(self, exc):
        async with self.condition:
            self._fail_locked(exc)

    def _produce(self):
        if not self.input_queue:
            return False
        head = self.input_queue[0]
        count = min(self.block_frames, len(head) // 2 - self.input_offset)
        if any(output.buffered + count > output.capacity for output in self.outputs.values()):
            return False
        first = self.input_offset * 2
        self.engine.submit(1, self.next_frame, head[first:first + count * 2])
        self.next_frame += count
        self.submit_calls += 1
        self.input_offset += count
        self.input_buffered -= count
        if self.input_offset == len(head) // 2:
            self.input_queue.popleft()
            self.input_resident -= len(head) // 2
            self.input_offset = 0
        return True

    async def read(self, output_id, nframes):
        if output_id not in self.outputs or type(nframes) is not int or not 1 <= nframes <= 4096:
            raise ValueError("bounded live read required")
        if output_id in self.reading:
            await self.fail(LiveFailure("concurrent reads of one live output"))
            raise self.failure
        self.reading.add(output_id)
        result = bytearray()
        deadline = asyncio.get_running_loop().time() + self.stall_timeout
        try:
            async with self.condition:
                try:
                    if not self.started:
                        raise LiveFailure("live timeline has not started")
                    output = self.outputs[output_id]
                    while len(result) < nframes * 4:
                        self._require_live()
                        if output.queue:
                            presentation, pcm = output.queue[0]
                            target = presentation + output.offset * 1_000_000_000 // self.sample_rate
                            if self.clock_ns() + 50_000_000 > target:
                                raise LiveFailure("live output missed common presentation deadline")
                            count = min(len(pcm) // 4 - output.offset, nframes - len(result) // 4)
                            offset = output.offset * 4
                            part = pcm[offset:offset + count * 4]
                            result.extend(part)
                            output.consumed_hash.update(part)
                            output.consumed_frames += count
                            output.offset += count
                            if output.offset == len(pcm) // 4:
                                output.queue.popleft()
                                output.buffered -= len(pcm) // 4
                                output.offset = 0
                            deadline = asyncio.get_running_loop().time() + self.stall_timeout
                            self.condition.notify_all()
                        elif self._produce():
                            self.condition.notify_all()
                        else:
                            remaining = deadline - asyncio.get_running_loop().time()
                            if remaining <= 0:
                                raise LiveFailure("live input or peer stalled")
                            await asyncio.wait_for(self.condition.wait(), remaining)
                    return bytes(result)
                except BaseException as exc:
                    self._fail_locked(exc)
                    raise
        except asyncio.CancelledError as exc:
            async with self.condition:
                self._fail_locked(exc)
            raise
        finally:
            self.reading.discard(output_id)

    async def stop(self):
        async with self.condition:
            self.engine.close()
            self.stopped = True
            self.input_queue.clear()
            self.input_buffered = self.input_resident = self.input_offset = 0
            self.first_block.set()
            self.condition.notify_all()

    def report(self):
        return {"live": True, "native_core_used": self.submit_calls > 0,
                "input_frames": self.input_frames, "native_submitted_frames": self.next_frame,
                "input_peak_frames": self.input_peak, "input_capacity_frames": self.input_capacity_frames,
                "native_submit_calls": self.submit_calls, "hub_stopped": self.stopped,
                "group_failed": self.failure is not None,
                "playback_origin_ns": self.origin_ns, "first_receipt_ns": self.first_receipt_ns,
                "clock_anchor": "python_first_pcm_receipt_not_native_host_time",
                "capture_to_receipt_uncertainty_ns": None,
                "acoustic_sync_verified": False,
                "outputs": [{"output_id": key, "native_frames": output.native_frames,
                             "consumed_frames": output.consumed_frames,
                             "queue_peak_frames": output.peak, "queue_capacity_frames": output.capacity,
                             "first_presentation_ns": output.first_presentation_ns,
                             "native_pcm_sha256": output.native_hash.hexdigest(),
                             "consumed_pcm_sha256": output.consumed_hash.hexdigest()}
                            for key, output in self.outputs.items()]}
