"""candidate_03 regressions; unit simulations are not real OS link trials."""

import json
from pathlib import Path
import unittest
from unittest import mock

import test_helpers as helpers
from test_helpers import Files, module

STRICT_PATH = "skill/pynq-dma-validation/scripts/inspect_overlay_strict.py"
strict = module("strict_overlay_v3_boundaries", STRICT_PATH)


class SymlinkDiagnosticRegression(unittest.TestCase):
    def test_actual_escape_test_assertion_without_link_privileges(self):
        # Execute the original test's assertion even on Windows without symlink
        # privileges. Actual kernel/filesystem behavior remains a separate test.
        original = helpers.links.no_aliases

        def simulated_link(path, target, target_is_directory=False):
            path.write_bytes(Path(target).read_bytes())

        def simulated_rejection(path):
            if Path(path).name == "link.py":
                raise ValueError("symlink or reparse-point reference is unsupported")
            return original(path)

        result = unittest.TestResult()
        with mock.patch.object(Path, "symlink_to", simulated_link), mock.patch.object(
            helpers.links, "no_aliases", simulated_rejection
        ):
            helpers.LinkTests("test_symlink_escape_when_os_allows").run(result)
        self.assertEqual(result.testsRun, 1)
        self.assertEqual(result.failures, [])
        self.assertEqual(result.errors, [])
        self.assertEqual(result.skipped, [])


class StrictInputBoundaryRegression(Files):
    def assert_json_error(self, *args):
        result = self.cli(STRICT_PATH, *args)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        report = json.loads(result.stderr)
        self.assertIs(report["input_valid"], False)
        self.assertIsInstance(report["error"], str)
        self.assertNotIn("Traceback", result.stderr)
        return report

    def test_hwh_only_input_rejected_before_hashing(self):
        for suffix in (".hwh", ".HWH"):
            with self.subTest(suffix=suffix):
                hwh = self.write("without_bit" + suffix, b'<SYSTEM><MODULE MODTYPE="axi_dma"/></SYSTEM>')
                with mock.patch.object(strict, "snapshot", side_effect=AssertionError("must not read")):
                    with self.assertRaisesRegex(ValueError, r"\.bit suffix"):
                        strict.inspect(hwh, ["axi_dma"])
                report = self.assert_json_error(hwh)
                self.assertIn(".bit suffix", report["error"])

    def test_other_or_missing_suffix_rejected(self):
        for name in ("design.txt", "design"):
            with self.subTest(name=name):
                self.assertIn(".bit suffix", self.assert_json_error(self.base / name)["error"])

    def test_valid_bit_pair_including_uppercase_suffix(self):
        # The HWH companion keeps the documented lowercase .hwh suffix.
        for suffix in (".bit", ".BIT"):
            with self.subTest(suffix=suffix):
                bit = self.write("design" + suffix, b"synthetic-not-a-valid-bitstream")
                self.write("design.hwh", b'<SYSTEM><MODULE MODTYPE="axi_dma"/></SYSTEM>')
                result = self.cli(STRICT_PATH, bit)
                self.assertEqual(result.returncode, 0)
                self.assertEqual(result.stderr, "")
                report = json.loads(result.stdout)
                self.assertIs(report["ok"], True)
                self.assertIs(report["bit_payload_validity_verified"], False)
                self.assertNotEqual(report["bit_sha256"], report["hwh_sha256"])

    def test_unknown_flag_json(self):
        for args in (("--unsupported-flag",), ("design.bit", "--unsupported-flag")):
            with self.subTest(args=args):
                self.assertIn("argument parsing", self.assert_json_error(*args)["error"])

    def test_missing_positional_json(self):
        self.assertIn("argument parsing", self.assert_json_error()["error"])

    def test_missing_option_value_json(self):
        self.assertIn("argument parsing", self.assert_json_error("design.bit", "--require-type")["error"])

    def test_help_still_succeeds(self):
        result = self.cli(STRICT_PATH, "--help")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, "")
        self.assertIn("--require-type", result.stdout)
