"""Frozen D005-A 64-byte stream-header and chained-payload software contract."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Iterable

from tiled_gemm import (
    FusedTileTransaction,
    K_MAJOR_BK,
    Layout,
    TileTransaction,
    align_up,
    input_transport_bytes,
)


CHAIN_MAGIC = 0x4F4E5055
# Protocol V2 (D006-2): version 2 identifies the K-major layout; version 1 is
# the frozen D005 header.  The header byte count stays 64 for both.
CHAIN_VERSION_V1 = 1
CHAIN_VERSION_V2 = 2
CHAIN_VERSION = CHAIN_VERSION_V1  # backward-compat alias (default v1)
CHAIN_HEADER_BYTES = 64
CHAIN_HEADER = struct.Struct("<16I")

FLAG_FUSED = 1 << 0
FLAG_BIAS = 1 << 1
FLAG_RELU = 1 << 2
FLAG_ROUND = 1 << 3
FLAG_SATURATE = 1 << 4
FLAG_K_MAJOR = 1 << 5
# FLAG_B_RESIDENT = 1 << 6  # reserved for D006-3; NOT accepted yet (see below)
FLAG_CHAIN_LAST = 1 << 31
# FLAG_B_RESIDENT is deliberately omitted from KNOWN_FLAGS until D006-3 lands:
# an unimplmented flag must be rejected as "unknown" rather than silently
# accepted and ignored.
KNOWN_FLAGS = (
    FLAG_FUSED
    | FLAG_BIAS
    | FLAG_RELU
    | FLAG_ROUND
    | FLAG_SATURATE
    | FLAG_K_MAJOR
    | FLAG_CHAIN_LAST
)

# MODE enumeration (spec v3.2 §3 + D006 03 §4.1).  MODE is an enum, not a bit
# field.  0x5/0x6 are the chain-only K-major modes added by D006-2.
MODE_LEGACY_INT32 = 0x1
MODE_LEGACY_FUSED = 0x2
MODE_CHAIN_INT32 = 0x3
MODE_CHAIN_FUSED = 0x4
MODE_CHAIN_INT32_K_MAJOR = 0x5
MODE_CHAIN_FUSED_K_MAJOR = 0x6

# PL error code for layout/version mismatch (03 §4.1): a v2 payload fed to a v1
# mode, or vice versa.  The driver must recognise it; the software side prevents
# it by checking CAPABILITIES/BUILD_ID before transfer.
PL_ERROR_LAYOUT_MISMATCH = 0x0D

Transaction = TileTransaction | FusedTileTransaction


@dataclass(frozen=True)
class ChainHeaderFields:
    version: int
    job_id: int
    flags: int
    matrix_m: int
    matrix_n: int
    matrix_k: int
    m_offset: int
    n_offset: int
    block_m: int
    block_n: int
    block_k: int
    input_transport_bytes: int
    output_valid_bytes: int
    output_transport_bytes: int
    scale_mult: int
    scale_shift: int
    round_enable: bool
    output_zero_point: int
    bias_transport_bytes: int

    @property
    def fused(self) -> bool:
        return bool(self.flags & FLAG_FUSED)

    @property
    def k_major(self) -> bool:
        return self.version == CHAIN_VERSION_V2

    @property
    def chain_last(self) -> bool:
        return bool(self.flags & FLAG_CHAIN_LAST)


@dataclass(frozen=True)
class ChainRecord:
    header: ChainHeaderFields
    header_bytes: bytes
    payload: bytes

    @property
    def bytes(self) -> bytes:
        return self.header_bytes + self.payload


def _base(transaction: Transaction) -> TileTransaction:
    return transaction.base if isinstance(transaction, FusedTileTransaction) else transaction


def _payload(transaction: Transaction) -> bytes:
    payload = transaction.payload
    return payload + bytes(align_up(len(payload)) - len(payload))


def _expected_input_bytes(fields: ChainHeaderFields) -> int:
    # Single length function (tiled_gemm.input_transport_bytes) is the sole
    # source of truth for both layouts, per 06 §3 item 3.
    layout = Layout.K_MAJOR if fields.k_major else Layout.ROW_MAJOR
    return input_transport_bytes(
        fields.block_m,
        fields.block_n,
        fields.block_k,
        fields.matrix_k,
        layout,
        bias_transport_bytes=fields.bias_transport_bytes,
    )


def build_chain_record(
    transaction: Transaction, job_id: int, *, chain_last: bool
) -> ChainRecord:
    base = _base(transaction)
    payload = _payload(transaction)
    fused = isinstance(transaction, FusedTileTransaction)
    layout = base.config.layout
    version = CHAIN_VERSION_V2 if layout == Layout.K_MAJOR else CHAIN_VERSION_V1
    flags = FLAG_CHAIN_LAST if chain_last else 0
    if layout == Layout.K_MAJOR:
        flags |= FLAG_K_MAJOR
    scale_mult = 0
    scale_shift_cfg = 0
    bias_transport_bytes = 0
    if fused:
        flags |= FLAG_FUSED | FLAG_SATURATE
        if transaction.bias is not None:
            flags |= FLAG_BIAS
        if transaction.requantize.relu:
            flags |= FLAG_RELU
        if transaction.requantize.round_enable:
            flags |= FLAG_ROUND
        scale_mult = transaction.requantize.scale_mult & 0xFFFF_FFFF
        scale_shift_cfg = (
            transaction.requantize.scale_shift
            | (int(transaction.requantize.round_enable) << 8)
            | ((transaction.requantize.output_zero_point & 0xFF) << 16)
        )
        bias_transport_bytes = transaction.bias_transport_bytes
        output_valid_bytes = transaction.output_valid_bytes
    else:
        output_valid_bytes = base.expected_output_bytes
    output_transport_bytes = align_up(output_valid_bytes)
    words = (
        CHAIN_MAGIC,
        version | (CHAIN_HEADER_BYTES << 16),
        job_id & 0xFFFF_FFFF,
        flags,
        base.matrix_m,
        base.matrix_n,
        base.matrix_k,
        base.m_offset,
        base.n_offset,
        base.actual_bm | (base.actual_bn << 8) | (base.config.bk << 16),
        len(payload),
        output_valid_bytes,
        output_transport_bytes,
        scale_mult,
        scale_shift_cfg,
        bias_transport_bytes,
    )
    header_bytes = CHAIN_HEADER.pack(*words)
    header = parse_chain_header(header_bytes)
    if len(payload) != header.input_transport_bytes:
        raise AssertionError("packed payload length differs from chain header")
    return ChainRecord(header=header, header_bytes=header_bytes, payload=payload)


def parse_chain_header(data: bytes) -> ChainHeaderFields:
    if len(data) != CHAIN_HEADER_BYTES:
        raise ValueError(f"chain header must be exactly {CHAIN_HEADER_BYTES} bytes")
    words = CHAIN_HEADER.unpack(data)
    magic, version_header = words[:2]
    version = version_header & 0xFFFF
    header_bytes = version_header >> 16
    if magic != CHAIN_MAGIC:
        raise ValueError("invalid chain magic")
    if version not in (CHAIN_VERSION_V1, CHAIN_VERSION_V2) or header_bytes != CHAIN_HEADER_BYTES:
        raise ValueError("unsupported chain header version or length")
    flags = words[3]
    if flags & ~KNOWN_FLAGS:
        raise ValueError("chain header has unknown flags")
    block_mnk = words[9]
    block_m = block_mnk & 0xFF
    block_n = (block_mnk >> 8) & 0xFF
    block_k = (block_mnk >> 16) & 0xFF
    if block_mnk >> 24:
        raise ValueError("reserved block_mnk bits must be zero")
    shift_cfg = words[14]
    if shift_cfg & ~0x00FF_01FF:
        raise ValueError("reserved scale_shift_cfg bits must be zero")
    zero_u8 = (shift_cfg >> 16) & 0xFF
    zero_point = zero_u8 - 256 if zero_u8 >= 128 else zero_u8
    scale_mult = words[13]
    scale_mult = scale_mult - (1 << 32) if scale_mult & (1 << 31) else scale_mult
    fields = ChainHeaderFields(
        version=version,
        job_id=words[2],
        flags=flags,
        matrix_m=words[4],
        matrix_n=words[5],
        matrix_k=words[6],
        m_offset=words[7],
        n_offset=words[8],
        block_m=block_m,
        block_n=block_n,
        block_k=block_k,
        input_transport_bytes=words[10],
        output_valid_bytes=words[11],
        output_transport_bytes=words[12],
        scale_mult=scale_mult,
        scale_shift=shift_cfg & 0xFF,
        round_enable=bool(shift_cfg & (1 << 8)),
        output_zero_point=zero_point,
        bias_transport_bytes=words[15],
    )
    _validate_header(fields)
    return fields


def _validate_header(fields: ChainHeaderFields) -> None:
    if fields.k_major and not fields.flags & FLAG_K_MAJOR:
        raise ValueError("version 2 chain header requires the K_MAJOR flag")
    if not fields.k_major and fields.flags & FLAG_K_MAJOR:
        raise ValueError("version 1 chain header must not set the K_MAJOR flag")
    if not all(1 <= value <= 512 for value in (fields.matrix_m, fields.matrix_n, fields.matrix_k)):
        raise ValueError("chain matrix dimensions must be in range 1..512")
    if not all(1 <= value <= 64 for value in (fields.block_m, fields.block_n, fields.block_k)):
        raise ValueError("chain block dimensions must be in range 1..64")
    if fields.k_major and fields.block_k != K_MAJOR_BK:
        raise ValueError(f"K-major chain jobs require block_k == {K_MAJOR_BK}")
    if fields.m_offset + fields.block_m > fields.matrix_m:
        raise ValueError("chain M tile exceeds matrix bounds")
    if fields.n_offset + fields.block_n > fields.matrix_n:
        raise ValueError("chain N tile exceeds matrix bounds")
    expected_output_valid = fields.block_m * fields.block_n * (1 if fields.fused else 4)
    if fields.output_valid_bytes != expected_output_valid:
        raise ValueError("chain output valid length mismatch")
    if fields.output_transport_bytes != align_up(expected_output_valid):
        raise ValueError("chain output transport length mismatch")
    if fields.input_transport_bytes != _expected_input_bytes(fields):
        raise ValueError("chain input transport length mismatch")
    if fields.fused:
        if not fields.flags & FLAG_SATURATE:
            raise ValueError("fused chain jobs require saturation")
        expected_bias = align_up(fields.block_n * 4) if fields.flags & FLAG_BIAS else 0
        if fields.bias_transport_bytes != expected_bias:
            raise ValueError("chain bias transport length mismatch")
        if not 0 <= fields.scale_shift <= 31:
            raise ValueError("chain scale shift must be in range 0..31")
    elif (
        fields.flags & (FLAG_BIAS | FLAG_RELU | FLAG_ROUND | FLAG_SATURATE)
        or fields.scale_mult
        or fields.scale_shift
        or fields.round_enable
        or fields.output_zero_point
        or fields.bias_transport_bytes
    ):
        raise ValueError("non-fused chain job contains fused-only fields")


def pack_chain(transactions: Iterable[Transaction], first_job_id: int = 1) -> tuple[bytes, list[ChainRecord]]:
    jobs = list(transactions)
    if not jobs:
        raise ValueError("a chain must contain at least one transaction")
    records = [
        build_chain_record(
            transaction,
            (first_job_id + index) & 0xFFFF_FFFF,
            chain_last=index == len(jobs) - 1,
        )
        for index, transaction in enumerate(jobs)
    ]
    return b"".join(record.bytes for record in records), records


def split_chain_output(payload: bytes, records: Iterable[ChainRecord]) -> list[bytes]:
    """Split one padded S2MM frame into per-job valid output payloads.

    D005 keeps every intermediate job on a full 64-bit AXI beat so AXI DMA
    Simple Mode never sees a partial TKEEP before the global TLAST.  The
    returned byte strings omit that transport padding and therefore match the
    legacy per-tile software oracles directly.
    """
    jobs = list(records)
    expected_bytes = sum(job.header.output_transport_bytes for job in jobs)
    if len(payload) != expected_bytes:
        raise ValueError(
            f"chain output length {len(payload)} != expected {expected_bytes}"
        )
    outputs: list[bytes] = []
    cursor = 0
    for job in jobs:
        transport_end = cursor + job.header.output_transport_bytes
        valid_end = cursor + job.header.output_valid_bytes
        padding = payload[valid_end:transport_end]
        if padding != bytes(len(padding)):
            raise ValueError(f"chain output job {len(outputs)} has nonzero padding")
        outputs.append(payload[cursor:valid_end])
        cursor = transport_end
    return outputs
