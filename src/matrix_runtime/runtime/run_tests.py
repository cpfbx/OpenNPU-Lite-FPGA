"""PC-only regression; fixture bytes on fake DMA are never hardware evidence."""
from pathlib import Path
import sys
import unittest

ROOT=Path(__file__).resolve().parent
for path in reversed([ROOT/'tests',ROOT/'src',ROOT,ROOT/'legacy',
                      ROOT/'legacy/frozen_source',ROOT/'legacy/frozen_tests']):
    sys.path.insert(0,str(path))


def main():
    suite=unittest.TestLoader().loadTestsFromNames([
        'test_driver_integration','test_entry_safety','test_flat_candidate',
        'test_chain_protocol','test_k_major','test_d007_mode11_contract','test_comparison','test_process',
        'test_round','test_runtime','test_round_runtime','test_runtime_v3'])
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() and not result.skipped else 1


if __name__=='__main__':sys.exit(main())
