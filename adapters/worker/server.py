"""Async single-session dispatcher with conservative cleanup/reuse semantics."""
from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
import time

from .protocol import COMMANDS, IdHistory, ProtocolError, parse_request, related_session
from .runner import RunReport, inspect_wav, native_runner, scan_receivers, validate_start


@dataclass
class Session:
    request_id: str
    session_id: str
    params: dict
    report: RunReport = field(default_factory=RunReport)
    task: asyncio.Task | None = None
    stop_requested: bool = False
    finalizing: bool = False


class WorkerServer:
    def __init__(self, emit, runner=native_runner, scanner=scan_receivers,
                 inspector=inspect_wav, stop_timeout=10.0, id_limit=4096, preflight=validate_start):
        self.emit_callback = emit
        self.runner, self.scanner, self.inspector = runner, scanner, inspector
        self.preflight = preflight
        self.stop_timeout = stop_timeout
        self.ids = IdHistory(id_limit)
        self.active = None
        self.last_session = None
        self.sessions = set()
        self.cleaned_sessions = set()
        self.poisoned = self.shutting_down = False

    def emit(self, request_id, event, session=None, payload=None):
        self.emit_callback({"v": 1, "id": request_id, "event": event,
                            "session": session, "payload": payload if payload is not None else {}})

    def error(self, request_id, code, message, session=None, **extra):
        self.emit(request_id, "error", session, {"code": code, "message": message, **extra})

    @staticmethod
    def clean(report):
        return (report.get("cleanup_complete") is True and report.get("input_closed") is True
                and report.get("hub_stopped") is True and not report.get("pending_cleanup_tasks"))

    async def handle_line(self, line):
        try:
            request = parse_request(line)
        except ProtocolError as exc:
            if exc.request_id and exc.request_id in self.ids.values:
                self.error(None, "duplicate_id", "request ID has already been used", offending_id=exc.request_id)
            else:
                self.error(exc.request_id, exc.code, str(exc), exc.session)
            return
        request_id, command, params = request["id"], request["command"], request["params"]
        correlation = related_session(command, params)
        added = self.ids.add(request_id, self.active.request_id if self.active else None)
        if added is False:
            self.error(None, "duplicate_id", "request ID has already been used", offending_id=request_id)
            return
        if added is None and command not in ("stop", "shutdown"):
            self.error(request_id, "resource_limit", "worker ID capacity reached; restart worker", correlation)
            return
        if self.shutting_down:
            self.error(request_id, "busy", "worker is shutting down", correlation)
            return
        if self.poisoned and command not in ("hello", "stop", "shutdown"):
            self.error(request_id, "worker_poisoned", "cleanup is uncertain; restart the worker", correlation)
            return
        try:
            if command == "hello":
                self.emit(request_id, "result", payload={
                    "protocol_version": 1, "commands": list(COMMANDS), "core_abi_version": 1,
                    "capabilities": {"offline": True, "airplay": True, "capture": False,
                                     "stereo_pair": False, "realtime_volume": False, "av_offset": False},
                    "worker_poisoned": self.poisoned})
            elif command in ("scan", "inspect"):
                if self.active:
                    self.error(request_id, "busy", "a playback session is active")
                    return
                payload = await self.scanner(params) if command == "scan" else await self.inspector(params["wav"])
                if command == "scan":
                    payload["devices"] = payload.get("devices", [])[:64]
                self.emit(request_id, "result", payload=payload)
            elif command == "start":
                if self.active:
                    self.error(request_id, "busy", "a playback session is active", params["session"])
                    return
                if params["session"].lower() in self.sessions:
                    self.error(request_id, "stale_session", "session UUID must not be reused", params["session"])
                    return
                if len(self.sessions) >= self.ids.limit:
                    self.error(request_id, "resource_limit", "worker session capacity reached; restart worker", correlation)
                    return
                try:
                    await self.preflight(params)
                except Exception:
                    self.error(request_id, "invalid_params", "local WAV, library or channel mapping failed validation", params["session"])
                    return
                self.sessions.add(params["session"].lower())
                session = Session(request_id, params["session"], params)
                self.active = session
                self.emit(request_id, "accepted", session.session_id, {"execution": params["execution"]})
                session.task = asyncio.create_task(self._run_session(session))
                # Enter the session's try/finally before a queued stop/EOF can
                # cancel it, otherwise a never-started Task cannot certify cleanup.
                await asyncio.sleep(0)
            elif command == "stop":
                await self._stop_request(request_id, params["session"])
            elif command == "shutdown":
                self.shutting_down = True
                if self.active:
                    await self._stop_active()
                if self.poisoned:
                    self.error(request_id, "cleanup_failed", "worker will exit; cleanup was not confirmed")
                else:
                    self.emit(request_id, "result", payload={"state": "shutdown", "cleanup_complete": True})
        except asyncio.CancelledError:
            raise
        except BaseException as exc:
            # Never echo raw params, exception strings, credentials or library logs.
            self.error(request_id, "operation_failed", f"operation failed ({type(exc).__name__})", correlation)

    async def _monitor(self, session):
        while True:
            report = session.report
            if (session.params["execution"] == "airplay"
                    and type(report.get("shared_start_ts")) is int
                    and type(report.get("send_origin_ns")) is int
                    and time.monotonic_ns() >= report["send_origin_ns"]):
                self.emit(session.request_id, "state", session.session_id,
                          {"state": "streaming", "execution": "airplay", "acoustic_sync_verified": False})
                return
            await asyncio.sleep(.02)

    async def _run_session(self, session):
        self.emit(session.request_id, "state", session.session_id,
                  {"state": "preparing", "execution": session.params["execution"]})
        monitor = asyncio.create_task(self._monitor(session))
        state = "failed"
        failure = None
        try:
            await self.runner(session.params, session.report)
            state = "stopped" if session.stop_requested else "completed"
        except asyncio.CancelledError:
            state = "stopped"
        except BaseException as exc:
            failure = type(exc).__name__
        finally:
            session.finalizing = True
            monitor.cancel()
            await asyncio.gather(monitor, return_exceptions=True)
            clean = self.clean(session.report)
            if not clean:
                self.poisoned = True
                state = "failed"
            self.emit(session.request_id, "state", session.session_id, {"state": state})
            if state == "failed":
                self.error(session.request_id, "cleanup_failed" if not clean else "operation_failed",
                           "session cleanup was not confirmed" if not clean else f"session failed ({failure or 'unknown error'})",
                           session.session_id, cleanup_complete=clean)
            else:
                self.emit(session.request_id, "result", session.session_id,
                          {"state": state, "report": dict(session.report), "cleanup_complete": True})
            self.last_session = (session.session_id, clean)
            if clean:
                self.cleaned_sessions.add(session.session_id.lower())
            if self.active is session:
                self.active = None

    async def _stop_active(self):
        session = self.active
        if not session:
            return True
        session.stop_requested = True
        if session.task and not session.task.done():
            if not session.finalizing:
                session.task.cancel()
            done, _pending = await asyncio.wait({session.task}, timeout=self.stop_timeout)
            if not done:
                self.poisoned = True
                return False
        return not self.poisoned and self.clean(session.report)

    async def _stop_request(self, request_id, session_id):
        if self.active:
            if self.active.session_id.lower() != session_id.lower():
                self.error(request_id, "stale_session", "stop does not match the active session", session_id)
                return
            clean = await self._stop_active()
            if clean:
                self.emit(request_id, "result", session_id,
                          {"state": "stopped", "already_stopped": False, "cleanup_complete": True})
            else:
                self.error(request_id, "cleanup_failed", "stop could not confirm cleanup", session_id)
        elif session_id.lower() in self.cleaned_sessions:
            self.emit(request_id, "result", session_id,
                      {"state": "stopped", "already_stopped": True, "cleanup_complete": True})
        else:
            self.error(request_id, "stale_session", "no matching active or cleaned session", session_id)

    async def eof(self):
        self.shutting_down = True
        if self.active:
            await self._stop_active()
        return 2 if self.poisoned else 0
