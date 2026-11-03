#!/usr/bin/env python3
"""Validate PYNQ GEMM soak or error-recovery board evidence."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")


def validate(
    evidence: dict[str, Any],
    *,
    minimum_duration_seconds: float = 0.0,
    require_board_identity: bool = False,
) -> dict[str, Any]:
    errors: list[str] = []
    warnings: list[str] = []

    def require(condition: bool, message: str) -> None:
        if not condition:
            errors.append(message)

    schema = evidence.get("schema")
    require(
        schema in ("opennpu.board_gemm_soak.v1", "opennpu.board_gemm_recovery.v1"),
        "unsupported schema",
    )
    require(evidence.get("success") is True, "success must be true")
    require("failure" not in evidence, "failure record is present")
    require(isinstance(evidence.get("started_utc"), str), "started_utc missing")
    require(isinstance(evidence.get("finished_utc"), str), "finished_utc missing")
    require(float(evidence.get("timeout_seconds", 0)) > 0, "timeout_seconds must be positive")
    require(int(evidence.get("clock_hz", 0)) > 0, "clock_hz must be positive")
    require(
        SHA256_RE.fullmatch(str(evidence.get("bitstream_sha256", ""))) is not None,
        "bitstream_sha256 missing or invalid",
    )
    require(bool(str(evidence.get("build_id", "")).strip()), "build_id missing")
    require(bool(str(evidence.get("capabilities", "")).strip()), "capabilities missing")

    identity_fields = ("board_serial", "pynq_image", "pynq_version")
    for field in identity_fields:
        value = str(evidence.get(field, "")).strip().lower()
        if require_board_identity:
            require(value not in ("", "unknown"), f"{field} is unknown")
        elif value in ("", "unknown"):
            warnings.append(f"{field} is unknown")

    if schema == "opennpu.board_gemm_soak.v1":
        requested = float(evidence.get("requested_duration_seconds", 0))
        elapsed = float(evidence.get("elapsed_seconds", 0))
        required = max(float(minimum_duration_seconds), requested)
        require(requested > 0, "requested_duration_seconds must be positive")
        require(elapsed >= required, f"elapsed_seconds must be >= {required}")
        require(int(evidence.get("completed_cases", 0)) > 0, "no completed cases")
        for field in ("mismatches", "timeouts", "recoveries"):
            require(evidence.get(field) == 0, f"{field} must be zero")
        shapes = evidence.get("shapes")
        counts = evidence.get("shape_case_counts")
        require(isinstance(shapes, list) and bool(shapes), "shapes missing")
        require(isinstance(counts, dict) and bool(counts), "shape_case_counts missing")
        if isinstance(counts, dict):
            require(all(isinstance(v, int) and v > 0 for v in counts.values()), "every shape must complete at least once")
            require(sum(counts.values()) == evidence.get("completed_cases"), "shape case counts do not sum to completed_cases")
        summary = evidence.get("transaction_summary", {})
        require(int(summary.get("transactions", 0)) > 0, "no transactions recorded")
        require(int(summary.get("effective_macs", 0)) > 0, "no effective MACs recorded")
        require(float(summary.get("dma_pl_wall_seconds", -1)) >= 0, "DMA+PL wall time missing")
        require(int(summary.get("pl_total_cycles", -1)) >= 0, "PL cycle count missing")
    elif schema == "opennpu.board_gemm_recovery.v1":
        expected_error = evidence.get("expected_error_code")
        require(expected_error == 0x07, "expected unsupported-mode error must be 0x07")
        require(evidence.get("injected_error_code") == expected_error, "injected error code mismatch")
        require(evidence.get("post_reset_error_code") == 0, "soft reset did not clear the error")
        require(evidence.get("post_reset_exact") is True, "post-reset GEMM was not exact")
        require(int(evidence.get("post_reset_transactions", 0)) > 0, "no post-reset transactions")
        shape = evidence.get("post_reset_shape", {})
        require(all(isinstance(shape.get(k), int) and shape[k] > 0 for k in ("m", "n", "k")), "post-reset shape missing")

    return {
        "schema": "pynq.gemm_resilience_validation.v1",
        "evidence_schema": schema,
        "passed": not errors,
        "errors": errors,
        "warnings": warnings,
    }


def self_test() -> None:
    common = {
        "success": True,
        "started_utc": "2026-09-12T00:00:00Z",
        "finished_utc": "2026-09-12T00:30:01Z",
        "timeout_seconds": 10,
        "clock_hz": 100_000_000,
        "bitstream_sha256": "a" * 64,
        "build_id": "0x2026d003",
        "capabilities": "0x1",
        "board_serial": "demo",
        "pynq_image": "pynq-z2-v3.1.1",
        "pynq_version": "3.1.1",
    }
    soak = dict(common)
    soak.update({
        "schema": "opennpu.board_gemm_soak.v1",
        "requested_duration_seconds": 1800,
        "elapsed_seconds": 1800.1,
        "completed_cases": 2,
        "mismatches": 0,
        "timeouts": 0,
        "recoveries": 0,
        "shapes": [{"m": 1, "n": 1, "k": 1}],
        "shape_case_counts": {"1x1x1": 2},
        "transaction_summary": {
            "transactions": 2,
            "effective_macs": 2,
            "dma_pl_wall_seconds": 0.1,
            "pl_total_cycles": 10,
        },
    })
    assert validate(soak, minimum_duration_seconds=1800, require_board_identity=True)["passed"]
    soak["timeouts"] = 1
    assert not validate(soak)["passed"]

    recovery = dict(common)
    recovery.update({
        "schema": "opennpu.board_gemm_recovery.v1",
        "expected_error_code": 7,
        "injected_error_code": 7,
        "post_reset_error_code": 0,
        "post_reset_exact": True,
        "post_reset_transactions": 12,
        "post_reset_shape": {"m": 15, "n": 13, "k": 17},
    })
    assert validate(recovery, require_board_identity=True)["passed"]
    recovery["post_reset_exact"] = False
    assert not validate(recovery)["passed"]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("evidence", type=Path, nargs="?")
    parser.add_argument("--require-duration", type=float, default=0.0)
    parser.add_argument("--require-board-identity", action="store_true")
    parser.add_argument("--json", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("PASS: self-test")
        return 0
    if args.evidence is None:
        parser.error("evidence is required unless --self-test is used")
    if args.require_duration < 0:
        parser.error("--require-duration must be nonnegative")
    try:
        evidence = json.loads(args.evidence.read_text(encoding="utf-8"))
        result = validate(
            evidence,
            minimum_duration_seconds=args.require_duration,
            require_board_identity=args.require_board_identity,
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
