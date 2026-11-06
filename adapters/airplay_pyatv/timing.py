"""Finite-session timing plan audited against pyatv 0.18.0 RAOP internals.

These are protocol targets, never evidence of acoustic synchronization.
All monotonic values belong to the host-supplied clock domain.
"""
from dataclasses import dataclass

_BILLION = 1_000_000_000
_NTP_SCALE = 1 << 32
_NTP_EPOCH_OFFSET = 2_208_988_800
_INT64_MAX = (1 << 63) - 1


class LateStartError(ValueError):
    """The group can no longer safely use its fixed start plan."""


def _nonnegative_integer(name: str, value: int) -> None:
    if type(value) is not int or value < 0:
        raise ValueError(f"{name} must be a nonnegative integer")


def ntp_from_unix_ns(unix_ns: int) -> int:
    """Convert a wall-clock snapshot using integers, before freezing the anchor."""
    _nonnegative_integer("unix_ns", unix_ns)
    seconds, fraction_ns = divmod(unix_ns, _BILLION)
    return ((seconds + _NTP_EPOCH_OFFSET) << 32) + fraction_ns * _NTP_SCALE // _BILLION


@dataclass(frozen=True)
class TimingPlan:
    presentation_ns: int
    send_origin_ns: int
    ntp_send_origin: int
    start_ts: int
    sample_rate: int
    latency_samples: int

    def assert_ready(self, now_ns: int, guard_ns: int = 50_000_000) -> None:
        """Call after rendering and preparation, before releasing any stream."""
        _nonnegative_integer("now_ns", now_ns)
        _nonnegative_integer("guard_ns", guard_ns)
        if now_ns > self.send_origin_ns - guard_ns:
            raise LateStartError("group missed pre-release readiness deadline")

    def assert_release(self, now_ns: int, tolerance_ns: int = 20_000_000) -> None:
        """After waiting for send_origin, reject an excessively late release.

        This method does not sleep; the caller must wait until send_origin.
        Early calls are invalid, so a future target cannot accidentally send now.
        """
        _nonnegative_integer("now_ns", now_ns)
        _nonnegative_integer("tolerance_ns", tolerance_ns)
        if now_ns < self.send_origin_ns:
            raise ValueError("release before common send origin")
        if now_ns > self.send_origin_ns + tolerance_ns:
            raise LateStartError("group missed common send origin")


def build_timing_plan(presentation_ns: int, mono_anchor_ns: int, ntp_anchor: int,
                      sample_rate: int, latency_samples: int) -> TimingPlan:
    """Map native core's expected playback origin to pyatv's send/sync origin.

    pyatv emits first audio RTP=latency, while its sync maps RTP=0 to
    ts2ntp(start_ts). Hence the sync/send origin precedes playback by latency/R.
    start_ts uses exactly pyatv's ntp2ts truncation, not a guessed conversion.
    """
    for name, value in (("presentation_ns", presentation_ns),
                        ("mono_anchor_ns", mono_anchor_ns), ("ntp_anchor", ntp_anchor),
                        ("sample_rate", sample_rate), ("latency_samples", latency_samples)):
        _nonnegative_integer(name, value)
    if sample_rate == 0:
        raise ValueError("sample_rate must be positive")
    if presentation_ns > _INT64_MAX or mono_anchor_ns > _INT64_MAX:
        raise ValueError("monotonic timestamp exceeds native int64 domain")
    send_origin_ns = presentation_ns - latency_samples * _BILLION // sample_rate
    if send_origin_ns < 0:
        raise ValueError("latency exceeds nonnegative presentation origin")
    ntp_send_origin = ntp_anchor + (send_origin_ns - mono_anchor_ns) * _NTP_SCALE // _BILLION
    if ntp_send_origin < 0:
        raise ValueError("mapped NTP origin is negative")
    start_ts = ((ntp_send_origin >> 16) * sample_rate) >> 16
    return TimingPlan(presentation_ns, send_origin_ns, ntp_send_origin, start_ts,
                      sample_rate, latency_samples)
