"""Experimental Windows-native AirPlay test. Sender logs are NOT acoustic proof.

Uses pyatv 0.18.0 internals through a process-local adapter. No installed files
are modified. All receivers finish RTSP preparation before the adapter gives
their independent audio streams the same NTP/sample-time origin.
"""
import argparse
import asyncio
from importlib.metadata import version
import json
import logging
import math
import os
from pathlib import Path
import struct
import sys
import time
import wave


def make_audio(path, role, duration, continuous=False):
    """Distinct tones, with measurement markers at known 100 ms offsets."""
    rate = 44100
    with wave.open(str(path), 'wb') as output:
        output.setparams((2, 2, rate, 0, 'NONE', 'not compressed'))
        for second in range(duration):
            chunk = bytearray()
            for sample in range(rate):
                t = sample / rate
                channels = []
                for channel in range(2):
                    position = {'front': 0, 'rear-left': 1, 'rear-right': 2}.get(role, channel + 1)
                    # Quiet identifying tones at the start of each five-second cycle.
                    value = 0.0
                    if continuous:
                        absolute_t = second + t
                        fade = min(1.0, absolute_t / 0.03, (duration - absolute_t) / 0.03)
                        value = 0.30 * fade * math.sin(2 * math.pi * (440 + 220 * position) * t)
                    if second % 5 == 0 and 0.1 <= t < 0.35:
                        envelope = math.sin(math.pi * (t - 0.1) / 0.25) ** 2
                        if not continuous:
                            value += 0.15 * envelope * math.sin(2 * math.pi * (440 + 220 * position) * t)
                    # Measurement marker: front at .5, rear L at .6, rear R at .7.
                    dt = t - (0.5 + 0.1 * position)
                    if second % 5 == 2 and 0 <= dt < 0.025:
                        envelope = math.sin(math.pi * dt / 0.025) ** 2
                        if not continuous:
                            value += 0.20 * envelope * math.sin(2 * math.pi * 1800 * dt)
                    channels.append(round(value * 32767))
                chunk.extend(struct.pack('<hh', *channels))
            output.writeframesraw(chunk)


class SharedTimeline:
    def __init__(self, count, report):
        self.count = count
        self.report = report
        self.clients = []
        self.ready = asyncio.Event()
        self.error = None

    def install(self):
        from pyatv.protocols.raop import timing
        from pyatv.protocols.raop.stream_client import ControlClient, StreamClient

        if version('pyatv') != '0.18.0':
            raise RuntimeError('This experimental adapter requires pyatv==0.18.0')
        original_start = ControlClient.start
        original_stream = StreamClient._stream_data
        gate = self

        def defer_sync(control, address):
            control._probe_sync_address = address

        async def stream_together(client, source, transport):
            gate.clients.append(client)
            if len(gate.clients) == gate.count:
                formats = {(c.context.sample_rate, c.context.channels,
                            c.context.bytes_per_channel, c.context.latency)
                           for c in gate.clients}
                if len(formats) != 1:
                    gate.error = RuntimeError(f'Receiver formats/latencies differ: {formats}')
                else:
                    now = timing.ntp_now()
                    for item in gate.clients:
                        context = item.context
                        context.start_ts = timing.ntp2ts(now, context.sample_rate)
                        context.head_ts = context.start_ts
                    gate.report['shared_ntp_origin'] = now
                    gate.report['sample_rate'] = client.context.sample_rate
                    gate.report['protocol_latency_samples'] = client.context.latency
                    gate.report['streams_prepared'] = gate.count
                gate.ready.set()
            await asyncio.wait_for(gate.ready.wait(), timeout=30)
            if gate.error:
                raise gate.error
            control = client.control_client
            original_start(control, control._probe_sync_address)
            gate.report.setdefault('sender_stream_starts', []).append({
                'host': client.rtsp.connection.remote_ip,
                'monotonic_ns': time.monotonic_ns(),
                'start_ts': client.context.start_ts,
            })
            await original_stream(client, source, transport)

        ControlClient.start = defer_sync
        StreamClient._stream_data = stream_together
        self.originals = (ControlClient, StreamClient, original_start, original_stream)

    def restore(self):
        control, stream, start, send = self.originals
        control.start = start
        stream._stream_data = send


async def run(args):
    import pyatv
    from pyatv.const import Protocol

    loop = asyncio.get_running_loop()
    roles = [('front', args.front), ('rear', args.rear),
             ('rear-left', args.rear_left), ('rear-right', args.rear_right)]
    if args.pair_test:
        roles = [('pair-member-a', args.pair_test[0]), ('pair-member-b', args.pair_test[1])]
    hosts = [host for _, host in roles if host]
    devices = await pyatv.scan(loop, hosts=hosts or None, timeout=8, protocol=Protocol.RAOP)
    print(json.dumps([{'name': d.name, 'address': str(d.address),
                       'model': str(d.device_info.model)} for d in devices], ensure_ascii=True), flush=True)
    if args.scan:
        return
    independent_rears = bool(args.rear_left and args.rear_right)
    if (not args.front and not args.pair_test and not independent_rears) or (len(hosts) < 2 and not args.single):
        raise RuntimeError('Provide a front and rear output, or use --single for front-only testing')
    if len(hosts) != len(set(hosts)):
        raise RuntimeError('Each role must use a different output group IP')
    bundle = None
    bundle_files = {}
    if args.bundle:
        if args.single or args.pair_test or not (args.rear or independent_rears):
            raise RuntimeError('--bundle requires a rear pair or two independent rear speakers')
        folder = Path(args.bundle).resolve()
        bundle = json.loads((folder / 'manifest.json').read_text(encoding='utf-8'))
        if bundle.get('kind') not in ('generated_discrete_5.1_test', 'downloaded_discrete_5.1_clip', 'downloaded_discrete_5.1_music'):
            raise RuntimeError('Unsupported test bundle')
        shapes = set()
        for role, host in roles:
            if not host:
                continue
            if role not in bundle['outputs']:
                raise RuntimeError(f'Bundle has no output for role {role}')
            path = (folder / bundle['outputs'][role]).resolve()
            with wave.open(str(path)) as audio:
                shapes.add((audio.getnchannels(), audio.getsampwidth(), audio.getframerate(), audio.getnframes()))
            bundle_files[role] = str(path)
        expected = (2, 2, bundle['sample_rate'], bundle['frames'])
        if shapes != {expected}:
            raise RuntimeError('Bundle outputs must be equal-length 16-bit stereo PCM')
        args.seconds = bundle['duration_seconds']
    selected = []
    for role, host in roles:
        if not host:
            continue
        matches = [d for d in devices if str(d.address) == host]
        if not matches:
            raise RuntimeError(f'{role}: no RAOP service discovered at {host}')
        selected.append((role, matches[0]))

    Path('artifacts').mkdir(exist_ok=True)
    report = {'status': 'preparing', 'acoustic_sync_verified': False,
              'test_type': 'single-output connectivity' if args.single else 'different-stream shared-timeline experiment',
              'duration_seconds': args.seconds, 'volume_percent': args.volume,
              'receivers': [{'role': role, 'name': conf.name, 'ip': str(conf.address)} for role, conf in selected]}
    if args.pair_test:
        report['test_type'] = 'same stereo track to both native pair members; channel separation unverified'
    report['shared_timeline_adapter'] = not args.stock
    report['audio_transport'] = 'ALAC-verbatim' if args.alac else 'PCM'
    report['audio_file'] = args.audio_file
    if bundle:
        report['source_5_1_sha256'] = bundle['source_sha256']
        report['source_channel_order'] = bundle['channel_order']
        report['routed_files'] = bundle_files
    from pyatv.protocols.raop.protocols import TimingServer
    from pyatv.protocols.raop.stream_client import ControlClient
    original_timing_receive = TimingServer.datagram_received
    original_control_receive = ControlClient.datagram_received
    report['incoming_timing_packets'] = 0
    report['incoming_control_packets'] = 0

    def timing_receive(server, data, address):
        report['incoming_timing_packets'] += 1
        return original_timing_receive(server, data, address)

    def control_receive(client, data, address):
        report['incoming_control_packets'] += 1
        return original_control_receive(client, data, address)

    TimingServer.datagram_received = timing_receive
    ControlClient.datagram_received = control_receive
    for role, _ in selected:
        if not args.audio_file and not bundle:
            make_audio(Path(f'artifacts/{role}.wav'), role, args.seconds, args.continuous)
    gate = SharedTimeline(len(selected), report)
    alac = None
    if args.alac:
        from alac_adapter import AlacAdapter
        alac = AlacAdapter()
        alac.install()
    connections, tasks = [], []
    if not args.stock:
        gate.install()
    try:
        for role, conf in selected:
            connection = await asyncio.wait_for(pyatv.connect(conf, loop, protocol=Protocol.RAOP), 20)
            connections.append(connection)
            await connection.audio.set_volume(args.volume)
        for (role, _), connection in zip(selected, connections):
            audio_path = bundle_files.get(role) or args.audio_file or f'artifacts/{role}.wav'
            # miniaudio's file decoder in this build fails on absolute Unicode
            # paths; paths relative to this workspace avoid its ANSI path issue.
            audio_path = os.path.relpath(audio_path)
            tasks.append(asyncio.create_task(connection.stream.stream_file(audio_path)))
        print('Starting quiet test tones. Acoustic recording/listening is required.', flush=True)
        done, pending = await asyncio.wait(tasks, timeout=args.seconds + 60, return_when=asyncio.FIRST_EXCEPTION)
        for task in done:
            task.result()
        if pending:
            raise TimeoutError('One or more streams did not finish')
        report['status'] = 'sender_completed_unverified_acoustically'
    except BaseException as exc:
        report['status'] = 'failed'
        report['error'] = f'{type(exc).__name__}: {exc}'
        raise
    finally:
        for task in tasks:
            if not task.done():
                task.cancel()
        if tasks:
            await asyncio.gather(*tasks, return_exceptions=True)
        close_tasks = set()
        for connection in connections:
            close_tasks.update(connection.close())
        if close_tasks:
            await asyncio.gather(*close_tasks, return_exceptions=True)
        if not args.stock:
            gate.restore()
        TimingServer.datagram_received = original_timing_receive
        ControlClient.datagram_received = original_control_receive
        if alac:
            report['audio_packets'] = alac.packet_count
            report['nonzero_audio_packets'] = alac.nonzero_packet_count
            alac.restore()
        Path('artifacts/last_run.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
        print(json.dumps(report, ensure_ascii=True, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--scan', action='store_true')
    parser.add_argument('--front')
    parser.add_argument('--rear')
    parser.add_argument('--rear-left', help='Independent left mini IP; do not use with --rear')
    parser.add_argument('--rear-right', help='Independent right mini IP; do not use with --rear')
    parser.add_argument('--pair-test', nargs=2, metavar=('MEMBER_A', 'MEMBER_B'),
                        help='Send the same stereo audio file to both members of a native stereo pair')
    parser.add_argument('--single', action='store_true')
    parser.add_argument('--continuous', action='store_true', help='Play a continuous tone instead of spaced markers')
    parser.add_argument('--stock', action='store_true', help='Use original pyatv timing for a single-output baseline')
    parser.add_argument('--audio-file', help='Local audio file for a single-output listening test')
    parser.add_argument('--bundle', help='Prepared 5.1 test directory containing manifest.json and routed WAV files')
    codec = parser.add_mutually_exclusive_group()
    codec.add_argument('--alac', dest='alac', action='store_true', help='ALAC transport (default; audible on tested HomePod)')
    codec.add_argument('--pcm', dest='alac', action='store_false', help='Raw PCM diagnostic only; silent on tested HomePod')
    parser.set_defaults(alac=True)
    parser.add_argument('--seconds', type=int, default=30)
    parser.add_argument('--volume', type=float, default=15)
    args = parser.parse_args()
    if args.pair_test and (args.front or args.rear or args.rear_left or args.rear_right or args.single or args.bundle or not args.audio_file):
        parser.error('--pair-test requires --audio-file and no other layout arguments')
    if args.rear and (args.rear_left or args.rear_right):
        parser.error('Choose a stereo pair (--rear) or independent minis (--rear-left/--rear-right)')
    if args.single and (args.rear or args.rear_left or args.rear_right):
        parser.error('--single permits only --front')
    if args.stock and not args.single:
        parser.error('--stock requires --single; independent stock sessions do not test shared timing')
    if args.audio_file and (not (args.single or args.pair_test) or not Path(args.audio_file).is_file()):
        parser.error('--audio-file requires --single or --pair-test, and an existing file')
    if args.bundle and (args.audio_file or args.continuous or args.single or args.stock):
        parser.error('--bundle uses its own tracks and shared timing; cannot mix with audio-file/continuous/single/stock')
    if not 1 <= args.seconds <= 3600 or not 0 <= args.volume <= 100:
        parser.error('seconds must be 1..3600; volume must be 0..100 for this probe')
    Path('artifacts').mkdir(exist_ok=True)
    logging.basicConfig(filename='artifacts/probe.log', level=logging.INFO,
                        format='%(asctime)s %(name)s %(levelname)s %(message)s', encoding='utf-8')
    try:
        asyncio.run(run(args))
    except Exception as exc:
        logging.exception('Probe failed')
        print(f'{type(exc).__name__}: {exc}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
