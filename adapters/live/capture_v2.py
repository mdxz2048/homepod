"""Owned macOS capture host subprocess consuming strict HPCM v2.

Inherits the bounded v1 lifecycle (owned subprocess, start/stop, stderr trail,
EOF/timeout escalation) and swaps the protocol decode plus v2 command, ready,
stop and error validation. No shell, recording file, automated capture,
permission inference or playback. Import is inert.
"""
from __future__ import annotations

import asyncio
import json
import math

from .capture import CaptureHost
from .hub import LiveFailure
from .pcm_v2 import (CANONICAL_DEVICE_UID, LAYOUTS, RES_LAYOUTS,
                     PCMV2Validator, read_frame_v2)


class CaptureHostV2(CaptureHost):
    def __init__(self, executable, session, hub, device_uid, layout, processor):
        if layout not in LAYOUTS or layout in RES_LAYOUTS:
            raise ValueError("unsupported virtual input layout")
        if CANONICAL_DEVICE_UID.get(layout) != device_uid:
            raise ValueError("device UID does not match the canonical input layout")
        if not callable(processor):
            raise ValueError("virtual input processor must be callable")
        super().__init__(executable, session, hub)
        self.device_uid = device_uid
        self.layout = layout
        self.channels = len(LAYOUTS[layout])
        self.processor = processor
        self.validator = PCMV2Validator(session, self.start_id)

    async def _command(self, command, command_id):
        params = {"session": self.session}
        if command == "start":
            params["deviceUID"] = self.device_uid
            params["layout"] = self.layout
        encoded = (json.dumps({"v": 2, "id": command_id, "command": command,
                               "params": params}, allow_nan=False) + "\n").encode()
        self.process.stdin.write(encoded)
        await asyncio.wait_for(self.process.stdin.drain(), 1)

    @staticmethod
    def _source_rate_ok(value):
        return (type(value) in (int, float) and not isinstance(value, bool)
                and math.isfinite(value) and value in (44100, 48000))

    def _ready_ok(self, header):
        return (type(header.get("outputRate")) is int
                and header.get("outputRate") == 44100
                and type(header.get("outputChannels")) is int
                and header.get("outputChannels") == self.channels
                and header.get("outputLayout") == self.layout
                and header.get("deviceUID") == self.device_uid
                and self._source_rate_ok(header.get("sourceRate"))
                and type(header.get("sourceChannels")) is int
                and header.get("sourceChannels") == self.channels)

    async def _pump(self):
        received_ready = False
        try:
            while True:
                frame = await read_frame_v2(self.process.stdout)
                header = frame.header
                kind = header["kind"]
                if kind == "ready":
                    self.validator.correlated(header)
                    if received_ready or self.ready.done():
                        raise LiveFailure("invalid or duplicate capture ready")
                    if not self._ready_ok(header):
                        raise LiveFailure("invalid capture ready")
                    received_ready = True
                    self.ready_header = header
                    self.ready.set_result(header)
                elif kind == "pcm":
                    if not received_ready:
                        raise LiveFailure("PCM arrived before capture ready")
                    samples = self.validator.pcm(frame)
                    processed = self.processor(samples)
                    if not self.stopping:
                        await self.hub.push(processed)
                elif kind == "stopped":
                    if not self.stopping:
                        raise LiveFailure("capture host stopped without controller stop")
                    self.validator.correlated(header, self.stop_id)
                    if self.stopped_reply.done():
                        raise LiveFailure("duplicate capture stop")
                    if (type(header.get("cleanupComplete")) is not bool
                            or header.get("drainComplete") is not False
                            or type(header.get("discardedConverterTail")) is not bool):
                        raise LiveFailure("capture stop lacks cleanup evidence")
                    self.stopped_reply.set_result(header)
                    return
                else:
                    self.validator.correlated(header)
                    if (header.get("cleanupComplete") is not None
                            and type(header.get("cleanupComplete")) is not bool):
                        raise LiveFailure("capture error lacks strict cleanup state")
                    self.error_header = header
                    code = str(header.get("code", "unknown"))[:128]
                    message = " ".join(str(header.get("message", "")).split())[:128]
                    raise LiveFailure("capture host reported failure: " +
                                      f"{code} {message}".strip())
        except BaseException as exc:
            self.last_error = type(exc).__name__
            if not self.ready.done():
                self.ready.set_exception(exc)
            if not self.stopped_reply.done():
                self.stopped_reply.set_exception(exc)
            if not self.stopping:
                await self.hub.fail(exc)
            # Futures carry the failure to start/stop; never leak task exceptions.
