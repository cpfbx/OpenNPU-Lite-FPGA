import copy
import hashlib
import json
import os
from pathlib import Path
import stat
import tempfile
from types import SimpleNamespace
from unittest import mock
import unittest

from test_helpers import Files, GEMM_PATH, ROOT, gemm, links, manifest, module

STRICT_PATH = "skill/pynq-dma-validation/scripts/inspect_overlay_strict.py"
strict = module("strict_overlay_v2", STRICT_PATH)
legacy = module("legacy_spoof_regression", "skill/pynq-dma-validation/scripts/inspect_overlay.py")


class ManifestEntryRegression(Files):
    def setUp(self):
        super().setUp()
        (self.base / "item").write_bytes(b"ok")
        (self.base / "manifest.json").write_text(json.dumps({"format": "skill-review-manifest-v1", "files": {"item": hashlib.sha256(b"ok").hexdigest()}}), encoding="utf-8")

    def symlink(self, name, destination, directory=False):
        try:
            (self.base / name).symlink_to(destination, target_is_directory=directory)
        except OSError as exc:
            self.skipTest("OS denied symlink creation: " + str(exc))

    def test_unexpected_empty_directory_rejected(self):
        (self.base / "unexpected").mkdir()
        self.assertFalse(manifest.verify(self.base)["member_identity_ok"])

    def test_directory_link_rejected(self):
        other = tempfile.TemporaryDirectory(prefix="skill_outside_dir_")
        self.addCleanup(other.cleanup)
        (Path(other.name) / "synthetic.txt").write_bytes(b"not-private")
        self.symlink("escaped", other.name, True)
        with self.assertRaises(ValueError):
            manifest.verify(self.base)

    def test_dangling_link_rejected(self):
        self.symlink("dangling", self.base / "does_not_exist")
        with self.assertRaises(ValueError):
            manifest.verify(self.base)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "real FIFO creation requires POSIX")
    def test_fifo_rejected_without_open(self):
        os.mkfifo(self.base / "unexpected.pipe")
        with self.assertRaises(ValueError):
            manifest.verify(self.base)

    def test_windows_reparse_detection_unit(self):
        # A unit branch check, not a real Windows junction trial.
        info = SimpleNamespace(st_mode=stat.S_IFDIR, st_file_attributes=0x400)
        self.assertTrue(manifest.link_or_reparse(info))

    def test_real_directory_allowed_when_required(self):
        subdir = self.base / "sub"
        subdir.mkdir()
        (subdir / "member").write_bytes(b"x")
        manifest_path = self.base / "manifest.json"
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        data["files"]["sub/member"] = hashlib.sha256(b"x").hexdigest()
        manifest_path.write_text(json.dumps(data), encoding="utf-8")
        self.assertTrue(manifest.verify(self.base)["member_identity_ok"])


class LinkLineAndAliasRegression(Files):
    def document(self, raw):
        path = self.write("source.py", raw)
        doc = {"format": "skill-review-links-v1", "claims": [{"id": "line-claim", "statement": "LF line 2 quote", "classification": "observed", "references": [{"path": path.name, "sha256": hashlib.sha256(raw).hexdigest(), "lines": [2, 2], "quote": "target_line = 99"}]}]}
        return path, doc

    def test_bare_cr_is_not_newline(self):
        _, doc = self.document(b"progress 10%\rprogress 100%\ntarget_line = 99\n")
        self.assertTrue(links.check(doc, self.base)["link_integrity_ok"])

    def test_review_json_directory_rejected_before_open(self):
        with self.assertRaisesRegex(ValueError, "regular file"):
            links.load_review(self.base)

    def test_crlf_normalized_for_anchor(self):
        _, doc = self.document(b"line one\r\ntarget_line = 99\r\n")
        self.assertTrue(links.check(doc, self.base)["link_integrity_ok"])

    def test_other_unicode_controls_not_newlines(self):
        for separator in ("\v", "\f", "\u2028", "\u2029", "\u0085"):
            with self.subTest(separator=repr(separator)):
                _, doc = self.document(("a" + separator + "b\ntarget_line = 99\n").encode("utf-8"))
                self.assertTrue(links.check(doc, self.base)["link_integrity_ok"])

    def test_no_phantom_line_after_trailing_lf(self):
        _, doc = self.document(b"one\ntarget_line = 99\n")
        doc["claims"][0]["references"][0].update(lines=[3, 3], quote="x")
        self.assertFalse(links.check(doc, self.base)["link_integrity_ok"])

    def test_internal_symlink_rejected(self):
        path, doc = self.document(b"one\ntarget_line = 99\n")
        alias = self.base / "alias.py"
        try:
            alias.symlink_to(path)
        except OSError as exc:
            self.skipTest("OS denied symlink creation: " + str(exc))
        doc["claims"][0]["references"][0]["path"] = alias.name
        with self.assertRaises(ValueError):
            links.check(doc, self.base)

    def test_reparse_alias_unit_without_os_link(self):
        # Exercises the Windows attribute check only; not OS junction evidence.
        with mock.patch.object(Path, "lstat", return_value=SimpleNamespace(st_mode=stat.S_IFREG, st_file_attributes=0x400)):
            with self.assertRaisesRegex(ValueError, "reparse"):
                links.no_aliases(self.base / "example")


class GemmCliRegression(Files):
    def assert_json_error(self, *args):
        result = self.cli(GEMM_PATH, *args)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertFalse(json.loads(result.stderr)["input_valid"])

    def test_large_shape_structured_error(self):
        self.assert_json_error("--a", "absent", "--b", "absent", "--output", "absent", "--shape", "512,512,512")

    def test_shape_syntax_structured_error(self):
        self.assert_json_error("--a", "absent", "--b", "absent", "--output", "absent", "--shape", "1,no,2")

    def test_missing_required_argument_structured_error(self):
        self.assert_json_error("--shape", "1,1,1")

    def test_unknown_flag_structured_error(self):
        self.assert_json_error("--a", "absent", "--b", "absent", "--output", "absent", "--shape", "1,1,1", "--unsupported")

    def test_help_still_succeeds(self):
        result = self.cli(GEMM_PATH, "--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("--shape", result.stdout)


class StrictOverlayRegression(Files):
    def pair(self, module_xml):
        bit = self.write("design.bit", b"synthetic-not-bit")
        self.write("design.hwh", ("<SYSTEM>" + module_xml + "</SYSTEM>").encode())
        return bit

    def test_instance_name_spoofs_legacy_not_strict(self):
        bit = self.pair('<MODULE INSTANCE="axi_dma_fake" MODTYPE="xlconstant" VLNV="xilinx.com:ip:xlconstant:1.0"/>')
        self.assertTrue(legacy.inspect(bit, ["axi_dma"])["ok"])
        self.assertFalse(strict.inspect(bit, ["axi_dma"])["ok"])
        result = self.cli(STRICT_PATH, bit, "--require-type", "axi_dma")
        self.assertEqual(result.returncode, 1)
        self.assertFalse(json.loads(result.stdout)["ok"])

    def test_type_substring_not_sufficient(self):
        bit = self.pair('<MODULE INSTANCE="x" MODTYPE="not_axi_dma"/>')
        self.assertFalse(strict.inspect(bit, ["axi_dma"])["ok"])

    def test_exact_type_with_different_instance(self):
        bit = self.pair('<MODULE INSTANCE="transfer_7" MODTYPE="axi_dma" VLNV="xilinx.com:ip:axi_dma:7.1"/>')
        report = strict.inspect(bit, ["axi_dma"])
        self.assertTrue(report["ok"])
        self.assertEqual(report["matches"]["axi_dma"][0]["matched_fields"], ["modtype", "vlnv_name"])
        self.assertFalse(report["bit_payload_validity_verified"])
        self.assertFalse(report["address_map_verified"])

    def test_exact_vlnv_when_modtype_missing(self):
        bit = self.pair('<MODULE INSTANCE="transfer_7" VLNV="xilinx.com:ip:axi_dma:7.1"/>')
        self.assertTrue(strict.inspect(bit, ["axi_dma"])["ok"])

    def test_conflicting_type_metadata_rejected(self):
        bit = self.pair('<MODULE INSTANCE="x" MODTYPE="xlconstant" VLNV="xilinx.com:ip:axi_dma:7.1"/>')
        report = strict.inspect(bit, ["axi_dma"])
        self.assertFalse(report["ok"])
        self.assertTrue(report["type_conflicts"])

    def test_all_requested_types_required(self):
        bit = self.pair('<MODULE INSTANCE="x" MODTYPE="axi_dma"/>')
        self.assertFalse(strict.inspect(bit, ["axi_dma", "absent"])["ok"])

    def test_xml_namespace(self):
        bit = self.pair('<p:MODULE xmlns:p="urn:test" INSTANCE="x" MODTYPE="axi_dma"/>')
        self.assertTrue(strict.inspect(bit, ["axi_dma"])["ok"])

    def test_dtd_rejected(self):
        bit = self.pair("")
        bit.with_suffix(".hwh").write_bytes(b'<!DOCTYPE SYSTEM [<!ENTITY x "axi_dma">]><SYSTEM/>')
        with self.assertRaisesRegex(ValueError, "DTD"):
            strict.inspect(bit, ["axi_dma"])

    def test_missing_hwh_cli_two(self):
        bit = self.write("missing.bit", b"fake")
        self.assertEqual(self.cli(STRICT_PATH, bit).returncode, 2)


class LegacyDisclosureRegression(Files):
    def evidence(self):
        return {"schema": "opennpu.board_gemm.v1", "success": True,
                "started_utc": "synthetic", "finished_utc": "synthetic",
                "shape": {"m": 1, "n": 1, "k": 1}, "seed": 1,
                "requested_iterations": 1, "completed_iterations": True,
                "timeout_seconds": 1, "clock_hz": 100, "bitstream_sha256": "a" * 64,
                "build_id": "demo", "capabilities": "demo", "tile_config": {"bm": 1},
                "case_summary": {"iterations": 1, "effective_macs": 1, "end_to_end_seconds": 0.2},
                "summary": {"transactions": 1, "effective_macs": 1,
                            "dma_pl_wall_seconds": float("inf"), "pl_total_cycles": 0,
                            "pl_compute_accounted_cycles": 999999}}

    def test_legacy_bool_infinity_and_counter_not_hardened(self):
        adapter = module("legacy_gemm_ce05", "skill/pynq-gemm-validation/scripts/validate_gemm_evidence.py")
        self.assertTrue(adapter.validate(self.evidence())["passed"])

    def test_legacy_arrays_crash_not_normal_invalid_code(self):
        array = self.write("array.json", b"[]")
        for script in ("validate_gemm_evidence.py", "validate_resilience_evidence.py"):
            with self.subTest(script=script):
                result = self.cli("skill/pynq-gemm-validation/scripts/" + script, array)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Traceback", result.stderr)

    def test_generated_json_is_lf(self):
        for relative in ("provenance.json", "evaluation/link_example.json"):
            self.assertNotIn(b"\r\n", (ROOT / relative).read_bytes())
