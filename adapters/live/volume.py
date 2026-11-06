"""Session-owned live receiver-volume control; no global device state."""
import asyncio
import math


class VolumeNotReady(RuntimeError):
    pass


class LiveVolumeControl:
    def __init__(self):
        self.connections = ()
        self.ready = False
        self.closed = False
        self.lock = asyncio.Lock()

    def bind(self, connections):
        if self.closed or self.connections or not connections:
            raise VolumeNotReady("volume group cannot be rebound")
        self.connections = tuple(connections)

    async def set_volume(self, percent):
        if type(percent) not in (int, float) or not 0 <= percent <= 100 or not math.isfinite(percent):
            raise ValueError("volume must be finite 0..100")
        async with self.lock:
            if self.closed or not self.ready or not self.connections:
                raise VolumeNotReady("live volume group is not streaming")
            # Receiver-level commands: actual acknowledgements, not software-gain
            # or a sample-exact cross-device ramp. A partial failure is fatal to
            # the group and the worker stops it rather than claiming success.
            replies = await asyncio.gather(*(asyncio.wait_for(
                connection.audio.set_volume(percent), 3) for connection in self.connections),
                return_exceptions=True)
            failures = [reply for reply in replies if isinstance(reply, BaseException)]
            if failures:
                raise RuntimeError("a receiver did not acknowledge volume") from failures[0]
            if self.closed:
                raise VolumeNotReady("live volume group closed during update")
            return len(self.connections)

    def close(self):
        self.closed = True
        self.ready = False
