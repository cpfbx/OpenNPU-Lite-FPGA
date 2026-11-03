#!/usr/bin/env python3
"""Validate reproducibility and arithmetic invariants in GEMM board evidence."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def validate(
    evidence: dict[str, Any],
    *,
    min_iterations: int = 1,
    expected_shape: tuple[int, int, int] | None = None,
    require_board_identity: bool = False,
    require_random_1000_gate: bool = False,
    require_pressure_512: bool = False,
) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    require(evidence.get("schema") == "opennpu.board_gemm.v1", "unsupported schema")
    require(evidence.get("success") is True, "success must be true")
    require("failure" not in evidence, "failure record is present")

    shape = evidence.get("shape", {})
    dims = tuple(shape.get(key) for key in ("m", "n", "k"))
    require(all(positive_int(value) for value in dims), "shape m/n/k must be positive integers")
    if expected_shape is not None:
        require(dims == expected_shape, f"shape {dims} != required {expected_shape}")

    requested = evidence.get("requested_iterations")
    completed = evidence.get("completed_iterations")
    require(positive_int(requested), "requested_iterations must be positive")
    require(isinstance(completed, int) and completed >= min_iterations, f"completed_iterations must be >= {min_iterations}")
    require(completed == requested, "completed_iterations != requested_iterations")

    require(positive_int(evidence.get("seed")), "seed must be a positive integer")
    require(isinstance(evidence.get("started_utc"), str), "started_utc missing")
    require(isinstance(evidence.get("finished_utc"), str), "finished_utc missing")
    require(float(evidence.get("timeout_seconds", 0)) > 0, "timeout_seconds must be positive")
    require(positive_int(evidence.get("clock_hz")), "clock_hz must be positive")
    require(SHA256_RE.fullmatch(str(evidence.get("bitstream_sha256", ""))) is not None, "bitstream_sha256 missing or invalid")
    require(isinstance(evidence.get("build_id"), str) and bool(evidence.get("build_id")), "build_id missing")
    require(isinstance(evidence.get("capabilities"), str) and bool(evidence.get("capabilities")), "capabilities missing")

    tile = evidence.get("tile_config", {})
    require(bool(tile) and all(positive_int(value) for value in tile.values()), "tile_config must contain positive integer dimensions")

    case = evidence.get("case_summary", {})
    summary = evidence.get("summary", {})
    require(case.get("iterations") == completed, "case_summary.iterations mismatch")
    require(isinstance(summary.get("transactions"), int) and summary.get("transactions", 0) > 0, "no GEMM transactions recorded")

    if all(positive_int(value) for value in dims) and isinstance(completed, int):
        expected_macs = dims[0] * dims[1] * dims[2] * completed
        require(case.get("effective_macs") == expected_macs, "case_summary.effective_macs mismatch")
        require(summary.get("effective_macs") == expected_macs, "summary.effective_macs mismatch")

    for field in ("dma_pl_wall_seconds", "pl_total_cycles", "pl_compute_accounted_cycles"):
        require(isinstance(summary.get(field), (int, float)) and summary.get(field, -1) >= 0, f"summary.{field} missing or negative")
    require(isinstance(case.get("end_to_end_seconds"), (int, float)) and case.get("end_to_end_seconds", -1) >= 0, "case_summary.end_to_end_seconds missing or negative")

    board_serial = str(evidence.get("board_serial", "")).strip()
    pynq_image = str(evidence.get("pynq_image", "")).strip()
    pynq_version = str(evidence.get("pynq_version", "")).strip()
    if require_board_identity:
        require(board_serial.lower() not in ("", "unknown"), "board_serial is unknown")
        require(pynq_image.lower() not in ("", "unknown"), "pynq_image is unknown")
        require(pynq_version.lower() not in ("", "unknown"), "pynq_version is unknown")
    elif board_serial.lower() in ("", "unknown"):
        warnings.append("board_serial is unknown")

    if require_random_1000_gate:
        require(evidence.get("random_1000_gate_pass") is True, "random_1000_gate_pass is not true")
    if require_pressure_512:
        require(evidence.get("pressure_512_pass") is True, "pressure_512_pass is not true")
        require(dims == (512, 512, 512), "pressure gate evidence is not shape 512,512,512")

    return {
        "schema": "pynq.gemm_evidence_validation.v1",
        "passed": not errors,
        "errors": errors,
        "warnings": warnings,
        "observed_shape_mnk": list(dims),
        "observed_iterations": completed,
    }


def parse_shape(text: str) -> tuple[int, int, int]:
    try:
        values = tuple(int(item) for item in text.split(","))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("shape must be M,N,K") from exc
    if len(values) != 3 or any(value <= 0 for value in values):
        raise argparse.ArgumentTypeError("shape must contain three positive integers")
    return values


def self_test() -> None:
    sample = {
        "schema": "opennpu.board_gemm.v1",
        "success": True,
        "started_utc": "2026-09-09T00:00:00Z",
        "finished_utc": "2026-09-09T00:00:01Z",
        "board_serial": "demo",
        "pynq_image": "3.0.1",
        "pynq_version": "3.0.1",
        "seed": 1,
        "shape": {"m": 3, "n": 4, "k": 5},
        "requested_iterations": 2,
        "completed_iterations": 2,
        "timeout_seconds": 1.0,
        "clock_hz": 100_000_000,
        "bitstream_sha256": "a" * 64,
        "build_id": "0x1",
        "capabilities": "0x2",
        "tile_config": {"bm": 4, "bn": 4, "bk": 8},
        "summary": {
            "transactions": 2,
            "effective_macs": 120,
            "dma_pl_wall_seconds": 0.1,
            "pl_total_cycles": 100,
            "pl_compute_accounted_cycles": 80,
        },
        "case_summary": {"iterations": 2, "effective_macs": 120, "end_to_end_seconds": 0.2},
    }
    assert validate(sample, expected_shape=(3, 4, 5))["passed"]
    sample["case_summary"]["effective_macs"] = 119
    assert not validate(sample)["passed"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path, nargs="?")
    parser.add_argument("--min-iterations", type=int, default=1)
    parser.add_argument("--shape", type=parse_shape)
    parser.add_argument("--require-board-identity", action="store_true")
    parser.add_argument("--require-random-1000-gate", action="store_true")
    parser.add_argument("--require-pressure-512", action="store_true")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        self_test()
        print("PASS: self-test")
        return 0
    if args.evidence is None:
        parser.error("evidence is required unless --self-test is used")
    if args.min_iterations <= 0:
        parser.error("--min-iterations must be positive")

    try:
        evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
        result = validate(
            evidence,
            min_iterations=args.min_iterations,
            expected_shape=args.shape,
            require_board_identity=args.require_board_identity,
            require_random_1000_gate=args.require_random_1000_gate,
            require_pressure_512=args.require_pressure_512,
        )
    except (OSError, json.JSONDecodeError, TypeError, ValueError) as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 2

    rendered = json.dumps(result, indent=2)
    print(rendered)
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(rendered + "\n", encoding="utf-8")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
