"""Experimental ALAC transport for pyatv's AirPlay 2 sender.

Encodes 16-bit stereo big-endian PCM as ALAC verbatim channel-pair elements.
Protocol references: Apple ALAC format; pyatv issue #2915 and HomePod-Bridge
identify verbatim ALAC as an alternative to raw PCM on AirPlay receivers.
"""


def verbatim_alac(pcm):
    if not pcm or len(pcm) % 4:
        raise ValueError('Expected whole 16-bit stereo PCM frames')
    frames = len(pcm) // 4
    # Channel-pair element (3), instance (4), reserved (12), explicit-size (1),
    # extra sample bytes (2), verbatim (1), then frame count (32).
    prefix = ((1 << 20) | 9) << 32 | frames
    sample_bits = len(pcm) * 8
    bits = 55 + sample_bits + 3
    packed = ((prefix << sample_bits) | int.from_bytes(pcm, 'big')) << 3 | 7
    padding = (-bits) % 8
    return (packed << padding).to_bytes((bits + padding) // 8, 'big')


class AlacAdapter:
    def install(self):
        from pyatv.protocols.raop.protocols.airplayv2 import AirPlayV2
        self.original_setup = AirPlayV2.setup_audio_stream
        self.original_send = AirPlayV2.send_audio_packet
        adapter = self
        self.packet_count = 0
        self.nonzero_packet_count = 0

        async def setup(client, control_port):
            base_setup = client.rtsp.setup

            async def negotiate(*args, **kwargs):
                body = kwargs.get('body')
                if isinstance(body, dict):
                    for stream in body.get('streams', []):
                        stream['audioFormat'] = 0x40000
                        stream['ct'] = 2
                return await base_setup(*args, **kwargs)

            client.rtsp.setup = negotiate
            try:
                return await adapter.original_setup(client, control_port)
            finally:
                del client.rtsp.setup

        async def send(client, transport, header, pcm):
            adapter.packet_count += 1
            if any(pcm):
                adapter.nonzero_packet_count += 1
            return await adapter.original_send(client, transport, header, verbatim_alac(pcm))

        AirPlayV2.setup_audio_stream = setup
        AirPlayV2.send_audio_packet = send

    def restore(self):
        from pyatv.protocols.raop.protocols.airplayv2 import AirPlayV2
        AirPlayV2.setup_audio_stream = self.original_setup
        AirPlayV2.send_audio_packet = self.original_send
