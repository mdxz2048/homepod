"""Production runner delegates to the existing frozen native streaming path."""
from __future__ import annotations


class RunReport(dict):
    def __init__(self):
        super().__init__()
        self.network_started = False

    def __setitem__(self, key, value):
        if key == "status" and value == "connecting":
            self.network_started = True
        super().__setitem__(key, value)

    def update(self, *args, **kwargs):
        for key, value in dict(*args, **kwargs).items():
            self[key] = value


async def native_runner(params, report):
    # Lazy imports keep hello independent from native/pyatv availability.
    reader = None
    invoked_stream = False
    try:
        from adapters.airplay_pyatv.streaming import WavReader, stream_dry_run, stream_play
        reader = WavReader(params["wav"])
        routes = {route["output_id"]: route["channels"] for route in params["routes"]}
        if any(channel >= reader.channels for route in routes.values() for channel in route):
            raise ValueError("route exceeds WAV channel count")
        lead_ns = int(params.get("lead_seconds", 8) * 1_000_000_000)
        invoked_stream = True
        if params["execution"] == "offline":
            await stream_dry_run(params["library"], reader, routes, lead_ns=lead_ns, report=report)
        else:
            hosts = {route["output_id"]: route["host"] for route in params["routes"]}
            await stream_play(params["library"], reader, routes, hosts,
                              volume=params.get("volume", 15), lead_ns=lead_ns, report=report)
    finally:
        if reader:
            reader.close()
        if invoked_stream:
            # Missing hub/cleanup evidence is uncertainty, even if the reader
            # itself closed. Never manufacture a stopped native-hub result.
            report["input_closed"] = report.get("input_closed") is True and reader.closed
        else:
            # Failure before invoking stream_* cannot own native/network work.
            report.update(input_closed=reader is None or reader.closed,
                          hub_stopped=True, cleanup_complete=True)


async def inspect_wav(path):
    from adapters.airplay_pyatv.streaming import WavReader
    reader = WavReader(path)
    try:
        return {"sample_rate": reader.sample_rate, "channels": reader.channels,
                "frames": reader.total_frames, "duration_seconds": reader.total_frames / reader.sample_rate}
    finally:
        reader.close()


async def validate_start(params):
    from pathlib import Path
    if not Path(params["library"]).is_file() or not Path(params["wav"]).is_file():
        raise ValueError("selected local file or library is unavailable")
    metadata = await inspect_wav(params["wav"])
    if any(channel >= metadata["channels"] for route in params["routes"] for channel in route["channels"]):
        raise ValueError("route exceeds the actual WAV channel count")
    if params["execution"] == "airplay" and metadata["sample_rate"] != 44100:
        raise ValueError("AirPlay streaming requires 44100Hz input")
    return metadata


async def scan_receivers(params):
    from adapters.airplay_pyatv.session import scan
    devices = await scan(params.get("hosts"), params.get("timeout_seconds", 8))
    return {"devices": [{"name": str(device.name)[:128], "address": str(device.address)[:128],
                         "model": str(device.device_info.model)[:128]} for device in devices[:64]]}
