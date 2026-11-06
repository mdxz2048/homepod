"""Custom pyatv source consuming exclusively native-core routed PCM."""
from __future__ import annotations

import math
from pyatv.protocols.raop.audio_source import AudioSource
from pyatv.interface import MediaMetadata

from .render import RenderedOutput


class CoreAudioSource(AudioSource):
    def __init__(self, output_id: int, sample_rate: int, frames: int):
        self.output_id = output_id
        self._sample_rate = sample_rate
        self.frames = frames
        self._pcm = None
        self._offset = 0
        self.frames_read = 0
        self.closed = False

    def attach(self, output: RenderedOutput) -> None:
        if (self._pcm is not None or self.closed or output.output_id != self.output_id
                or output.sample_rate != self.sample_rate or output.channels != 2
                or output.frames != self.frames):
            raise ValueError("native output does not match stereo AudioSource")
        if len(output.pcm_be) != self.frames * 4:
            raise ValueError("invalid core routed PCM size")
        self._pcm = output.pcm_be

    async def readframes(self, nframes: int) -> bytes:
        if self.closed:
            return b""
        if self._pcm is None:
            raise RuntimeError("native routing has not completed at playback barrier")
        if nframes <= 0:
            raise ValueError("positive frame count required")
        end = min(len(self._pcm), self._offset + nframes * 4)
        data = self._pcm[self._offset:end]
        self._offset = end
        self.frames_read += len(data) // 4
        return data

    async def get_metadata(self):
        return MediaMetadata(title="HomePod Flow core test", duration=self.frames / self.sample_rate)

    async def close(self):
        self.closed = True
        self._pcm = b""

    @property
    def sample_rate(self):
        return self._sample_rate

    @property
    def channels(self):
        return 2

    @property
    def sample_size(self):
        return 2

    @property
    def duration(self):
        return math.ceil(self.frames / self.sample_rate)
