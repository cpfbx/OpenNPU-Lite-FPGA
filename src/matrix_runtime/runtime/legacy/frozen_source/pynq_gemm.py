#!/usr/bin/env python3
"""PYNQ-Z2 functional acceptance driver for the OpenNPU-Lite GEMM overlay.

The PYNQ imports stay inside :class:`PynqGemm` so register generation and
metric aggregation remain unit-testable on a normal development PC.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import socket
import sys
import time
from dataclasses import asdict
from pathlib import Path
from typing import TYPE_CHECKING, Any

import numpy as np

from chain_protocol import ChainRecord, pack_chain
if TYPE_CHECKING:
    from prepared_chain import PreparedDenseChain
from d007_mode11_contract import validate_summary as validate_mode11_counters
from pynq_dma_loopback import (
    CONTROL_CLEAR_ERROR,
    CONTROL_SOFT_RESET,
    CONTROL_START,
    REG_BUILD_ID,
    REG_CAPABILITIES,
    REG_CONTROL,
    REG_ERROR_CODE,
    REG_INPUT_STALL,
    REG_JOB_ID,
    REG_OUTPUT_STALL,
    REG_STATUS,
    STATUS_DONE,
    STATUS_ERROR,
    STATUS_IDLE,
    file_sha256,
    read_u64,
    resolve_overlay_object,
    select_ip_key,
    try_git_commit,
    wait_until,
    reset_simple_dma,
)
from tiled_gemm import (
    FusedTileTransaction,
    Layout,
    TileConfig,
    TileTransaction,
    emulate_transaction,
    iter_transactions,
    place_output,
)


REG_M = 0x10
REG_N = 0x14
REG_K = 0x18
REG_M_OFFSET = 0x1C
REG_N_OFFSET = 0x20
REG_BLOCK_MNK = 0x24
REG_MODE = 0x28
REG_SCALE_MULT = 0x2C
REG_SCALE_SHIFT = 0x30
REG_EXPECTED_IN = 0x34
REG_EXPECTED_OUT = 0x38
REG_TOTAL_LO = 0x40
REG_TOTAL_HI = 0x44
REG_COMPUTE_LO = 0x48
REG_COMPUTE_HI = 0x4C
REG_MACS_LO = 0x58
REG_MACS_HI = 0x5C
REG_FAILED_TILE = 0x68
REG_CHAIN_JOBS = 0x6C
REG_RECEIVE_LO = 0x70
REG_RECEIVE_HI = 0x74
REG_CLEAR_LO = 0x78
REG_CLEAR_HI = 0x7C
REG_ARRAY_LO = 0x80
REG_ARRAY_HI = 0x84
REG_STORE_LO = 0x88
REG_STORE_HI = 0x8C
REG_OUTPUT_LO = 0x90
REG_OUTPUT_HI = 0x94
REG_TRANSITION_LO = 0x98
REG_TRANSITION_HI = 0x9C
REG_D7_LOAD_WORK_LO = 0x0A0
REG_D7_LOAD_WORK_HI = 0x0A4
REG_D7_ARRAY_WORK_LO = 0x0A8
REG_D7_ARRAY_WORK_HI = 0x0AC
REG_D7_STORE_WORK_LO = 0x0B0
REG_D7_STORE_WORK_HI = 0x0B4
REG_D7_OUTPUT_WORK_LO = 0x0B8
REG_D7_OUTPUT_WORK_HI = 0x0BC
REG_D7_WORK_UNION_LO = 0x0C0
REG_D7_WORK_UNION_HI = 0x0C4
REG_D7_OVERLAP_LO = 0x0C8
REG_D7_OVERLAP_HI = 0x0CC
REG_D7_NO_WORK_LO = 0x0D0
REG_D7_NO_WORK_HI = 0x0D4
REG_D7_LOAD_STALL_LO = 0x0D8
REG_D7_LOAD_STALL_HI = 0x0DC
REG_D7_ARRAY_STALL_LO = 0x0E0
REG_D7_ARRAY_STALL_HI = 0x0E4
REG_D7_STORE_STALL_LO = 0x0E8
REG_D7_STORE_STALL_HI = 0x0EC
REG_D7_OUTPUT_STALL_LO = 0x0F0
REG_D7_OUTPUT_STALL_HI = 0x0F4
REG_D7_LOAD_ARRAY_LO = 0x0F8
REG_D7_LOAD_ARRAY_HI = 0x0FC
REG_D7_ARRAY_STORE_LO = 0x100
REG_D7_ARRAY_STORE_HI = 0x104
REG_D7_ARRAY_WAIT_LO = 0x108
REG_D7_ARRAY_WAIT_HI = 0x10C
REG_D7_BANK_WAIT_LO = 0x110
REG_D7_BANK_WAIT_HI = 0x114
REG_D7_STORE_WAIT_LO = 0x118
REG_D7_STORE_WAIT_HI = 0x11C
REG_D7_TREADY_WAIT_LO = 0x120
REG_D7_TREADY_WAIT_HI = 0x124
REG_D7_MAX_FIFO = 0x128
REG_D7_CONTRACT = 0x12C
REG_D7_ARRAY_OUTPUT_LO = 0x130
REG_D7_ARRAY_OUTPUT_HI = 0x134

MODE_OS_INT32 = 0x0000_0001
MODE_OS_INT8_FUSED = 0x0000_0002
MODE_CHAIN_INT32 = 0x0000_0003
MODE_CHAIN_INT8_FUSED = 0x0000_0004
MODE_CHAIN_INT32_K_MAJOR = 0x0000_0005
MODE_CHAIN_INT8_FUSED_K_MAJOR = 0x0000_0006
MODE_CHAIN_INT32_K_MAJOR_DECOUPLED = 0x0000_0007
MODE_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE = 0x0000_0009
MODE_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH = 0x0000_000A
MODE_CHAIN_INT32_K_MAJOR_DUAL_C = 0x0000_000B
CAPABILITY_OS_INT32 = 1 << 1
CAPABILITY_FUSED_INT8 = 1 << 2
CAPABILITY_CHAIN_INT32 = 1 << 3
CAPABILITY_CHAIN_FUSED_INT8 = 1 << 4
CAPABILITY_CHAIN_INT32_K_MAJOR = 1 << 5
CAPABILITY_CHAIN_FUSED_INT8_K_MAJOR = 1 << 6
CAPABILITY_CHAIN_INT32_K_MAJOR_DECOUPLED = 1 << 7
CAPABILITY_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE = 1 << 9
CAPABILITY_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH = 1 << 10
CAPABILITY_CHAIN_INT32_K_MAJOR_DUAL_C = 1 << 11
DEFAULT_CLOCK_HZ = 100_000_000
LEGACY_PHASE_COUNTER_FIELDS = (
    "pl_receive_parse_cycles",
    "pl_clear_c_cycles",
    "pl_array_phase_cycles",
    "pl_store_c_cycles",
    "pl_output_drain_cycles",
    "pl_transition_cycles",
)
D007_PIPELINE_COUNTER_FIELDS = (
    "pl_load_work_cycles",
    "pl_array_work_cycles",
    "pl_store_work_cycles",
    "pl_output_work_cycles",
    "pl_work_union_cycles",
    "pl_overlap_credit_cycles",
    "pl_no_work_cycles",
    "pl_load_stall_cycles",
    "pl_array_stall_cycles",
    "pl_store_stall_cycles",
    "pl_output_engine_stall_cycles",
    "pl_load_array_work_overlap_cycles",
    "pl_array_store_work_overlap_cycles",
)
# 2026-09-11: packed output plus single-port C-BRAM read.
EXPECTED_GEMM_BUILD_IDS = {
    0x2026D001,
    0x2026D003,
    0x2026D004,
    0x2026D005,
    0x2026D006,
    0x2026D007,
    0x2026D072,
    0x2026D073,
    0x2026D074,
    0x2026D075,
}


REGISTER_OFFSETS = {
    "job_id": REG_JOB_ID,
    "matrix_m": REG_M,
    "matrix_n": REG_N,
    "matrix_k": REG_K,
    "m_offset": REG_M_OFFSET,
    "n_offset": REG_N_OFFSET,
    "block_mnk": REG_BLOCK_MNK,
    "mode": REG_MODE,
    "scale_mult": REG_SCALE_MULT,
    "scale_shift": REG_SCALE_SHIFT,
    "expected_in_bytes": REG_EXPECTED_IN,
    "expected_out_bytes": REG_EXPECTED_OUT,
}


def transaction_register_writes(
    transaction: TileTransaction | FusedTileTransaction, job_id: int
) -> list[tuple[int, int]]:
    """Return the complete, ordered register program for one tile transaction."""
    base = transaction.base if isinstance(transaction, FusedTileTransaction) else transaction
    if base.config.layout != Layout.ROW_MAJOR:
        raise ValueError("K-major transactions are supported only by chain MODE 5/6")
    mode = MODE_OS_INT8_FUSED if isinstance(transaction, FusedTileTransaction) else MODE_OS_INT32
    values = transaction.registers(job_id, mode=mode)
    return [(REGISTER_OFFSETS[name], value) for name, value in values.items()]


def chain_execution_contract(
    transactions: list[TileTransaction | FusedTileTransaction],
) -> tuple[bool, bool, int, int]:
    """Return ``(fused, k_major, mode, capability)`` for a homogeneous chain."""
    if not transactions:
        raise ValueError("a chain must contain at least one transaction")
    fused = isinstance(transactions[0], FusedTileTransaction)
    if any(isinstance(job, FusedTileTransaction) != fused for job in transactions):
        raise ValueError("a chain cannot mix dense and fused transactions")
    layouts = {
        (job.base if isinstance(job, FusedTileTransaction) else job).config.layout
        for job in transactions
    }
    if len(layouts) != 1:
        raise ValueError("a chain cannot mix row-major and K-major layouts")
    k_major = next(iter(layouts)) == Layout.K_MAJOR
    if k_major:
        mode = (
            MODE_CHAIN_INT8_FUSED_K_MAJOR
            if fused
            else MODE_CHAIN_INT32_K_MAJOR
        )
        capability = (
            CAPABILITY_CHAIN_FUSED_INT8_K_MAJOR
            if fused
            else CAPABILITY_CHAIN_INT32_K_MAJOR
        )
    else:
        mode = MODE_CHAIN_INT8_FUSED if fused else MODE_CHAIN_INT32
        capability = (
            CAPABILITY_CHAIN_FUSED_INT8 if fused else CAPABILITY_CHAIN_INT32
        )
    return fused, k_major, mode, capability


def compare_payload(actual: bytes, expected: bytes, label: str) -> None:
    if len(actual) != len(expected):
        raise AssertionError(
            f"{label}: output length {len(actual)} != expected {len(expected)}"
        )
    actual_array = np.frombuffer(actual, dtype=np.uint8)
    expected_array = np.frombuffer(expected, dtype=np.uint8)
    mismatch = np.flatnonzero(actual_array != expected_array)
    if mismatch.size:
        byte_index = int(mismatch[0])
        element_index = byte_index // 4
        actual_i32 = np.frombuffer(actual, dtype="<i4")
        expected_i32 = np.frombuffer(expected, dtype="<i4")
        raise AssertionError(
            f"{label}: INT32 mismatch at element {element_index}: "
            f"expected={int(expected_i32[element_index])}, "
            f"actual={int(actual_i32[element_index])}; "
            f"mismatching_bytes={mismatch.size}"
        )


def compare_fused_payload(
    actual: bytes, expected: bytes, valid_bytes: int, label: str
) -> None:
    if len(actual) != len(expected):
        raise AssertionError(
            f"{label}: output length {len(actual)} != expected {len(expected)}"
        )
    if not 0 <= valid_bytes <= len(expected):
        raise ValueError("valid_bytes is outside the payload")
    mismatch = np.flatnonzero(
        np.frombuffer(actual[:valid_bytes], dtype=np.uint8)
        != np.frombuffer(expected[:valid_bytes], dtype=np.uint8)
    )
    if mismatch.size:
        index = int(mismatch[0])
        raise AssertionError(
            f"{label}: INT8 mismatch at element {index}: "
            f"expected={int(np.frombuffer(expected[:valid_bytes], dtype=np.int8)[index])}, "
            f"actual={int(np.frombuffer(actual[:valid_bytes], dtype=np.int8)[index])}"
        )
    if actual[valid_bytes:] != bytes(len(actual) - valid_bytes):
        raise AssertionError(f"{label}: nonzero fused-output padding")


def summarize_transactions(
    runs: list[dict[str, Any]], clock_hz: int = DEFAULT_CLOCK_HZ
) -> dict[str, Any]:
    if not runs:
        return {
            "transactions": 0,
            "effective_macs": 0,
            "dma_pl_wall_seconds": 0.0,
            "dma_pl_wall_gmac_s": 0.0,
            "pl_total_cycles": 0,
            "pl_compute_accounted_cycles": 0,
            "pl_total_gmac_s": 0.0,
            "pl_compute_accounted_gmac_s": 0.0,
        }
    macs = sum(int(run["effective_macs"]) for run in runs)
    wall_seconds = sum(float(run["seconds"]) for run in runs)
    total_cycles = sum(int(run["pl_total_cycles"]) for run in runs)
    compute_cycles = sum(int(run["pl_compute_accounted_cycles"]) for run in runs)

    def rate(seconds: float) -> float:
        return macs / seconds / 1_000_000_000.0 if seconds > 0 else 0.0

    result = {
        "transactions": len(runs),
        "input_transport_bytes": sum(int(run["input_bytes"]) for run in runs),
        "input_effective_bytes": sum(int(run["effective_input_bytes"]) for run in runs),
        "output_bytes": sum(int(run["output_bytes"]) for run in runs),
        "effective_macs": macs,
        "dma_pl_wall_seconds": wall_seconds,
        "dma_pl_wall_gmac_s": rate(wall_seconds),
        "pl_total_cycles": total_cycles,
        "pl_compute_accounted_cycles": compute_cycles,
        "pl_total_gmac_s": rate(total_cycles / clock_hz),
        "pl_compute_accounted_gmac_s": rate(compute_cycles / clock_hz),
    }
    versions = {int(run.get("counter_contract_version", 0)) for run in runs}
    if 2 in versions:
        if versions != {2}:
            raise ValueError("MODE11 v2 and legacy counter windows cannot be aggregated together")
        fields = (
            "pl_load_work_cycles", "pl_array_work_cycles", "pl_store_work_cycles",
            "pl_output_work_cycles", "pl_work_union_cycles", "pl_overlap_credit_cycles",
            "pl_no_work_cycles", "pl_array_output_work_overlap_cycles",
            "pl_compute_wait_bank_cycles", "pl_output_wait_tready_cycles",
        )
        for run in runs:
            if not all(validate_mode11_counters(run).values()):
                raise ValueError("invalid MODE11 v2 counters")
        result.update({field: sum(int(run[field]) for run in runs) for field in fields})
        result["counter_contract_version"] = 2
        result["counter_contract"] = "d007_global_work_v2"
        return result
    result["pl_input_stall_cycles"] = sum(int(run["pl_input_stall_cycles"]) for run in runs)
    result["pl_output_stall_cycles"] = sum(int(run["pl_output_stall_cycles"]) for run in runs)
    if all(all(field in run for field in LEGACY_PHASE_COUNTER_FIELDS) for run in runs):
        for field in LEGACY_PHASE_COUNTER_FIELDS:
            result[field] = sum(int(run[field]) for run in runs)
        result["pl_phase_sum_cycles"] = sum(
            int(result[field]) for field in LEGACY_PHASE_COUNTER_FIELDS
        )
        result["pl_phase_accounting_delta_cycles"] = (
            total_cycles - int(result["pl_phase_sum_cycles"])
        )
        result["counter_contract"] = "legacy_six_phase_v1"
    if all(all(field in run for field in D007_PIPELINE_COUNTER_FIELDS) for run in runs):
        for field in D007_PIPELINE_COUNTER_FIELDS:
            result[field] = sum(int(run[field]) for run in runs)
        versions = {int(run.get("counter_contract_version", -1)) for run in runs}
        if len(versions) != 1:
            raise ValueError("D007 counter contract versions differ between transactions")
        result["counter_contract_version"] = versions.pop()
        result["counter_contract"] = "d007_parallel_work_v1"
        for engine in ("load", "array", "store", "output"):
            stall_field = (
                "pl_output_engine_stall_cycles"
                if engine == "output"
                else f"pl_{engine}_stall_cycles"
            )
            result[f"pl_{engine}_idle_cycles"] = (
                total_cycles
                - int(result[f"pl_{engine}_work_cycles"])
                - int(result[stall_field])
            )
        result["pl_work_union_delta_cycles"] = (
            sum(int(result[f"pl_{engine}_work_cycles"]) for engine in (
                "load", "array", "store", "output"
            ))
            - int(result["pl_work_union_cycles"])
            - int(result["pl_overlap_credit_cycles"])
        )
        result["pl_total_union_delta_cycles"] = (
            total_cycles
            - int(result["pl_work_union_cycles"])
            - int(result["pl_no_work_cycles"])
        )
    return result


def summarize_host_profile(runs: list[dict[str, Any]]) -> dict[str, Any]:
    """Aggregate optional per-transaction host timing probes without inventing zeros."""
    profiles = [run["host_profile"] for run in runs if "host_profile" in run]
    if not profiles:
        return {"profiled_transactions": 0, "totals_seconds": {}, "means_seconds": {}}
    fields = tuple(profiles[0])
    if any(tuple(profile) != fields for profile in profiles):
        raise ValueError("host profile fields differ between transactions")
    totals = {
        field: sum(float(profile[field]) for profile in profiles) for field in fields
    }
    return {
        "profiled_transactions": len(profiles),
        "totals_seconds": totals,
        "means_seconds": {
            field: total / len(profiles) for field, total in totals.items()
        },
    }


def summarize_cases(runs: list[dict[str, Any]]) -> dict[str, Any]:
    """Summarize full host cases, including packing, DMA, and verification."""
    macs = sum(int(run["effective_macs"]) for run in runs)
    seconds = sum(float(run["seconds"]) for run in runs)
    return {
        "iterations": len(runs),
        "effective_macs": macs,
        "end_to_end_seconds": seconds,
        "end_to_end_gmac_s": macs / seconds / 1_000_000_000.0 if seconds > 0 else 0.0,
    }


class PynqGemm:
    def __init__(self, bit_path: Path) -> None:
        try:
            import pynq
            from pynq import MMIO, Overlay, allocate
        except ImportError as exc:
            raise RuntimeError("Run this driver on a PYNQ Linux image with pynq installed") from exc

        self._pynq = pynq
        self._allocate = allocate
        self.overlay = Overlay(str(bit_path), download=True)
        dma_key = select_ip_key(self.overlay.ip_dict, "axi_dma", "axi_dma")
        accel_key = select_ip_key(self.overlay.ip_dict, "accel")
        self.dma = resolve_overlay_object(self.overlay, dma_key)
        accel_info = self.overlay.ip_dict[accel_key]
        self.mmio = MMIO(int(accel_info["phys_addr"]), int(accel_info["addr_range"]))

        self.build_id = int(self.mmio.read(REG_BUILD_ID))
        self.capabilities = int(self.mmio.read(REG_CAPABILITIES))
        if self.build_id not in EXPECTED_GEMM_BUILD_IDS:
            raise RuntimeError(
                f"RTL/driver mismatch: build_id=0x{self.build_id:08x}, "
                f"expected one of "
                f"{', '.join(f'0x{x:08x}' for x in sorted(EXPECTED_GEMM_BUILD_IDS))}"
            )
        if not self.capabilities & CAPABILITY_OS_INT32:
            raise RuntimeError(
                f"Overlay does not advertise OS+INT32 capability: 0x{self.capabilities:08x}"
            )
        if self.build_id == 0x2026D075 and self.capabilities != 0x00080EFE:
            raise RuntimeError("MODE11 candidate capability/build identity mismatch")
        self.mmio.write(REG_CONTROL, CONTROL_SOFT_RESET)
        wait_until(
            lambda: bool(int(self.mmio.read(REG_STATUS)) & STATUS_IDLE),
            1.0,
            "accelerator reset to IDLE",
        )

    @property
    def pynq_version(self) -> str:
        return str(getattr(self._pynq, "__version__", "unknown"))

    def allocate_buffers(self, input_bytes: int, output_bytes: int) -> tuple[Any, Any]:
        input_buffer = self._allocate(shape=(input_bytes,), dtype=np.uint8)
        try:
            output_buffer = self._allocate(shape=(output_bytes,), dtype=np.uint8)
        except BaseException:
            # A failed second allocation must not leak the first CMA buffer.
            if hasattr(input_buffer, "freebuffer"):
                input_buffer.freebuffer()
            elif hasattr(input_buffer, "close"):
                input_buffer.close()
            raise
        return input_buffer, output_buffer

    def _recover(self) -> dict[str, Any]:
        """Reset DMA and accelerator without PYNQ's unbounded start loop."""
        try:
            return reset_simple_dma(self.dma)
        finally:
            self.mmio.write(REG_CONTROL, CONTROL_SOFT_RESET)

    def _read_phase_counters(self) -> dict[str, int]:
        return {
            "pl_receive_parse_cycles": read_u64(
                self.mmio, REG_RECEIVE_LO, REG_RECEIVE_HI
            ),
            "pl_clear_c_cycles": read_u64(self.mmio, REG_CLEAR_LO, REG_CLEAR_HI),
            "pl_array_phase_cycles": read_u64(
                self.mmio, REG_ARRAY_LO, REG_ARRAY_HI
            ),
            "pl_store_c_cycles": read_u64(self.mmio, REG_STORE_LO, REG_STORE_HI),
            "pl_output_drain_cycles": read_u64(
                self.mmio, REG_OUTPUT_LO, REG_OUTPUT_HI
            ),
            "pl_transition_cycles": read_u64(
                self.mmio, REG_TRANSITION_LO, REG_TRANSITION_HI
            ),
        }

    def _read_d007_counters(self) -> dict[str, int]:
        pairs = {
            "pl_load_work_cycles": (REG_D7_LOAD_WORK_LO, REG_D7_LOAD_WORK_HI),
            "pl_array_work_cycles": (REG_D7_ARRAY_WORK_LO, REG_D7_ARRAY_WORK_HI),
            "pl_store_work_cycles": (REG_D7_STORE_WORK_LO, REG_D7_STORE_WORK_HI),
            "pl_output_work_cycles": (REG_D7_OUTPUT_WORK_LO, REG_D7_OUTPUT_WORK_HI),
            "pl_work_union_cycles": (REG_D7_WORK_UNION_LO, REG_D7_WORK_UNION_HI),
            "pl_overlap_credit_cycles": (REG_D7_OVERLAP_LO, REG_D7_OVERLAP_HI),
            "pl_no_work_cycles": (REG_D7_NO_WORK_LO, REG_D7_NO_WORK_HI),
            "pl_load_stall_cycles": (REG_D7_LOAD_STALL_LO, REG_D7_LOAD_STALL_HI),
            "pl_array_stall_cycles": (REG_D7_ARRAY_STALL_LO, REG_D7_ARRAY_STALL_HI),
            "pl_store_stall_cycles": (REG_D7_STORE_STALL_LO, REG_D7_STORE_STALL_HI),
            "pl_output_engine_stall_cycles": (
                REG_D7_OUTPUT_STALL_LO, REG_D7_OUTPUT_STALL_HI
            ),
            "pl_load_array_work_overlap_cycles": (
                REG_D7_LOAD_ARRAY_LO, REG_D7_LOAD_ARRAY_HI
            ),
            "pl_array_store_work_overlap_cycles": (
                REG_D7_ARRAY_STORE_LO, REG_D7_ARRAY_STORE_HI
            ),
            "pl_array_wait_result_slot_cycles": (
                REG_D7_ARRAY_WAIT_LO, REG_D7_ARRAY_WAIT_HI
            ),
            "pl_compute_wait_bank_cycles": (
                REG_D7_BANK_WAIT_LO, REG_D7_BANK_WAIT_HI
            ),
            "pl_store_wait_result_cycles": (
                REG_D7_STORE_WAIT_LO, REG_D7_STORE_WAIT_HI
            ),
            "pl_output_wait_tready_cycles": (
                REG_D7_TREADY_WAIT_LO, REG_D7_TREADY_WAIT_HI
            ),
        }
        result = {
            name: read_u64(self.mmio, low, high)
            for name, (low, high) in pairs.items()
        }
        result["pl_max_result_fifo_occupancy"] = int(
            self.mmio.read(REG_D7_MAX_FIFO)
        )
        result["counter_contract_version"] = int(
            self.mmio.read(REG_D7_CONTRACT)
        )
        return result

    def _mode11_word_reader(self):
        # Cache only the mapping/whitelist, NEVER counter values.
        if (getattr(self, "_mode11_reader_source", None) is not self.mmio
                or getattr(self, "_mode11_reader_array", None) is not self.mmio.array):
            from counter_word_reader import CounterWordReader
            offsets = tuple(globals()[f"REG_D7_{name}_{half}"]
                for name in ("LOAD_WORK", "ARRAY_WORK", "STORE_WORK", "OUTPUT_WORK",
                             "WORK_UNION", "OVERLAP", "NO_WORK", "ARRAY_OUTPUT",
                             "BANK_WAIT", "TREADY_WAIT") for half in ("LO", "HI")) + (REG_D7_CONTRACT,)
            reader = CounterWordReader(self.mmio, offsets)
            self._mode11_reader = reader
            self._mode11_reader_source = self.mmio
            self._mode11_reader_array = self.mmio.array
        else:
            # Identity alone misses in-place dtype/shape/stride/address changes
            # or a device/capability change. Reject these before arming DMA and
            # again at the completed-counter group boundary.
            self._mode11_reader.validate_mapping(self.mmio)
        return self._mode11_reader

    def _read_mode11_counters(self, total_cycles: int, *, fast_counter_reads: bool = False) -> dict[str, int]:
        if type(fast_counter_reads) is not bool:
            raise ValueError("fast_counter_reads must be a boolean")
        counter_mmio = self._mode11_word_reader() if fast_counter_reads else self.mmio
        pairs = {
            "pl_load_work_cycles": (REG_D7_LOAD_WORK_LO, REG_D7_LOAD_WORK_HI),
            "pl_array_work_cycles": (REG_D7_ARRAY_WORK_LO, REG_D7_ARRAY_WORK_HI),
            "pl_store_work_cycles": (REG_D7_STORE_WORK_LO, REG_D7_STORE_WORK_HI),
            "pl_output_work_cycles": (REG_D7_OUTPUT_WORK_LO, REG_D7_OUTPUT_WORK_HI),
            "pl_work_union_cycles": (REG_D7_WORK_UNION_LO, REG_D7_WORK_UNION_HI),
            "pl_overlap_credit_cycles": (REG_D7_OVERLAP_LO, REG_D7_OVERLAP_HI),
            "pl_no_work_cycles": (REG_D7_NO_WORK_LO, REG_D7_NO_WORK_HI),
            "pl_array_output_work_overlap_cycles": (REG_D7_ARRAY_OUTPUT_LO, REG_D7_ARRAY_OUTPUT_HI),
            "pl_compute_wait_bank_cycles": (REG_D7_BANK_WAIT_LO, REG_D7_BANK_WAIT_HI),
            "pl_output_wait_tready_cycles": (REG_D7_TREADY_WAIT_LO, REG_D7_TREADY_WAIT_HI),
        }
        result = {name: read_u64(counter_mmio, low, high)
                  for name, (low, high) in pairs.items()}
        result["counter_contract_version"] = int(counter_mmio.read(REG_D7_CONTRACT))
        gates = validate_mode11_counters({**result, "pl_total_cycles": total_cycles})
        if not all(gates.values()):
            raise AssertionError(f"MODE11 counter contract failed: {gates}")
        return result

    def run_chain(
        self,
        transactions: list[TileTransaction | FusedTileTransaction],
        input_buffer: Any,
        output_buffer: Any,
        first_job_id: int,
        timeout_s: float,
        launch_order: str = "dma-first",
        profile_host: bool = False,
        mode_override: int | None = None,
        fast_counter_reads: bool = False,
    ) -> tuple[bytes, list[ChainRecord], dict[str, Any]]:
        """Execute one homogeneous v1/v2 chain with one transfer per DMA channel."""
        fused, k_major, chain_mode, capability = chain_execution_contract(
            transactions
        )
        if mode_override is not None:
            if mode_override not in (
                MODE_CHAIN_INT32_K_MAJOR_DECOUPLED,
                MODE_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE,
                MODE_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH,
                MODE_CHAIN_INT32_K_MAJOR_DUAL_C,
            ):
                raise ValueError(f"unsupported chain mode override {mode_override}")
            if fused or not k_major:
                raise ValueError("MODE 7/9/10/11 requires a dense K-major chain")
            chain_mode = mode_override
            capability = {
                MODE_CHAIN_INT32_K_MAJOR_DECOUPLED:
                    CAPABILITY_CHAIN_INT32_K_MAJOR_DECOUPLED,
                MODE_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE:
                    CAPABILITY_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE,
                MODE_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH:
                    CAPABILITY_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH,
                MODE_CHAIN_INT32_K_MAJOR_DUAL_C:
                    CAPABILITY_CHAIN_INT32_K_MAJOR_DUAL_C,
            }[mode_override]
        if type(fast_counter_reads) is not bool:
            raise ValueError("fast_counter_reads must be a boolean")
        if fast_counter_reads:
            if chain_mode != MODE_CHAIN_INT32_K_MAJOR_DUAL_C:
                raise ValueError("fast counter reads require MODE11")
            self._mode11_word_reader()  # Reject unsupported storage before DMA.
        if not self.capabilities & capability:
            label = ("K-major " if k_major else "") + (
                "fused INT8" if fused else "INT32"
            )
            raise RuntimeError(
                f"Overlay does not advertise chained {label} capability: "
                f"0x{self.capabilities:08x}"
            )

        chain_payload, records = pack_chain(
            transactions, first_job_id=first_job_id
        )
        input_bytes = len(chain_payload)
        output_bytes = sum(record.header.output_transport_bytes for record in records)
        if input_bytes > input_buffer.size or output_bytes > output_buffer.size:
            raise ValueError("allocated DMA buffers are too small for this chain")

        return self._submit_chain(
            chain_payload, records, transactions, input_buffer, output_buffer,
            first_job_id, timeout_s, launch_order, profile_host, chain_mode, k_major,
            fast_counter_reads=fast_counter_reads,
        )

    def run_prepared_chain(
        self, prepared: PreparedDenseChain, input_buffer: Any, output_buffer: Any,
        first_job_id: int, timeout_s: float, launch_order: str = "dma-first",
        profile_host: bool = False, mode_override: int | None = None,
    ) -> tuple[bytes, dict[str, Any]]:
        """Submit a dense immutable packet without rebuilding records or frame.

        All rejection checks below precede MMIO writes/cache operations/DMA arm.
        Original-array numerical validation remains the caller's responsibility.
        """
        # Do not add a runtime import dependency to legacy-only driver packages.
        from prepared_chain import validate_prepared_dense_chain

        validation_started = time.perf_counter() if profile_host else 0.0
        validate_prepared_dense_chain(prepared)
        if type(first_job_id) is not int or first_job_id != prepared.first_job_id:
            raise ValueError("prepared first_job_id differs from this invocation")
        if (isinstance(timeout_s, bool) or not isinstance(timeout_s, (int, float))
                or not math.isfinite(timeout_s) or timeout_s <= 0):
            raise ValueError("timeout must be finite and positive")
        if launch_order not in ("dma-first", "pl-first"):
            raise ValueError("unsupported launch order")
        chain_mode = MODE_CHAIN_INT32_K_MAJOR if prepared.k_major else MODE_CHAIN_INT32
        capabilities = {
            MODE_CHAIN_INT32: CAPABILITY_CHAIN_INT32,
            MODE_CHAIN_INT32_K_MAJOR: CAPABILITY_CHAIN_INT32_K_MAJOR,
            MODE_CHAIN_INT32_K_MAJOR_DECOUPLED: CAPABILITY_CHAIN_INT32_K_MAJOR_DECOUPLED,
            MODE_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE: CAPABILITY_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE,
            MODE_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH: CAPABILITY_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH,
            MODE_CHAIN_INT32_K_MAJOR_DUAL_C: CAPABILITY_CHAIN_INT32_K_MAJOR_DUAL_C,
        }
        if mode_override is not None:
            if (type(mode_override) is not int or mode_override not in capabilities
                    or (mode_override != MODE_CHAIN_INT32) != prepared.k_major):
                raise ValueError("prepared mode/layout mismatch")
            chain_mode = mode_override
        for channel, buffer, length in (
            (self.dma.sendchannel, input_buffer, prepared.input_bytes),
            (self.dma.recvchannel, output_buffer, prepared.output_bytes),
        ):
            if (not isinstance(buffer, np.ndarray) or buffer.dtype != np.dtype(np.uint8)
                    or buffer.ndim != 1 or not buffer.flags.c_contiguous
                    or not buffer.flags.writeable):
                raise ValueError("DMA buffers must be writable contiguous 1D uint8 arrays")
            if buffer.nbytes < length:
                raise ValueError("allocated DMA buffers are too small for this chain")
            if (not callable(getattr(buffer, "flush", None))
                    or not callable(getattr(buffer, "invalidate", None))
                    or type(getattr(buffer, "physical_address", None)) is not int
                    or buffer.physical_address < 0):
                raise ValueError("DMA buffers must expose allocated physical storage/cache methods")
            limit = getattr(channel, "_max_size", None)
            if type(limit) is not int or limit <= 0:
                raise RuntimeError("DMA channel transfer limit is unavailable")
            if length > limit:
                raise ValueError("prepared chain exceeds DMA channel transfer limit")
            alignment = getattr(channel, "_align", None)
            dre = getattr(channel, "_dre", None)
            if type(alignment) is not int or alignment <= 0 or type(dre) is not bool:
                raise RuntimeError("DMA channel alignment configuration is unavailable")
            if not dre and buffer.physical_address % alignment:
                raise ValueError("DMA buffer physical address is not channel-aligned")
        # Read the currently loaded identity, not just cached constructor values.
        build_id = int(self.mmio.read(REG_BUILD_ID))
        current_capabilities = int(self.mmio.read(REG_CAPABILITIES))
        if (build_id not in EXPECTED_GEMM_BUILD_IDS or build_id != self.build_id
                or current_capabilities != self.capabilities):
            raise RuntimeError("Overlay identity changed since runner construction")
        if build_id == 0x2026D075 and current_capabilities != 0x00080EFE:
            raise RuntimeError("MODE11 candidate capability/build identity mismatch")
        if not current_capabilities & capabilities[chain_mode]:
            raise RuntimeError("Overlay does not advertise prepared chain capability")
        validation_seconds = time.perf_counter() - validation_started if profile_host else 0.0
        payload, _, metrics = self._submit_chain(
            prepared.frame, prepared.records, None, input_buffer, output_buffer,
            first_job_id, timeout_s, launch_order, profile_host, chain_mode,
            prepared.k_major, prepared=prepared,
        )
        metrics["chain_preparation"] = "prepare_once"
        if profile_host:
            # This is nested in the outer driver_call, not chain_total_seconds.
            metrics["host_profile"]["prepared_validation_seconds"] = validation_seconds
        return payload, metrics

    def _submit_chain(
        self, chain_payload: bytes, records: list[ChainRecord] | tuple[ChainRecord, ...],
        transactions: list[TileTransaction | FusedTileTransaction] | None,
        input_buffer: Any, output_buffer: Any, first_job_id: int, timeout_s: float,
        launch_order: str, profile_host: bool, chain_mode: int, k_major: bool,
        *, prepared: PreparedDenseChain | None = None, fast_counter_reads: bool = False,
    ) -> tuple[bytes, list[ChainRecord] | tuple[ChainRecord, ...], dict[str, Any]]:
        """Shared unchanged DMA/START/wait/readback body of the legacy API."""
        input_bytes = len(chain_payload)
        output_bytes = sum(record.header.output_transport_bytes for record in records)
        host_profile: dict[str, float] = {}
        chain_started = time.perf_counter() if profile_host else 0.0

        step_started = time.perf_counter() if profile_host else 0.0
        input_buffer[:input_bytes] = np.frombuffer(chain_payload, dtype=np.uint8)
        if profile_host:
            host_profile["input_copy_seconds"] = time.perf_counter() - step_started
        step_started = time.perf_counter() if profile_host else 0.0
        output_buffer[:output_bytes] = np.uint8(0xA5)
        if profile_host:
            host_profile["output_prefill_seconds"] = time.perf_counter() - step_started
        step_started = time.perf_counter() if profile_host else 0.0
        input_buffer.flush()
        if profile_host:
            host_profile["input_flush_seconds"] = time.perf_counter() - step_started
        step_started = time.perf_counter() if profile_host else 0.0
        output_buffer.flush()
        if profile_host:
            host_profile["output_flush_seconds"] = time.perf_counter() - step_started

        step_started = time.perf_counter() if profile_host else 0.0
        self.mmio.write(REG_CONTROL, CONTROL_CLEAR_ERROR)
        self.mmio.write(REG_JOB_ID, first_job_id & 0xFFFF_FFFF)
        self.mmio.write(REG_MODE, chain_mode)
        self.mmio.write(REG_EXPECTED_IN, input_bytes)
        self.mmio.write(REG_EXPECTED_OUT, output_bytes)
        if profile_host:
            host_profile["mmio_config_seconds"] = time.perf_counter() - step_started

        started = time.perf_counter()
        try:
            step_started = time.perf_counter() if profile_host else 0.0
            self.dma.recvchannel.transfer(output_buffer, nbytes=output_bytes)
            if profile_host:
                host_profile["recv_arm_seconds"] = time.perf_counter() - step_started
            if launch_order == "dma-first":
                step_started = time.perf_counter() if profile_host else 0.0
                self.dma.sendchannel.transfer(input_buffer, nbytes=input_bytes)
                if profile_host:
                    host_profile["send_arm_seconds"] = time.perf_counter() - step_started
                step_started = time.perf_counter() if profile_host else 0.0
                self.mmio.write(REG_CONTROL, CONTROL_START)
                if profile_host:
                    host_profile["control_start_seconds"] = time.perf_counter() - step_started
            elif launch_order == "pl-first":
                step_started = time.perf_counter() if profile_host else 0.0
                self.mmio.write(REG_CONTROL, CONTROL_START)
                if profile_host:
                    host_profile["control_start_seconds"] = time.perf_counter() - step_started
                step_started = time.perf_counter() if profile_host else 0.0
                self.dma.sendchannel.transfer(input_buffer, nbytes=input_bytes)
                if profile_host:
                    host_profile["send_arm_seconds"] = time.perf_counter() - step_started
            else:
                raise ValueError(f"unsupported launch_order: {launch_order}")
            step_started = time.perf_counter() if profile_host else 0.0
            wait_until(
                lambda: bool(int(self.mmio.read(REG_STATUS)) & STATUS_ERROR)
                or bool(self.dma.sendchannel.idle and self.dma.recvchannel.idle),
                timeout_s,
                "chained DMA completion or PL ERROR",
            )
            if profile_host:
                host_profile["dma_wait_seconds"] = time.perf_counter() - step_started
            step_started = time.perf_counter() if profile_host else 0.0
            wait_until(
                lambda: bool(
                    int(self.mmio.read(REG_STATUS)) & (STATUS_DONE | STATUS_ERROR)
                ),
                timeout_s,
                "chained PL DONE or ERROR",
            )
            if profile_host:
                host_profile["pl_done_wait_seconds"] = time.perf_counter() - step_started
        except Exception:
            self._recover()
            raise
        elapsed = time.perf_counter() - started

        status = int(self.mmio.read(REG_STATUS))
        error_code = int(self.mmio.read(REG_ERROR_CODE))
        failed_tile = int(self.mmio.read(REG_FAILED_TILE))
        completed_jobs = int(self.mmio.read(REG_CHAIN_JOBS))
        if status & STATUS_ERROR:
            self._recover()
            raise RuntimeError(
                f"PL sticky chain error 0x{error_code:08x}, "
                f"failed_tile={failed_tile}, completed_jobs={completed_jobs}, "
                f"status=0x{status:08x}"
            )
        if not status & STATUS_DONE:
            self._recover()
            raise RuntimeError(
                f"chained DMA became idle without PL DONE, status=0x{status:08x}"
            )

        output_buffer.invalidate()
        payload = np.asarray(output_buffer[:output_bytes], dtype=np.uint8).tobytes()
        total_cycles = read_u64(self.mmio, REG_TOTAL_LO, REG_TOTAL_HI)
        compute_cycles = read_u64(self.mmio, REG_COMPUTE_LO, REG_COMPUTE_HI)
        effective_macs = read_u64(self.mmio, REG_MACS_LO, REG_MACS_HI)
        expected_macs = (prepared.effective_macs if prepared is not None
                         else sum(job.effective_macs for job in transactions))
        if completed_jobs != len(records):
            raise AssertionError(
                f"PL completed {completed_jobs} chain jobs, expected {len(records)}"
            )
        if effective_macs != expected_macs:
            raise AssertionError(
                f"PL effective MAC counter {effective_macs} != expected {expected_macs}"
            )
        if profile_host:
            host_profile["chain_total_seconds"] = time.perf_counter() - chain_started
        metrics = {
            "first_job_id": first_job_id & 0xFFFF_FFFF,
            "jobs": len(records),
            "mode": chain_mode,
            "layout": "k_major" if k_major else "row_major",
            "input_bytes": input_bytes,
            "input_payload_bytes": sum(len(record.payload) for record in records),
            "input_header_bytes": len(records) * 64,
            "input_effective_bytes": (prepared.input_effective_bytes if prepared is not None
                                      else sum(job.effective_input_bytes for job in transactions)),
            "output_bytes": output_bytes,
            "output_valid_bytes": sum(
                record.header.output_valid_bytes for record in records
            ),
            "seconds": elapsed,
            "pl_total_cycles": total_cycles,
            "pl_compute_accounted_cycles": compute_cycles,
            "effective_macs": effective_macs,
            "status": status,
            "error_code": error_code,
            "failed_tile_index": failed_tile,
            "chain_jobs_completed": completed_jobs,
        }
        if chain_mode == MODE_CHAIN_INT32_K_MAJOR_DUAL_C:
            if fast_counter_reads:
                metrics.update(self._read_mode11_counters(total_cycles, fast_counter_reads=True))
                metrics["mode11_counter_read_strategy"] = "whitelisted_scalar_u32"
            else:
                metrics.update(self._read_mode11_counters(total_cycles))
                metrics["mode11_counter_read_strategy"] = "pynq_mmio_read"
            metrics["counter_contract"] = "d007_global_work_v2"
        else:
            metrics["pl_input_stall_cycles"] = int(self.mmio.read(REG_INPUT_STALL))
            metrics["pl_output_stall_cycles"] = int(self.mmio.read(REG_OUTPUT_STALL))
            metrics.update(self._read_phase_counters())
        if chain_mode in (
            MODE_CHAIN_INT32_K_MAJOR_DECOUPLED,
            MODE_CHAIN_INT32_K_MAJOR_FIRST_K_OVERWRITE,
            MODE_CHAIN_INT32_K_MAJOR_PANEL_PREFETCH,
        ):
            metrics.update(self._read_d007_counters())
        if profile_host:
            metrics["host_profile"] = host_profile
        return payload, records, metrics

    def run_transaction(
        self,
        transaction: TileTransaction | FusedTileTransaction,
        input_buffer: Any,
        output_buffer: Any,
        job_id: int,
        timeout_s: float,
        launch_order: str = "pl-first",
        profile_host: bool = False,
    ) -> tuple[bytes, dict[str, Any]]:
        if isinstance(transaction, FusedTileTransaction) and not (
            self.capabilities & CAPABILITY_FUSED_INT8
        ):
            raise RuntimeError(
                f"Overlay does not advertise fused INT8 capability: "
                f"0x{self.capabilities:08x}"
            )
        input_bytes = transaction.expected_input_bytes
        output_bytes = transaction.expected_output_bytes
        if input_bytes > input_buffer.size or output_bytes > output_buffer.size:
            raise ValueError("allocated DMA buffers are too small for this transaction")

        host_profile: dict[str, float] = {}
        transaction_started = time.perf_counter() if profile_host else 0.0

        step_started = time.perf_counter() if profile_host else 0.0
        input_buffer[:input_bytes] = np.frombuffer(transaction.payload, dtype=np.uint8)
        if profile_host:
            host_profile["input_copy_seconds"] = time.perf_counter() - step_started
        step_started = time.perf_counter() if profile_host else 0.0
        output_buffer[:output_bytes] = np.uint8(0xA5)
        if profile_host:
            host_profile["output_prefill_seconds"] = time.perf_counter() - step_started
        step_started = time.perf_counter() if profile_host else 0.0
        input_buffer.flush()
        if profile_host:
            host_profile["input_flush_seconds"] = time.perf_counter() - step_started
        step_started = time.perf_counter() if profile_host else 0.0
        output_buffer.flush()
        if profile_host:
            host_profile["output_flush_seconds"] = time.perf_counter() - step_started

        step_started = time.perf_counter() if profile_host else 0.0
        self.mmio.write(REG_CONTROL, CONTROL_CLEAR_ERROR)
        for offset, value in transaction_register_writes(transaction, job_id):
            self.mmio.write(offset, value)
        if profile_host:
            host_profile["mmio_config_seconds"] = time.perf_counter() - step_started

        started = time.perf_counter()
        try:
            # Arm S2MM before START so the first result can never race the receiver.
            step_started = time.perf_counter() if profile_host else 0.0
            self.dma.recvchannel.transfer(output_buffer, nbytes=output_bytes)
            if profile_host:
                host_profile["recv_arm_seconds"] = time.perf_counter() - step_started
            if launch_order == "dma-first":
                # AXI permits MM2S to hold TVALID until the accelerator asserts
                # TREADY.  Arming it before START therefore removes software/DMA
                # launch latency from the PL input-stall counter without risking
                # loss of the first beat.
                step_started = time.perf_counter() if profile_host else 0.0
                self.dma.sendchannel.transfer(input_buffer, nbytes=input_bytes)
                if profile_host:
                    host_profile["send_arm_seconds"] = time.perf_counter() - step_started
                step_started = time.perf_counter() if profile_host else 0.0
                self.mmio.write(REG_CONTROL, CONTROL_START)
                if profile_host:
                    host_profile["control_start_seconds"] = time.perf_counter() - step_started
            elif launch_order == "pl-first":
                step_started = time.perf_counter() if profile_host else 0.0
                self.mmio.write(REG_CONTROL, CONTROL_START)
                if profile_host:
                    host_profile["control_start_seconds"] = time.perf_counter() - step_started
                step_started = time.perf_counter() if profile_host else 0.0
                self.dma.sendchannel.transfer(input_buffer, nbytes=input_bytes)
                if profile_host:
                    host_profile["send_arm_seconds"] = time.perf_counter() - step_started
            else:
                raise ValueError(f"unsupported launch_order: {launch_order}")
            step_started = time.perf_counter() if profile_host else 0.0
            wait_until(
                lambda: bool(int(self.mmio.read(REG_STATUS)) & STATUS_ERROR)
                or bool(self.dma.sendchannel.idle and self.dma.recvchannel.idle),
                timeout_s,
                "DMA completion or PL ERROR",
            )
            if profile_host:
                host_profile["dma_wait_seconds"] = time.perf_counter() - step_started
            step_started = time.perf_counter() if profile_host else 0.0
            wait_until(
                lambda: bool(int(self.mmio.read(REG_STATUS)) & (STATUS_DONE | STATUS_ERROR)),
                timeout_s,
                "PL DONE or ERROR",
            )
            if profile_host:
                host_profile["pl_done_wait_seconds"] = time.perf_counter() - step_started
        except Exception:
            self._recover()
            raise
        elapsed = time.perf_counter() - started

        step_started = time.perf_counter() if profile_host else 0.0
        status = int(self.mmio.read(REG_STATUS))
        error_code = int(self.mmio.read(REG_ERROR_CODE))
        if profile_host:
            host_profile["status_read_seconds"] = time.perf_counter() - step_started
        if status & STATUS_ERROR:
            self._recover()
            raise RuntimeError(f"PL sticky error 0x{error_code:08x}, status=0x{status:08x}")
        if not status & STATUS_DONE:
            self._recover()
            raise RuntimeError(f"DMA became idle without PL DONE, status=0x{status:08x}")

        step_started = time.perf_counter() if profile_host else 0.0
        output_buffer.invalidate()
        if profile_host:
            host_profile["output_invalidate_seconds"] = time.perf_counter() - step_started
        step_started = time.perf_counter() if profile_host else 0.0
        payload = np.asarray(output_buffer[:output_bytes], dtype=np.uint8).tobytes()
        if profile_host:
            host_profile["output_copy_seconds"] = time.perf_counter() - step_started
        step_started = time.perf_counter() if profile_host else 0.0
        total_cycles = read_u64(self.mmio, REG_TOTAL_LO, REG_TOTAL_HI)
        compute_cycles = read_u64(self.mmio, REG_COMPUTE_LO, REG_COMPUTE_HI)
        input_stall_cycles = int(self.mmio.read(REG_INPUT_STALL))
        output_stall_cycles = int(self.mmio.read(REG_OUTPUT_STALL))
        effective_macs = read_u64(self.mmio, REG_MACS_LO, REG_MACS_HI)
        if profile_host:
            host_profile["counter_read_seconds"] = time.perf_counter() - step_started
            host_profile["transaction_total_seconds"] = (
                time.perf_counter() - transaction_started
            )
        metrics = {
            "job_id": job_id & 0xFFFFFFFF,
            "m_offset": transaction.m_offset,
            "n_offset": transaction.n_offset,
            "block_m": transaction.actual_bm,
            "block_n": transaction.actual_bn,
            "block_k": transaction.config.bk,
            "input_bytes": input_bytes,
            "effective_input_bytes": transaction.effective_input_bytes,
            "output_bytes": output_bytes,
            "seconds": elapsed,
            "pl_total_cycles": total_cycles,
            "pl_compute_accounted_cycles": compute_cycles,
            "pl_input_stall_cycles": input_stall_cycles,
            "pl_output_stall_cycles": output_stall_cycles,
            "effective_macs": effective_macs,
            "status": status,
            "error_code": error_code,
            **self._read_phase_counters(),
        }
        if profile_host:
            metrics["host_profile"] = host_profile
        if metrics["effective_macs"] != transaction.effective_macs:
            raise AssertionError(
                f"PL effective MAC counter {metrics['effective_macs']} != "
                f"expected {transaction.effective_macs}"
            )
        return payload, metrics


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bit", type=Path, default=Path("opennpu_gemm_accelerator.bit"))
    parser.add_argument("--m", type=int, default=15)
    parser.add_argument("--n", type=int, default=13)
    parser.add_argument("--k", type=int, default=17)
    parser.add_argument("--bm", type=int, default=8)
    parser.add_argument("--bn", type=int, default=8)
    parser.add_argument("--bk", type=int, default=8)
    parser.add_argument("--iterations", type=int, default=1)
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--clock-hz", type=int, default=DEFAULT_CLOCK_HZ)
    parser.add_argument("--seed", type=int, default=20260908)
    parser.add_argument("--metrics", type=Path, default=Path("board_gemm.json"))
    parser.add_argument("--board-serial", default=os.environ.get("BOARD_SERIAL", "unknown"))
    parser.add_argument("--pynq-image", default=os.environ.get("PYNQ_IMAGE", "unknown"))
    parser.add_argument("--notes", default="")
    parser.add_argument(
        "--launch-order",
        choices=("dma-first", "pl-first"),
        default="pl-first",
        help="use the measured end-to-end baseline (default) or arm MM2S first for diagnostics",
    )
    parser.add_argument(
        "--profile-host",
        action="store_true",
        help="record segmented host timings for each transaction",
    )
    return parser


def validate_args(args: argparse.Namespace) -> TileConfig:
    if not args.bit.is_file():
        raise FileNotFoundError(args.bit)
    hwh_path = args.bit.with_suffix(".hwh")
    if not hwh_path.is_file():
        raise FileNotFoundError(f"Matching HWH file is required: {hwh_path}")
    if not all(1 <= value <= 512 for value in (args.m, args.n, args.k)):
        raise ValueError("--m, --n and --k must each be in range 1..512")
    if args.iterations <= 0:
        raise ValueError("--iterations must be positive")
    if args.timeout <= 0 or args.clock_hz <= 0:
        raise ValueError("--timeout and --clock-hz must be positive")
    config = TileConfig(args.bm, args.bn, args.bk)
    config.validate()
    return config


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    metrics: dict[str, Any] = {
        "schema": "opennpu.board_gemm.v1",
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host": socket.gethostname(),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "board_serial": args.board_serial,
        "pynq_image": args.pynq_image,
        "notes": args.notes,
        "launch_order": args.launch_order,
        "host_profile_enabled": args.profile_host,
        "git_commit": try_git_commit(),
        "seed": args.seed,
        "shape": {"m": args.m, "n": args.n, "k": args.k},
        "requested_iterations": args.iterations,
        "timeout_seconds": args.timeout,
        "clock_hz": args.clock_hz,
        "success": False,
    }
    runner: PynqGemm | None = None
    input_buffer = None
    output_buffer = None
    transaction_runs: list[dict[str, Any]] = []
    case_runs: list[dict[str, Any]] = []
    completed_iterations = 0
    exit_code = 1
    try:
        config = validate_args(args)
        metrics["tile_config"] = asdict(config)
        metrics["bitstream"] = str(args.bit.resolve())
        metrics["bitstream_sha256"] = file_sha256(args.bit)
        runner = PynqGemm(args.bit)
        metrics["pynq_version"] = runner.pynq_version
        metrics["build_id"] = f"0x{runner.build_id:08x}"
        metrics["capabilities"] = f"0x{runner.capabilities:08x}"

        rng = np.random.default_rng(args.seed)
        first_a = rng.integers(-128, 128, size=(args.m, args.k), dtype=np.int8)
        first_b = rng.integers(-128, 128, size=(args.k, args.n), dtype=np.int8)
        first_transactions = list(iter_transactions(first_a, first_b, config))
        max_input = max(job.expected_input_bytes for job in first_transactions)
        max_output = max(job.expected_output_bytes for job in first_transactions)
        input_buffer, output_buffer = runner.allocate_buffers(max_input, max_output)

        # Reuse the first generated pair; later iterations draw fresh matrices.
        for iteration in range(args.iterations):
            if iteration == 0:
                a, b = first_a, first_b
            else:
                a = rng.integers(-128, 128, size=(args.m, args.k), dtype=np.int8)
                b = rng.integers(-128, 128, size=(args.k, args.n), dtype=np.int8)
            case_started = time.perf_counter()
            actual = np.zeros((args.m, args.n), dtype=np.int32)
            jobs = list(iter_transactions(a, b, config))
            for tile_index, transaction in enumerate(jobs):
                job_id = iteration * len(jobs) + tile_index + 1
                payload, run = runner.run_transaction(
                    transaction,
                    input_buffer,
                    output_buffer,
                    job_id,
                    args.timeout,
                    args.launch_order,
                    args.profile_host,
                )
                compare_payload(payload, emulate_transaction(transaction), f"job {job_id}")
                place_output(actual, transaction, payload)
                transaction_runs.append(run)
            expected = a.astype(np.int32) @ b.astype(np.int32)
            if not np.array_equal(actual, expected):
                index = tuple(int(value) for value in np.argwhere(actual != expected)[0])
                raise AssertionError(
                    f"iteration {iteration + 1}: matrix mismatch at {index}: "
                    f"expected={int(expected[index])}, actual={int(actual[index])}"
                )
            case_runs.append(
                {
                    "iteration": iteration + 1,
                    "effective_macs": args.m * args.n * args.k,
                    "seconds": time.perf_counter() - case_started,
                    "transactions": len(jobs),
                }
            )
            completed_iterations += 1
            print(
                f"PASS {completed_iterations}/{args.iterations}: "
                f"shape={args.m}x{args.n}x{args.k}, tiles={len(jobs)}"
            )

        metrics["summary"] = summarize_transactions(transaction_runs, args.clock_hz)
        metrics["host_profile_summary"] = summarize_host_profile(transaction_runs)
        metrics["case_summary"] = summarize_cases(case_runs)
        metrics["success"] = True
        metrics["random_1000_gate_pass"] = completed_iterations >= 1000
        metrics["pressure_512_pass"] = bool(
            (args.m, args.n, args.k) == (512, 512, 512)
            and completed_iterations >= 1
        )
        exit_code = 0
    except Exception as exc:
        metrics["failure"] = {"type": type(exc).__name__, "message": str(exc)}
        print(f"FAIL: {type(exc).__name__}: {exc}", file=sys.stderr)
    finally:
        metrics["completed_iterations"] = completed_iterations
        metrics["summary"] = summarize_transactions(transaction_runs, args.clock_hz)
        metrics["host_profile_summary"] = summarize_host_profile(transaction_runs)
        metrics["case_summary"] = summarize_cases(case_runs)
        if transaction_runs:
            metrics["last_transaction"] = transaction_runs[-1]
        if case_runs:
            metrics["last_case"] = case_runs[-1]
        for buffer in (input_buffer, output_buffer):
            if buffer is not None:
                try:
                    buffer.freebuffer()
                except Exception:
                    pass
        metrics["finished_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        args.metrics.parent.mkdir(parents=True, exist_ok=True)
        args.metrics.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
        print(f"Metrics: {args.metrics}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
