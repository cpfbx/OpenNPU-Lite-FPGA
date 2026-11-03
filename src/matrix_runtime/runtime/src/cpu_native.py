"""Pinned existing ARM OpenBLAS wrapper; runtime guard BEFORE any native library load."""
import hashlib
import importlib.util
from pathlib import Path
import platform
import sys

LIB_SHA='a1ee68685946287785a55e07fb60089441252676fc78ee1756a28c3f5de29c3b'
SOURCE_SHA='42a5ac0fe3b2d0cf4ea8471df3593f2cb407528f7e8cb7c758dc6fbad1571a27'


def native_compute(root,*,enabled=False):
    if enabled is not True:raise ValueError('ARM native CPU default-off')
    if (platform.system()!='Linux' or platform.machine()!='armv7l' or sys.byteorder!='little'
            or platform.release()!='6.6.10-xilinx-v2024.1-g3c0eca68c652'):
        raise RuntimeError('exact original ARM runtime only; no PC fallback')
    root=Path(root).absolute();source=root/'runtime_cpu/blas_candidate.py'
    if hashlib.sha256(source.read_bytes()).hexdigest()!=SOURCE_SHA:raise ValueError('frozen CPU wrapper drift')
    # The enclosing binding verifies the WHOLE package and no-alias tree first.
    spec=importlib.util.spec_from_file_location('comparison_native_blas',source)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module.BlasCandidate(root/'runtime_cpu/libmatrix_blas_arm.so',LIB_SHA,
                                threads=2,target='arm',enabled=True)
