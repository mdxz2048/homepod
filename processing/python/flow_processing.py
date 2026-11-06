"""Serial, bounded block binding for flow_processing ABI 1. No platform imports."""
from array import array
import ctypes as C
import math
import os


class ProcessingError(RuntimeError):
    pass


class _Device(C.Structure):
    _fields_ = [("x", C.c_float), ("y", C.c_float), ("gain", C.c_float)]


def _uint(value, label, upper=(1 << 64) - 1):
    if type(value) is not int or not 0 <= value <= upper:
        raise ValueError(label + " must be an unsigned integer in range")
    return value


def _unit(value, label):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(label + " must be a number in [0,1]")
    value = float(value)
    if not math.isfinite(value) or not 0 <= value <= 1:
        raise ValueError(label + " must be finite in [0,1]")
    return value


class Processor:
    """devices: sequence of {x, y, gain?}; mode='sync'|'cinema'.

    All coordinates normalized [0,1], screen at y=0. initial_master_gain
    defaults to ZERO, so no first-block full-volume transient. A new session
    starts frame0. One caller serializes controls and processing. No final
    duration, epoch or network clock is invented by this library.
    """
    def __init__(self, library, devices, mode="sync", listener=(0.5, 0.7),
                 max_frames=4096, initial_master_gain=0.0):
        self._handle = None
        self.next_frame = 0
        if mode not in ("sync", "cinema"):
            raise ValueError("mode must be sync or cinema")
        if not 1 <= len(devices) <= 8:
            raise ValueError("one to eight devices required")
        self.device_count = len(devices)
        self.max_frames = _uint(max_frames, "max_frames", 65536)
        if not self.max_frames:
            raise ValueError("max_frames must be positive")
        if len(listener) != 2:
            raise ValueError("listener must have x,y")
        lx, ly = (_unit(v, "listener coordinate") for v in listener)
        master = _unit(initial_master_gain, "initial_master_gain")
        configs = (_Device * len(devices))(*[
            _Device(_unit(d["x"], "device x"), _unit(d["y"], "device y"),
                    _unit(d.get("gain", 1.0), "device gain")) for d in devices])
        self._lib = C.CDLL(os.fspath(library))
        lib = self._lib
        lib.flow_processing_version.argtypes = []
        lib.flow_processing_version.restype = C.c_uint32
        if lib.flow_processing_version() != 1:
            raise ProcessingError("unsupported processing ABI")
        lib.flow_processing_create.argtypes = [C.c_uint32, C.POINTER(_Device), C.c_uint32,
            C.c_float, C.c_float, C.c_uint32, C.c_float]
        lib.flow_processing_create.restype = C.c_void_p
        lib.flow_processing_set_gain.argtypes = [C.c_void_p, C.c_int32, C.c_float, C.c_uint64, C.c_uint32]
        lib.flow_processing_set_gain.restype = C.c_int32
        lib.flow_processing_process.argtypes = [C.c_void_p, C.c_uint64, C.POINTER(C.c_float),
            C.c_uint64, C.POINTER(C.c_float), C.c_uint64]
        lib.flow_processing_process.restype = C.c_int32
        lib.flow_processing_matrix.argtypes = [C.c_void_p, C.POINTER(C.c_float), C.c_uint32]
        lib.flow_processing_matrix.restype = C.c_int32
        lib.flow_processing_last_error.argtypes = [C.c_void_p]
        lib.flow_processing_last_error.restype = C.c_char_p
        lib.flow_processing_destroy.argtypes = [C.c_void_p]
        lib.flow_processing_destroy.restype = None
        self._handle = lib.flow_processing_create(mode == "cinema", configs, len(devices),
                                                  lx, ly, self.max_frames, master)
        if not self._handle:
            raise ProcessingError("processor creation rejected configuration or allocation")

    def _check(self, status):
        if status:
            raise ProcessingError("processing status %d: %s" % (status,
                self._lib.flow_processing_last_error(self._handle).decode("utf-8", "replace")))

    def _require_open(self):
        if not self._handle:
            raise ProcessingError("processor closed")

    def set_gain(self, target, output_index=-1, effective_frame=None, ramp_frames=882):
        self._require_open()
        target = _unit(target, "target gain")
        if type(output_index) is not int or not -1 <= output_index < self.device_count:
            raise ValueError("invalid output_index")
        frame = self.next_frame if effective_frame is None else _uint(effective_frame, "effective_frame")
        _uint(ramp_frames, "ramp_frames", 441000)
        if ramp_frames < 882:
            raise ValueError("ramp must last at least 20ms (882 frames)")
        self._check(self._lib.flow_processing_set_gain(self._handle, output_index, target, frame, ramp_frames))

    def process(self, stereo, first_frame=None):
        self._require_open()
        if not isinstance(stereo, array) or stereo.typecode != "f" or stereo.itemsize != 4:
            raise TypeError("stereo must be native array('f') with 32-bit items")
        if not stereo or len(stereo) % 2 or len(stereo) // 2 > self.max_frames:
            raise ValueError("nonempty bounded interleaved stereo block required")
        frame = self.next_frame if first_frame is None else _uint(first_frame, "first_frame")
        result = array("f", [0.0]) * (len(stereo) * self.device_count)
        source = (C.c_float * len(stereo)).from_buffer(stereo)
        output = (C.c_float * len(result)).from_buffer(result)
        self._check(self._lib.flow_processing_process(self._handle, frame, source,
                                                     len(stereo), output, len(result)))
        self.next_frame = frame + len(stereo) // 2
        return result

    @property
    def matrix(self):
        self._require_open()
        out = (C.c_float * (4 * self.device_count))()
        self._check(self._lib.flow_processing_matrix(self._handle, out, len(out)))
        return [tuple(out[d*4:d*4+4]) for d in range(self.device_count)]

    def close(self):
        if self._handle:
            self._lib.flow_processing_destroy(self._handle)
            self._handle = None

    def __enter__(self):
        self._require_open()
        return self

    def __exit__(self, *_):
        self.close()

    def __del__(self):
        self.close()
