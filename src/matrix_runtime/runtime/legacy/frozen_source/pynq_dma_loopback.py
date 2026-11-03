#!/usr/bin/env python3
"""First-board PYNQ-Z2 AXI DMA loopback acceptance test.

This module keeps PYNQ imports inside ``PynqLoopback`` so its discovery,
counter, and metric helpers can be unit-tested on a normal PC.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import socket
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Callable

import numpy as np


REG_CONTROL = 0x00
REG_STATUS = 0x04
REG_ERROR_CODE = 0x08
REG_JOB_ID = 0x0C
REG_EXPECTED_IN = 0x34
REG_EXPECTED_OUT = 0x38
REG_TOTAL_LO = 0x40
REG_TOTAL_HI = 0x44
REG_INPUT_STALL = 0x50
REG_OUTPUT_STALL = 0x54
REG_BUILD_ID = 0x60
REG_CAPABILITIES = 0x64

CONTROL_START = 1 << 0
CONTROL_SOFT_RESET = 1 << 1
CONTROL_CLEAR_ERROR = 1 << 2
STATUS_IDLE = 1 << 0
STATUS_BUSY = 1 << 1
STATUS_DONE = 1 << 2
STATUS_ERROR = 1 << 3
DMA_DMACR_RESET = 1 << 2
DMA_DMACR_RUN_IRQ_THRESHOLD = 0x0000_1001
DMA_DMASR_OFFSET = 0x04
DMA_DMASR_HALTED = 1 << 0
DMA_DMASR_IDLE = 1 << 1
DMA_DMASR_ERROR_MASK = 0x0000_0770


def reset_dma_channel_software_state(
    channel: Any, *, hardware_reset_verified: bool
) -> None:
    """Synchronize PYNQ's private simple-DMA state after a hardware reset.

    PYNQ remembers that a channel has already transferred and otherwise
    rejects the first post-reset transfer when AXI DMA has not yet asserted
    its idle bit. The driver already depends on private MMIO fields for a
    bounded reset, so make that compatibility step explicit and testable.
    """
    if not hardware_reset_verified:
        raise RuntimeError("DMA software state may only follow a verified hardware reset")
    channel._first_transfer = True
    channel._active_buffer = None


EXPECTED_BUILD_ID = 0x20260908


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def select_ip_key(
    ip_dict: dict[str, dict[str, Any]],
    instance_name: str,
    type_fragment: str | None = None,
) -> str:
    """Find one IP instance while tolerating a future hierarchy prefix."""
    by_name = [key for key in ip_dict if key.rsplit("/", 1)[-1] == instance_name]
    candidates = by_name
    if not candidates and type_fragment:
        fragment = type_fragment.lower()
        candidates = [
            key
            for key, description in ip_dict.items()
            if fragment in str(description.get("type", "")).lower()
        ]
    if len(candidates) != 1:
        raise RuntimeError(
            f"Expected exactly one {instance_name!r} IP, found {candidates}; "
            f"available={sorted(ip_dict)}"
        )
    return candidates[0]


def resolve_overlay_object(overlay: Any, ip_key: str) -> Any:
    obj = overlay
    for component in ip_key.split("/"):
        obj = getattr(obj, component)
    return obj


def read_u64(mmio: Any, low_offset: int, high_offset: int) -> int:
    """Read a live split counter without accepting a rollover tear."""
    for _ in range(4):
        high_before = int(mmio.read(high_offset))
        low = int(mmio.read(low_offset))
        high_after = int(mmio.read(high_offset))
        if high_before == high_after:
            return (high_after << 32) | low
    raise RuntimeError("64-bit counter changed too quickly for a coherent read")


def wait_until(predicate: Callable[[], bool], timeout_s: float, label: str) -> None:
    deadline = time.monotonic() + timeout_s
    while not predicate():
        if time.monotonic() >= deadline:
            raise TimeoutError(f"Timed out after {timeout_s:.3f}s waiting for {label}")
        time.sleep(0.0005)


def dma_channel_status(channel: Any) -> dict[str, Any]:
    """Read one AXI DMA channel status without interpreting IDLE as a gate."""
    raw = int(channel._mmio.read(channel._offset + DMA_DMASR_OFFSET))
    return {
        "raw": f"0x{raw:08x}",
        "halted": bool(raw & DMA_DMASR_HALTED),
        "idle": bool(raw & DMA_DMASR_IDLE),
        "error_bits": f"0x{raw & DMA_DMASR_ERROR_MASK:08x}",
    }


def reset_simple_dma(dma: Any, timeout_s: float = 1.0) -> dict[str, Any]:
    """Reset the complete Simple-DMA instance and resynchronize PYNQ state.

    AXI DMA reset is instance-wide.  The reset self-clear and both restarted
    channels are checked with bounded waits.  IDLE is deliberately observed,
    not required: PYNQ's first-transfer path exists because IDLE can be false
    immediately after a channel start and before its first transfer.
    """
    channels = {
        "send": dma.sendchannel,
        "recv": dma.recvchannel,
    }
    dma_mmio = channels["send"]._mmio
    snapshots = {
        "before_reset": {
            name: dma_channel_status(channel) for name, channel in channels.items()
        }
    }
    dma_mmio.write(channels["send"]._offset, DMA_DMACR_RESET)
    wait_until(
        lambda: not bool(
            int(dma_mmio.read(channels["send"]._offset)) & DMA_DMACR_RESET
        ),
        timeout_s,
        "AXI DMA reset",
    )
    for channel in channels.values():
        wait_until(
            lambda channel=channel: not bool(
                int(channel._mmio.read(channel._offset + DMA_DMASR_OFFSET))
                & DMA_DMASR_ERROR_MASK
            ),
            timeout_s,
            "DMA channel reset error bits to clear",
        )
    snapshots["after_reset"] = {
        name: dma_channel_status(channel) for name, channel in channels.items()
    }
    for channel in channels.values():
        channel._mmio.write(channel._offset, DMA_DMACR_RUN_IRQ_THRESHOLD)
        reset_dma_channel_software_state(channel, hardware_reset_verified=True)
        wait_until(lambda channel=channel: channel.running, timeout_s, "DMA channel start")
        wait_until(
            lambda channel=channel: not bool(
                int(channel._mmio.read(channel._offset + DMA_DMASR_OFFSET))
                & DMA_DMASR_ERROR_MASK
            ),
            timeout_s,
            "DMA channel error bits to clear",
        )
    snapshots["after_restart"] = {
        name: dma_channel_status(channel) for name, channel in channels.items()
    }
    return snapshots


def summarize_runs(runs: list[dict[str, Any]]) -> dict[str, Any]:
    if not runs:
        return {
            "iterations": 0,
            "bytes_per_iteration": 0,
            "transfer_seconds": 0.0,
            "payload_mb_s": 0.0,
            "aggregate_read_write_mb_s": 0.0,
            "min_payload_mb_s": 0.0,
            "max_payload_mb_s": 0.0,
        }
    byte_count = sum(int(run["bytes"]) for run in runs)
    elapsed = sum(float(run["seconds"]) for run in runs)
    bandwidths = [float(run["payload_mb_s"]) for run in runs]
    payload_mb_s = byte_count / elapsed / 1_000_000.0
    return {
        "iterations": len(runs),
        "bytes_per_iteration": int(runs[0]["bytes"]),
        "transfer_seconds": elapsed,
        "payload_mb_s": payload_mb_s,
        "aggregate_read_write_mb_s": 2.0 * payload_mb_s,
        "min_payload_mb_s": min(bandwidths),
        "max_payload_mb_s": max(bandwidths),
    }


def try_git_commit() -> str | None:
    try:
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        ).stdout.strip()
    except (FileNotFoundError, subprocess.SubprocessError):
        return None


class PynqLoopback:
    def __init__(self, bit_path: Path) -> None:
        try:
            import pynq
            from pynq import MMIO, Overlay, allocate
        except ImportError as exc:
            raise RuntimeError("Run this test on a PYNQ Linux image with pynq installed") from exc

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
        if self.build_id != EXPECTED_BUILD_ID:
            raise RuntimeError(
                f"RTL/driver mismatch: build_id=0x{self.build_id:08x}, "
                f"expected=0x{EXPECTED_BUILD_ID:08x}"
            )
        self.mmio.write(REG_CONTROL, CONTROL_SOFT_RESET)
        wait_until(
            lambda: bool(int(self.mmio.read(REG_STATUS)) & STATUS_IDLE),
            1.0,
            "accelerator reset to IDLE",
        )

    @property
    def pynq_version(self) -> str:
        return str(getattr(self._pynq, "__version__", "unknown"))

    def allocate_buffers(self, byte_count: int) -> tuple[Any, Any]:
        return (
            self._allocate(shape=(byte_count,), dtype=np.uint8),
            self._allocate(shape=(byte_count,), dtype=np.uint8),
        )

    def _recover(self) -> dict[str, Any]:
        try:
            return reset_simple_dma(self.dma)
        finally:
            self.mmio.write(REG_CONTROL, CONTROL_SOFT_RESET)

    def run_once(
        self,
        input_buffer: Any,
        output_buffer: Any,
        byte_count: int,
        job_id: int,
        timeout_s: float,
    ) -> dict[str, Any]:
        output_buffer[:] = np.uint8(0xA5)
        input_buffer.flush()
        output_buffer.flush()

        self.mmio.write(REG_CONTROL, CONTROL_CLEAR_ERROR)
        self.mmio.write(REG_JOB_ID, job_id & 0xFFFFFFFF)
        self.mmio.write(REG_EXPECTED_IN, byte_count)
        self.mmio.write(REG_EXPECTED_OUT, byte_count)

        started = time.perf_counter()
        try:
            # Arm the DDR writer first, then PL, then the DDR reader. This order
            # prevents output backpressure from becoming a first-beat race.
            self.dma.recvchannel.transfer(output_buffer, nbytes=byte_count)
            self.mmio.write(REG_CONTROL, CONTROL_START)
            self.dma.sendchannel.transfer(input_buffer, nbytes=byte_count)
            wait_until(
                lambda: bool(self.dma.sendchannel.idle and self.dma.recvchannel.idle),
                timeout_s,
                "both AXI DMA channels",
            )
            wait_until(
                lambda: bool(
                    int(self.mmio.read(REG_STATUS)) & (STATUS_DONE | STATUS_ERROR)
                ),
                timeout_s,
                "PL DONE or ERROR",
            )
        except Exception:
            self._recover()
            raise
        elapsed = time.perf_counter() - started

        output_buffer.invalidate()
        status = int(self.mmio.read(REG_STATUS))
        error_code = int(self.mmio.read(REG_ERROR_CODE))
        if status & STATUS_ERROR:
            self._recover()
            raise RuntimeError(f"PL sticky error 0x{error_code:08x}, status=0x{status:08x}")
        if not status & STATUS_DONE:
            self._recover()
            raise RuntimeError(f"DMA became idle without PL DONE, status=0x{status:08x}")

        actual = np.asarray(output_buffer[:byte_count])
        expected = np.asarray(input_buffer[:byte_count])
        mismatch = np.flatnonzero(actual != expected)
        if mismatch.size:
            index = int(mismatch[0])
            raise AssertionError(
                f"Byte mismatch at {index}: expected={int(expected[index])}, "
                f"actual={int(actual[index])}, mismatches={mismatch.size}"
            )

        return {
            "bytes": byte_count,
            "seconds": elapsed,
            "payload_mb_s": byte_count / elapsed / 1_000_000.0,
            "pl_total_cycles": read_u64(self.mmio, REG_TOTAL_LO, REG_TOTAL_HI),
            "pl_input_stall_cycles": int(self.mmio.read(REG_INPUT_STALL)),
            "pl_output_stall_cycles": int(self.mmio.read(REG_OUTPUT_STALL)),
            "status": status,
            "error_code": error_code,
        }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bit", type=Path, default=Path("opennpu_dma_loopback.bit"))
    parser.add_argument("--size", type=int, default=256 * 1024)
    parser.add_argument("--iterations", type=int, default=1000)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--seed", type=int, default=20260908)
    parser.add_argument("--metrics", type=Path, default=Path("board_dma_loopback.json"))
    parser.add_argument("--board-serial", default=os.environ.get("BOARD_SERIAL", "unknown"))
    parser.add_argument("--pynq-image", default=os.environ.get("PYNQ_IMAGE", "unknown"))
    parser.add_argument("--notes", default="")
    return parser


def validate_args(args: argparse.Namespace) -> None:
    if not args.bit.is_file():
        raise FileNotFoundError(args.bit)
    hwh_path = args.bit.with_suffix(".hwh")
    if not hwh_path.is_file():
        raise FileNotFoundError(f"Matching HWH file is required: {hwh_path}")
    if args.size <= 0 or args.size >= (1 << 23):
        raise ValueError("--size must be in range 1..8388607 for this DMA build")
    if args.iterations <= 0:
        raise ValueError("--iterations must be positive")
    if args.timeout <= 0:
        raise ValueError("--timeout must be positive")


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    metrics: dict[str, Any] = {
        "schema": "opennpu.board_dma_loopback.v1",
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "host": socket.gethostname(),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "board_serial": args.board_serial,
        "pynq_image": args.pynq_image,
        "notes": args.notes,
        "git_commit": try_git_commit(),
        "seed": args.seed,
        "requested_iterations": args.iterations,
        "requested_bytes": args.size,
        "timeout_seconds": args.timeout,
        "success": False,
    }
    runner: PynqLoopback | None = None
    input_buffer = None
    output_buffer = None
    runs: list[dict[str, Any]] = []
    exit_code = 1
    try:
        validate_args(args)
        metrics["bitstream"] = str(args.bit.resolve())
        metrics["bitstream_sha256"] = file_sha256(args.bit)
        runner = PynqLoopback(args.bit)
        metrics["pynq_version"] = runner.pynq_version
        metrics["build_id"] = f"0x{runner.build_id:08x}"
        metrics["capabilities"] = f"0x{runner.capabilities:08x}"
        input_buffer, output_buffer = runner.allocate_buffers(args.size)
        rng = np.random.default_rng(args.seed)
        for iteration in range(args.iterations):
            input_buffer[:] = rng.integers(0, 256, size=args.size, dtype=np.uint8)
            result = runner.run_once(
                input_buffer,
                output_buffer,
                args.size,
                iteration + 1,
                args.timeout,
            )
            runs.append(result)
            completed = iteration + 1
            if completed == 1 or completed % 100 == 0 or completed == args.iterations:
                print(
                    f"PASS {completed}/{args.iterations}: "
                    f"{result['payload_mb_s']:.2f} MB/s, "
                    f"PL cycles={result['pl_total_cycles']}"
                )
        metrics["summary"] = summarize_runs(runs)
        metrics["last_run"] = runs[-1]
        metrics["success"] = True
        metrics["first_board_gate_pass"] = bool(
            len(runs) >= 1000
            and args.size >= 256 * 1024
            and metrics["summary"]["payload_mb_s"] >= 50.0
        )
        exit_code = 0
    except Exception as exc:
        metrics["completed_iterations"] = len(runs)
        metrics["summary"] = summarize_runs(runs)
        metrics["failure"] = {"type": type(exc).__name__, "message": str(exc)}
        print(f"FAIL: {type(exc).__name__}: {exc}", file=sys.stderr)
    finally:
        for buffer in (input_buffer, output_buffer):
            if buffer is not None:
                try:
                    buffer.freebuffer()
                except Exception:
                    pass
        metrics["finished_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        args.metrics.parent.mkdir(parents=True, exist_ok=True)
        args.metrics.write_text(json.dumps(metrics, indent=2), encoding="utf-8")
        print(f"Metrics: {args.metrics}")
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
