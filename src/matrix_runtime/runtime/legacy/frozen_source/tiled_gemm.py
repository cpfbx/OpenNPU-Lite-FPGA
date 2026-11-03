#!/usr/bin/env python3
"""Host transaction model for arbitrary-size INT8 tiled GEMM."""

from __future__ import annotations

import argparse
import json
import time
from dataclasses import asdict, dataclass
from enum import Enum
from pathlib import Path
from typing import Iterator

import numpy as np


ALIGNMENT = 8
MAX_DIMENSION = 512
MAX_BLOCK = 64


class Layout(str, Enum):
    """Payload layout family (D006-2).

    ``ROW_MAJOR`` is the frozen D005 byte order (MODE 0x1-0x4) and must never
    change: every existing oracle and board gate depends on it.

    ``K_MAJOR`` is the D006-2 dual-operand layout (MODE 0x5/0x6).  Operands are
    stored in groups of 8 rows/cols with K as the fast axis inside a group, so
    one 64-bit AXI beat (8 lanes) spreads across the 8 banks and the PL parser
    can accept 8 bytes/cycle instead of 1 (see 06_复核修正记录.md §3 and
    rtl/axis_tile_gemm_core.sv:158-161,548-556).

    Subclassing ``str`` keeps the enum JSON-serializable so ``boundary_regression``
    output (``asdict(config)``) round-trips through ``json.dumps`` unchanged.
    """

    ROW_MAJOR = "row_major"
    K_MAJOR = "k_major"


# D006-2 frozen constants. Authoritative source: 06_复核修正记录.md §3.
#   v2 fixes BK == MAX_BLOCK == 64 (shorter K blocks are zero-padded by software);
#   the 8-element group equals ARRAY_ROWS/ARRAY_COLS of the 8x8 build, so a
#   64-bit beat's 8 lanes map 1:1 onto the 8 banks.
K_MAJOR_BK = 64
K_MAJOR_GROUP = 8
K_MAJOR_SEGMENT = K_MAJOR_BK * K_MAJOR_GROUP  # 512 bytes per 8-row/col group


def align_up(value: int, alignment: int = ALIGNMENT) -> int:
    if value < 0 or alignment <= 0 or alignment & (alignment - 1):
        raise ValueError("value must be nonnegative and alignment a positive power of two")
    return (value + alignment - 1) & -alignment


@dataclass(frozen=True)
class TileConfig:
    bm: int = 64
    bn: int = 64
    bk: int = 64
    layout: Layout = Layout.ROW_MAJOR

    def validate(self) -> None:
        for name, value in (("bm", self.bm), ("bn", self.bn), ("bk", self.bk)):
            if not 1 <= value <= 64:
                raise ValueError(f"{name} must be in range 1..64, got {value}")
        # D006-2 freezes BK == MAX_BLOCK == 64 for the K-major layout. The
        # read-path address formula stays identical to the v2 write formula only
        # under this strict equality (06 §1.1 / §3); reject anything else rather
        # than silently emitting a payload the RTL would mis-parse.
        if self.layout == Layout.K_MAJOR and self.bk != K_MAJOR_BK:
            raise ValueError(
                f"K-major layout requires bk == {K_MAJOR_BK} (BK is fixed), got {self.bk}"
            )


@dataclass(frozen=True)
class BlockLayout:
    k_offset: int
    actual_bk: int
    a_offset: int
    a_bytes: int
    b_offset: int
    b_bytes: int


@dataclass(frozen=True)
class TileTransaction:
    matrix_m: int
    matrix_n: int
    matrix_k: int
    m_offset: int
    n_offset: int
    actual_bm: int
    actual_bn: int
    config: TileConfig
    payload: bytes
    effective_input_bytes: int
    blocks: tuple[BlockLayout, ...]

    @property
    def expected_input_bytes(self) -> int:
        return len(self.payload)

    @property
    def expected_output_bytes(self) -> int:
        return self.actual_bm * self.actual_bn * 4

    @property
    def effective_macs(self) -> int:
        return self.actual_bm * self.actual_bn * self.matrix_k

    def registers(self, job_id: int, mode: int = 0) -> dict[str, int]:
        return {
            "job_id": job_id & 0xFFFFFFFF,
            "matrix_m": self.matrix_m,
            "matrix_n": self.matrix_n,
            "matrix_k": self.matrix_k,
            "m_offset": self.m_offset,
            "n_offset": self.n_offset,
            "block_mnk": self.actual_bm | (self.actual_bn << 8) | (self.config.bk << 16),
            "mode": mode & 0xFFFFFFFF,
            "expected_in_bytes": self.expected_input_bytes,
            "expected_out_bytes": self.expected_output_bytes,
        }


@dataclass(frozen=True)
class RequantizeConfig:
    scale_mult: int
    scale_shift: int
    round_enable: bool = True
    relu: bool = False
    output_zero_point: int = 0

    def validate(self) -> None:
        if not -(1 << 31) <= self.scale_mult < (1 << 31):
            raise ValueError("scale_mult must fit signed INT32")
        if not 0 <= self.scale_shift <= 31:
            raise ValueError("scale_shift must be in range 0..31")
        if not -128 <= self.output_zero_point <= 127:
            raise ValueError("output_zero_point must fit signed INT8")

    @property
    def packed_shift_config(self) -> int:
        self.validate()
        return (
            self.scale_shift
            | (int(self.round_enable) << 8)
            | (int(self.relu) << 9)
            | ((self.output_zero_point & 0xFF) << 16)
        )


@dataclass(frozen=True)
class FusedTileTransaction:
    base: TileTransaction
    requantize: RequantizeConfig
    bias: tuple[int, ...] | None
    payload: bytes
    bias_transport_bytes: int

    @property
    def m_offset(self) -> int:
        return self.base.m_offset

    @property
    def n_offset(self) -> int:
        return self.base.n_offset

    @property
    def actual_bm(self) -> int:
        return self.base.actual_bm

    @property
    def actual_bn(self) -> int:
        return self.base.actual_bn

    @property
    def config(self) -> TileConfig:
        return self.base.config

    @property
    def expected_input_bytes(self) -> int:
        return len(self.payload)

    @property
    def output_valid_bytes(self) -> int:
        return self.base.actual_bm * self.base.actual_bn

    @property
    def expected_output_bytes(self) -> int:
        return align_up(self.output_valid_bytes)

    @property
    def effective_input_bytes(self) -> int:
        bias_bytes = 0 if self.bias is None else len(self.bias) * 4
        return self.base.effective_input_bytes + bias_bytes

    @property
    def effective_macs(self) -> int:
        return self.base.effective_macs

    def registers(self, job_id: int, mode: int = 2) -> dict[str, int]:
        if mode != 2:
            raise ValueError("FusedTileTransaction requires MODE 0x2")
        values = self.base.registers(job_id, mode=mode)
        values["expected_in_bytes"] = self.expected_input_bytes
        values["expected_out_bytes"] = self.expected_output_bytes
        values["scale_mult"] = self.requantize.scale_mult & 0xFFFF_FFFF
        values["scale_shift"] = self.requantize.packed_shift_config | (
            int(self.bias is not None) << 10
        )
        return values


def _validate_inputs(a: np.ndarray, b: np.ndarray, config: TileConfig) -> tuple[int, int, int]:
    config.validate()
    if a.dtype != np.int8 or b.dtype != np.int8:
        raise TypeError("A and B must both use dtype int8")
    if a.ndim != 2 or b.ndim != 2:
        raise ValueError("A and B must both be rank-2 matrices")
    matrix_m, matrix_k = a.shape
    b_k, matrix_n = b.shape
    if matrix_k != b_k:
        raise ValueError(f"inner dimensions differ: {matrix_k} != {b_k}")
    if not all(1 <= value <= MAX_DIMENSION for value in (matrix_m, matrix_n, matrix_k)):
        raise ValueError("M, N and K must each be in range 1..512")
    return matrix_m, matrix_n, matrix_k


def _append_aligned(payload: bytearray, matrix: np.ndarray) -> tuple[int, int]:
    aligned = align_up(len(payload))
    payload.extend(b"\x00" * (aligned - len(payload)))
    raw = np.ascontiguousarray(matrix, dtype=np.int8).view(np.uint8).tobytes()
    offset = len(payload)
    payload.extend(raw)
    return offset, len(raw)


# ---------------------------------------------------------------------------
# D006-2 K-major layout (v2, MODE 0x5/0x6) -- software golden model.
#
# The frozen v2 contract (06_复核修正记录.md §3):
#     write address: addr = group*MAX_BLOCK + k        (group = row/8 or col/8)
#     bank          : lane in [0,7]                    (one beat -> 8 banks)
#     read address  : unchanged  (rtl axis_tile_gemm_core.sv:268)
#     bank depth    : unchanged (8x8 build is already 512)
#     BK            : fixed to MAX_BLOCK == 64 (tail zero-padded by software)
#     BM/BN         : rounded up to whole 8-element groups (ceil(dim/8))
#
# The read path already fetches bank[r] at address (row/8)*64 + bank_k for
# row == g*8 + r, so it expects byte (g,k,r) at bank r, address g*64 + k.
# The packers below emit exactly that, which is why the read path needs no
# change and why a beat's 8 bytes land in 8 distinct banks.
# ---------------------------------------------------------------------------


def k_major_groups(dim: int) -> int:
    """Number of 8-element bank groups after padding: ceil(dim / 8)."""
    if dim < 0:
        raise ValueError("dim must be nonnegative")
    return (dim + K_MAJOR_GROUP - 1) // K_MAJOR_GROUP


def k_major_a_bank_address(row: int, k: int) -> tuple[int, int]:
    """Reference model of the v2 A write path: (bank, address) for A[row][k].

    Mirrors rtl/axis_tile_gemm_core.sv write path: bank = row % 8,
    address = (row // 8) * MAX_BLOCK + k.  A beat holding rows g*8..g*8+7 for a
    fixed k therefore spreads its 8 bytes across banks 0..7 (no write conflict).
    """
    return row % K_MAJOR_GROUP, (row // K_MAJOR_GROUP) * K_MAJOR_BK + k


def _k_major_a_bytes(block: np.ndarray, bm: int, actual_bk: int) -> bytes:
    """Pack an A tile ``(bm x actual_bk, int8)`` into K-major byte order.

    Emit order (03 §4.3): for g in groups, for k in 0..63, for r in 0..7,
    emit A[g*8 + r][k]; positions outside ``bm``/``actual_bk`` are zero.  The
    reshape/transpose makes ``bytes[g*512 + k*8 + r] == A[g*8+r][k]``, which is
    exactly bank ``r`` at address ``g*64 + k``.
    """
    groups = k_major_groups(bm)
    padded = np.zeros((groups * K_MAJOR_GROUP, K_MAJOR_BK), dtype=np.int8)
    padded[:bm, :actual_bk] = block
    # [g, r, k] -> [g, k, r] then flatten C-order => emit (g, k, r).
    return np.transpose(
        padded.reshape(groups, K_MAJOR_GROUP, K_MAJOR_BK), (0, 2, 1)
    ).tobytes()


def _k_major_b_bytes(block: np.ndarray, bn: int, actual_bk: int) -> bytes:
    """Pack a B tile ``(actual_bk x bn, int8)`` into K-major byte order.

    Emit order (03 §4.3): for g in groups, for k in 0..63, for c in 0..7,
    emit B[k][g*8 + c]; positions outside ``bn``/``actual_bk`` are zero.
    """
    groups = k_major_groups(bn)
    padded = np.zeros((K_MAJOR_BK, groups * K_MAJOR_GROUP), dtype=np.int8)
    padded[:actual_bk, :bn] = block
    # [k, g, c] -> [g, k, c] then flatten C-order => emit (g, k, c).
    return np.transpose(
        padded.reshape(K_MAJOR_BK, groups, K_MAJOR_GROUP), (1, 0, 2)
    ).tobytes()


def _unpack_k_major_a(data: bytes, bm: int, actual_bk: int) -> np.ndarray:
    """Inverse of :func:`_k_major_a_bytes`: recover the ``(bm, actual_bk)`` tile."""
    groups = k_major_groups(bm)
    arr = np.frombuffer(data, dtype=np.int8).reshape(
        groups, K_MAJOR_BK, K_MAJOR_GROUP
    )  # [g, k, r]
    padded = np.transpose(arr, (0, 2, 1)).reshape(
        groups * K_MAJOR_GROUP, K_MAJOR_BK
    )  # [row, k]
    return padded[:bm, :actual_bk]


def _unpack_k_major_b(data: bytes, bn: int, actual_bk: int) -> np.ndarray:
    """Inverse of :func:`_k_major_b_bytes`: recover the ``(actual_bk, bn)`` tile."""
    groups = k_major_groups(bn)
    arr = np.frombuffer(data, dtype=np.int8).reshape(
        groups, K_MAJOR_BK, K_MAJOR_GROUP
    )  # [g, k, c]
    padded = np.transpose(arr, (1, 0, 2)).reshape(
        K_MAJOR_BK, groups * K_MAJOR_GROUP
    )  # [k, col]
    return padded[:actual_bk, :bn]


def _append_bytes_aligned(payload: bytearray, raw: bytes) -> tuple[int, int]:
    """Align the payload to 8 bytes, then append ``raw``; return (offset, len)."""
    aligned = align_up(len(payload))
    payload.extend(b"\x00" * (aligned - len(payload)))
    offset = len(payload)
    payload.extend(raw)
    return offset, len(raw)


def input_transport_bytes(
    block_m: int,
    block_n: int,
    block_k: int,
    matrix_k: int,
    layout: Layout,
    bias_transport_bytes: int = 0,
) -> int:
    """Single source of truth for a tile's input transport length.

    D006-2 requires the software packer, the chain-header writer, and (later)
    the RTL ``cfg_expected_in`` to all derive this length from ONE function
    rather than hand-written copies (06 §3 item 3).  The ROW_MAJOR branch is
    byte-for-byte the frozen D005 formula; the K_MAJOR branch pads every K block
    to BK=64 and BM/BN to whole 8-element groups.
    """
    if layout == Layout.ROW_MAJOR:
        cursor = bias_transport_bytes
        for k_offset in range(0, matrix_k, block_k):
            actual_bk = min(block_k, matrix_k - k_offset)
            cursor = align_up(cursor)
            cursor += block_m * actual_bk
            cursor = align_up(cursor)
            cursor += actual_bk * block_n
        return align_up(cursor)
    if layout == Layout.K_MAJOR:
        if block_k != K_MAJOR_BK:
            raise ValueError(f"K-major transport requires block_k == {K_MAJOR_BK}")
        cursor = bias_transport_bytes
        a_bytes = k_major_groups(block_m) * K_MAJOR_SEGMENT
        b_bytes = k_major_groups(block_n) * K_MAJOR_SEGMENT
        for _ in range(0, matrix_k, block_k):
            cursor = align_up(cursor)
            cursor += a_bytes
            cursor = align_up(cursor)
            cursor += b_bytes
        return align_up(cursor)
    raise ValueError(f"unknown layout {layout!r}")


def iter_transactions(
    a: np.ndarray,
    b: np.ndarray,
    config: TileConfig = TileConfig(),
) -> Iterator[TileTransaction]:
    matrix_m, matrix_n, matrix_k = _validate_inputs(a, b, config)
    if config.layout == Layout.K_MAJOR:
        yield from _iter_k_major_transactions(a, b, config, matrix_m, matrix_n, matrix_k)
        return
    # v1 row-major path (frozen D005 semantics; do not alter).
    for m_offset in range(0, matrix_m, config.bm):
        actual_bm = min(config.bm, matrix_m - m_offset)
        for n_offset in range(0, matrix_n, config.bn):
            actual_bn = min(config.bn, matrix_n - n_offset)
            payload = bytearray()
            blocks: list[BlockLayout] = []
            effective_input_bytes = 0
            for k_offset in range(0, matrix_k, config.bk):
                actual_bk = min(config.bk, matrix_k - k_offset)
                a_block = a[
                    m_offset : m_offset + actual_bm,
                    k_offset : k_offset + actual_bk,
                ]
                b_block = b[
                    k_offset : k_offset + actual_bk,
                    n_offset : n_offset + actual_bn,
                ]
                a_offset, a_bytes = _append_aligned(payload, a_block)
                b_offset, b_bytes = _append_aligned(payload, b_block)
                effective_input_bytes += a_bytes + b_bytes
                blocks.append(
                    BlockLayout(
                        k_offset=k_offset,
                        actual_bk=actual_bk,
                        a_offset=a_offset,
                        a_bytes=a_bytes,
                        b_offset=b_offset,
                        b_bytes=b_bytes,
                    )
                )
            yield TileTransaction(
                matrix_m=matrix_m,
                matrix_n=matrix_n,
                matrix_k=matrix_k,
                m_offset=m_offset,
                n_offset=n_offset,
                actual_bm=actual_bm,
                actual_bn=actual_bn,
                config=config,
                payload=bytes(payload),
                effective_input_bytes=effective_input_bytes,
                blocks=tuple(blocks),
            )


def _iter_k_major_transactions(
    a: np.ndarray,
    b: np.ndarray,
    config: TileConfig,
    matrix_m: int,
    matrix_n: int,
    matrix_k: int,
) -> Iterator[TileTransaction]:
    """K-major transaction generator (v2, MODE 0x5/0x6).

    Same tiling as v1, but A/B segments are packed K-major and every K block is
    padded to BK=64 with BM/BN rounded up to whole 8-element groups (06 §3).
    ``effective_input_bytes`` stays the logical operand bytes (unchanged from
    v1) so padding cost shows up as ``expected - effective``, not as phantom
    operand traffic.
    """
    for m_offset in range(0, matrix_m, config.bm):
        actual_bm = min(config.bm, matrix_m - m_offset)
        for n_offset in range(0, matrix_n, config.bn):
            actual_bn = min(config.bn, matrix_n - n_offset)
            payload = bytearray()
            blocks: list[BlockLayout] = []
            effective_input_bytes = 0
            a_segment = k_major_groups(actual_bm) * K_MAJOR_SEGMENT
            b_segment = k_major_groups(actual_bn) * K_MAJOR_SEGMENT
            for k_offset in range(0, matrix_k, config.bk):
                actual_bk = min(config.bk, matrix_k - k_offset)
                a_block = a[
                    m_offset : m_offset + actual_bm,
                    k_offset : k_offset + actual_bk,
                ]
                b_block = b[
                    k_offset : k_offset + actual_bk,
                    n_offset : n_offset + actual_bn,
                ]
                a_offset, a_bytes = _append_bytes_aligned(
                    payload, _k_major_a_bytes(a_block, actual_bm, actual_bk)
                )
                b_offset, b_bytes = _append_bytes_aligned(
                    payload, _k_major_b_bytes(b_block, actual_bn, actual_bk)
                )
                # Logical bytes only; the packed segments are already full-width.
                effective_input_bytes += actual_bm * actual_bk + actual_bk * actual_bn
                blocks.append(
                    BlockLayout(
                        k_offset=k_offset,
                        actual_bk=actual_bk,
                        a_offset=a_offset,
                        a_bytes=a_bytes,
                        b_offset=b_offset,
                        b_bytes=b_bytes,
                    )
                )
            yield TileTransaction(
                matrix_m=matrix_m,
                matrix_n=matrix_n,
                matrix_k=matrix_k,
                m_offset=m_offset,
                n_offset=n_offset,
                actual_bm=actual_bm,
                actual_bn=actual_bn,
                config=config,
                payload=bytes(payload),
                effective_input_bytes=effective_input_bytes,
                blocks=tuple(blocks),
            )


def emulate_transaction(transaction: TileTransaction) -> bytes:
    if transaction.config.layout == Layout.K_MAJOR:
        return _emulate_k_major_transaction(transaction)
    # v1 row-major emulation (frozen D005 semantics; do not alter).
    accumulator = np.zeros((transaction.actual_bm, transaction.actual_bn), dtype=np.int32)
    cursor = 0
    for k_offset in range(0, transaction.matrix_k, transaction.config.bk):
        actual_bk = min(transaction.config.bk, transaction.matrix_k - k_offset)
        cursor = align_up(cursor)
        a_count = transaction.actual_bm * actual_bk
        a_block = np.frombuffer(transaction.payload, dtype=np.int8, count=a_count, offset=cursor)
        a_block = a_block.reshape(transaction.actual_bm, actual_bk)
        cursor += a_count
        cursor = align_up(cursor)
        b_count = actual_bk * transaction.actual_bn
        b_block = np.frombuffer(transaction.payload, dtype=np.int8, count=b_count, offset=cursor)
        b_block = b_block.reshape(actual_bk, transaction.actual_bn)
        cursor += b_count
        accumulator += a_block.astype(np.int32) @ b_block.astype(np.int32)
    if cursor != len(transaction.payload):
        raise ValueError(f"payload has {len(transaction.payload) - cursor} trailing bytes")
    return accumulator.astype("<i4", copy=False).tobytes(order="C")


def _emulate_k_major_transaction(transaction: TileTransaction) -> bytes:
    """Golden emulation of a K-major payload (the read-path oracle).

    Mirrors the RTL read path: for each K block it strides over the padded
    A/B segments and unpacks them back into ``(bm, actual_bk)`` /
    ``(actual_bk, bn)`` tiles, accumulating the INT32 product.  The padded
    region (k >= actual_bk, or rows/cols beyond bm/bn) is sliced away here and
    is never read by the array (feed_k < actual_bk in the RTL).
    """
    accumulator = np.zeros((transaction.actual_bm, transaction.actual_bn), dtype=np.int32)
    cursor = 0
    a_segment = k_major_groups(transaction.actual_bm) * K_MAJOR_SEGMENT
    b_segment = k_major_groups(transaction.actual_bn) * K_MAJOR_SEGMENT
    for k_offset in range(0, transaction.matrix_k, transaction.config.bk):
        actual_bk = min(transaction.config.bk, transaction.matrix_k - k_offset)
        cursor = align_up(cursor)
        a_block = _unpack_k_major_a(
            transaction.payload[cursor : cursor + a_segment],
            transaction.actual_bm,
            actual_bk,
        )
        cursor += a_segment
        cursor = align_up(cursor)
        b_block = _unpack_k_major_b(
            transaction.payload[cursor : cursor + b_segment],
            transaction.actual_bn,
            actual_bk,
        )
        cursor += b_segment
        accumulator += a_block.astype(np.int32) @ b_block.astype(np.int32)
    if cursor != len(transaction.payload):
        raise ValueError(f"payload has {len(transaction.payload) - cursor} trailing bytes")
    return accumulator.astype("<i4", copy=False).tobytes(order="C")


def make_fused_transaction(
    transaction: TileTransaction,
    requantize: RequantizeConfig,
    bias: np.ndarray | None,
) -> FusedTileTransaction:
    """Build the frozen D004 MODE=2 payload for one output tile."""
    requantize.validate()
    payload = bytearray()
    bias_values: tuple[int, ...] | None = None
    bias_transport_bytes = 0
    if bias is not None:
        bias_array = np.asarray(bias)
        if bias_array.ndim != 1 or bias_array.size != transaction.actual_bn:
            raise ValueError("bias must contain one value per output-tile column")
        if not np.issubdtype(bias_array.dtype, np.integer):
            raise TypeError("bias must contain integers")
        as_object = bias_array.astype(object)
        if np.any(as_object < -(1 << 31)) or np.any(as_object >= (1 << 31)):
            raise ValueError("bias values must fit signed INT32")
        bias_i32 = bias_array.astype("<i4")
        payload.extend(bias_i32.tobytes(order="C"))
        payload.extend(b"\x00" * (align_up(len(payload)) - len(payload)))
        bias_transport_bytes = len(payload)
        bias_values = tuple(int(value) for value in bias_i32)

    payload.extend(transaction.payload)
    payload.extend(b"\x00" * (align_up(len(payload)) - len(payload)))
    return FusedTileTransaction(
        base=transaction,
        requantize=requantize,
        bias=bias_values,
        payload=bytes(payload),
        bias_transport_bytes=bias_transport_bytes,
    )


def emulate_fused_transaction(transaction: FusedTileTransaction) -> bytes:
    accumulator = np.frombuffer(
        emulate_transaction(transaction.base), dtype="<i4"
    ).reshape(transaction.base.actual_bm, transaction.base.actual_bn)
    bias = None
    if transaction.bias is not None:
        bias = np.asarray(transaction.bias, dtype=np.int32)
    valid = requantize_int8(
        accumulator,
        bias,
        transaction.requantize.scale_mult,
        transaction.requantize.scale_shift,
        round_enable=transaction.requantize.round_enable,
        relu=transaction.requantize.relu,
        output_zero_point=transaction.requantize.output_zero_point,
    ).tobytes(order="C")
    return valid + b"\x00" * (transaction.expected_output_bytes - len(valid))


def place_output(destination: np.ndarray, transaction: TileTransaction, payload: bytes) -> None:
    if len(payload) != transaction.expected_output_bytes:
        raise ValueError(
            f"output length {len(payload)} != expected {transaction.expected_output_bytes}"
        )
    block = np.frombuffer(payload, dtype="<i4").reshape(
        transaction.actual_bm, transaction.actual_bn
    )
    destination[
        transaction.m_offset : transaction.m_offset + transaction.actual_bm,
        transaction.n_offset : transaction.n_offset + transaction.actual_bn,
    ] = block


def tiled_gemm(a: np.ndarray, b: np.ndarray, config: TileConfig = TileConfig()) -> tuple[np.ndarray, list[TileTransaction]]:
    matrix_m, matrix_n, _ = _validate_inputs(a, b, config)
    result = np.zeros((matrix_m, matrix_n), dtype=np.int32)
    transactions = list(iter_transactions(a, b, config))
    for transaction in transactions:
        place_output(result, transaction, emulate_transaction(transaction))
    return result, transactions


def requantize_int8(
    accumulator: np.ndarray,
    bias: np.ndarray | None,
    scale_mult: int,
    scale_shift: int,
    *,
    round_enable: bool = True,
    relu: bool = False,
    output_zero_point: int = 0,
) -> np.ndarray:
    if accumulator.dtype != np.int32:
        raise TypeError("accumulator must use dtype int32")
    if not 0 <= scale_shift <= 31:
        raise ValueError("scale_shift must be in range 0..31")
    wide = accumulator.astype(np.int64)
    if bias is not None:
        bias_array = np.asarray(bias, dtype=np.int32)
        if bias_array.ndim != 1 or bias_array.size != accumulator.shape[-1]:
            raise ValueError("bias must be one INT32 value per output column")
        wide = wide + bias_array.astype(np.int64)
    wide *= int(scale_mult)
    if scale_shift:
        if round_enable:
            half = 1 << (scale_shift - 1)
            # Match the fixed-width RTL exactly. NumPy int64 arithmetic wraps
            # modulo 2^64 here, including the otherwise troublesome -2^63
            # corner. Applying the signed bias before one arithmetic shift is
            # also the RTL implementation of round-to-nearest, ties away from
            # zero.
            rounding_bias = np.where(wide >= 0, half, half - 1).astype(np.int64)
            wide = wide + rounding_bias
        wide >>= scale_shift
    if relu:
        wide = np.maximum(wide, 0)
    wide += int(output_zero_point)
    return np.clip(wide, -128, 127).astype(np.int8)


def boundary_regression(seed: int, config: TileConfig) -> dict:
    rng = np.random.default_rng(seed)
    dimensions = (1, 3, 4, 7, 8, 15, 16, 31)
    cases = 0
    transactions = 0
    effective_bytes = 0
    transport_bytes = 0
    started = time.perf_counter()
    for matrix_m in dimensions:
        for matrix_n in dimensions:
            for matrix_k in dimensions:
                a = rng.integers(-128, 128, size=(matrix_m, matrix_k), dtype=np.int8)
                b = rng.integers(-128, 128, size=(matrix_k, matrix_n), dtype=np.int8)
                actual, jobs = tiled_gemm(a, b, config)
                expected = a.astype(np.int32) @ b.astype(np.int32)
                if not np.array_equal(actual, expected):
                    mismatch = np.argwhere(actual != expected)[0].tolist()
                    raise AssertionError(
                        f"shape {(matrix_m, matrix_n, matrix_k)} mismatch at {mismatch}"
                    )
                cases += 1
                transactions += len(jobs)
                effective_bytes += sum(job.effective_input_bytes for job in jobs)
                transport_bytes += sum(job.expected_input_bytes for job in jobs)
    elapsed = time.perf_counter() - started
    return {
        "schema": "opennpu.tiled_gemm_host_regression.v1",
        "seed": seed,
        "dimensions": list(dimensions),
        "config": asdict(config),
        "cases": cases,
        "transactions": transactions,
        "effective_input_bytes": effective_bytes,
        "transport_input_bytes": transport_bytes,
        "alignment_overhead_bytes": transport_bytes - effective_bytes,
        "elapsed_seconds": elapsed,
        "success": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seed", type=int, default=20260908)
    parser.add_argument("--bm", type=int, default=7)
    parser.add_argument("--bn", type=int, default=7)
    parser.add_argument("--bk", type=int, default=7)
    parser.add_argument(
        "--layout",
        type=Layout,
        choices=list(Layout),
        default=Layout.ROW_MAJOR,
        help="payload layout; K-major requires --bk 64 (BK is fixed)",
    )
    parser.add_argument("--metrics", type=Path, default=Path("metrics/tiled_gemm_host_regression.json"))
    args = parser.parse_args()
    metrics = boundary_regression(args.seed, TileConfig(args.bm, args.bn, args.bk, args.layout))
    args.metrics.parent.mkdir(parents=True, exist_ok=True)
    args.metrics.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    print(
        f"PASS {metrics['cases']} shapes, {metrics['transactions']} transactions, "
        f"layout={args.layout.value}, "
        f"alignment overhead={metrics['alignment_overhead_bytes']} bytes"
    )
    print(f"Metrics: {args.metrics}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
