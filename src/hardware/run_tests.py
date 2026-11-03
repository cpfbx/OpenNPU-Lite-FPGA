"""Packaging-only tests; no real Vivado or device invocation."""
from pathlib import Path
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parent))


def main():
    suite=unittest.TestLoader().loadTestsFromNames(['test_rebuild','test_windows_launcher'])
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() and not result.skipped else 1


if __name__=='__main__':sys.exit(main())
