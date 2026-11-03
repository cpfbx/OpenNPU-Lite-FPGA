#!/usr/bin/env python3
"""Read-only, bounded exact PC comparison of raw row-major signed INT8 GEMM."""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys

MAX_MACS = 2_000_000
INT32_MAX = 2**31 - 1


def checked_shape(shape):
    if not isinstance(shape, (tuple, list)) or len(shape) != 3:
        raise ValueError("shape must be M,N,K")
    if any(type(d) is not int or d <= 0 for d in shape):
        raise ValueError("dimensions must be positive non-boolean integers")
    m, n, k = shape
    if k * 16384 > INT32_MAX:
        raise ValueError("full signed INT8 domain may overflow mathematical INT32")
    if m * n * k > MAX_MACS:
        raise ValueError(f"PC example limited to {MAX_MACS} MACs; use approved project oracle")
    return m, n, k


def read_exact(path, count):
    path = Path(path)
    if not path.is_file() or path.stat().st_size != count:
        raise ValueError("input missing, nonregular or wrong byte length")
    with path.open("rb") as source:
        data = source.read(count + 1)
    if len(data) != count:
        raise ValueError("input length changed during read")
    return data


def compare(a_path, b_path, output_path, shape):
    m, n, k = checked_shape(shape)
    a_raw = read_exact(a_path, m * k)
    b_raw = read_exact(b_path, k * n)
    c_raw = read_exact(output_path, m * n * 4)
    a = [v if v < 128 else v - 256 for v in a_raw]
    b = [v if v < 128 else v - 256 for v in b_raw]
    mismatches = 0
    first = None
    for row in range(m):
        for col in range(n):
            expected = sum(a[row * k + t] * b[t * n + col] for t in range(k))
            actual = struct.unpack_from("<i", c_raw, 4 * (row * n + col))[0]
            if expected != actual:
                mismatches += 1
                if first is None:
                    first = {"row": row, "column": col, "expected": expected, "actual": actual}
    return {
        "check_scope": "bounded_pc_raw_row_major_gemm",
        "evidence_class": "offline_input_files_origin_unverified",
        "shape_mnk": [m, n, k],
        "effective_macs": m * n * k,
        "checked_positions": m * n,
        "mismatches": mismatches,
        "first_mismatch": first,
        "exact": mismatches == 0,
        "input_sha256": {key: hashlib.sha256(data).hexdigest()
                         for key, data in (("a", a_raw), ("b", b_raw), ("c", c_raw))},
        "hardware_execution_verified": False,
        "performance_verified": False,
    }


def parse_shape(value):
    return checked_shape(tuple(int(x) for x in value.split(",")))


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise ValueError("argument parsing: " + message)


def main():
    parser = JsonArgumentParser(description=__doc__)
    parser.add_argument("--a", type=Path, required=True)
    parser.add_argument("--b", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--shape", required=True)
    try:
        args = parser.parse_args()
        result = compare(args.a, args.b, args.output, parse_shape(args.shape))
    except (OSError, ValueError, struct.error) as exc:
        print(json.dumps({"input_valid": False, "error": str(exc)}), file=sys.stderr)
        return 2
    print(json.dumps(result, allow_nan=False, sort_keys=True))
    return 0 if result["exact"] else 1


if __name__ == "__main__":
    sys.exit(main())
