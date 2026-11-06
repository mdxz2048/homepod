"""ctypes binding for flow/bridge.h ABI v1. No network or audio side effects."""
from __future__ import annotations

import array
import ctypes as C
from dataclasses import dataclass
from pathlib import Path

OK, INVALID_ARGUMENT, INVALID_STATE, UNSUPPORTED = range(4)
PREPARE_FAILED, WOULD_BLOCK, TRANSPORT_FAILED, TIMESTAMP_DISCONTINUITY, INTERNAL_ERROR = range(4, 9)


class CoreError(RuntimeError):
    def __init__(self, code: int, message: str):
        self.code = code
        super().__init__(f"core status {code}: {message}")


@dataclass(frozen=True)
class RoutedBlock:
    output_id: int
    sample_rate: int
    channels: int
    epoch: int
    first_frame: int
    presentation_ns: int
    samples: array.array


class CaptureOutput:
    """Finite owned queue. Clear on close; enqueue refuses to exceed sample cap."""
    def __init__(self, max_samples: int):
        if max_samples <= 0:
            raise ValueError("positive sample cap required")
        self.max_samples = max_samples
        self.blocks: list[RoutedBlock] = []
        self.sample_count = 0
        self.open = False

    def prepare(self, sample_rate: int, channels: int) -> int:
        self.blocks.clear()
        self.sample_count = 0
        self.open = True
        return OK

    def enqueue(self, block: RoutedBlock) -> int:
        if not self.open:
            return TRANSPORT_FAILED
        if self.sample_count + len(block.samples) > self.max_samples:
            return WOULD_BLOCK
        self.blocks.append(block)
        self.sample_count += len(block.samples)
        return OK

    def close(self) -> None:
        self.blocks.clear()
        self.sample_count = 0
        self.open = False


PrepareFn = C.CFUNCTYPE(C.c_int32, C.c_void_p, C.c_uint32, C.c_uint32, C.c_uint32)
EnqueueFn = C.CFUNCTYPE(C.c_int32, C.c_void_p, C.c_uint32, C.c_uint32, C.c_uint32,
                      C.c_uint64, C.c_uint64, C.c_int64, C.POINTER(C.c_float), C.c_uint64)
CloseFn = C.CFUNCTYPE(None, C.c_void_p, C.c_uint32)


def _unsigned(value: int, bits: int, name: str) -> int:
    if not isinstance(value, int) or not 0 <= value < 1 << bits:
        raise ValueError(f"{name} must fit uint{bits}")
    return value


def _signed64(value: int, name: str) -> int:
    if not isinstance(value, int) or not -(1 << 63) <= value < 1 << 63:
        raise ValueError(f"{name} must fit int64")
    return value


class Engine:
    """Serialized host API; callback owners remain alive until destroy returns."""
    def __init__(self, library: str | Path, sample_rate: int, channels: int):
        self._handle = None
        _unsigned(sample_rate, 32, "sample_rate")
        _unsigned(channels, 32, "channels")
        self.lib = C.CDLL(str(Path(library).resolve(strict=True)))
        lib = self.lib
        lib.flow_v1_abi_version.argtypes = []
        lib.flow_v1_abi_version.restype = C.c_uint32
        if lib.flow_v1_abi_version() != 1:
            raise RuntimeError("unsupported Flow ABI version")
        lib.flow_v1_create.argtypes = [C.c_uint32, C.c_uint32, PrepareFn, EnqueueFn, CloseFn, C.c_void_p]
        lib.flow_v1_create.restype = C.c_void_p
        lib.flow_v1_add_output.argtypes = [C.c_void_p, C.c_uint32, C.POINTER(C.c_uint32), C.c_uint32, C.c_uint32]
        lib.flow_v1_prepare.argtypes = [C.c_void_p]
        lib.flow_v1_start.argtypes = [C.c_void_p, C.c_uint64, C.c_int64, C.c_int64, C.POINTER(C.c_int64)]
        lib.flow_v1_submit.argtypes = [C.c_void_p, C.c_uint64, C.c_uint64, C.POINTER(C.c_float), C.c_uint64]
        lib.flow_v1_stop.argtypes = [C.c_void_p]
        lib.flow_v1_destroy.argtypes = [C.c_void_p]
        lib.flow_v1_destroy.restype = None
        lib.flow_v1_last_error.argtypes = [C.c_void_p]
        lib.flow_v1_last_error.restype = C.c_char_p
        for name in ("add_output", "prepare", "start", "submit", "stop"):
            getattr(lib, "flow_v1_" + name).restype = C.c_int32
        self.outputs: dict[int, object] = {}
        self.callback_error = ""

        def status_code(value):
            if type(value) is not int or not OK <= value <= INTERNAL_ERROR:
                raise ValueError("output callback must return a Flow integer status")
            return value

        def prepare(_user, output_id, rate, count):
            try:
                return status_code(self.outputs[output_id].prepare(rate, count))
            except BaseException as exc:
                self.callback_error = repr(exc)
                return PREPARE_FAILED

        def enqueue(_user, output_id, rate, count, epoch, first, presentation, samples, length):
            try:
                owned = array.array("f")
                owned.frombytes(C.string_at(samples, length * C.sizeof(C.c_float)))
                block = RoutedBlock(output_id, rate, count, epoch, first, presentation, owned)
                return status_code(self.outputs[output_id].enqueue(block))
            except BaseException as exc:
                self.callback_error = repr(exc)
                return TRANSPORT_FAILED

        def close(_user, output_id):
            try:
                self.outputs[output_id].close()
            except BaseException as exc:
                # close cannot propagate through a C callback; retain diagnostic.
                self.callback_error = repr(exc)

        self._callbacks = (PrepareFn(prepare), EnqueueFn(enqueue), CloseFn(close))
        self._handle = lib.flow_v1_create(sample_rate, channels, *self._callbacks, None)
        if not self._handle:
            raise CoreError(INVALID_ARGUMENT, "create failed: format, callbacks or allocation")

    def _check(self, code: int) -> None:
        if code:
            detail = self.lib.flow_v1_last_error(self._handle).decode("utf-8", "replace")
            if self.callback_error:
                detail += "; callback: " + self.callback_error
            raise CoreError(code, detail)

    def _require_open(self) -> None:
        if not self._handle:
            raise CoreError(INVALID_STATE, "engine destroyed")

    def add_output(self, output_id: int, channels: list[int], output, scheduled=True) -> None:
        self._require_open()
        _unsigned(output_id, 32, "output_id")
        if output_id in self.outputs:
            raise ValueError("duplicate output id")
        if any(existing is output for existing in self.outputs.values()):
            raise ValueError("same output object cannot own multiple routes")
        mapped = [_unsigned(ch, 32, "channel") for ch in channels]
        values = (C.c_uint32 * len(mapped))(*mapped)
        self._check(self.lib.flow_v1_add_output(self._handle, output_id, values, len(mapped), int(scheduled)))
        self.outputs[output_id] = output

    def prepare(self) -> None:
        self._require_open()
        self._check(self.lib.flow_v1_prepare(self._handle))

    def start(self, epoch: int, now_ns: int, lead_ns: int) -> int:
        self._require_open()
        _unsigned(epoch, 64, "epoch")
        _signed64(now_ns, "now_ns")
        _signed64(lead_ns, "lead_ns")
        origin = C.c_int64()
        self._check(self.lib.flow_v1_start(self._handle, epoch, now_ns, lead_ns, C.byref(origin)))
        return origin.value

    def submit(self, epoch: int, first_frame: int, samples) -> None:
        self._require_open()
        _unsigned(epoch, 64, "epoch")
        _unsigned(first_frame, 64, "first_frame")
        owned = samples if isinstance(samples, array.array) and samples.typecode == "f" else array.array("f", samples)
        if owned.itemsize != 4:
            raise RuntimeError("native float32 array required")
        values = (C.c_float * len(owned)).from_buffer(owned)
        self._check(self.lib.flow_v1_submit(self._handle, epoch, first_frame, values, len(owned)))

    def stop(self) -> None:
        self._require_open()
        self._check(self.lib.flow_v1_stop(self._handle))

    def close(self) -> None:
        if self._handle:
            self.lib.flow_v1_destroy(self._handle)
            self._handle = None

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def __del__(self):
        self.close()
