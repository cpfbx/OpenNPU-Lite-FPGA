"""Executable examples for the proposed MODE 11 global-timeline contract."""

from __future__ import annotations

import unittest

from d007_mode11_contract import summarize_cycles, validate_summary


def cycle(*active: str, bank_wait: bool = False, output_wait: bool = False):
    return {
        "load": "load" in active,
        "array": "array" in active,
        "store": "store" in active,
        "output": "output" in active,
        "bank_wait": bank_wait,
        "output_wait": output_wait,
    }


class Mode11ContractTests(unittest.TestCase):
    def test_cross_tile_array_output_overlap_is_global(self) -> None:
        snapshot = summarize_cycles([
            cycle("load"),
            cycle("array", "output"),  # two distinct tiles may own the work
            cycle("store", "output"),
            cycle(bank_wait=True, output_wait=True),
        ])
        self.assertTrue(all(validate_summary(snapshot).values()))
        self.assertEqual(snapshot["pl_total_cycles"], 4)
        self.assertEqual(snapshot["pl_overlap_credit_cycles"], 2)
        self.assertEqual(snapshot["pl_array_output_work_overlap_cycles"], 1)
        self.assertEqual(snapshot["pl_compute_wait_bank_cycles"], 1)
        self.assertEqual(snapshot["pl_no_work_cycles"], 1)

    def test_ready_bank_is_not_parallel_work(self) -> None:
        snapshot = summarize_cycles([cycle("array"), cycle("output")])
        self.assertEqual(snapshot["pl_overlap_credit_cycles"], 0)
        self.assertEqual(snapshot["pl_array_output_work_overlap_cycles"], 0)
        self.assertTrue(all(validate_summary(snapshot).values()))

    def test_false_double_count_and_version_are_rejected(self) -> None:
        snapshot = summarize_cycles([cycle("array", "output")])
        snapshot["pl_overlap_credit_cycles"] += 1
        snapshot["counter_contract_version"] = 1
        gates = validate_summary(snapshot)
        self.assertFalse(gates["work_conservation"])
        self.assertFalse(gates["version"])

    def test_invalid_cycle_is_not_silently_accepted(self) -> None:
        with self.assertRaisesRegex(ValueError, "classify exactly"):
            summarize_cycles([{"array": True}])
        with self.assertRaisesRegex(ValueError, "cannot also wait"):
            summarize_cycles([cycle("output", output_wait=True)])

    def test_algebraically_closed_but_impossible_union_is_rejected(self) -> None:
        snapshot = summarize_cycles([cycle("array", "output")])
        snapshot.update(pl_work_union_cycles=0, pl_no_work_cycles=1,
                        pl_overlap_credit_cycles=2)
        gates = validate_summary(snapshot)
        self.assertTrue(gates["work_conservation"])
        self.assertTrue(gates["total_partition"])
        self.assertFalse(gates["union_bounds"])


if __name__ == "__main__":
    unittest.main()
