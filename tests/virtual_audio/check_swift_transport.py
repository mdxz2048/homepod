import asyncio, json, math, pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2]))
from adapters.live.pcm_v2 import PCMV2Validator, read_frame_v2

async def check(folder):
    manifest = json.loads((folder / 'manifest.json').read_text())
    total = 0
    for entry in manifest:
        reader = asyncio.StreamReader()
        reader.feed_data((folder / entry['file']).read_bytes()); reader.feed_eof()
        validator = PCMV2Validator(entry['session'], entry['startID'])
        tail = []
        for index in range(entry['packets']):
            frame = await read_frame_v2(reader)
            assert frame.header['provenance'] == 'source_upstream_mapped'
            assert frame.header['source']['nativeClaim'] is False
            assert frame.header['source']['sourceLayoutVerified'] is False
            tail.extend(validator.pcm(frame))
            tail = tail[-1024 * entry['channels']:]
        assert await reader.read() == b'', 'trailing bytes'
        assert validator.frames == entry['frames'] and validator.frames > 0
        expected = entry['inputFrames'] * 44100 / entry['sourceRate']
        assert abs(validator.frames - expected) <= 128, (entry, expected)
        for index, value in enumerate(tail):
            wanted = (index % entry['channels'] + 1) * .05
            assert math.isfinite(value) and abs(value - wanted) < .002, (entry['file'], index, value, wanted)
        total += validator.frames
        print(f"PASS {entry['file']}: {entry['packets']} packets, {validator.frames} frames")
    print(f'PASS Swift -> Python: {len(manifest)} cases, {total} frames; channel order, continuity, provenance and frame ratio checked')

asyncio.run(check(pathlib.Path(sys.argv[1])))
