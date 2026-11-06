"""Explicit CLI. dry-run never discovers devices or creates network sessions."""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
from pathlib import Path
import time

from .render import generated_tones, load_wav, render_audio


def mapping(text):
    try:
        key, values = text.split("=", 1)
        return int(key), [int(channel) for channel in values.split(",")]
    except ValueError as exc:
        raise argparse.ArgumentTypeError("use OUTPUT_ID=CHANNEL,CHANNEL") from exc


def target(text):
    try:
        key, host = text.split("=", 1)
        if not host:
            raise ValueError()
        return int(key), host
    except ValueError as exc:
        raise argparse.ArgumentTypeError("use OUTPUT_ID=IP_ADDRESS") from exc


def unique(entries, label):
    result = dict(entries)
    if len(result) != len(entries):
        raise ValueError("duplicate " + label)
    return result


async def dry_run(library, samples, rate, channels, routes, lead_ns):
    from .source import CoreAudioSource
    batch = render_audio(library, samples, rate, channels, routes, time.monotonic_ns(), lead_ns)
    report = batch.report()
    consumed = {}
    for key, output in batch.outputs.items():
        source = CoreAudioSource(key, rate, output.frames)
        try:
            source.attach(output)
            digest = hashlib.sha256()
            while data := await source.readframes(352):
                digest.update(data)
            if source.frames_read != output.frames:
                raise RuntimeError("custom AudioSource consumed wrong frame count")
            consumed[str(key)] = {"frames": source.frames_read, "pcm_sha256": digest.hexdigest()}
        finally:
            await source.close()
    report.update({"status": "offline_dry_run_completed", "network_used": False,
                   "audio_source_consumed": consumed})
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    scan_parser = commands.add_parser("scan", help="explicitly discover RAOP devices; no playback")
    scan_parser.add_argument("--host", action="append", default=[])
    scan_parser.add_argument("--timeout", type=int, default=8)
    scan_parser.add_argument("--report", type=Path)
    for command in ("dry-run", "play", "stream"):
        item = commands.add_parser(command)
        item.add_argument("--library", required=True, type=Path, help="explicit path to flow_bridge dylib/dll/so")
        item.add_argument("--wav", type=Path, help="16-bit PCM WAV (no implicit conversion or download)")
        item.add_argument("--seconds", type=float, default=60 if command == "stream" else 3,
                          help="generated tones duration (stream max3600, other commands max30)")
        item.add_argument("--channels", type=int, default=3, help="generated input channels")
        item.add_argument("--route", action="append", type=mapping, default=[])
        item.add_argument("--lead-seconds", type=float, default=8)
        item.add_argument("--report", type=Path)
        if command == "play":
            item.add_argument("--target", action="append", type=target, required=True)
            item.add_argument("--volume", type=float, default=15)
        if command == "stream":
            item.add_argument("--dry-run", action="store_true", help="offline accelerated stream, never scans or plays")
            item.add_argument("--target", action="append", type=target, default=[])
            item.add_argument("--volume", type=float, default=15)
            item.add_argument("--block-frames", type=int, default=352)
            item.add_argument("--capacity-blocks", type=int, default=4)
            item.add_argument("--stall-timeout", type=float, default=2.0)
    args = parser.parse_args(argv)
    report = {"status": "initializing", "acoustic_sync_verified": False}
    exit_code = 0
    try:
        if args.command == "scan":
            from .session import scan
            devices = asyncio.run(scan(args.host, args.timeout))
            report.update({"status": "scan_completed", "playback_started": False,
                           "devices": [{"name": device.name, "address": str(device.address),
                                        "model": str(device.device_info.model)} for device in devices]})
        else:
            if not 0 < args.lead_seconds <= 30:
                raise ValueError("lead must be greater than zero and at most 30 seconds")
            if args.command == "stream":
                from .streaming import ToneReader, WavReader, stream_dry_run, stream_play
                reader = WavReader(args.wav) if args.wav else ToneReader(args.seconds, args.channels)
                try:
                    routes = unique(args.route, "route id") if args.route else {i: [i, i] for i in range(reader.channels)}
                    lead = int(args.lead_seconds * 1e9)
                    report.update({"command": "stream", "input_sample_rate": reader.sample_rate,
                                   "input_channels": reader.channels, "input_frames": reader.total_frames,
                                   "routes": {str(key): value for key, value in routes.items()},
                                   "native_library": str(args.library.resolve())})
                    if args.dry_run:
                        if args.target:
                            raise ValueError("--dry-run does not accept network targets")
                        asyncio.run(stream_dry_run(args.library, reader, routes, lead, args.block_frames,
                                                   args.capacity_blocks, args.stall_timeout, report))
                    else:
                        hosts = unique(args.target, "target id")
                        asyncio.run(stream_play(args.library, reader, routes, hosts, args.volume, lead,
                                                args.block_frames, args.capacity_blocks, args.stall_timeout, report))
                finally:
                    reader.close()
            else:
                samples, rate, channels = load_wav(args.wav) if args.wav else generated_tones(args.seconds, args.channels)
                routes = unique(args.route, "route id") if args.route else {i: [i, i] for i in range(channels)}
                lead = int(args.lead_seconds * 1e9)
                report.update({"command": args.command, "input_sample_rate": rate,
                               "input_channels": channels, "input_frames": len(samples) // channels,
                               "routes": {str(key): value for key, value in routes.items()},
                               "native_library": str(args.library.resolve())})
                if args.command == "dry-run":
                    report.update(asyncio.run(dry_run(args.library, samples, rate, channels, routes, lead)))
                else:
                    from .session import play
                    hosts = unique(args.target, "target id")
                    asyncio.run(play(args.library, samples, rate, channels, routes, hosts,
                                     args.volume, lead, report))
    except (Exception, KeyboardInterrupt) as exc:
        exit_code = 1
        report.update({"status": "failed", "error": f"{type(exc).__name__}: {exc}"})
    payload = json.dumps(report, ensure_ascii=False, indent=2)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(payload + "\n", encoding="utf-8")
    print(payload, flush=True)
    return exit_code
