"""Unit tests and destructive counterexamples for KWS full hybrid offline candidate.

Covers all positive and negative gates specified in acceptance.md.
Run via:
  python -I -B test_hybrid_candidate.py --sources /abs/path/to/unpacked_sources --output /abs/path/to/test_scratch
"""
from __future__ import annotations

import copy
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parent
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import hybrid_contract as hc
from hybrid_graph import (
    HybridGraphExecutor,
    checked_owning_125x64,
    evaluate_gate_with_historical_vad,
    run_hybrid_session,
)

SOURCES_ROOT: Path | None = None
SCRATCH_ROOT: Path | None = None


class HybridCandidateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        assert SOURCES_ROOT is not None and SCRATCH_ROOT is not None
        cls.sources_root = SOURCES_ROOT
        cls.scratch_root = SCRATCH_ROOT
        cls.scratch_root.mkdir(parents=True, exist_ok=True)
        cls.bundle = hc.load_hybrid_bundle(cls.sources_root, enabled=True)
        cls.executor = HybridGraphExecutor(cls.bundle, enabled=True)
        cls.c = cls.bundle.shared_components
        cls.case2_0 = cls.c.reference.derive(2, 0)
        cls.case4_0 = cls.c.reference.derive(4, 0)
        cls.item0 = cls.bundle.cohort[0]
        cls.feat0, _ = cls.bundle.frontend.process(cls.item0)
        cls.feat0_sha = hc.sha(cls.feat0.tobytes(order='C'))
        cls.t23_0, cls.prefix_tensors0, cls.prefix_accs0, _ = cls.executor.run_prefix(
            cls.feat0, 0, cls.item0['source_id'], cls.feat0_sha
        )
        cls.oracle0 = cls.executor.compute_full_cpu_oracle(cls.feat0)

    def fresh_out(self, tag: str) -> Path:
        base = Path(tempfile.mkdtemp(prefix=f'{self._testMethodName}_', dir=self.scratch_root))
        return base / tag

    # --- Group 1: Default-off, manifest/source pins, output path & no-board-entry gates ---

    def test_01_default_off_gates(self):
        with self.assertRaisesRegex(ValueError, 'default-off'):
            hc.load_hybrid_bundle(self.sources_root)
        with self.assertRaisesRegex(ValueError, 'default-off'):
            HybridGraphExecutor(self.bundle)
        with self.assertRaisesRegex(ValueError, 'default-off'):
            run_hybrid_session(self.bundle, self.fresh_out('unused'))

    def test_02_wrong_candidate_manifest_pin_rejected(self):
        with self.assertRaisesRegex(ValueError, 'manifest pin mismatch'):
            hc.verify_candidate_tree('0' * 64)

    def test_03_existing_or_inside_output_rejected(self):
        existing = self.fresh_out('existing')
        existing.mkdir(parents=True)
        with self.assertRaisesRegex(ValueError, 'already exists'):
            hc.validate_output_dir(existing, self.sources_root)
        with self.assertRaisesRegex(ValueError, 'outside candidate'):
            hc.validate_output_dir(hc.ROOT / 'forbidden_inside_candidate', self.sources_root)
        with self.assertRaisesRegex(ValueError, 'outside unpacked sources'):
            hc.validate_output_dir(self.sources_root / 'forbidden_inside_sources', self.sources_root)

    def test_04_modified_frozen_source_rejected(self):
        fake_sources = self.fresh_out('fake_sources')
        fake_sources.mkdir(parents=True)
        for name in hc.SOURCE_ANCHORS:
            src = self.sources_root / name
            dst = fake_sources / name
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dst)
        raw = bytearray((fake_sources / 'selection12.json').read_bytes())
        raw[0] ^= 1
        (fake_sources / 'selection12.json').write_bytes(bytes(raw))
        with self.assertRaisesRegex(ValueError, 'source anchor drift'):
            hc.verify_sources_tree(fake_sources)

    def test_05_strict_json_rejects_duplicate_keys_and_nan(self):
        with self.assertRaisesRegex(ValueError, 'duplicate JSON key'):
            hc.strict_json('{"a": 1, "a": 2}')
        with self.assertRaisesRegex(ValueError, 'nonfinite JSON'):
            hc.strict_json('{"a": NaN}')

    # --- Group 2: Envelope / operand / schedule / weight swap / permit reuse gates ---

    def test_06_cross_window_or_wrong_layer_or_wrong_tensor_rejected(self):
        env_wrong_win = self.c.envelope_type(2, 23, 30, self.item0['source_id'], self.feat0_sha, self.t23_0.copy(order='C'))
        out = self.fresh_out('cross_win')
        with self.assertRaisesRegex(ValueError, 'shared window identity'):
            run_hybrid_session(self.bundle, out, enabled=True, mode='smoke1', raise_on_error=True,
                               mutate_hook=lambda stage, idx, val: env_wrong_win if stage == 'before_op2_call' else val)

        env_wrong_layer = self.c.envelope_type(4, 23, 0, self.item0['source_id'], self.feat0_sha, self.t23_0.copy(order='C'))
        out2 = self.fresh_out('wrong_layer')
        with self.assertRaisesRegex(ValueError, 'shared layer identity'):
            run_hybrid_session(self.bundle, out2, enabled=True, mode='smoke1', raise_on_error=True,
                               mutate_hook=lambda stage, idx, val: env_wrong_layer if stage == 'before_op2_call' else val)

        env_wrong_tensor = self.c.envelope_type(2, 25, 0, self.item0['source_id'], self.feat0_sha, self.t23_0.copy(order='C'))
        out3 = self.fresh_out('wrong_tensor')
        with self.assertRaisesRegex(ValueError, 'shared layer identity'):
            run_hybrid_session(self.bundle, out3, enabled=True, mode='smoke1', raise_on_error=True,
                               mutate_hook=lambda stage, idx, val: env_wrong_tensor if stage == 'before_op2_call' else val)

    def test_07_wrong_source_id_or_bool_index_rejected(self):
        env_wrong_src = self.c.envelope_type(2, 23, 0, 'foreign:source:id', self.feat0_sha, self.t23_0.copy(order='C'))
        with self.assertRaisesRegex(ValueError, 'shared window identity'):
            run_hybrid_session(self.bundle, self.fresh_out('wrong_src'), enabled=True, mode='smoke1', raise_on_error=True,
                               mutate_hook=lambda stage, idx, val: env_wrong_src if stage == 'before_op2_call' else val)

        env_bool_idx = self.c.envelope_type(2, 23, False, self.item0['source_id'], self.feat0_sha, self.t23_0.copy(order='C'))
        with self.assertRaisesRegex(ValueError, 'shared window identity'):
            run_hybrid_session(self.bundle, self.fresh_out('bool_idx'), enabled=True, mode='smoke1', raise_on_error=True,
                               mutate_hook=lambda stage, idx, val: env_bool_idx if stage == 'before_op2_call' else val)

    def test_08_non_owning_or_wrong_dtype_input_rejected_before_dispatch(self):
        backing = np.zeros((2, 125, 64), dtype=np.int8)
        backing[0] = self.t23_0
        view_arr = backing[0]
        self.assertFalse(view_arr.flags.owndata)
        env_view = self.c.envelope_type(2, 23, 0, self.item0['source_id'], self.feat0_sha, view_arr)
        with self.assertRaisesRegex(ValueError, 'shared owning exact input'):
            run_hybrid_session(self.bundle, self.fresh_out('non_owning'), enabled=True, mode='smoke1', raise_on_error=True,
                               mutate_hook=lambda stage, idx, val: env_view if stage == 'before_op2_call' else val)

        env_dtype = self.c.envelope_type(2, 23, 0, self.item0['source_id'], self.feat0_sha, self.t23_0.astype(np.int32))
        with self.assertRaisesRegex(ValueError, 'shared owning exact input'):
            run_hybrid_session(self.bundle, self.fresh_out('wrong_dtype'), enabled=True, mode='smoke1', raise_on_error=True,
                               mutate_hook=lambda stage, idx, val: env_dtype if stage == 'before_op2_call' else val)

    def test_09_op2_op4_case_or_weight_swap_rejected(self):
        req = self.bundle.shared_contract.fixture_request(hc.SHARED_CANDIDATE_MANIFEST_SHA, 'normal')
        env = self.bundle.wire_environment_type(self.c, 'normal')
        session = self.bundle.shared_session_type(
            req, lambda: env.stop, enabled=True, fixture=True,
            components=self.c, evidence=env.evidence, overrides=env.overrides
        )
        with env.install():
            try:
                session.start()
                with self.assertRaisesRegex(ValueError, 'exact shared case fields|sealed shared case'):
                    self.c.call_type(session.owner, self.case4_0, enabled=True)
            finally:
                if not session.owner._held and not session.owner._unsafe:
                    session.close()

        env2 = self.bundle.wire_environment_type(self.c, 'normal')
        session2 = self.bundle.shared_session_type(
            req, lambda: env2.stop, enabled=True, fixture=True,
            components=self.c, evidence=env2.evidence, overrides=env2.overrides
        )
        with env2.install():
            try:
                session2.start()
                bad_case = dict(self.case2_0, weights=self.case4_0['weights'])
                with self.assertRaisesRegex(ValueError, 'sealed shared case weights'):
                    self.c.call_type(session2.owner, bad_case, enabled=True)
            finally:
                if not session2.owner._held and not session2.owner._unsafe:
                    session2.close()

    def test_10_repeat_call_or_duplicate_permit_rejected(self):
        req = self.bundle.shared_contract.fixture_request(hc.SHARED_CANDIDATE_MANIFEST_SHA, 'normal')
        env = self.bundle.wire_environment_type(self.c, 'normal')
        session = self.bundle.shared_session_type(
            req, lambda: env.stop, enabled=True, fixture=True,
            components=self.c, evidence=env.evidence, overrides=env.overrides
        )
        with env.install():
            try:
                session.start()
                call = self.c.call_type(session.owner, self.case2_0, enabled=True)
                e2 = self.c.envelope_type(2, 23, 0, self.item0['source_id'], self.feat0_sha, self.t23_0.copy(order='C'))
                call(e2)
                with self.assertRaisesRegex(ValueError, 'one-shot'):
                    call(e2)
            finally:
                if not session.owner._held and not session.owner._unsafe:
                    session.close()

    # --- Group 3: Dynamic dataflow integrity (no golden bypass in frontend, prefix, DW3, or suffix) ---

    def test_11_perturbed_frontend_output_intercepted(self):
        def perturb_feat(stage, idx, val):
            if stage == 'after_frontend':
                mut = val.copy(order='C')
                mut[0, 0] = np.int8(int(mut[0, 0]) ^ 1)
                return mut
            return val

        with self.assertRaisesRegex(ValueError, 'recomputed WAV feature mismatch'):
            run_hybrid_session(self.bundle, self.fresh_out('perturb_feat'), enabled=True, mode='smoke1',
                               raise_on_error=True, mutate_hook=perturb_feat)

    def test_12_perturbed_prefix_output_intercepted_not_replaced_by_golden(self):
        def perturb_prefix(stage, idx, val):
            if stage == 'after_prefix':
                mut = val.copy(order='C')
                mut[0, 0] = np.int8(int(mut[0, 0]) ^ 1)
                return mut
            return val

        with self.assertRaisesRegex(ValueError, 'prefix op1 tensor23/accumulator mismatch'):
            run_hybrid_session(self.bundle, self.fresh_out('perturb_prefix'), enabled=True, mode='smoke1',
                               raise_on_error=True, mutate_hook=perturb_prefix)

    def test_13_perturbed_op4_output_consumed_by_suffix_with_quantization_masking_control(self):
        t26_base = self.oracle0['tensors'][26].reshape(125, 64).copy(order='C')
        t26_masked = t26_base.copy(order='C')
        t26_masked.reshape(-1)[0] = np.int8(int(t26_masked.reshape(-1)[0]) ^ 1)
        logits_m, suf_tensors_m, suf_accs_m, _ = self.executor.run_suffix(
            t26_masked, 0, self.item0['source_id'], self.feat0_sha
        )
        self.assertEqual(int(np.count_nonzero(suf_accs_m[5] != self.oracle0['accumulators'][5])), 4)
        self.assertTrue(np.array_equal(suf_tensors_m[27], self.oracle0['tensors'][27]))
        self.assertTrue(np.array_equal(logits_m, self.oracle0['logits']))

        with self.assertRaisesRegex(ValueError, 'suffix op5 accumulator mismatch'):
            run_hybrid_session(
                self.bundle,
                self.fresh_out('perturb_op4_masked'),
                enabled=True,
                mode='smoke1',
                raise_on_error=True,
                mutate_hook=lambda stage, idx, val: t26_masked.copy(order='C') if stage == 'before_suffix' else val,
            )

        t26_unmasked = t26_base.copy(order='C')
        t26_unmasked.reshape(-1)[11] = np.int8(int(t26_unmasked.reshape(-1)[11]) ^ 1)
        logits_u, suf_tensors_u, suf_accs_u, _ = self.executor.run_suffix(
            t26_unmasked, 0, self.item0['source_id'], self.feat0_sha
        )
        self.assertEqual(int(np.count_nonzero(suf_accs_u[5] != self.oracle0['accumulators'][5])), 4)
        self.assertEqual(int(np.count_nonzero(suf_tensors_u[27] != self.oracle0['tensors'][27])), 2)
        self.assertEqual(int(np.count_nonzero(logits_u != self.oracle0['logits'])), 2)

    # --- Group 4: Fault / stop / unsafe retention boundaries at window 90 ---

    def test_14_window90_raw_fault_rejected_before_relu_and_saves_first_failure(self):
        out = self.fresh_out('raw_fault_90')
        with self.assertRaises(ValueError):
            run_hybrid_session(self.bundle, out, enabled=True, mode='fixed12', profile='raw_fault', raise_on_error=True)
        summary = hc.strict_json((out / 'summary.json').read_bytes())
        self.assertFalse(summary['operation_success'])
        self.assertEqual(summary['completed_indices'], [0, 30, 60])
        self.assertEqual(summary['accepted_op2_calls'], 4)
        self.assertEqual(summary['depthwise_executed_calls'], 4)
        self.assertEqual(summary['accepted_op4_calls'], 3)
        self.assertEqual(summary['driver_returns'], 8)
        self.assertEqual(summary['session']['software_admission']['consumed'], 8)
        self.assertEqual(summary['failure']['cohort_index'], 90)
        self.assertEqual(summary['failure']['stage'], 'op4_call')
        self.assertTrue((out / 'first_failure.bin').is_file())
        self.assertTrue((out / 'return_diagnostic.json').is_file())
        self.assertTrue(summary['session']['owner_closed'])
        self.assertFalse(summary['safety_unresolved'])

    def test_15_window90_stop_before_depthwise_cleanly_aborts(self):
        out = self.fresh_out('stop_90')
        with self.assertRaises(Exception):
            run_hybrid_session(self.bundle, out, enabled=True, mode='fixed12', profile='stop', raise_on_error=True)
        summary = hc.strict_json((out / 'summary.json').read_bytes())
        self.assertFalse(summary['operation_success'])
        self.assertEqual(summary['completed_indices'], [0, 30, 60])
        self.assertEqual(summary['accepted_op2_calls'], 4)
        self.assertEqual(summary['depthwise_executed_calls'], 3)
        self.assertEqual(summary['accepted_op4_calls'], 3)
        self.assertEqual(summary['driver_returns'], 7)
        self.assertEqual(summary['session']['software_admission']['consumed'], 7)
        self.assertEqual(summary['failure']['cohort_index'], 90)
        self.assertEqual(summary['failure']['stage'], 'before_depthwise')
        self.assertTrue(summary['session']['owner_closed'])
        self.assertFalse(summary['safety_unresolved'])

    def test_16_window90_unsafe_start_failure_retains_owner_without_fake_close(self):
        out = self.fresh_out('unsafe_90')
        with self.assertRaises(RuntimeError):
            run_hybrid_session(self.bundle, out, enabled=True, mode='fixed12', profile='unsafe', raise_on_error=True)
        summary = hc.strict_json((out / 'summary.json').read_bytes())
        self.assertFalse(summary['operation_success'])
        self.assertTrue(summary['safety_unresolved'])
        self.assertTrue(summary['finite_supervisor_fixture'])
        self.assertFalse(summary['session']['owner_closed'])
        self.assertEqual(summary['session']['close_attempts'], 0)
        self.assertTrue(summary['session']['resources']['held'])
        self.assertTrue((out / 'attention_retained.json').is_file())
        self.assertEqual(summary['completed_indices'], [0, 30, 60])
        self.assertEqual(summary['accepted_op2_calls'], 4)
        self.assertEqual(summary['depthwise_executed_calls'], 4)
        self.assertEqual(summary['accepted_op4_calls'], 3)
        self.assertEqual(summary['driver_returns'], 7)
        self.assertEqual(summary['session']['software_admission']['consumed'], 8)

    # --- Group 5: VAD / Gate binding & quantization parameter counterexamples ---

    def test_17_vad_cross_window_pcm_or_wrong_quantization_or_recomputed_claim_rejected(self):
        logits_0 = [int(x) for x in self.oracle0['logits'].reshape(-1)]
        with self.assertRaisesRegex(ValueError, 'cross-window VAD rejected'):
            evaluate_gate_with_historical_vad(
                self.bundle, 0, self.item0['source_id'], self.item0['source_sha256'], self.item0['pcm_sha256'],
                logits_0, vad_override=self.bundle.historical_vad_by_index[30]
            )
        with self.assertRaisesRegex(ValueError, 'quantization scale/zero_point mismatch'):
            evaluate_gate_with_historical_vad(
                self.bundle, 0, self.item0['source_id'], self.item0['source_sha256'], self.item0['pcm_sha256'],
                logits_0, scale=0.25, zero_point=14
            )
        with self.assertRaisesRegex(ValueError, 'quantization scale/zero_point mismatch'):
            evaluate_gate_with_historical_vad(
                self.bundle, 0, self.item0['source_id'], self.item0['source_sha256'], self.item0['pcm_sha256'],
                logits_0, scale=hc.LOGITS_SCALE, zero_point=0
            )
        with self.assertRaisesRegex(ValueError, 'never be marked as recomputed'):
            evaluate_gate_with_historical_vad(
                self.bundle, 0, self.item0['source_id'], self.item0['source_sha256'], self.item0['pcm_sha256'],
                logits_0, claim_vad_recomputed=True
            )


def main():
    global SOURCES_ROOT, SCRATCH_ROOT
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sources', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args, remaining = parser.parse_known_args()
    SOURCES_ROOT = args.sources.resolve()
    SCRATCH_ROOT = hc.validate_output_dir(args.output, SOURCES_ROOT)
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(HybridCandidateTests)
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    summary = dict(
        tests_run=result.testsRun,
        failures=len(result.failures),
        errors=len(result.errors),
        skipped=len(result.skipped),
        operation_success=result.wasSuccessful() and len(result.skipped) == 0,
    )
    hc.write_json_exclusive(SCRATCH_ROOT / 'unittest_summary.json', summary)
    print(hc.encode_json(summary).decode('utf-8').strip())
    raise SystemExit(0 if summary['operation_success'] else 1)


if __name__ == '__main__':
    main()
