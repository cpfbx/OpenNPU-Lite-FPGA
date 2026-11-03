"""Independent cycle-level reference contract for experimental MODE 11.

This is a specification oracle, not evidence that the RTL exposes these
counters yet. MODE 1--10 retain their existing version-1 counter contract.
"""

from __future__ import annotations

from collections.abc import Iterable, Mapping


CONTRACT_VERSION = 2
WORK_ENGINES = ("load", "array", "store", "output")
EVENTS = (*WORK_ENGINES, "bank_wait", "output_wait")


def summarize_cycles(cycles: Iterable[Mapping[str, bool]]) -> dict[str, int]:
    """Count one global clock timeline; no per-tile sums are involved."""

    result = {
        "counter_contract_version": CONTRACT_VERSION,
        "pl_total_cycles": 0,
        "pl_work_union_cycles": 0,
        "pl_overlap_credit_cycles": 0,
        "pl_no_work_cycles": 0,
        "pl_array_output_work_overlap_cycles": 0,
        "pl_compute_wait_bank_cycles": 0,
        "pl_output_wait_tready_cycles": 0,
    }
    for engine in WORK_ENGINES:
        result[f"pl_{engine}_work_cycles"] = 0

    for index, cycle in enumerate(cycles):
        if set(cycle) != set(EVENTS):
            raise ValueError(f"cycle {index} must classify exactly {EVENTS}")
        if any(type(value) is not bool for value in cycle.values()):
            raise ValueError(f"cycle {index} events must be booleans")
        if cycle["output_wait"] and cycle["output"]:
            raise ValueError("an output transfer cannot also wait for TREADY")

        result["pl_total_cycles"] += 1
        active = sum(cycle[engine] for engine in WORK_ENGINES)
        for engine in WORK_ENGINES:
            result[f"pl_{engine}_work_cycles"] += cycle[engine]
        result["pl_work_union_cycles"] += active != 0
        result["pl_overlap_credit_cycles"] += max(active - 1, 0)
        result["pl_no_work_cycles"] += active == 0
        result["pl_array_output_work_overlap_cycles"] += (
            cycle["array"] and cycle["output"]
        )
        result["pl_compute_wait_bank_cycles"] += cycle["bank_wait"]
        result["pl_output_wait_tready_cycles"] += cycle["output_wait"]
    return result


def validate_summary(summary: Mapping[str, int]) -> dict[str, bool]:
    """Check exact construction identities and subset bounds."""

    required = (
        "counter_contract_version",
        "pl_total_cycles",
        "pl_work_union_cycles",
        "pl_overlap_credit_cycles",
        "pl_no_work_cycles",
        "pl_array_output_work_overlap_cycles",
        "pl_compute_wait_bank_cycles",
        "pl_output_wait_tready_cycles",
        *(f"pl_{engine}_work_cycles" for engine in WORK_ENGINES),
    )
    values = {}
    for key in required:
        value = summary.get(key)
        if type(value) is not int or value < 0:
            raise ValueError(f"{key} must be a nonnegative integer")
        values[key] = value

    total = values["pl_total_cycles"]
    union = values["pl_work_union_cycles"]
    work = {engine: values[f"pl_{engine}_work_cycles"] for engine in WORK_ENGINES}
    return {
        "version": values["counter_contract_version"] == CONTRACT_VERSION,
        "total_partition": total == union + values["pl_no_work_cycles"],
        "work_conservation": sum(work.values())
        == union + values["pl_overlap_credit_cycles"],
        "array_output_bound": values["pl_array_output_work_overlap_cycles"]
        <= min(work["array"], work["output"]),
        "wait_bounds": values["pl_compute_wait_bank_cycles"] <= total
        and values["pl_output_wait_tready_cycles"] <= total,
        "engine_bounds": all(value <= total for value in work.values()),
        "union_bounds": max(work.values()) <= union <= sum(work.values())
        and values["pl_overlap_credit_cycles"] <= 3 * union,
    }
