"""Managed system-audio worker. Import/default startup never captures or plays.

Only explicit start invokes adapters.live.session; no WAV/file playback API.
The shared request lifecycle reuses the separately tested worker control base,
not its finite audio runner or file command validation.
"""
from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import math
import os
from pathlib import Path
import sys
import threading
import time

from adapters.worker.__main__ import InputPump
from adapters.worker.protocol import (MAX_LINE_BYTES, IdHistory, ProtocolError,
    absolute_path, identifier, keys, number, session_id)
from adapters.worker.server import Session, WorkerServer
from adapters.live.volume import LiveVolumeControl, VolumeNotReady
from adapters.live.latency_control import validate_latency_report

COMMANDS = ("hello", "scan", "start", "stop", "shutdown", "set_volume", "analyze_probe", "calibration_latency", "calibration_snapshot")


async def scan_receivers(params):
    """Keep device identity separate from its mutable address and display name."""
    from adapters.airplay_pyatv.session import scan
    expected = set(params.get("expected_identifiers", []))
    devices = []
    attempts = 4 if expected else 1
    for attempt in range(attempts):
        if attempt:
            await asyncio.sleep(.4 * attempt)
        try:
            fresh = await scan(params.get("hosts") if attempt == 0 else None,
                               params.get("timeout_seconds", 4 if expected else 8))
        except (OSError, asyncio.TimeoutError):
            if not expected or attempt == attempts - 1:
                raise
            continue
        identities = {device.identifier for device in fresh if device.identifier}
        devices = fresh + [device for device in devices if device.identifier not in identities]
        if not expected or expected.issubset({device.identifier for device in devices}):
            break
    result = []
    for device in devices[:64]:
        item = {"name": str(device.name)[:128], "address": str(device.address)[:128],
                "model": str(device.device_info.model)[:128]}
        if device.identifier:
            item["identifier"] = str(device.identifier)
        result.append(item)
    return {"devices": result}


def parse_system_request(line):
    def unique(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError("duplicate key")
            result[key] = value
        return result

    def finite(value):
        parsed = float(value)
        if not math.isfinite(parsed):
            raise ValueError("nonfinite number")
        return parsed

    request_id = correlation = None
    try:
        if not isinstance(line, bytes) or not 0 < len(line) <= MAX_LINE_BYTES or not line.endswith(b"\n"):
            raise ValueError("invalid line")
        obj = json.loads(line.decode("utf-8"), object_pairs_hook=unique,
                         parse_float=finite, parse_constant=lambda _: (_ for _ in ()).throw(ValueError()))
        if not isinstance(obj, dict):
            raise ValueError("not object")
        request_id = obj.get("id") if identifier(obj.get("id")) else None
        if isinstance(obj.get("params"), dict):
            try:
                correlation = session_id(obj["params"].get("session"))
            except ProtocolError:
                pass
        if set(obj) != {"v", "id", "command", "params"} or request_id is None:
            raise ProtocolError("invalid_request", "invalid request envelope")
        if type(obj["v"]) is not int or obj["v"] != 1:
            raise ProtocolError("unsupported_version", "system worker requires protocol v1")
        command, params = obj["command"], obj["params"]
        if command not in COMMANDS:
            raise ProtocolError("unknown_command", "unsupported system-audio command")
        if command in ("hello", "shutdown"):
            keys(params)
        elif command == "scan":
            keys(params, optional=("hosts", "timeout_seconds", "expected_identifiers"))
            hosts = params.get("hosts", [])
            if (not isinstance(hosts, list) or len(hosts) > 8
                    or any(not isinstance(h, str) or not 0 < len(h) <= 255 for h in hosts)
                    or len(set(hosts)) != len(hosts)):
                raise ProtocolError("invalid_params", "scan requires up to eight unique addresses")
            number(params.get("timeout_seconds", 8), 1, 15, "timeout_seconds")
            expected = params.get("expected_identifiers", [])
            if (not isinstance(expected, list) or len(expected) > 8
                    or any(not isinstance(item, str) or not 0 < len(item) <= 128 for item in expected)
                    or len(set(expected)) != len(expected)):
                raise ProtocolError("invalid_params", "scan requires unique expected device identities")
        elif command == "calibration_snapshot":
            keys(params, ('helper',))
            absolute_path(params['helper'], 'helper')
        elif command == "calibration_latency":
            keys(params, ('helper', 'target_ms'))
            absolute_path(params['helper'], 'helper')
            if type(params['target_ms']) is not int:
                raise ProtocolError('invalid_params', 'whole milliseconds required')
            number(params['target_ms'], 0, 3000, 'target_ms')
        elif command == "analyze_probe":
            keys(params, ("recording", "sample_rate", "first_sample_ns", "presentation_ns", "nominal_ms"), ("injection_ns", "code", "expected_latency_ms", "clock", "signal_version", "diagnostics_path",
                         "probe_kind", "probe_rate"))
            if type(params.get('signal_version', 1)) is not int or params.get('signal_version', 1) not in (1, 3, 4):
                raise ProtocolError('invalid_params', 'unsupported probe signal version')
            absolute_path(params["recording"], "recording")
            number(params["sample_rate"], 44100, 96000, "sample_rate")
            for name in ("first_sample_ns", "presentation_ns"):
                number(params[name], 1, 2**63 - 1, name)
            number(params["nominal_ms"], 0, 3000, "nominal_ms")
            if 'clock' in params:
                absolute_path(params['clock'], 'clock')
            if 'diagnostics_path' in params:
                absolute_path(params['diagnostics_path'], 'diagnostics_path')
            if 'probe_rate' in params and params['probe_rate'] not in (44100, 48000, 96000):
                raise ProtocolError('invalid_params', 'unsupported probe sample rate')
            if 'probe_kind' in params and params['probe_kind'] not in ('sweep', 'linear', 'pink', 'white'):
                raise ProtocolError('invalid_params', 'unsupported probe kind')
            if "injection_ns" in params:
                number(params['injection_ns'], 1, 2**63 - 1, 'injection_ns')
            if "code" in params and (type(params['code']) is not int or not 0 <= params['code'] <= 7):
                raise ProtocolError('invalid_params', 'invalid probe code')
            if 'expected_latency_ms' in params:
                number(params['expected_latency_ms'], 0, 3000, 'expected_latency_ms')
        elif command == "stop":
            keys(params, ("session",))
            session_id(params["session"])
        elif command == "set_volume":
            keys(params, ("session", "volume"))
            session_id(params["session"])
            number(params["volume"], 0, 100, "volume")
        else:
            keys(params, ("session", "library", "capture_host", "routes"), ("volume", "exclude_pids", "mode", "input", "probe", "calibration"))
            session_id(params["session"])
            absolute_path(params["library"], "library")
            absolute_path(params["capture_host"], "capture_host")
            number(params.get("volume", 15), 0, 100, "volume")
            if params.get("mode", "synchronized") not in ("cinema", "synchronized"):
                raise ProtocolError("invalid_params", "unsupported playback mode")
            exclusions = params.get("exclude_pids", [])
            if (not isinstance(exclusions, list) or len(exclusions) > 64
                    or any(type(pid) is not int or not 0 < pid < (1 << 31) for pid in exclusions)):
                raise ProtocolError("invalid_params", "invalid excluded PIDs")
            routes = params["routes"]
            if not isinstance(routes, list) or not 1 <= len(routes) <= 8:
                raise ProtocolError("invalid_params", "select one to eight independent outputs")
            ids, addresses = set(), set()
            for route in routes:
                keys(route, ("output_id", "channels", "host"), ("role",) if "input" in params else ())
                output, host = route["output_id"], route["host"]
                if (type(output) is not int or not 0 <= output < 1 << 32 or output in ids
                        or not isinstance(host, str) or not 0 < len(host) <= 255 or host in addresses
                        or route["channels"] != [0, 1]
                        or any(type(ch) is not int for ch in route["channels"])):
                    raise ProtocolError("invalid_params", "system stereo requires unique outputs and [0,1] routes")
                ids.add(output); addresses.add(host)
            if "probe" in params and (params["probe"] is not True or "input" not in params
                                      or params.get("volume") not in tuple(range(1, 101))
                                      or ids != set(range(len(routes)))):
                raise ProtocolError("invalid_params", "probe requires virtual input, sequential output IDs and volume 1..100")
            if "calibration" in params:
                calibration = params["calibration"]
                if (not isinstance(calibration, dict) or set(calibration) != {str(r['output_id']) for r in routes}
                        or 'input' not in params):
                    raise ProtocolError("invalid_params", "calibration must cover every cinema output")
                for residual in calibration.values():
                    number(residual, -250, 750, "residual_ms")
            if "input" in params:
                config = params['input']
                keys(config, ('backend', 'device_uid', 'layout'),
                     ('latency_report', 'latency_control'))
                from adapters.live.pcm_v2 import CANONICAL_DEVICE_UID
                if (config['backend'] != 'virtual_device_v2'
                        or not isinstance(config['layout'], str)
                        or CANONICAL_DEVICE_UID.get(config['layout']) != config['device_uid']):
                    raise ProtocolError('invalid_params', 'unsupported virtual input descriptor')
                if 'latency_control' in config:
                    absolute_path(config['latency_control'], 'latency_control')
                if 'latency_report' in config:
                    try:
                        normalized = validate_latency_report(config['latency_report'])
                    except (ValueError, TypeError):
                        raise ProtocolError('invalid_params', 'invalid verified Core Audio latency report')
                    params['input'] = dict(config)
                    params['input']['latency_report'] = normalized
                try:
                    from adapters.live.routing_v2 import VirtualRoutePlan
                    VirtualRoutePlan(config['layout'], [r['output_id'] for r in routes],
                                     params.get('mode', 'synchronized'),
                                     {r['output_id']: r['role'] for r in routes if 'role' in r})
                except (ValueError, TypeError):
                    raise ProtocolError('invalid_params', 'invalid virtual endpoint routing')
        return obj
    except ProtocolError as error:
        error.request_id, error.session = request_id, correlation
        raise
    except (ValueError, TypeError, UnicodeError, RecursionError, OverflowError):
        raise ProtocolError("invalid_request", "invalid UTF-8 JSONL request", request_id, correlation)


async def system_runner(params, report):
    entered = False
    try:
        from adapters.live.session import play_system_audio
        report["session"] = params["session"]
        entered = True
        await play_system_audio(params["library"], params["capture_host"],
            {r["output_id"]: r["channels"] for r in params["routes"]},
            {r["output_id"]: r["host"] for r in params["routes"]},
            volume=params.get("volume", 15), exclude_pids=tuple(params.get("exclude_pids", ())), report=report,
            volume_control=params.get("_volume_control"), input_config=params.get('input'),
            mode=params.get('mode', 'synchronized'),
            endpoint_roles={r['output_id']: r['role'] for r in params['routes'] if 'role' in r},
            probe=params.get('probe', False),
            calibration={int(k): v for k, v in params.get('calibration', {}).items()} or None)
        raise RuntimeError("live session returned without an explicit stop")
    finally:
        if not entered:
            report.update(input_closed=True, hub_stopped=True, cleanup_complete=True)


class SystemWorkerServer(WorkerServer):
    def __init__(self, emit, runner=system_runner, scanner=scan_receivers, stop_timeout=12):
        super().__init__(emit, runner=runner, scanner=scanner, stop_timeout=stop_timeout)

    async def handle_line(self, line):
        try:
            request = parse_system_request(line)
        except ProtocolError as error:
            if error.request_id and error.request_id in self.ids.values:
                self.error(None, "duplicate_id", "request ID has already been used", offending_id=error.request_id)
            else:
                self.error(error.request_id, error.code, str(error), error.session)
            return
        rid, command, params = request["id"], request["command"], request["params"]
        correlation = params.get("session") if command in ("start", "stop", "set_volume") else None
        seen = self.ids.add(rid, self.active.request_id if self.active else None)
        if seen is False:
            self.error(None, "duplicate_id", "request ID has already been used", offending_id=rid); return
        if seen is None and command not in ("stop", "shutdown"):
            self.error(rid, "resource_limit", "restart system worker", correlation); return
        if self.shutting_down or (self.active and command in ("scan", "start", "analyze_probe", "calibration_latency", "calibration_snapshot")):
            self.error(rid, "busy", "a system-audio session is active or shutting down", correlation); return
        if self.poisoned and command not in ("hello", "stop", "shutdown"):
            self.error(rid, "worker_poisoned", "cleanup unconfirmed; restart worker", correlation); return
        try:
            if command == "hello":
                self.emit(rid, "result", payload={"protocol_version": 1, "core_abi_version": 1,
                    "commands": list(COMMANDS), "worker_pid": os.getpid(),
                    "capabilities": {"system_audio": True, "live": True, "capture": True,
                                     "stereo_pair": False, "realtime_volume": True, "av_offset": False,
                                     "virtual_device_v2": True, "acoustic_calibration_v1": True, "acoustic_calibration_v2": True, "acoustic_calibration_v3": True, "acoustic_calibration_v4": True},
                    "worker_poisoned": self.poisoned})
            elif command == "scan":
                payload = await self.scanner(params)
                payload["devices"] = payload.get("devices", [])[:64]
                self.emit(rid, "result", payload=payload)
            elif command == "calibration_snapshot":
                from adapters.live.latency_apply import _status
                snapshot = await _status(params['helper'])
                if snapshot.pending_status == 'pending':
                    self.error(rid, 'latency_pending', 'Flow 声卡配置尚未完成。请重新启动 Mac 后再测试。'); return
                self.emit(rid, 'result', payload={'target_ms': round(snapshot.ms), 'revision': snapshot.revision})
            elif command == "calibration_latency":
                from adapters.live.latency_apply import apply_planned_latency
                result = await apply_planned_latency(params['helper'], 0, 44100, target_ms=params['target_ms'])
                if result.status not in ('applied', 'unchanged'):
                    self.error(rid, 'latency_pending', '声卡延迟写入尚未完成，请稍后重试'); return
                self.emit(rid, 'result', payload=result.report())
            elif command == "analyze_probe":
                from adapters.calibration.acoustic import analyze_recording
                try:
                    result = await asyncio.to_thread(analyze_recording, params['recording'],
                        params['sample_rate'], params['first_sample_ns'], params['presentation_ns'], params['nominal_ms'],
                        params.get('injection_ns'), params.get('code'), params.get('expected_latency_ms'), params.get('clock'),
                        params.get('signal_version', 1), params.get('diagnostics_path'),
                        params.get('probe_kind', 'sweep'), params.get('probe_rate'))
                except (ValueError, OSError) as error:
                    self.error(rid, 'measurement_failed', str(error)); return
                self.emit(rid, 'result', payload=result)
            elif command == "start":
                sid = params["session"]
                if sid.lower() in self.sessions:
                    self.error(rid, "stale_session", "session UUID cannot be reused", sid); return
                if (not Path(params["library"]).is_file() or not Path(params["capture_host"]).is_file()
                        or not os.access(params["capture_host"], os.X_OK)):
                    self.error(rid, "invalid_params", "native library or capture host is unavailable", sid); return
                helper = params.get("input", {}).get("latency_control")
                if (helper is not None and (not Path(helper).is_file()
                                            or not os.access(helper, os.X_OK))):
                    self.error(rid, "invalid_params", "latency helper is unavailable", sid); return
                self.sessions.add(sid.lower())
                runtime_params = dict(params)
                runtime_params["_volume_control"] = LiveVolumeControl()
                state = Session(rid, sid, runtime_params)
                self.active = state
                if 'input' in params:
                    from adapters.live.routing_v2 import VirtualRoutePlan
                    state.report.update(VirtualRoutePlan(params['input']['layout'],
                        [r['output_id'] for r in params['routes']], params.get('mode', 'synchronized'),
                        {r['output_id']: r['role'] for r in params['routes'] if 'role' in r}).report())
                self.emit(rid, "accepted", sid, {"execution": "system_audio", "actual_mode": state.report.get('actual_mode', 'same_stereo')})
                state.task = asyncio.create_task(self._run_session(state))
                await asyncio.sleep(0)
            elif command == "set_volume":
                state = self.active
                if (not state or state.session_id.lower() != params["session"].lower()
                        or state.stop_requested or state.finalizing):
                    self.error(rid, "stale_session", "volume requires the active session", correlation); return
                if state.params.get('probe') and not 1 <= params['volume'] <= 100:
                    self.error(rid, 'invalid_params', '测试音量限定为 1% 至 100%', correlation); return
                try:
                    applied = await state.params["_volume_control"].set_volume(params["volume"])
                except VolumeNotReady:
                    self.error(rid, "not_ready", "volume group is not streaming", correlation); return
                except Exception:
                    clean = await self._stop_active()
                    self.error(rid, "volume_failed", "volume update failed; group stopped", correlation,
                               cleanup_complete=clean); return
                state.report["volume_percent"] = params["volume"]
                state.report["volume_updates"] = state.report.get("volume_updates", 0) + 1
                self.emit(rid, "result", correlation, {"state": "volume_applied",
                    "volume_percent": params["volume"], "applied_outputs": applied})
            elif command == "stop":
                await self._stop_request(rid, params["session"])
            else:
                self.shutting_down = True
                if self.active:
                    await self._stop_active()
                if self.poisoned:
                    self.error(rid, "cleanup_failed", "system cleanup was not confirmed", cleanup_complete=False)
                else:
                    self.emit(rid, "result", payload={"state": "shutdown", "cleanup_complete": True})
        except asyncio.CancelledError:
            raise
        except BaseException as error:
            self.error(rid, "operation_failed", f"system operation failed ({type(error).__name__})", correlation)

    async def _monitor(self, session):
        previous = None
        while True:
            report = session.report
            phase = report.get("status")
            if (type(report.get("send_origin_ns")) is int and report.get("shared_start_ts") is not None
                    and time.monotonic_ns() >= report["send_origin_ns"]):
                phase = "streaming"
            elif phase in ("capturing", "capture_starting"):
                phase = "capturing"
            else:
                phase = "preparing"
            latency_state = report.get("latency_state")
            signature = (phase, json.dumps(latency_state, sort_keys=True)
                         if isinstance(latency_state, dict) else None)
            if signature != previous:
                payload = {"state": phase, "execution": "system_audio",
                    "actual_mode": report.get('actual_mode', 'same_stereo'),
                    "acoustic_sync_verified": False}
                if isinstance(latency_state, dict):
                    payload["latency_state"] = latency_state
                if report.get("probe_version") in (1, 2):
                    payload["probe"] = {key: report.get(key) for key in
                        ("playback_origin_ns", "nominal_probe_ms", "first_receipt_ns")}
                if phase in ("capturing", "streaming"):
                    scheduling = report.get("scheduling")
                    if isinstance(scheduling, dict):
                        payload["latency_plan"] = {
                            "preparation_ms": scheduling.get("preparation_ms"),
                            "negotiated_latency_ms": scheduling.get("negotiated_latency_ms"),
                            "planned_presentation_ms": scheduling.get("planned_presentation_ms"),
                            "report_verified": scheduling.get("report_verified", False),
                        }
                        comparison = scheduling.get("programmed_vs_reported_ms")
                        if isinstance(comparison, dict):
                            payload["programmed_vs_reported_ms"] = comparison
                self.emit(session.request_id, "state", session.session_id,
                    payload)
                previous = signature
            await asyncio.sleep(.05)

    def write_session_diagnostic(self, session, failure, clean, trace):
        """Persist the worker-side failure with the full session report."""
        try:
            import json
            from datetime import datetime
            from pathlib import Path
            directory = Path.home() / "Library/Application Support/HomePod Flow/Diagnostics"
            directory.mkdir(parents=True, exist_ok=True)
            record = {
                "at": datetime.now().isoformat(timespec="seconds"),
                "failure": failure,
                "clean": clean,
                "session": session.session_id,
                "traceback": trace,
                "report": dict(session.report),
            }
            with (directory / "worker-session.log").open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
        except Exception:
            pass

    async def _run_session(self, session):
        monitor = asyncio.create_task(self._monitor(session))
        failure = None
        trace = None
        stopped = False
        try:
            await self.runner(session.params, session.report)
            failure = "unexpected live EOF"
        except asyncio.CancelledError:
            stopped = session.stop_requested
            if not stopped:
                failure = "unexpected session cancellation"
            import traceback
            trace = traceback.format_exc()
        except BaseException as error:
            failure = type(error).__name__
            import traceback
            trace = traceback.format_exc()
        finally:
            session.finalizing = True
            monitor.cancel(); await asyncio.gather(monitor, return_exceptions=True)
            clean = self.clean(session.report)
            if not clean:
                self.poisoned = True
            state = "stopped" if stopped and clean else "failed"
            self.emit(session.request_id, "state", session.session_id, {"state": state})
            if state == "stopped":
                self.emit(session.request_id, "result", session.session_id,
                    {"state": "stopped", "cleanup_complete": True, "report": dict(session.report)})
            else:
                preparation = session.report.get("preparation_failure", {})
                latency = session.report.get("latency_state", {})
                if preparation and latency.get("status") in ("failure", "pending"):
                    message = "声卡延迟更新未完成：" + str(latency.get("detail") or latency.get("pending_reason") or preparation.get("detail", ""))[:256]
                else:
                    message = f"system session failed ({failure or 'cleanup unconfirmed'})"
                self.error(session.request_id, "operation_failed" if clean else "cleanup_failed",
                    message, session.session_id, cleanup_complete=clean, report=dict(session.report))
            self.write_session_diagnostic(session, failure, clean, trace)
            self.last_session = (session.session_id, clean)
            if clean:
                self.cleaned_sessions.add(session.session_id.lower())
            if self.active is session:
                self.active = None


async def serve(stdin, stdout):
    def emit(event):
        data = (json.dumps(event, ensure_ascii=False, allow_nan=False, separators=(",", ":")) + "\n").encode()
        if len(data) > MAX_LINE_BYTES:
            data = (json.dumps({"v": 1, "id": event["id"], "event": "error", "session": event["session"],
                "payload": {"code": "resource_limit", "message": "system report exceeds 64 KiB"}}) + "\n").encode()
        stdout.write(data); stdout.flush()
    queue = asyncio.Queue(maxsize=16)
    pump = InputPump(stdin, asyncio.get_running_loop(), queue)
    threading.Thread(target=pump.run, daemon=True, name="flow-system-stdin").start()
    server = SystemWorkerServer(emit)
    try:
        while not server.shutting_down:
            line = await queue.get()
            if line is None:
                break
            await server.handle_line(line)
        return await server.eof()
    finally:
        pump.closed.set()


def main():
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    logging.basicConfig(stream=sys.stderr, level=logging.WARNING)
    loop = asyncio.new_event_loop(); asyncio.set_event_loop(loop)
    code = 2
    with contextlib.redirect_stdout(sys.stderr):
        try:
            code = loop.run_until_complete(serve(stdin, stdout))
        except BaseException as error:
            print(f"system worker stopped ({type(error).__name__})", file=sys.stderr)
    stdout.flush(); sys.stderr.flush()
    # Dedicated disposable worker: the daemon stdin reader must not hold up
    # interpreter finalization; all owned-session cleanup happened in serve/eof.
    os._exit(code)


if __name__ == "__main__":
    main()
