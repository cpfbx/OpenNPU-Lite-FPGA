"""Explicit PC-only suite with raw receipts handled by the outer author runner."""
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parent
for entry in reversed([ROOT/'frozen_source',ROOT,ROOT/'frozen_tests']):
    sys.path.insert(0,str(entry))


def main():
    suite=unittest.TestLoader().loadTestsFromNames(['test_driver_integration','test_entry_safety','test_flat_candidate',
        'test_chain_protocol','test_k_major','test_d007_mode11_contract'])
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() and not result.skipped else 1


if __name__=='__main__':sys.exit(main())
