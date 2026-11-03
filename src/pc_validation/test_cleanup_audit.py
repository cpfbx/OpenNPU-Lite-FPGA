"""Counterexamples for the incremental post-reset identity gate."""
import copy
import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import cleanup_audit as audit

ASSETS = Path(__file__).resolve().parent / 'inputs'


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.outer, self.terminal = audit.read_archive(ASSETS / 'shared12_evidence_v1.tar.gz')

    def fresh(self):
        return self.terminal['session']['cleanup_readback']['terminal']['recovery']['fresh_accelerator_identity']

    def rejected(self, mutate, resync=True):
        mutate()
        if resync:
            self.outer['child_terminal'] = copy.deepcopy(self.terminal)
        with self.assertRaises((ValueError, KeyError, TypeError)):
            audit.validate(self.outer, self.terminal)

    def test_original_passes(self):
        self.assertTrue(audit.validate(self.outer, self.terminal)['operation_success'])

    def test_runtime_version_is_not_cleanup_version(self):
        self.rejected(lambda: self.fresh().__setitem__('counter_contract_version', 2))

    def test_expected_version_two_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('expected_counter_contract_version', 2))

    def test_boolean_version_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('counter_contract_version', True))

    def test_float_version_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('counter_contract_version', 1.0))

    def test_string_version_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('counter_contract_version', '1'))

    def test_wrong_phase_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('phase', 'running'))

    def test_missing_fresh_field_rejected(self):
        self.rejected(lambda: self.fresh().pop('capabilities'))

    def test_extra_fresh_field_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('unknown', 0))

    def test_wrong_build_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('build_id', 0))

    def test_wrong_capabilities_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('capabilities', 0))

    def test_nonzero_error_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('error', 1))

    def test_boolean_error_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('error', False))

    def test_missing_identity_rejected(self):
        self.rejected(lambda: self.terminal['session']['cleanup_readback']['terminal']['recovery'].pop('fresh_accelerator_identity'))

    def test_outer_only_mutation_rejected(self):
        self.outer['child_terminal']['session']['cleanup_readback']['terminal']['recovery']['fresh_accelerator_identity']['counter_contract_version'] = 2
        with self.assertRaises(ValueError):
            audit.validate(self.outer, self.terminal)

    def test_worker_only_mutation_rejected(self):
        self.rejected(lambda: self.fresh().__setitem__('counter_contract_version', 2), False)

    def test_held_resources_rejected(self):
        self.rejected(lambda: self.terminal['session']['cleanup_readback']['resources'].__setitem__('held', True))

    def test_ticket_drift_rejected(self):
        self.rejected(lambda: self.terminal['ticket'].__setitem__('inode', 1))

    def test_unconfirmed_recovery_rejected(self):
        self.rejected(lambda: self.terminal['session']['cleanup_readback']['terminal']['recovery'].__setitem__('confirmed', False))

    def test_duplicate_json_rejected(self):
        with self.assertRaises(ValueError):
            audit.strict_json('{"version":1,"version":2}')

    def test_nonfinite_json_rejected(self):
        with self.assertRaises(ValueError):
            audit.strict_json('{"version":NaN}')


if __name__ == '__main__':
    unittest.main(verbosity=2)
