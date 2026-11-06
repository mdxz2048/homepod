"""Explicit network session using native-routed sources and one scoped patch owner.

Private pyatv integration is deliberately pinned to 0.18.0. Import is passive.
"""
from __future__ import annotations

import asyncio
from importlib.metadata import version
import math
import time

from .render import render_audio
from .source import CoreAudioSource
from .timing import build_timing_plan, ntp_from_unix_ns


def check_versions() -> None:
    if version("pyatv") != "0.18.0" or version("srptools") != "1.0.1":
        raise RuntimeError("bridge requires pyatv==0.18.0 and srptools==1.0.1")


def verbatim_alac(pcm: bytes) -> bytes:
    if not pcm or len(pcm) % 4:
        raise ValueError("ALAC requires whole signed16 big-endian stereo frames")
    frames = len(pcm) // 4
    prefix = ((1 << 20) | 9) << 32 | frames
    sample_bits = len(pcm) * 8
    bits = 55 + sample_bits + 3
    packed = ((prefix << sample_bits) | int.from_bytes(pcm, "big")) << 3 | 7
    padding = (-bits) % 8
    return (packed << padding).to_bytes((bits + padding) // 8, "big")


class SessionPatches:
    """Own all pyatv patches for exactly one dedicated, serialized session."""
    _active = False

    def __init__(self, library, samples, sample_rate, channels, routes, report,
                 lead_ns=8_000_000_000, barrier_timeout=30):
        self.library = library
        self.samples, self.sample_rate, self.channels = samples, sample_rate, channels
        self.routes, self.report = routes, report
        self.lead_ns, self.barrier_timeout = lead_ns, barrier_timeout
        self.sources = {key: CoreAudioSource(key, sample_rate, len(samples) // channels) for key in routes}
        self.clients = []
        self.ready = asyncio.Event()
        self.failure = None
        self.plan = None
        self.rendered = None
        self._originals = []
        self._installed = False

    def _replace(self, owner, name, value):
        original = getattr(owner, name)
        self._originals.append((owner, name, original))
        setattr(owner, name, value)
        return original

    def __enter__(self):
        check_versions()
        if SessionPatches._active:
            raise RuntimeError("another bridge patch session is active")
        SessionPatches._active = True
        self._installed = True
        try:
            self._install()
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def _install(self):
        import pyatv.protocols.raop as raop
        from pyatv.protocols.raop.stream_client import ControlClient, StreamClient
        from pyatv.protocols.raop.protocols.airplayv2 import AirPlayV2
        original_open = raop.open_source
        original_setup = AirPlayV2.setup_audio_stream
        original_send = AirPlayV2.send_audio_packet
        original_start = ControlClient.start
        original_stream = StreamClient._stream_data
        originals = ((original_open, "pyatv.protocols.raop.audio_source"),
                     (original_setup, "pyatv.protocols.raop.protocols.airplayv2"),
                     (original_send, "pyatv.protocols.raop.protocols.airplayv2"),
                     (original_start, "pyatv.protocols.raop.stream_client"),
                     (original_stream, "pyatv.protocols.raop.stream_client"))
        if any(getattr(function, "__module__", None) != module for function, module in originals):
            raise RuntimeError("pyatv methods are already patched; use an isolated bridge process")
        session = self

        async def open_source(source, rate, channels, width):
            if isinstance(source, CoreAudioSource):
                if source not in session.sources.values() or (rate, channels, width) != (source.sample_rate, 2, 2):
                    raise ValueError("receiver cannot accept this native stereo source format")
                return source
            return await original_open(source, rate, channels, width)

        async def setup(client, control_port):
            rtsp = client.rtsp
            base_setup = rtsp.setup
            had_instance_override = "setup" in rtsp.__dict__
            previous_override = rtsp.__dict__.get("setup")

            async def negotiate(*args, **kwargs):
                body = kwargs.get("body")
                if isinstance(body, dict):
                    for stream in body.get("streams", []):
                        stream["audioFormat"], stream["ct"] = 0x40000, 2
                return await base_setup(*args, **kwargs)

            rtsp.setup = negotiate
            try:
                return await original_setup(client, control_port)
            finally:
                if had_instance_override:
                    rtsp.setup = previous_override
                else:
                    del rtsp.setup

        async def send(client, transport, header, pcm):
            session.report["audio_packets"] = session.report.get("audio_packets", 0) + 1
            if any(pcm):
                session.report["nonzero_packets"] = session.report.get("nonzero_packets", 0) + 1
            return await original_send(client, transport, header, verbatim_alac(pcm))

        def defer_start(control, address):
            control._flow_sync_address = address

        async def stream(client, source, transport):
            if source not in session.sources.values() or not isinstance(client._protocol, AirPlayV2):
                raise RuntimeError("bridge only supports its own native sources on AirPlay2")
            from pyatv.protocols.airplay.utils import pct_to_dbfs
            # Confirm the requested level after RTSP setup; in particular pyatv's
            # truthy `if volume` fallback must not skip an explicit zero volume.
            await client.set_volume(pct_to_dbfs(session.report.get("volume_percent", 15.0)))
            await session.arrive(client, source)
            control = client.control_client
            original_start(control, control._flow_sync_address)
            session.report.setdefault("stream_releases", []).append({
                "output_id": source.output_id, "monotonic_ns": time.monotonic_ns(),
                "start_ts": client.context.start_ts, "first_rtp": client.context.rtptime})
            try:
                await original_stream(client, source, transport)
                if source.frames_read != source.frames:
                    raise RuntimeError("transport stopped before consuming every native-routed frame")
                if client.context.padding_sent < client.context.latency:
                    raise RuntimeError("transport stopped before protocol-latency padding completed")
            finally:
                control.stop()

        self._replace(raop, "open_source", open_source)
        self._replace(AirPlayV2, "setup_audio_stream", setup)
        self._replace(AirPlayV2, "send_audio_packet", send)
        self._replace(ControlClient, "start", defer_start)
        self._replace(StreamClient, "_stream_data", stream)

    async def arrive(self, client, source):
        if any(existing is source for _, existing in self.clients):
            raise RuntimeError("duplicate stream at barrier")
        self.clients.append((client, source))
        if len(self.clients) == len(self.sources):
            try:
                self._prepare_plan()
            except BaseException as exc:
                self.failure = exc
            self.ready.set()
        await asyncio.wait_for(self.ready.wait(), self.barrier_timeout)
        if self.failure:
            raise self.failure
        self.plan.assert_ready(time.monotonic_ns())
        while True:
            remaining = self.plan.send_origin_ns - time.monotonic_ns()
            if remaining <= 0:
                break
            await asyncio.sleep(remaining / 1_000_000_000)
        self.plan.assert_release(time.monotonic_ns())

    def _prepare_plan(self):
        formats = {(c.context.sample_rate, c.context.channels, c.context.bytes_per_channel,
                    c.context.latency) for c, _ in self.clients}
        if len(formats) != 1:
            raise ValueError("all receivers must use the same rate, width, channels and latency")
        rate, channels, width, latency = next(iter(formats))
        if (rate, channels, width) != (self.sample_rate, 2, 2):
            raise ValueError("M1 receiver must match input rate and signed16 stereo")
        # Freeze one host monotonic↔wall anchor; no independent per-device epochs.
        before = time.monotonic_ns()
        ntp = ntp_from_unix_ns(time.time_ns())
        after = time.monotonic_ns()
        anchor = (before + after) // 2
        self.rendered = render_audio(self.library, self.samples, self.sample_rate,
                                     self.channels, self.routes, after, self.lead_ns)
        self.plan = build_timing_plan(self.rendered.origin_ns, anchor, ntp, rate, latency)
        for client, source in self.clients:
            source.attach(self.rendered.outputs[source.output_id])
            client.context.start_ts = self.plan.start_ts
            client.context.head_ts = self.plan.start_ts
        self.plan.assert_ready(time.monotonic_ns())
        self.report.update(self.rendered.report())
        self.report.update({"send_origin_ns": self.plan.send_origin_ns,
                            "protocol_latency_samples": latency,
                            "protocol_sample_rate": rate,
                            "shared_start_ts": self.plan.start_ts,
                            "prepared_receivers": len(self.clients),
                            "anchor_uncertainty_ns": after - before})

    def __exit__(self, *_):
        for owner, name, original in reversed(self._originals):
            setattr(owner, name, original)
        self._originals.clear()
        self.rendered = None
        if self._installed:
            self._installed = False
            SessionPatches._active = False


async def scan(hosts=None, timeout=8):
    check_versions()
    import pyatv
    from pyatv.const import Protocol
    return await pyatv.scan(asyncio.get_running_loop(), hosts=hosts or None,
                            timeout=timeout, protocol=Protocol.RAOP)


async def cleanup_session(connections, tasks, sources, report, timeout=5):
    """Cancel the group, close every connection/source, bound teardown waiting."""
    waiting = set(tasks)
    close_tasks = set()
    errors = []
    for task in tasks:
        if not task.done():
            task.cancel()
    for connection in connections:
        try:
            close_tasks.update(connection.close())
        except BaseException as exc:
            errors.append(f"connection.close: {type(exc).__name__}: {exc}")
    waiting.update(close_tasks)
    for source in sources:
        try:
            await source.close()
        except BaseException as exc:
            errors.append(f"source.close: {type(exc).__name__}: {exc}")
    pending = set()
    if waiting:
        done, pending = await asyncio.wait(waiting, timeout=timeout)
        if pending:
            for task in pending:
                task.cancel()
            extra_done, pending = await asyncio.wait(pending, timeout=2)
            done.update(extra_done)
        for task in done:
            if task.cancelled():
                if task in close_tasks:
                    errors.append("connection.close task was cancelled")
            else:
                # Retrieve exceptions even when the operation already failed.
                error = task.exception()
                if error is not None and task in close_tasks:
                    errors.append(f"connection.close task: {type(error).__name__}: {error}")
    report["cleanup_complete"] = not pending and not errors
    if errors:
        report["cleanup_errors"] = errors
    if pending:
        report["pending_cleanup_tasks"] = len(pending)
    return report["cleanup_complete"]


async def play(library, samples, sample_rate, channels, routes, hosts,
               volume=15.0, lead_ns=8_000_000_000, report=None):
    """Explicit audible operation; callers must opt into calling this function."""
    check_versions()
    if (not math.isfinite(volume) or not 0 <= volume <= 100 or sample_rate != 44100
            or set(routes) != set(hosts) or len(set(hosts.values())) != len(hosts)
            or any(len(mapping) != 2 for mapping in routes.values())):
        raise ValueError("valid volume, 44100Hz, unique hosts and stereo maps required")
    # Validate and route once offline before opening any receiver; real plan is
    # recreated at the prepared barrier, so stale rendering times are never reused.
    render_audio(library, samples, sample_rate, channels, routes, 0, lead_ns)
    report = report if report is not None else {}
    report.update({"status": "discovering", "volume_percent": volume,
                   "acoustic_sync_verified": False, "native_core_used": False})
    devices = await scan(list(hosts.values()))
    by_host = {str(device.address): device for device in devices}
    missing = [host for host in hosts.values() if host not in by_host]
    if missing:
        raise RuntimeError("RAOP receiver not discovered: " + ", ".join(missing))
    import pyatv
    from pyatv.const import Protocol
    connections, tasks = [], []
    with SessionPatches(library, samples, sample_rate, channels, routes, report, lead_ns) as patch:
        try:
            report["status"] = "connecting"
            for key, host in hosts.items():
                connection = await asyncio.wait_for(pyatv.connect(
                    by_host[host], asyncio.get_running_loop(), protocol=Protocol.RAOP), 20)
                connections.append(connection)
                await connection.audio.set_volume(volume)
            report["status"] = "preparing"
            for (key, _host), connection in zip(hosts.items(), connections):
                tasks.append(asyncio.create_task(connection.stream.stream_file(patch.sources[key])))
            duration = len(samples) / channels / sample_rate
            done, pending = await asyncio.wait(tasks, timeout=duration + lead_ns / 1e9 + 60,
                                                return_when=asyncio.FIRST_EXCEPTION)
            for task in done:
                task.result()
            if pending:
                raise TimeoutError("group did not complete within finite-session deadline")
            report["status"] = "sender_completed_unverified_acoustically"
            report["frames_consumed"] = {str(key): source.frames_read for key, source in patch.sources.items()}
        except BaseException as exc:
            report["status"] = "failed"
            report["error"] = f"{type(exc).__name__}: {exc}"
            raise
        finally:
            cleaned = await cleanup_session(connections, tasks, patch.sources.values(), report)
            if not cleaned and report.get("status") != "failed":
                report["status"] = "failed"
                report["error"] = "group cleanup incomplete"
                raise RuntimeError("group cleanup incomplete")
    return report
