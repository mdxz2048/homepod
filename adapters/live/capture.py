"""Owned macOS capture host subprocess; no shell, recording file or auto-start."""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import uuid

from .hub import LiveFailure
from .pcm import PCMValidator, read_frame


class CaptureHost:
    def __init__(self, executable, session, hub, exclude_pids=()):
        path = Path(executable)
        if not path.is_absolute() or not path.is_file() or not os.access(path, os.X_OK):
            raise ValueError("an installed executable capture host is required")
        if any(type(pid) is not int or pid <= 0 for pid in exclude_pids) or len(exclude_pids) > 62:
            raise ValueError("invalid capture exclusions")
        self.executable, self.session, self.hub = str(path), session, hub
        self.exclude_pids = sorted(set(exclude_pids) | {os.getpid()})
        self.start_id, self.stop_id = str(uuid.uuid4()), str(uuid.uuid4())
        self.validator = PCMValidator(session, self.start_id)
        self.process = self.pump_task = self.stderr_task = None
        self.ready = self.stopped_reply = None
        self.stopping = self.cleanup_complete = False
        self.stderr_tail = bytearray()
        self.last_error = None
        self.error_header = None
        self.ready_header = None

    async def _command(self, command, command_id):
        params = {"session": self.session}
        if command == "start":
            params["excludedProcessIDs"] = self.exclude_pids
        encoded = (json.dumps({"v": 1, "id": command_id, "command": command, "params": params}) + "\n").encode()
        self.process.stdin.write(encoded)
        await asyncio.wait_for(self.process.stdin.drain(), 1)

    async def start(self):
        if self.process:
            raise LiveFailure("capture process already started")
        loop = asyncio.get_running_loop()
        self.ready, self.stopped_reply = loop.create_future(), loop.create_future()
        self.process = await asyncio.create_subprocess_exec(
            self.executable, "--serve", stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, limit=98304)
        self.pump_task = asyncio.create_task(self._pump())
        self.stderr_task = asyncio.create_task(self._stderr())
        await self._command("start", self.start_id)
        # The public permission dialog may need human interaction before R0 exists.
        await asyncio.wait_for(asyncio.shield(self.ready), 90)
        await asyncio.wait_for(self.hub.first_block.wait(), 5)
        self.hub._require_live()

    async def _stderr(self):
        while data := await self.process.stderr.read(2048):
            self.stderr_tail.extend(data)
            del self.stderr_tail[:-8192]

    async def _pump(self):
        received_ready = False
        try:
            while True:
                frame = await read_frame(self.process.stdout)
                h = frame.header
                kind = h["kind"]
                if kind == "ready":
                    self.validator.correlated(h)
                    if (received_ready or type(h.get("outputRate")) is not int or h["outputRate"] != 44100
                            or type(h.get("outputChannels")) is not int or h["outputChannels"] != 2
                            or not isinstance(h.get("sourceFormat"), dict)):
                        raise LiveFailure("invalid or duplicate capture ready")
                    received_ready = True
                    self.ready_header = h
                    self.ready.set_result(h)
                elif kind == "pcm":
                    if not received_ready:
                        raise LiveFailure("PCM arrived before capture ready")
                    samples = self.validator.pcm(frame)
                    if not self.stopping:
                        await self.hub.push(samples)
                elif kind == "stopped":
                    if not self.stopping:
                        raise LiveFailure("capture host stopped without controller stop")
                    self.validator.correlated(h, self.stop_id)
                    if (type(h.get("cleanupComplete")) is not bool or h.get("drainComplete") is not False
                            or type(h.get("discardedConverterTail")) is not bool):
                        raise LiveFailure("capture stop lacks cleanup evidence")
                    self.stopped_reply.set_result(h)
                    return
                else:
                    self.validator.correlated(h)
                    self.error_header = h
                    raise LiveFailure("capture host reported failure: " + str(h.get("code", "unknown"))[:128])
        except BaseException as exc:
            self.last_error = type(exc).__name__
            if not self.ready.done():
                self.ready.set_exception(exc)
            if not self.stopped_reply.done():
                self.stopped_reply.set_exception(exc)
            if not self.stopping:
                await self.hub.fail(exc)
            # Futures carry the failure to start/stop; never leak task exceptions.

    async def stop(self):
        if self.stopping:
            return self.cleanup_complete
        self.stopping = True
        if not self.process:
            self.cleanup_complete = True
            return True
        try:
            # A terminal capture error may already carry confirmed HAL teardown.
            # It remains an operation failure; this only distinguishes resource
            # cleanup from killing an unknown live host after EOF/timeouts.
            if self.error_header and self.error_header.get("cleanupComplete") is True:
                code = await asyncio.wait_for(self.process.wait(), 2)
                self.cleanup_complete = code == 3
                return self.cleanup_complete
            await self._command("stop", self.stop_id)
            reply = await asyncio.wait_for(asyncio.shield(self.stopped_reply), 5)
            self.process.stdin.close()
            code = await asyncio.wait_for(self.process.wait(), 2)
            self.cleanup_complete = reply.get("cleanupComplete") is True and code == 0
        except (Exception, asyncio.CancelledError):
            # Escalation is bounded and explicitly NOT a clean HAL confirmation.
            self.cleanup_complete = False
            if self.process.returncode is None:
                try:
                    self.process.terminate()
                    await asyncio.wait_for(self.process.wait(), 2)
                except (ProcessLookupError, asyncio.TimeoutError):
                    if self.process.returncode is None:
                        try:
                            self.process.kill()
                        except ProcessLookupError:
                            pass
                        try:
                            await asyncio.wait_for(self.process.wait(), 2)
                        except asyncio.TimeoutError:
                            pass
        finally:
            for task in (self.pump_task, self.stderr_task):
                if task and not task.done():
                    task.cancel()
            await asyncio.gather(*(task for task in (self.pump_task, self.stderr_task) if task), return_exceptions=True)
            for future in (self.ready, self.stopped_reply):
                if future and future.done() and not future.cancelled():
                    future.exception()  # Retrieve failures even before start completed.
        return self.cleanup_complete

    def report(self):
        return {"capture_cleanup_complete": self.cleanup_complete,
                "capture_host_exited": self.process is None or self.process.returncode is not None,
                "input_closed": self.process is None or self.process.returncode is not None,
                "capture_frames": self.validator.frames, "capture_blocks": self.validator.sequence,
                "capture_first_source": self.validator.first_source,
                "capture_last_source": self.validator.last_source,
                "capture_last_error": self.last_error,
                "capture_error_code": (self.error_header or {}).get("code"),
                "capture_error_message": str((self.error_header or {}).get("message", ""))[:1024],
                "capture_error_cleanup_reported": (self.error_header or {}).get("cleanupComplete"),
                "capture_exclusion_policy": (self.ready_header or {}).get("exclusionPolicy"),
                "converter_delay_known": False, "capture_permission": "not_inferred",
                "drain_complete": False, "acoustic_sync_verified": False}
