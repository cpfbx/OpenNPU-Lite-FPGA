"""Packaging-only tests. Tool results below are synthetic, never hardware evidence."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('cold_build_candidate',ROOT/'rebuild.py')
build=importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


def bit(data):
    raw=b'\x00\x09'+b'123456789'+b'\x00\x01'
    for key in b'abcd': raw+=bytes([key])+b'\x00\x02'+b'x\x00'
    return raw+b'e'+len(data).to_bytes(4,'big')+data


TIMING='WNS(ns) TNS(ns)\n --- ---\n 0.118 0.000 0 100 0.066 0.000 0 100 3.750 0.000 0 100\n'


class SourceAndParsers(unittest.TestCase):
    def test_exact_vivado_release(self):
        for value in (b'Vivado v2026.1 (64-bit)\r\n',b'Vivado 2026.1\n',b'Vivado v2026.1'):
            with self.subTest(value=value):self.assertTrue(build.exact_vivado_version(value))

    def test_other_release_tokens_rejected(self):
        for value in (b'Vivado v2026.10 (64-bit)',b'Vivado v2026.1.1',b'Vivado v2026.1beta',
                      b'Vivado v2026.2',b'Vivado v2025.1',b'not Vivado v2026.1'):
            with self.subTest(value=value):self.assertFalse(build.exact_vivado_version(value))

    def test_forty_seven_inputs(self):
        value=build.identity()
        self.assertEqual(len(value['original_build_input_sha256']),47)
        self.assertEqual(len(value['files']),49)

    def test_bit_payload(self):self.assertEqual(build.payload(bit(b'abc')),b'abc')
    def test_short_bit(self):
        with self.assertRaises(ValueError):build.payload(b'abc')
    def test_trailing_bit(self):
        with self.assertRaises(ValueError):build.payload(bit(b'abc')+b'x')
    def test_truncated_bit(self):
        with self.assertRaises(ValueError):build.payload(bit(b'abc')[:-1])
    def test_changed_tag(self):
        raw=bit(b'abc').replace(b'e\x00\x00\x00\x03',b'f\x00\x00\x00\x03')
        with self.assertRaises(ValueError):build.payload(raw)
    def test_timing(self):self.assertIs(build.timing(TIMING)['natural_timing_closed'],True)
    def test_negative_timing(self):self.assertIs(build.timing(TIMING.replace('0.118','-0.118'))['natural_timing_closed'],False)
    def test_failing_endpoint(self):self.assertIs(build.timing(TIMING.replace('0 100','1 100',1))['natural_timing_closed'],False)
    def test_missing_timing_header(self):
        with self.assertRaises(ValueError):build.timing('no summary')
    def test_empty_timing(self):
        with self.assertRaises(ValueError):build.timing('WNS(ns) no rows')
    def test_relative_work_rejected(self):
        with self.assertRaises(ValueError):build.outside_kit('relative')
    def test_existing_work_rejected(self):
        with self.assertRaises(ValueError):build.outside_kit(ROOT)
    def test_work_in_kit_rejected(self):
        with self.assertRaises(ValueError):build.outside_kit(ROOT/'do_not_create')


class PrepareAndCollect(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='cold_build_fixture_')
        self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.work=self.root/'work'
        self.board=self.root/'board.zip'
        with zipfile.ZipFile(self.board,'x') as archive:
            for name in ['pynq-z2/','pynq-z2/A.0/']:archive.writestr(name,b'')
            for name in ['board.xml','part0_pins.xml','preset.xml','pynq_z2.jpg']:
                archive.writestr('pynq-z2/A.0/'+name,b'fixture')
        self.config=copy.deepcopy(build.identity())
        self.config['board_definition'].update(sha256=build.sha(self.board.read_bytes()),bytes=self.board.stat().st_size)
        patcher=patch.object(build,'identity',return_value=self.config)
        patcher.start()
        self.addCleanup(patcher.stop)

    def prepare(self):build.prepare(self.work,self.board)

    def test_prepare_without_tool(self):
        self.assertIs(build.prepare(self.work,self.board)['vivado_started'],False)
        self.assertEqual(build.prepared(self.work),self.config)
        self.assertFalse((self.work/'source/.git').exists())
        self.assertFalse((self.work/'source/.venv').exists())

    def test_wrong_board_hash(self):
        self.config['board_definition']['sha256']='0'*64
        with self.assertRaises(ValueError):self.prepare()
        self.assertFalse(self.work.exists())

    def test_source_tamper(self):
        self.prepare()
        name=next(iter(self.config['files']))
        (self.work/'source'/name).write_bytes(b'changed')
        with self.assertRaises(ValueError):build.prepared(self.work)

    def test_preset_tamper(self):
        self.prepare()
        (self.work/'source/.vendor/pynq-z2-board/files/pynq-z2/A.0/preset.xml').write_bytes(b'changed')
        with self.assertRaises(ValueError):build.prepared(self.work)

    def test_existing_work_not_overwritten(self):
        self.prepare()
        with self.assertRaises(ValueError):self.prepare()

    def test_prepare_identity_changed(self):
        self.prepare()
        path=self.work/'prepared.json'
        value=build.document(path)
        value['package_source_identity_sha256']='0'*64
        path.write_text(json.dumps(value),encoding='utf-8')
        with self.assertRaises(ValueError):build.prepared(self.work)

    def fixture_result(self,exitcode=0):
        self.prepare()
        (self.work/'build.receipt.json').write_text(json.dumps({'actual_exit_code':exitcode,'exit_observed':True}),encoding='utf-8')
        folder=self.work/'source/.board-work/full_overlay/reports'
        folder.mkdir(parents=True)
        for name in ['opennpu_gemm_accelerator.bit','opennpu_gemm_accelerator.hwh','opennpu_gemm_accelerator.xsa',
                     'gemm_accelerator_implementation_timing_summary.rpt','gemm_accelerator_implementation_constrained_timing_summary.rpt',
                     'gemm_accelerator_implementation_utilization.rpt']:
            data=bit(b'abc') if name.endswith('.bit') else b'<HWH/>' if name.endswith('.hwh') else TIMING.encode()
            (folder/name).write_bytes(data)
        return folder

    def test_synthetic_collection_not_promotion(self):
        self.fixture_result()
        result=build.collect(self.work)
        self.assertIs(result['promotion'],False)
        self.assertIs(result['payload_matches_historical'],False)
        self.assertIs(result['needs_human_engineering_review'],True)

    def test_nonzero_build_not_accepted(self):
        self.fixture_result(1)
        with self.assertRaises(ValueError):build.collect(self.work)

    def test_bool_exit_not_zero(self):
        self.fixture_result(False)
        with self.assertRaises(ValueError):build.collect(self.work)

    def test_missing_artifact(self):
        folder=self.fixture_result()
        (folder/'opennpu_gemm_accelerator.hwh').unlink()
        with self.assertRaises(FileNotFoundError):build.collect(self.work)

    def test_negative_natural_timing(self):
        folder=self.fixture_result()
        (folder/'gemm_accelerator_implementation_timing_summary.rpt').write_text(TIMING.replace('0.118','-0.118'),encoding='utf-8')
        with self.assertRaises(ValueError):build.collect(self.work)

    def test_no_implicit_build(self):
        with self.assertRaises(ValueError):build.build(self.work,self.root,None)
        self.assertFalse(self.work.exists())


class CliChecks(unittest.TestCase):
    def test_missing_arguments_json(self):
        result=subprocess.run([sys.executable,'-I','-B',str(ROOT/'rebuild.py')],capture_output=True,timeout=10)
        self.assertEqual(result.returncode,2)
        self.assertIs(json.loads(result.stderr)['success'],False)

    def test_unknown_arguments_json(self):
        result=subprocess.run([sys.executable,'-I','-B',str(ROOT/'rebuild.py'),'--unsupported'],capture_output=True,timeout=10)
        self.assertEqual(result.returncode,2)
        self.assertIs(json.loads(result.stderr)['success'],False)


if __name__=='__main__':unittest.main(verbosity=2)
