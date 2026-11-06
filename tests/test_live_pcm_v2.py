"""Standalone HPCM v2 acceptance. Never captures, scans or plays audio."""
import array
import asyncio
import copy
import json
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from adapters.live.hub import LiveFailure
from adapters.live.pcm import Frame as FrameV1, read_frame as read_frame_v1
from adapters.live.pcm_v2 import (FrameV2, PCMV2Error, PCMV2Validator,
                                  read_frame_v2)

SESSION = "AB12CD34-AB12-4D34-AB12-AB12CD34EF56"
ORDER = {
    "mono": ["M"],
    "stereo": ["FL", "FR"],
    "3_0": ["FL", "FR", "FC"],
    "4_0": ["FL", "FR", "BL", "BR"],
    "5_1_side": ["FL", "FR", "FC", "LFE", "SL", "SR"],
    "5_1_back": ["FL", "FR", "FC", "LFE", "BL", "BR"],
    "7_1": ["FL", "FR", "FC", "LFE", "SL", "SR", "BL", "BR"],
}
UID = {
    "mono": "com.homepodflow.virtual-audio.mono.v1",
    "stereo": "com.homepodflow.virtual-audio.stereo.v1",
    "3_0": "com.homepodflow.virtual-audio.surround30.v1",
    "4_0": "com.homepodflow.virtual-audio.quad40.v1",
    "5_1_side": "com.homepodflow.virtual-audio.surround51s.v1",
    "5_1_back": "com.homepodflow.virtual-audio.surround51b.v1",
    "7_1": "com.homepodflow.virtual-audio.surround71.v1",
}


def payload(order, frames, frame_index=0, silent=()):
    values = []
    for frame in range(frames):
        for channel in range(len(order)):
            if channel in silent:
                values.append(0.0)
            else:
                values.append((((frame * len(order) + channel + frame_index)
                                % 16) + 1) / 20.0)
    return struct.pack("<%df" % len(values), *values)


def header(layout="stereo", sequence=0, first=0, frames=441,
           source_layout=None, source_order=None, source_channels=None,
           source_frames=480, source_start=0, provenance="source_native",
           transform=None, container=None, **updates):
    source_layout = layout if source_layout is None else source_layout
    source_order = ORDER[source_layout] if source_order is None else source_order
    source_channels = (len(source_order) if source_channels is None
                       else source_channels)
    order = ORDER[layout]
    host = 123_456_789 + source_start * 1_000_000_000 // 48000
    source = {
        "sourceRate": 48000,
        "sourceChannels": source_channels,
        "sourceLayout": source_layout,
        "sourceChannelOrder": list(source_order),
        "sourceLayoutAuthority": "decoder",
        "sourceOrigin": "decoder",
        "sourceLayoutVerified": True,
        "nativeClaim": provenance in ("source_native", "source_padded"),
        "upstreamTransform": "none_known",
        "evidence": "test fixture per-channel",
        "sourceFrameStart": source_start,
        "sourceFrames": source_frames,
        "sourceSequence": sequence,
        "hostTime": host,
        "sampleTime": "0.0",
        "flags": 3,
        "nowHostTime": host + 1000,
        "nowSampleTime": "0.0",
        "nowFlags": 3,
        "timebaseNumerator": 1_000_000_000,
        "timebaseDenominator": 48000,
        "droppedBlocksBefore": 0,
    }
    descriptor = {
        "deviceUID": UID[layout],
        "channels": len(order),
        "layout": layout,
        "channelOrder": list(order),
        "authority": "device",
        "verified": True,
    }
    if container is not None:
        descriptor = container
    if transform is None:
        transform = {"kind": "identity", "placed": [], "silentSlots": [],
                     "transformations": ["identity"]}
    result = {
        "v": 2,
        "id": "start-qa",
        "session": SESSION,
        "kind": "pcm",
        "sequence": sequence,
        "outputRate": 44100,
        "outputChannels": len(order),
        "outputLayout": layout,
        "outputChannelOrder": list(order),
        "outputFrameStart": first,
        "outputFrames": frames,
        "container": descriptor,
        "source": source,
        "captureTransform": transform,
        "provenance": provenance,
        "inputFramesConsumedTotal": source_start + source_frames,
        "converterLeadingFrames": 0,
        "converterTrailingFrames": 0,
        "primeMethod": "none",
        "converterDelayKnown": False,
        "timestampRelation": "input_block_metadata",
    }
    result.update(updates)
    return result


def identity_frame(layout="stereo", sequence=0, first=0, frames=441,
                   source_frames=480, **updates):
    return FrameV2(
        header(layout, sequence, first, frames, source_frames=source_frames,
               source_start=sequence * source_frames, **updates),
        payload(ORDER[layout], frames, sequence),
    )


def pad_51back_to_71(sequence=0, first=0, frames=441):
    placed = [{"sourceLabel": label, "slot": slot} for label, slot in
              (("FL", 0), ("FR", 1), ("FC", 2), ("LFE", 3),
               ("BL", 6), ("BR", 7))]
    transform = {"kind": "pad_silent", "placed": placed,
                 "silentSlots": [4, 5],
                 "transformations": ["pad_5_1_back_to_7_1"]}
    return FrameV2(
        header("7_1", sequence, first, frames, source_layout="5_1_back",
               provenance="source_padded", transform=transform,
               source_start=sequence * 480),
        payload(ORDER["7_1"], frames, sequence, silent=(4, 5)),
    )


def wire(frame):
    raw = json.dumps(frame.header, allow_nan=False,
                     separators=(",", ":")).encode()
    return (struct.pack("<4sII", b"HPCM", len(raw), len(frame.payload))
            + raw + frame.payload)


class PCMV2FramingTests(unittest.IsolatedAsyncioTestCase):
    async def read(self, data):
        reader = asyncio.StreamReader()
        reader.feed_data(data)
        reader.feed_eof()
        return await read_frame_v2(reader)

    async def test_valid_frames_survive_fragmentation_and_coalescing(self):
        first, second = identity_frame(), identity_frame(sequence=1, first=441)
        data = wire(first) + wire(second)
        reader = asyncio.StreamReader()

        async def feed():
            for offset in range(0, len(data), 7):
                reader.feed_data(data[offset:offset + 7])
                await asyncio.sleep(0)
            reader.feed_eof()

        task = asyncio.create_task(feed())
        self.assertEqual(await read_frame_v2(reader), first)
        self.assertEqual(await read_frame_v2(reader), second)
        await task
        with self.assertRaises(LiveFailure):
            await read_frame_v2(reader)

    async def test_v1_and_unknown_versions_are_rejected_by_v2(self):
        v1 = FrameV1({"v": 1, "id": "start-qa", "session": SESSION,
                      "kind": "pcm", "sequence": 0},
                     struct.pack("<4f", 0, 0, 0, 0))
        for frame in (v1, FrameV2({"v": 3, "kind": "ready"}, b""),
                      FrameV2({"v": 99, "kind": "ready"}, b"")):
            with self.subTest(v=frame.header.get("v")):
                with self.assertRaises(PCMV2Error) as caught:
                    await self.read(wire(frame))
                self.assertEqual(caught.exception.code, "unsupported_version")
        with self.assertRaises(PCMV2Error) as caught:
            await self.read(wire(FrameV2({"v": True, "kind": "ready"}, b"")))
        self.assertEqual(caught.exception.code, "invalid_header")

    async def test_v1_reader_still_rejects_v2(self):
        reader = asyncio.StreamReader()
        reader.feed_data(wire(identity_frame()))
        reader.feed_eof()
        with self.assertRaises(LiveFailure):
            await read_frame_v1(reader)

    async def test_header_and_payload_truncation_and_bad_framing(self):
        valid = wire(identity_frame())
        prefix = valid[:12]
        cases = [
            b"",
            prefix,
            prefix + valid[12:20],       # partial header
            valid[:-1],                  # partial payload
            struct.pack("<4sII", b"NOPE", 2, 0) + b"{}",
            struct.pack("<4sII", b"HPCM", 0, 0),
            struct.pack("<4sII", b"HPCM", 16385, 0),
            struct.pack("<4sII", b"HPCM", 1, 196609),
        ]
        for data in cases:
            with self.subTest(size=len(data)):
                with self.assertRaises(PCMV2Error):
                    await self.read(data)

    async def test_bad_json_control_payload_and_unknown_kind_rejected(self):
        for raw in (b'{"v":2,"v":2,"kind":"ready"}',
                    b'{"v":2,"kind":"ready","x":NaN}', b"\xff"):
            data = struct.pack("<4sII", b"HPCM", len(raw), 0) + raw
            with self.subTest(raw=raw), self.assertRaises(PCMV2Error):
                await self.read(data)
        control = FrameV2({"v": 2, "id": "x", "session": SESSION,
                           "kind": "ready"}, b"x")
        with self.assertRaises(PCMV2Error) as caught:
            await self.read(wire(control))
        self.assertEqual(caught.exception.code, "payload_mismatch")
        with self.assertRaises(PCMV2Error):
            await self.read(wire(FrameV2({"v": 2, "kind": "bogus"}, b"")))


class PCMV2ValidatorTests(unittest.TestCase):
    def validator(self):
        return PCMV2Validator(SESSION, "start-qa")

    def assert_code(self, code, frame, validator=None):
        with self.assertRaises(PCMV2Error) as caught:
            (validator or self.validator()).pcm(frame)
        self.assertEqual(caught.exception.code, code, str(caught.exception))

    def test_valid_stereo_51_and_71_identity_frames(self):
        for layout, channels in (("stereo", 2), ("5_1_side", 6), ("7_1", 8)):
            with self.subTest(layout=layout):
                validator = self.validator()
                first, second = (identity_frame(layout),
                                 identity_frame(layout, sequence=1, first=441))
                samples = validator.pcm(first)
                self.assertIsInstance(samples, array.array)
                self.assertEqual(len(samples), 441 * channels)
                self.assertTrue(all(abs(sample) <= 1 for sample in samples))
                validator.pcm(second)
                self.assertEqual((validator.sequence, validator.frames), (2, 882))
                self.assertEqual(validator.output_channels, channels)
                self.assertEqual(validator.output_layout, layout)

    def test_valid_pad_silent_51_back_to_71(self):
        validator = self.validator()
        frame = pad_51back_to_71()
        samples = validator.pcm(frame)
        self.assertEqual(len(samples), 441 * 8)
        for frame_index in range(441):
            self.assertEqual(samples[frame_index * 8 + 4], 0.0)
            self.assertEqual(samples[frame_index * 8 + 5], 0.0)
            self.assertNotEqual(samples[frame_index * 8 + 6], 0.0)

    def test_wrong_payload_lengths(self):
        frame = identity_frame()
        for payload_bytes in (frame.payload[:-4], frame.payload + b"\0" * 4):
            with self.subTest(length=len(payload_bytes)):
                self.assert_code("payload_mismatch",
                                 FrameV2(frame.header, payload_bytes))

    def test_channel_order_and_label_mismatch(self):
        frame = identity_frame("5_1_side")
        swapped = copy.deepcopy(frame.header)
        swapped["outputChannelOrder"] = ["FL", "FR", "FC", "LFE", "SR", "SL"]
        swapped["container"]["channelOrder"] = list(swapped["outputChannelOrder"])
        swapped["source"]["sourceChannelOrder"] = list(swapped["outputChannelOrder"])
        self.assert_code("channel_map_mismatch",
                         FrameV2(swapped, frame.payload))
        bad_label = identity_frame()
        bad_label.header["outputChannelOrder"] = ["FL", "XX"]
        self.assert_code("channel_map_mismatch", bad_label)
        duplicate = identity_frame()
        duplicate.header["outputChannelOrder"] = ["FL", "FL"]
        self.assert_code("channel_map_mismatch", duplicate)

    def test_unknown_and_reserved_layouts_rejected(self):
        for layout in ("5_1", "quad", "5_1_ambiguous", "5_1_2"):
            with self.subTest(layout=layout):
                frame = identity_frame()
                frame.header["outputLayout"] = layout
                frame.header["container"]["layout"] = layout
                self.assert_code(
                    "source_layout_ambiguous" if layout == "5_1_ambiguous"
                    else "unsupported_layout", frame)

    def test_sequence_and_frame_start_gaps(self):
        validator = self.validator()
        validator.pcm(identity_frame())
        gap = identity_frame(sequence=2, first=441)
        self.assert_code("frame_continuity", gap, validator)
        validator = self.validator()
        validator.pcm(identity_frame())
        gap = identity_frame(sequence=1, first=440)
        self.assert_code("frame_continuity", gap, validator)
        too_many = identity_frame(frames=4097)
        self.assert_code("invalid_header", too_many)

    def test_nonfinite_and_out_of_range_samples(self):
        frame = identity_frame()
        for value in (float("nan"), float("inf"), 1.5):
            with self.subTest(value=value):
                bad = bytearray(frame.payload)
                struct.pack_into("<f", bad, 0, value)
                self.assert_code("invalid_pcm_range",
                                 FrameV2(frame.header, bytes(bad)))

    def test_container_layout_and_device_mismatch(self):
        frame = identity_frame("5_1_side")
        container = copy.deepcopy(frame.header)
        container["container"]["channels"] = 2
        self.assert_code("container_layout_mismatch",
                         FrameV2(container, frame.payload))
        device = identity_frame("5_1_side")
        device.header["container"]["deviceUID"] = UID["7_1"]
        self.assert_code("device_mismatch", device)

    def test_capture_transform_mapping_and_padding_mismatch(self):
        frame = pad_51back_to_71()
        missing_silent = copy.deepcopy(frame.header)
        missing_silent["captureTransform"]["silentSlots"] = [4]
        self.assert_code("channel_map_mismatch",
                         FrameV2(missing_silent, frame.payload))
        wrong_slot = copy.deepcopy(frame.header)
        wrong_slot["captureTransform"]["placed"][-2]["slot"] = 4
        wrong_slot["captureTransform"]["silentSlots"] = [5, 6]
        self.assert_code("container_layout_mismatch",
                         FrameV2(wrong_slot, frame.payload))
        nonzero_pad = bytearray(frame.payload)
        struct.pack_into("<f", nonzero_pad, 4 * 4, 0.25)
        self.assert_code("silent_slot_nonzero",
                         FrameV2(frame.header, bytes(nonzero_pad)))

    def test_session_layout_change_and_stale_session(self):
        validator = self.validator()
        validator.pcm(identity_frame("5_1_side"))
        changed = identity_frame("7_1", sequence=1, first=441)
        self.assert_code("source_layout_changed", changed, validator)
        stale = identity_frame()
        stale.header["session"] = SESSION.lower()
        self.assert_code("stale_session", stale)
        wrong_id = identity_frame()
        wrong_id.header["id"] = "old-command"
        self.assert_code("stale_session", wrong_id)

    def test_source_clock_and_sequence_regression(self):
        validator = self.validator()
        validator.pcm(identity_frame())
        repeated = identity_frame(sequence=1, first=441)
        repeated.header["source"]["sourceSequence"] = 0
        self.assert_code("input_discontinuity", repeated, validator)
        dropped = identity_frame()
        dropped.header["source"]["droppedBlocksBefore"] = 1
        self.assert_code("input_discontinuity", dropped)

    def test_stereo_passthrough_requires_its_exact_transform(self):
        frame = identity_frame("stereo")
        transform = {"kind": "pad_silent",
                     "placed": [{"sourceLabel": "FL", "slot": 0},
                                {"sourceLabel": "FR", "slot": 1}],
                     "silentSlots": [2, 3, 4, 5],
                     "transformations": ["stereo_passthrough"]}
        good = FrameV2(
            header("5_1_side", source_layout="stereo",
                   source_order=["FL", "FR"], source_channels=2,
                   provenance="stereo_passthrough_in_multichannel",
                   transform=transform,
                   source_frames=480),
            payload(ORDER["5_1_side"], 441, silent=(2, 3, 4, 5)),
        )
        self.assertEqual(len(self.validator().pcm(good)), 441 * 6)
        bad = copy.deepcopy(good.header)
        bad["captureTransform"]["transformations"] = ["pad_silent"]
        self.assert_code("channel_map_mismatch",
                         FrameV2(bad, good.payload))
        wrong_provenance = copy.deepcopy(good.header)
        wrong_provenance["provenance"] = "source_padded"
        self.assert_code("channel_map_mismatch",
                         FrameV2(wrong_provenance, good.payload))

    def test_unpadded_source_native_must_match_container(self):
        frame = identity_frame("5_1_side")
        frame.header["source"]["sourceLayout"] = "5_1_back"
        frame.header["source"]["sourceChannelOrder"] = ORDER["5_1_back"]
        frame.header["captureTransform"]["kind"] = "pad_silent"
        frame.header["captureTransform"]["transformations"] = ["pad_silent"]
        self.assert_code("channel_map_mismatch", frame)


if __name__ == "__main__":
    unittest.main(verbosity=2)
