"""Opt-in isolated CPU baseline; no board runner, fallback or system install.

Inputs must be plain owning C-contiguous INT8 arrays in this first candidate.
The caller exclusively owns them for the complete call. No online INT64 oracle;
input/output conversions, allocation and thread selection are all timed by the
outer experiment. Persistent FP32 workspaces cache NO operand values.
"""
import ctypes
import hashlib
import os
from pathlib import Path
import platform
import struct
import threading

import numpy as np

_CALL_LOCK = threading.Lock()


def inputs(a, b):
    for value in (a, b):
        if type(value) is not np.ndarray or value.dtype != np.int8:
            raise TypeError('plain INT8 NumPy operands required')
        if (value.ndim != 2 or not value.flags.owndata or not value.flags.c_contiguous
                or any(not 1 <= x <= 512 for x in value.shape)):
            raise ValueError('owning C-contiguous rank-2 operands, dimensions 1..512 required')
    if a.shape[1] != b.shape[0]:
        raise ValueError('matching K required')
    if np.shares_memory(a, b):
        raise ValueError('independent input allocations required')
    return a.shape[0], b.shape[1], a.shape[1]


class BlasCandidate:
    def __init__(self, library, expected_sha256, *, threads, enabled=False, target='arm'):
        if enabled is not True:
            raise ValueError('CPU candidate default-off')
        if type(threads) is not int or threads not in (1, 2):
            raise ValueError('explicit one/two threads required')
        if target not in ('arm', 'pc'):
            raise ValueError('explicit supported target required')
        arm = target == 'arm'
        if (platform.system() != 'Linux' or struct.pack('=I', 1) != b'\x01\0\0\0'
                or ctypes.sizeof(ctypes.c_void_p) != (4 if arm else 8)
                or platform.machine() not in (('armv7l',) if arm else ('x86_64',))):
            raise RuntimeError('explicit target runtime mismatch; no fallback')
        path = Path(library).resolve(strict=True)
        data = path.read_bytes()
        if (type(expected_sha256) is not str or len(expected_sha256) != 64
                or hashlib.sha256(data).hexdigest() != expected_sha256):
            raise ValueError('exact library SHA required')
        if len(data) < 52 or data[:7] != b'\x7fELF' + bytes((1 if arm else 2, 1, 1)):
            raise ValueError('target ELF class/endian mismatch')
        kind, machine = struct.unpack_from('<HH', data, 16)
        if kind != 3 or machine != (40 if arm else 62):
            raise ValueError('target ELF machine/type mismatch')
        if arm:
            flags = struct.unpack_from('<I', data, 36)[0]
            if flags & 0xff000000 != 0x05000000 or not flags & 0x400 or flags & 0x200:
                raise ValueError('ARM EABI5 hard-float required')
        lib = ctypes.CDLL(str(path), mode=ctypes.RTLD_LOCAL)
        lib.opennpu_blas_abi.argtypes = []; lib.opennpu_blas_abi.restype = ctypes.c_uint32
        for name in ('opennpu_blas_config', 'opennpu_blas_core'):
            fn = getattr(lib, name); fn.argtypes = []; fn.restype = ctypes.c_char_p
        lib.opennpu_blas_parallel.argtypes = []; lib.opennpu_blas_parallel.restype = ctypes.c_int
        config = lib.opennpu_blas_config().decode('ascii')
        core = lib.opennpu_blas_core().decode('ascii')
        if (lib.opennpu_blas_abi() != 1 or not config.startswith('OpenBLAS 0.3.28 ')
                or 'MAX_THREADS=2' not in config or lib.opennpu_blas_parallel() != 1
                or core != ('CORTEXA9' if arm else 'generic')):
            raise ValueError('pinned CPU library ABI/configuration mismatch')
        ptr, size, u32 = ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32
        lib.opennpu_blas_gemm.argtypes = [ptr, size, ptr, size, u32, u32, u32,
                                         ptr, size, ptr, size, ptr, size, ptr, size, u32]
        lib.opennpu_blas_gemm.restype = ctypes.c_int
        self._lib = lib; self._threads = threads; self._owner = os.getpid(), threading.get_ident()
        self._failed = False
        self._scratch = tuple(np.empty(512*512, np.float32) for _ in range(3))
        self.identity = dict(library_sha256=expected_sha256, config=config, core=core,
                             configured_threads=threads, target=target, pc_fixture=not arm,
                             promotion=False, numerical_oracle_inside_call=False)

    def __call__(self, a, b):
        if (os.getpid(), threading.get_ident()) != self._owner:
            raise RuntimeError('CPU candidate process/thread ownership drift')
        if self._failed:
            raise RuntimeError('CPU candidate faulted; no automatic retry')
        if not _CALL_LOCK.acquire(blocking=False):
            raise RuntimeError('CPU library busy; no parallel measurements')
        try:
            m, n, k = inputs(a, b)
            output = np.empty((m, n), np.int32)
            fa, fb, fc = self._scratch
            if any(np.shares_memory(x, y) for x in (a, b, output) for y in self._scratch):
                raise ValueError('CPU workspace aliases request')
            code = self._lib.opennpu_blas_gemm(a.ctypes.data, a.nbytes, b.ctypes.data, b.nbytes,
                m, n, k, fa.ctypes.data, fa.nbytes, fb.ctypes.data, fb.nbytes,
                fc.ctypes.data, fc.nbytes, output.ctypes.data, output.nbytes, self._threads)
            if code:
                raise RuntimeError('CPU GEMM refused/failed with code ' + str(code))
            return output
        except BaseException:
            self._failed = True
            raise
        finally:
            _CALL_LOCK.release()
