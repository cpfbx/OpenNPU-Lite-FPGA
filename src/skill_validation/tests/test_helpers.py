import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def module(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


GEMM_PATH = "skill/pynq-gemm-validation/scripts/compare_int8_gemm.py"
LINK_PATH = "skill/engineering-evidence-review/scripts/check_evidence_links.py"
gemm = module("candidate_small_gemm", GEMM_PATH)
links = module("candidate_links", LINK_PATH)
inspect_overlay = module("candidate_overlay", "skill/pynq-dma-validation/scripts/inspect_overlay.py")
manifest = module("candidate_manifest", "verify_candidate.py")


class Files(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="opennpu_skill_test_")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)

    def write(self, name, raw):
        path = self.base / name
        path.write_bytes(raw)
        return path

    def cli(self, relative, *args):
        return subprocess.run([sys.executable, "-I", "-B", str(ROOT / relative), *map(str, args)],
                              capture_output=True, text=True, timeout=15)


class GemmTests(Files):
    def operands(self):
        # 2x3 times 3x2, independent hand-calculated C.
        a = self.write("a.bin", struct.pack("6b", -1, 2, 3, 4, -5, 6))
        b = self.write("b.bin", struct.pack("6b", 7, -8, 9, 10, -11, 12))
        c = self.write("c.bin", struct.pack("4i", -22, 64, -83, -10))
        # Explicit endian independent of the host.
        c.write_bytes(struct.pack("<4i", -22, 64, -83, -10))
        return a, b, c

    def test_hand_computed_signed_nonsquare(self):
        report = gemm.compare(*self.operands(), (2, 2, 3))
        self.assertTrue(report["exact"])
        self.assertEqual(report["checked_positions"], 4)
        self.assertEqual(report["effective_macs"], 12)
        self.assertFalse(report["hardware_execution_verified"])

    def test_signed_extrema(self):
        a = self.write("a", b"\x80\x7f")
        b = self.write("b", b"\x80\x7f")
        c = self.write("c", struct.pack("<i", 32513))
        self.assertTrue(gemm.compare(a, b, c, (1, 1, 2))["exact"])

    def test_all_mismatches_counted(self):
        a, b, c = self.operands()
        c.write_bytes(b"\0" * 16)
        result = gemm.compare(a, b, c, (2, 2, 3))
        self.assertEqual(result["mismatches"], 4)
        self.assertEqual(result["first_mismatch"]["expected"], -22)

    def test_trailing_bytes_rejected(self):
        a, b, c = self.operands()
        c.write_bytes(c.read_bytes() + b"\0")
        with self.assertRaises(ValueError):
            gemm.compare(a, b, c, (2, 2, 3))

    def test_short_input_rejected(self):
        a, b, c = self.operands()
        a.write_bytes(b"\0")
        with self.assertRaises(ValueError):
            gemm.compare(a, b, c, (2, 2, 3))

    def test_boolean_dimension_rejected(self):
        with self.assertRaises(ValueError):
            gemm.checked_shape((True, 1, 1))

    def test_nonpositive_dimension_rejected(self):
        with self.assertRaises(ValueError):
            gemm.checked_shape((1, 0, 1))

    def test_overflow_contract_rejected_before_read(self):
        with self.assertRaisesRegex(ValueError, "overflow"):
            gemm.compare("absent", "absent", "absent", (1, 1, 131072))

    def test_large_work_rejected_before_read(self):
        with self.assertRaisesRegex(ValueError, "limited"):
            gemm.compare("absent", "absent", "absent", (512, 512, 512))

    def test_cli_exact_zero_and_input_unchanged(self):
        paths = self.operands()
        before = [p.read_bytes() for p in paths]
        result = self.cli(GEMM_PATH, "--a", paths[0], "--b", paths[1], "--output", paths[2], "--shape", "2,2,3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(before, [p.read_bytes() for p in paths])

    def test_cli_mismatch_one(self):
        a, b, c = self.operands()
        c.write_bytes(b"\0" * 16)
        result = self.cli(GEMM_PATH, "--a", a, "--b", b, "--output", c, "--shape", "2,2,3")
        self.assertEqual(result.returncode, 1)

    def test_cli_invalid_two(self):
        result = self.cli(GEMM_PATH, "--a", "absent", "--b", "absent", "--output", "absent", "--shape", "1,1,1")
        self.assertEqual(result.returncode, 2)


class LinkTests(Files):
    def setUp(self):
        super().setUp()
        self.raw = b"line one\nvalue = 7\nline three\n"
        self.write("source.py", self.raw)
        self.doc = {"format": "skill-review-links-v1", "claims": [{"id": "c1", "statement": "A claim for review", "classification": "observed", "references": [{"path": "source.py", "sha256": hashlib.sha256(self.raw).hexdigest(), "lines": [2, 2], "quote": "value = 7"}]}]}

    def test_matching_links_not_truth(self):
        report = links.check(self.doc, self.base)
        self.assertTrue(report["link_integrity_ok"])
        self.assertFalse(report["claim_truth_verified"])
        self.assertFalse(report["independent_review_completed"])

    def test_false_prose_is_not_certified(self):
        self.doc["claims"][0]["statement"] = "This file proves global optimality and physical hardware success"
        report = links.check(self.doc, self.base)
        self.assertTrue(report["link_integrity_ok"])
        self.assertFalse(report["claim_truth_verified"])

    def test_changed_bytes_rejected(self):
        self.write("source.py", b"changed\n")
        self.assertFalse(links.check(self.doc, self.base)["link_integrity_ok"])

    def test_wrong_quote_rejected(self):
        self.doc["claims"][0]["references"][0]["quote"] = "value = 8"
        self.assertFalse(links.check(self.doc, self.base)["link_integrity_ok"])

    def test_wrong_line_rejected(self):
        self.doc["claims"][0]["references"][0]["lines"] = [4, 4]
        self.assertFalse(links.check(self.doc, self.base)["link_integrity_ok"])

    def test_missing_file_rejected(self):
        self.doc["claims"][0]["references"][0]["path"] = "absent.py"
        self.assertFalse(links.check(self.doc, self.base)["link_integrity_ok"])

    def test_parent_escape_rejected(self):
        self.doc["claims"][0]["references"][0]["path"] = "../source.py"
        with self.assertRaises(ValueError):
            links.check(self.doc, self.base)

    def test_absolute_drive_rejected(self):
        self.doc["claims"][0]["references"][0]["path"] = "C:/source.py"
        with self.assertRaises(ValueError):
            links.check(self.doc, self.base)

    def test_backslash_rejected(self):
        self.doc["claims"][0]["references"][0]["path"] = "sub\\source.py"
        with self.assertRaises(ValueError):
            links.check(self.doc, self.base)

    def test_extra_fields_rejected(self):
        self.doc["passed"] = True
        with self.assertRaises(ValueError):
            links.check(self.doc, self.base)

    def test_bool_line_rejected(self):
        self.doc["claims"][0]["references"][0]["lines"] = [True, 2]
        with self.assertRaises(ValueError):
            links.check(self.doc, self.base)

    def test_duplicate_claim_id_rejected(self):
        self.doc["claims"].append(copy.deepcopy(self.doc["claims"][0]))
        with self.assertRaises(ValueError):
            links.check(self.doc, self.base)

    def test_unverified_may_have_no_references(self):
        self.doc["claims"][0].update(classification="unverified", references=[])
        self.assertTrue(links.check(self.doc, self.base)["link_integrity_ok"])

    def test_observed_requires_references(self):
        self.doc["claims"][0]["references"] = []
        with self.assertRaises(ValueError):
            links.check(self.doc, self.base)

    def test_partial_anchor_rejected(self):
        del self.doc["claims"][0]["references"][0]["quote"]
        with self.assertRaises(ValueError):
            links.check(self.doc, self.base)

    def test_duplicate_json_keys_rejected(self):
        path = self.write("review.json", b'{"format":1,"format":2}')
        with self.assertRaises(ValueError):
            links.load_review(path)

    def test_nonfinite_json_rejected(self):
        for token in (b"NaN", b"Infinity", b"-Infinity"):
            path = self.write("review.json", b'{"value":' + token + b'}')
            with self.assertRaises(ValueError):
                links.load_review(path)

    def test_hash_only_before_anchor(self):
        ref = self.doc["claims"][0]["references"][0]
        self.doc["claims"][0]["references"].insert(0, {"path": ref["path"], "sha256": ref["sha256"]})
        self.assertTrue(links.check(self.doc, self.base)["link_integrity_ok"])

    def test_cli_zero(self):
        path = self.write("review.json", json.dumps(self.doc).encode())
        result = self.cli(LINK_PATH, path, "--root", self.base)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_cli_one(self):
        self.doc["claims"][0]["references"][0]["sha256"] = "0" * 64
        path = self.write("review.json", json.dumps(self.doc).encode())
        self.assertEqual(self.cli(LINK_PATH, path, "--root", self.base).returncode, 1)

    def test_cli_two(self):
        path = self.write("review.json", b'{"claims":[]}')
        self.assertEqual(self.cli(LINK_PATH, path, "--root", self.base).returncode, 2)

    def test_review_budget(self):
        path = self.write("review.json", b"x" * 20)
        with mock.patch.object(links, "MAX_REVIEW", 10):
            with self.assertRaisesRegex(ValueError, "budget"):
                links.load_review(path)

    def test_reference_budget(self):
        with mock.patch.object(links, "MAX_TEXT", 2):
            with self.assertRaisesRegex(ValueError, "budget"):
                links.check(self.doc, self.base)

    def test_too_many_claims(self):
        self.doc["claims"] = self.doc["claims"] * 1001
        with self.assertRaisesRegex(ValueError, "budget"):
            links.check(self.doc, self.base)

    def test_too_many_references(self):
        self.doc["claims"][0]["references"] *= 5001
        with self.assertRaisesRegex(ValueError, "budget"):
            links.check(self.doc, self.base)

    def test_invalid_utf8_anchor(self):
        raw = b"\xff\n"
        self.write("source.py", raw)
        self.doc["claims"][0]["references"][0]["sha256"] = hashlib.sha256(raw).hexdigest()
        path = self.write("review.json", json.dumps(self.doc).encode())
        self.assertEqual(self.cli(LINK_PATH, path, "--root", self.base).returncode, 2)

    def test_symlink_escape_when_os_allows(self):
        # Windows may require developer mode/privileges; a skip is not a pass.
        other = tempfile.TemporaryDirectory(prefix="opennpu_skill_outside_")
        self.addCleanup(other.cleanup)
        outside = Path(other.name) / "outside.py"
        outside.write_bytes(self.raw)
        link = self.base / "link.py"
        try:
            link.symlink_to(outside)
        except OSError as exc:
            self.skipTest("OS did not permit creating symlink: " + str(exc))
        self.doc["claims"][0]["references"][0]["path"] = "link.py"
        with self.assertRaisesRegex(ValueError, r"symlink|reparse|escapes"):
            links.check(self.doc, self.base)


class OverlayTests(Files):
    def pair(self):
        bit = self.write("other_design.bit", b"synthetic-not-a-bitstream")
        self.write("other_design.hwh", b'<SYSTEM><MODULE INSTANCE="transport_9" MODTYPE="axi_dma" VLNV="xilinx.com:ip:axi_dma:7.1"><PARAMETERS><PARAMETER NAME="C_BASEADDR" VALUE="0x42000000"/></PARAMETERS></MODULE></SYSTEM>')
        return bit

    def test_renamed_instance_discovered(self):
        result = inspect_overlay.inspect(self.pair(), ["axi_dma"])
        self.assertTrue(result["ok"])
        self.assertEqual(result["addressable_modules"][0]["instance"], "transport_9")

    def test_fake_bit_can_pass_metadata_not_bit_validity(self):
        self.assertTrue(inspect_overlay.inspect(self.pair(), ["axi_dma"])["ok"])

    def test_second_required_type_not_ignored(self):
        self.assertFalse(inspect_overlay.inspect(self.pair(), ["axi_dma", "not_present"])["ok"])

    def test_missing_hwh(self):
        bit = self.write("design.bit", b"fake")
        with self.assertRaises(FileNotFoundError):
            inspect_overlay.inspect(bit, ["axi_dma"])

    def test_malformed_hwh(self):
        bit = self.pair()
        bit.with_suffix(".hwh").write_bytes(b"<SYSTEM>")
        result = self.cli("skill/pynq-dma-validation/scripts/inspect_overlay.py", bit)
        self.assertEqual(result.returncode, 2)

    def test_cli_missing_type_exit_one(self):
        result = self.cli("skill/pynq-dma-validation/scripts/inspect_overlay.py", self.pair(), "--require-type", "absent")
        self.assertEqual(result.returncode, 1)


class ManifestTests(Files):
    def inventory(self):
        self.write("item.txt", b"kept")
        self.write("manifest.json", json.dumps({"format": "skill-review-manifest-v1", "files": {"item.txt": hashlib.sha256(b"kept").hexdigest()}}).encode())

    def test_exact_inventory(self):
        self.inventory()
        self.assertTrue(manifest.verify(self.base)["member_identity_ok"])

    def test_changed_member(self):
        self.inventory()
        self.write("item.txt", b"changed")
        self.assertFalse(manifest.verify(self.base)["member_identity_ok"])

    def test_extra_member(self):
        self.inventory()
        self.write("extra.txt", b"extra")
        self.assertFalse(manifest.verify(self.base)["member_identity_ok"])

    def test_missing_member(self):
        self.write("manifest.json", json.dumps({"format": "skill-review-manifest-v1", "files": {"absent.txt": "0" * 64}}).encode())
        self.assertFalse(manifest.verify(self.base)["member_identity_ok"])

    def test_manifest_path_escape(self):
        self.write("manifest.json", json.dumps({"format": "skill-review-manifest-v1", "files": {"../other.txt": "0" * 64}}).encode())
        with self.assertRaises(ValueError):
            manifest.verify(self.base)


class HistoricalAdapterLimits(unittest.TestCase):
    def test_retained_self_tests(self):
        for relative in ("skill/pynq-gemm-validation/scripts/validate_gemm_evidence.py",
                         "skill/pynq-gemm-validation/scripts/validate_resilience_evidence.py"):
            adapter = module("legacy_" + Path(relative).stem, relative)
            adapter.self_test()

    def test_legacy_recovery_infinite_timeout_is_not_hardened(self):
        adapter = module("legacy_limit_example", "skill/pynq-gemm-validation/scripts/validate_resilience_evidence.py")
        # Document the unchanged adapter's limitation; this is not a valid gate.
        evidence = {"schema": "opennpu.board_gemm_recovery.v1", "success": True,
                    "started_utc": "synthetic", "finished_utc": "synthetic",
                    "timeout_seconds": float("inf"), "clock_hz": 100,
                    "bitstream_sha256": "a" * 64, "build_id": "demo", "capabilities": "demo",
                    "expected_error_code": 7, "injected_error_code": 7, "post_reset_error_code": 0,
                    "post_reset_exact": True, "post_reset_transactions": 1,
                    "post_reset_shape": {"m": 1, "n": 1, "k": 1}}
        self.assertTrue(adapter.validate(evidence)["passed"])


if __name__ == "__main__":
    unittest.main()
