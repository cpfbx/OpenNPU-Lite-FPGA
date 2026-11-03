#!/usr/bin/env python3
"""Execute local standard-library tests without PYNQ or external services."""

from pathlib import Path
import json
import sys
import unittest

suite = unittest.defaultTestLoader.discover(str(Path(__file__).parent), pattern="test_*.py")
result = unittest.TextTestRunner(verbosity=2).run(suite)
print(json.dumps({"tests_run": result.testsRun, "failures": len(result.failures),
                  "errors": len(result.errors), "skipped": len(result.skipped),
                  "scope": "offline_script_tests_not_agent_behavior"}))
sys.exit(0 if result.wasSuccessful() else 1)
