"""Explicit system-audio playback session, without finite-file assumptions."""
from __future__ import annotations

import asyncio
import math
import time
import uuid

from adapters.airplay_pyatv.session import SessionPatches, check_versions, cleanup_session, scan
from adapters.airplay_pyatv.source import CoreAudioSource
from adapters.airplay_pyatv.timing import build_timing_plan, ntp_from_unix_ns
from .capture import CaptureHost
from .hub import LiveFailure, LiveHub
from .latency_control import PREPARATION_MS, playback_lead_ns, plan_telemetry


class LiveSource(CoreAudioSource):
    def __init__(self, hub, output_id):
        # 0 means unknown metadata duration, NOT a fabricated total frame count.
        super().__init__(output_id, 44100, 0)
        self.hub = hub

    @property
    def duration(self):
        return 0

    async def get_metadata(self):
        from pyatv.interface import MediaMetadata
        return MediaMetadata(title="HomePod Flow", duration=0)

    async def readframes(self, nframes):
        if self.closed:
            raise LiveFailure("live source is closed")
        data = await self.hub.read(self.output_id, nframes)
        self.frames_read += len(data) // 4
        return data

    async def close(self):
        self.closed = True


class LivePatches(SessionPatches):
    def __init__(self, hub, capture, report, volume_control=None, latency_report=None):
        self.hub, self.capture, self.report = hub, capture, report
        self.latency_report = latency_report
        self.library = None
        self.sample_rate, self.channels = 44100, 2
        self.routes = hub.routes
        self.sources = {key: LiveSource(hub, key) for key in hub.routes}
        self.clients = []
        self.ready = asyncio.Event()
        self.failure = self.plan = self.rendered = None
        self._originals = []
        self._installed = False
        self.cleanup_confirmed = True
        self.volume_control = volume_control

    def __exit__(self, *args):
        if self.cleanup_confirmed:
            return super().__exit__(*args)
        # A dedicated poisoned worker must exit before another session. Never
        # restore protocol functions under a still-running old sender task.
        self.report["patch_restore_skipped"] = True

    def _install(self):
        from pyatv.protocols.raop.stream_client import ControlClient, StreamClient
        from pyatv.protocols.raop.protocols.airplayv2 import AirPlayV2
        from pyatv.protocols.airplay.utils import pct_to_dbfs
        original_stream, original_start = StreamClient._stream_data, ControlClient.start
        # Reuse pinned ALAC negotiation/source/sync hooks, then replace the
        # finite-frame postcondition with an actual live-session lifecycle.
        super()._install()
        session = self

        async def stream(client, source, transport):
            if source not in session.sources.values() or not isinstance(client._protocol, AirPlayV2):
                raise LiveFailure("only this live group's AirPlay2 sources are supported")
            await client.set_volume(pct_to_dbfs(session.report.get("volume_percent", 15)))
            await session.arrive(client, source)
            control = client.control_client
            original_start(control, control._flow_sync_address)
            if session.volume_control:
                session.volume_control.ready = True
            session.report["status"] = "streaming"
            session.report.setdefault("stream_releases", []).append({
                "output_id": source.output_id, "monotonic_ns": time.monotonic_ns(),
                "start_ts": client.context.start_ts, "first_rtp": client.context.rtptime})
            try:
                await original_stream(client, source, transport)
                # An unknown-length capture never naturally completes.
                raise LiveFailure("live transport ended without controller stop")
            finally:
                control.stop()

        self._replace(StreamClient, "_stream_data", stream)

    async def arrive(self, client, source):
        if any(existing is source for _, existing in self.clients):
            raise LiveFailure("duplicate live receiver at barrier")
        self.clients.append((client, source))
        if len(self.clients) == len(self.sources):
            try:
                formats = {(c.context.sample_rate, c.context.channels,
                            c.context.bytes_per_channel, c.context.latency) for c, _ in self.clients}
                if len(formats) != 1:
                    raise LiveFailure("live receivers negotiated different latency or formats")
                rate, channels, width, latency = next(iter(formats))
                if (rate, channels, width) != (44100, 2, 2) or type(latency) is not int or latency < 0:
                    raise LiveFailure("unsupported live receiver format")
                self.report["status"] = "capturing"
                await self.capture.start()
                origin = self.hub.start(playback_lead_ns(latency, rate))
                before = time.monotonic_ns()
                ntp = ntp_from_unix_ns(time.time_ns())
                after = time.monotonic_ns()
                self.plan = build_timing_plan(origin, (before + after) // 2, ntp, rate, latency)
                for receiver, _ in self.clients:
                    receiver.context.start_ts = self.plan.start_ts
                    receiver.context.head_ts = self.plan.start_ts
                self.plan.assert_ready(time.monotonic_ns())
                self.report.update({"shared_start_ts": self.plan.start_ts,
                    "send_origin_ns": self.plan.send_origin_ns, "playback_origin_ns": origin,
                    "protocol_latency_samples": latency, "protocol_sample_rate": rate,
                    "preparation_ms": PREPARATION_MS,
                    "prepared_receivers": len(self.clients), "anchor_uncertainty_ns": after - before,
                    "capture_to_receipt_uncertainty_ns": None,
                    "converter_delay_known": False, "acoustic_sync_verified": False,
                    "scheduling": plan_telemetry(latency, rate, self.latency_report)})
            except BaseException as exc:
                self.failure = exc
            finally:
                self.ready.set()
        await asyncio.wait_for(self.ready.wait(), 120)
        if self.failure:
            raise self.failure
        self.plan.assert_ready(time.monotonic_ns())
        while remaining := max(0, self.plan.send_origin_ns - time.monotonic_ns()):
            await asyncio.sleep(remaining / 1e9)
        self.plan.assert_release(time.monotonic_ns())
        self.hub._require_live()
        if self.hub.input_frames < 352:
            raise LiveFailure("insufficient real capture pre-roll at common release")


async def play_system_audio(library, capture_host, routes, hosts, volume=15,
                            exclude_pids=(), report=None, volume_control=None,
                            input_config=None, mode='synchronized', endpoint_roles=None):
    """Runs until cancelled or failed. Calling is an explicit audible action.

    report cleanup fields describe resource shutdown, never acoustic proof.
    Each session owns all RAOP patches, capture process and native engine.
    """
    report = report if report is not None else {}
    report.update(status="preparing", live=True, volume_percent=volume,
                  acoustic_sync_verified=False, input_closed=False, hub_stopped=False,
                  cleanup_complete=False)
    hub = capture = patch = None
    connections, tasks = [], []
    cleaned = capture_clean = False
    try:
        check_versions()
        if (type(volume) not in (int, float) or not math.isfinite(volume) or not 0 <= volume <= 100
                or not routes or set(routes) != set(hosts) or len(set(hosts.values())) != len(hosts)
                or any(not isinstance(host, str) or not host or len(host) > 255 for host in hosts.values())):
            raise ValueError("valid live volume and unique receiver targets required")
        if input_config is None:
            hub = LiveHub(library, routes)
            capture = CaptureHost(capture_host, report.get("session", str(uuid.uuid4())), hub, exclude_pids)
        else:
            from .capture_v2 import CaptureHostV2
            from .routing_v2 import VirtualRoutePlan
            plan = VirtualRoutePlan(input_config['layout'], routes, mode, endpoint_roles)
            report.update(plan.report(), input_backend='virtual_device_v2',
                          source_layout=input_config['layout'], source_layout_verified=False)
            hub = LiveHub(library, plan.routes, input_channels=plan.channels)
            capture = CaptureHostV2(capture_host, report.get("session", str(uuid.uuid4())), hub,
                                    input_config['device_uid'], input_config['layout'], plan.process)
        devices = await scan(list(hosts.values()))
        by_host = {str(device.address): device for device in devices}
        if any(host not in by_host for host in hosts.values()):
            raise LiveFailure("a selected AirPlay receiver was not discovered")
        import pyatv
        from pyatv.const import Protocol
        latency_report = None
        if isinstance(input_config, dict):
            latency_report = input_config.get("latency_report")
        with LivePatches(hub, capture, report, volume_control, latency_report) as patch:
            patch.cleanup_confirmed = False
            try:
                report["status"] = "connecting"
                for host in hosts.values():
                    connection = await asyncio.wait_for(pyatv.connect(
                        by_host[host], asyncio.get_running_loop(), protocol=Protocol.RAOP), 20)
                    connections.append(connection)
                    await connection.audio.set_volume(volume)
                if volume_control:
                    volume_control.bind(connections)
                report["status"] = "preparing"
                tasks = [asyncio.create_task(connection.stream.stream_file(patch.sources[key]))
                         for (key, _host), connection in zip(hosts.items(), connections)]
                done, _pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
                for task in done:
                    task.result()
                raise LiveFailure("a live receiver stopped without controller stop")
            finally:
                if volume_control:
                    volume_control.close()
                # Patches remain installed until all streaming tasks have exited.
                results = await asyncio.gather(
                    capture.stop(), hub.stop(),
                    cleanup_session(connections, tasks, patch.sources.values(), report),
                    return_exceptions=True)
                capture_clean = results[0] is True
                cleaned = results[1] is None and results[2] is True
                patch.cleanup_confirmed = cleaned
    except BaseException as exc:
        report.update(status="failed", error_type=type(exc).__name__,
                      error_detail=" ".join(str(exc).split())[:256])
        raise
    finally:
        # Failure can occur before entering the patch scope or connecting peers.
        if volume_control:
            volume_control.close()
        if capture and not capture.stopping:
            capture_clean = await capture.stop()
        if patch is None:
            cleaned = not connections and not tasks
        if hub:
            await hub.stop()
            report.update(hub.report())
        else:
            report["hub_stopped"] = True
        if capture:
            report.update(capture.report())
        else:
            capture_clean = True
            report["input_closed"] = True
        report["cleanup_complete"] = (cleaned and capture_clean and report["hub_stopped"]
                                      and report["input_closed"])
