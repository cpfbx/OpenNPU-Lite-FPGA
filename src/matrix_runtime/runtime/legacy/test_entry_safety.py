"""Incremental safety regressions: exact code over explicit synthetic OS/PYNQ."""
import ast
import copy
import inspect
import json
from pathlib import Path
import sys
import tempfile
import textwrap
from types import ModuleType,SimpleNamespace
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parent
for path in reversed([ROOT/'frozen_source',ROOT]):sys.path.insert(0,str(path))
import numpy as np
import batch_owner
import os_evidence
import pynq_gemm
import binding_flat
import owner_entry_candidate
import lease_entry_candidate
from batch_policy import BatchPolicy,BatchStop
from batch_call import BatchCall
from kws_device_supervision_candidate import _needs_retention
from flat_driver_candidate import FlatPackPynqGemm,flat_runner_type
from owner_entry_candidate import EntrySafeBatchOwner
from lease_entry_candidate import EntrySafeObservedLease
from entry_fixture import FakeCanonicalEnvironment,PynqHarness
from test_driver_integration import bank,owner_execute


def assert_close_note_when_supported(testcase,error):
    """Notes are optional in 3.10; resource/quarantine assertions are not."""
    if callable(getattr(error,'add_note',None)):
        testcase.assertTrue(any('descriptor close failed' in note
                                for note in getattr(error,'__notes__',())))


def assert_attempt_order(testcase,enter):
    """Check top-level statement order BEFORE an AST equivalence test mutates it."""
    markers=[index for index,node in enumerate(enter.body)
             if isinstance(node,ast.Assign) and any(isinstance(t,ast.Attribute)
                 and t.attr=='acquisition_attempted' for t in node.targets)]
    factories=[index for index,node in enumerate(enter.body)
               if isinstance(node,ast.Assign) and isinstance(node.value,ast.Call)
               and isinstance(node.value.func,ast.Attribute) and node.value.func.attr=='factory']
    context_enters=[index for index,node in enumerate(enter.body)
                    if isinstance(node,ast.Expr) and isinstance(node.value,ast.Call)
                    and isinstance(node.value.func,ast.Attribute) and node.value.func.attr=='__enter__']
    testcase.assertEqual((len(markers),len(factories),len(context_enters)),(1,1,1))
    testcase.assertLess(markers[0],factories[0],'attempt marker must precede factory')
    testcase.assertLess(factories[0],context_enters[0],'factory must precede context enter')


class ProvenanceAndBinding(unittest.TestCase):
    def test_exact_source_mapping_catalog(self):
        value=binding_flat.source_identity()
        self.assertEqual(len(value['files']),23)
        self.assertEqual({x['path'] for x in value['files']},set(binding_flat.expected_origins()))

    def metadata_rejected(self,change):
        value=copy.deepcopy(binding_flat.source_identity())
        change(value)
        original=binding_flat.verifier.read_json
        with patch.object(binding_flat.verifier,'read_json',return_value=value):
            with self.assertRaises(ValueError):binding_flat.source_identity()

    def test_wrong_archive_metadata_rejected(self):
        self.metadata_rejected(lambda v:v['files'][0].update(archive_sha256='0'*64))

    def test_wrong_member_metadata_rejected(self):
        self.metadata_rejected(lambda v:v['files'][0].update(member='some_other_member.py'))

    def test_duplicate_source_entry_rejected(self):
        self.metadata_rejected(lambda v:v['files'].__setitem__(0,v['files'][1]))

    def test_missing_source_entry_rejected(self):
        self.metadata_rejected(lambda v:v['files'].pop())

    def test_source_size_bool_rejected(self):
        self.metadata_rejected(lambda v:v['files'][0].update(bytes=True))

    def test_preimport_pynq_rejected_before_verification_or_factory(self):
        with patch.dict(sys.modules,{'pynq':ModuleType('pynq')}),patch.object(binding_flat.verifier,'verify') as verify:
            with self.assertRaisesRegex(ValueError,'pre-imported PYNQ'):
                binding_flat.build_components('not needed',enabled=True)
            verify.assert_not_called()

    def test_orphan_pynq_submodule_also_rejected(self):
        with patch.dict(sys.modules,{'pynq.fake_submodule':ModuleType('pynq.fake_submodule')}):
            with self.assertRaisesRegex(ValueError,'pre-imported PYNQ'):binding_flat.require_cold_pynq()

    def test_all_explicit_candidate_path_collisions_rejected(self):
        for name in ('pynq_gemm','flat_driver_candidate','pack_chain_flat_candidate',
                     'owner_entry_candidate','lease_entry_candidate'):
            with self.subTest(module=name),patch.dict(sys.modules,{name:SimpleNamespace(__file__='outside.py')}):
                with self.assertRaisesRegex(ValueError,'collision'):binding_flat.loaded_paths()

    def test_components_factory_default_off(self):
        for enabled in (False,None,1,'true'):
            with self.subTest(enabled=enabled),self.assertRaises(ValueError):
                binding_flat.build_components('not needed',enabled=enabled)


class ExplicitCodeBoundaries(unittest.TestCase):
    def test_driver_signature_defaults_annotations_preserved(self):
        self.assertEqual(inspect.signature(FlatPackPynqGemm.run_chain),inspect.signature(pynq_gemm.PynqGemm.run_chain))

    def test_all_nine_driver_methods_inherited(self):
        for name in ('_submit_chain','_recover','allocate_buffers','_read_phase_counters',
                     '_read_mode11_counters','_read_d007_counters','_mode11_word_reader',
                     'run_prepared_chain','run_transaction'):
            with self.subTest(name=name):self.assertIs(getattr(FlatPackPynqGemm,name),getattr(pynq_gemm.PynqGemm,name))

    def test_only_owner_start_is_overridden(self):
        own={k for k,v in EntrySafeBatchOwner.__dict__.items() if callable(v)}
        self.assertEqual(own,{'start'})
        for name in ('__init__','_owned','_hold','_identity','_buffers_valid','pre_submit','execute_chain','close'):
            with self.subTest(name=name):self.assertIs(getattr(EntrySafeBatchOwner,name),getattr(batch_owner.BatchOwner,name))

    def test_owner_start_normal_try_body_is_frozen(self):
        old=ast.parse(textwrap.dedent(inspect.getsource(batch_owner.BatchOwner.start))).body[0]
        new=ast.parse(textwrap.dedent(inspect.getsource(EntrySafeBatchOwner.start))).body[0]
        self.assertEqual(ast.dump(old.args),ast.dump(new.args))
        old_try=next(x for x in old.body if isinstance(x,ast.Try))
        new_try=next(x for x in new.body if isinstance(x,ast.Try))
        self.assertEqual([ast.dump(x) for x in old_try.body],[ast.dump(x) for x in new_try.body])
        old_prefix=old.body[:old.body.index(old_try)]
        new_prefix=new.body[:new.body.index(new_try)]
        class LeaseName(ast.NodeTransformer):
            def visit_Name(self,node):
                if node.id=='EntrySafeObservedLease':node.id='ObservedLease'
                return node
        self.assertEqual([ast.dump(x) for x in old_prefix],[ast.dump(LeaseName().visit(x)) for x in new_prefix])

    def test_observer_enter_only_attempt_marker_and_reentry_guard_changed(self):
        old=ast.parse(textwrap.dedent(inspect.getsource(os_evidence.ObservedLease.__enter__))).body[0]
        new=ast.parse(textwrap.dedent(inspect.getsource(EntrySafeObservedLease.__enter__))).body[0]
        self.assertEqual(ast.dump(old.args),ast.dump(new.args))
        assert_attempt_order(self,new)
        assignments=[n for n in new.body if isinstance(n,ast.Assign) and any(isinstance(t,ast.Attribute) and t.attr=='acquisition_attempted' for t in n.targets)]
        self.assertEqual(len(assignments),1)
        self.assertIs(assignments[0].value.value,True)
        new.body.remove(assignments[0])
        guard=next(n for n in new.body if isinstance(n,ast.If))
        extra=guard.test.values.pop()
        self.assertIn('acquisition_attempted',ast.dump(extra))
        self.assertEqual(ast.dump(old),ast.dump(new))

    def test_attempt_order_checker_rejects_marker_after_factory_or_enter(self):
        source=ast.parse(textwrap.dedent(inspect.getsource(EntrySafeObservedLease.__enter__))).body[0]
        assert_attempt_order(self,source)
        for after in ('factory','__enter__'):
            with self.subTest(after=after):
                mutated=copy.deepcopy(source)
                marker=next(node for node in mutated.body if isinstance(node,ast.Assign)
                            and any(isinstance(t,ast.Attribute) and t.attr=='acquisition_attempted'
                                    for t in node.targets))
                mutated.body.remove(marker)
                call=next(node for node in mutated.body
                          if isinstance(node,(ast.Assign,ast.Expr)) and isinstance(node.value,ast.Call)
                          and isinstance(node.value.func,ast.Attribute) and node.value.func.attr==after)
                mutated.body.insert(mutated.body.index(call)+1,marker)
                with self.assertRaisesRegex(AssertionError,'attempt marker must precede factory'):
                    assert_attempt_order(self,mutated)

    def test_note_assertion_supports_absent_capability_but_checks_supported_notes(self):
        # A protocol stand-in for Python 3.10, not a claimed 3.10 execution.
        assert_close_note_when_supported(self,SimpleNamespace())
        assert_close_note_when_supported(self,SimpleNamespace(add_note=None))
        assert_close_note_when_supported(self,SimpleNamespace(
            add_note=lambda note:None,__notes__=['descriptor close failed: synthetic']))
        for error in (SimpleNamespace(add_note=lambda note:None),
                      SimpleNamespace(add_note=lambda note:None,__notes__=['unrelated'])):
            with self.subTest(error=error),self.assertRaises(AssertionError):
                assert_close_note_when_supported(self,error)

    def test_lease_audit_exit_and_owned_identity_inherited(self):
        for name in ('audit','__exit__','_owned'):
            with self.subTest(name=name):self.assertIs(getattr(EntrySafeObservedLease,name),getattr(os_evidence.ObservedLease,name))


class LeaseAttemptAndQuarantine(unittest.TestCase):
    def owner(self):
        owner=EntrySafeBatchOwner(BatchPolicy('smoke8',enabled=True),lambda:False,enabled=True)
        self.addCleanup(lambda:batch_owner._RETAINED.remove(owner) if owner in batch_owner._RETAINED else None)
        return owner

    def assert_quarantined(self,owner):
        self.assertTrue(owner._held)
        self.assertTrue(owner._unsafe)
        self.assertIsNotNone(owner._lease)
        self.assertTrue(_needs_retention(owner.supervision_status))
        with self.assertRaisesRegex(RuntimeError,'quarantined'):owner.close()
        self.assertIsNone(owner.cleanup_readback)

    def test_pre_factory_missing_path_can_exit_without_retention(self):
        owner=self.owner()
        env=FakeCanonicalEnvironment(precheck=True)
        with env.install():
            with self.assertRaises(FileNotFoundError):owner.start(object,Path('NO_DEVICE.bit'),env.factory,lambda:None)
            self.assertEqual((env.factory_calls,env.open_calls),(0,0))
            self.assertIsNone(owner._lease)
            self.assertFalse(_needs_retention(owner.supervision_status))
            owner.close()

    def test_actual_helper_busy_close_ok_retains_conservatively(self):
        owner=self.owner()
        env=FakeCanonicalEnvironment(busy=True)
        with env.install():
            with self.assertRaises(BlockingIOError):owner.start(object,Path('NO_DEVICE.bit'),env.factory,lambda:None)
            self.assertFalse(env.fd_live)
            self.assertEqual(env.close_calls,1)
            self.assert_quarantined(owner)

    def test_actual_helper_post_acquire_drift_close_ok_retains_conservatively(self):
        owner=self.owner()
        env=FakeCanonicalEnvironment(drift=True)
        with env.install():
            with self.assertRaises(ValueError):owner.start(object,Path('NO_DEVICE.bit'),env.factory,lambda:None)
            self.assertFalse(env.fd_live)
            self.assertEqual(env.close_calls,1)
            self.assert_quarantined(owner)

    def test_actual_helper_acquire_and_close_double_failure_retained(self):
        owner=self.owner()
        env=FakeCanonicalEnvironment(drift=True,close_error=True)
        with env.install():
            with self.assertRaises(ValueError) as raised:owner.start(object,Path('NO_DEVICE.bit'),env.factory,lambda:None)
            self.assertTrue(env.fd_live)
            self.assertTrue(env.exclusive_held)
            self.assertEqual(env.close_calls,1)
            assert_close_note_when_supported(self,raised.exception)
            self.assert_quarantined(owner)
            self.assertEqual(env.close_calls,1)  # owner.close did not retry a helper close.

    def test_quarantined_owner_start_cannot_retry_or_replace_lease(self):
        owner=self.owner()
        env=FakeCanonicalEnvironment(drift=True,close_error=True)
        with env.install():
            with self.assertRaises(ValueError):owner.start(object,Path('NO_DEVICE.bit'),env.factory,lambda:None)
            original_lease=owner._lease
            with self.assertRaisesRegex(RuntimeError,'already used'):owner.start(object,Path('NO_DEVICE.bit'),env.factory,lambda:None)
            self.assertIs(owner._lease,original_lease)
            self.assertEqual(env.factory_calls,1)
            self.assertEqual(env.close_calls,1)
            self.assert_quarantined(owner)

    def test_baseline_and_derived_double_failure_differ_only_retention(self):
        records=[]
        for cls in (batch_owner.BatchOwner,EntrySafeBatchOwner):
            owner=cls(BatchPolicy('smoke8',enabled=True),lambda:False,enabled=True)
            self.addCleanup(lambda owner=owner:batch_owner._RETAINED.remove(owner) if owner in batch_owner._RETAINED else None)
            env=FakeCanonicalEnvironment(drift=True,close_error=True)
            with env.install():
                with self.assertRaises(ValueError):owner.start(object,Path('NO_DEVICE.bit'),env.factory,lambda:None)
                records.append((env.fd_live,owner._held,owner._lease is not None))
        self.assertEqual(records,[(True,False,False),(True,True,True)])

    def test_factory_raises_before_returning_context_also_retained(self):
        owner=self.owner()
        env=FakeCanonicalEnvironment()
        def factory():raise RuntimeError('synthetic opaque factory failure')
        with env.install():
            with self.assertRaisesRegex(RuntimeError,'factory failure'):owner.start(object,Path('NO_DEVICE.bit'),factory,lambda:None)
            self.assertIsNone(owner._lease.context)
            self.assertIs(owner._lease.acquisition_attempted,True)
            self.assert_quarantined(owner)

    def test_batchstop_from_opaque_factory_is_not_safe_cleanup(self):
        owner=self.owner()
        env=FakeCanonicalEnvironment()
        def factory():raise BatchStop('synthetic stop during opaque acquisition')
        with env.install():
            with self.assertRaises(BatchStop):owner.start(object,Path('NO_DEVICE.bit'),factory,lambda:None)
            self.assert_quarantined(owner)

    def test_missing_attempt_marker_is_not_treated_as_no_acquisition(self):
        owner=self.owner()
        class Unknown:
            entered=False
            context=None
            def __enter__(self):raise RuntimeError('synthetic unknown lease')
        with patch.object(owner_entry_candidate,'EntrySafeObservedLease',return_value=Unknown()):
            with self.assertRaises(RuntimeError):owner.start(object,Path('NO_DEVICE.bit'),lambda:None,lambda:None)
        self.assert_quarantined(owner)

    def test_enter_attempt_cannot_be_retried_when_factory_raises(self):
        env=FakeCanonicalEnvironment()
        calls=[]
        def factory():calls.append(1);raise RuntimeError('synthetic failed factory')
        lease=EntrySafeObservedLease(factory)
        with env.install():
            with self.assertRaises(RuntimeError):lease.__enter__()
            with self.assertRaisesRegex(RuntimeError,'single-use'):lease.__enter__()
        self.assertEqual(calls,[1])

    def test_successful_actual_observer_audit_and_exit_close_once(self):
        env=FakeCanonicalEnvironment()
        with env.install():
            lease=EntrySafeObservedLease(env.factory)
            self.assertIs(lease.__enter__(),lease)
            self.assertIs(lease.acquisition_attempted,True)
            self.assertTrue(lease.audit()['exclusive_flock'])
            self.assertEqual(lease.fd,99)
            lease.__exit__(None,None,None)
            self.assertTrue(lease.released)
            self.assertFalse(env.fd_live)
            self.assertEqual(env.close_calls,1)

    def test_post_enter_fd_ambiguity_retains_context(self):
        owner=self.owner()
        env=FakeCanonicalEnvironment(ambiguous=True)
        with env.install():
            with self.assertRaisesRegex(RuntimeError,'ambiguity'):owner.start(object,Path('NO_DEVICE.bit'),env.factory,lambda:None)
            self.assertIs(owner._lease.entered,True)
            self.assertTrue(env.fd_live)
            self.assert_quarantined(owner)


class FullDerivedOwnerPath(unittest.TestCase):
    def harness(self,**options):
        h=PynqHarness(EntrySafeBatchOwner,**options)
        self.addCleanup(h.discard_synthetic_retention)
        return h

    def test_actual_helper_observer_owner_constructor_calls_cleanup(self):
        h=self.harness()
        env=FakeCanonicalEnvironment()
        with env.install():
            owner=h.start(env)
            call=BatchCall(owner,owner.policy,enabled=True)
            for index in (42,43):
                a,b,jobs,payload,expected=bank(index)
                h.engine.payload=payload
                result,metrics=call(a,b)
                np.testing.assert_array_equal(result,expected)
            owner.close()
            self.assertFalse(env.fd_live)
            self.assertFalse(_needs_retention(owner.supervision_status))
            self.assertEqual(env.close_calls,1)
            self.assertEqual([e for e in h.events if e[0]=='free'],[('free','rx'),('free','tx')])

    def failure(self,**options):
        h=self.harness(**options)
        env=FakeCanonicalEnvironment()
        with env.install():
            with self.assertRaises(RuntimeError):h.start(env)
            self.assertTrue(h.owner._held)
            self.assertIsNotNone(h.owner._lease)
            self.assertTrue(_needs_retention(h.owner.supervision_status))
            self.assertTrue(env.fd_live)
            with self.assertRaises(RuntimeError):h.owner.close()
            self.assertEqual(env.close_calls,0)
        return h

    def test_first_allocation_failure_keeps_lease(self):self.failure(allocation_failure=0)
    def test_second_allocation_failure_keeps_first_root(self):
        h=self.failure(allocation_failure=1)
        self.assertEqual(len(h.owner._buffers),1)
    def test_recovery_factory_failure_keeps_partial_runner(self):self.failure(recovery_factory_error=True)
    def test_recovery_confirmation_false_keeps_runner(self):self.failure(recovery_confirmation_failure=True)
    def test_pynq_version_drift_rejected(self):self.failure(pynq_version='wrong')
    def test_clock_drift_rejected(self):self.failure(clock=99.)

    def test_stop_after_successful_init_can_still_close_cleanly(self):
        h=self.harness(stop_after_allocation=True)
        env=FakeCanonicalEnvironment()
        with env.install():
            with self.assertRaises(BatchStop):h.start(env)
            self.assertFalse(h.owner._held)
            h.owner.close()
            self.assertFalse(env.fd_live)
            self.assertEqual(env.close_calls,1)

    def test_stop_during_pack_finishes_one_no_next_in_derived_owner(self):
        h=self.harness()
        env=FakeCanonicalEnvironment()
        import flat_driver_candidate
        original=flat_driver_candidate.pack_chain_flat
        def packing(*args,**kwargs):h.stop=True;return original(*args,**kwargs)
        with env.install():
            owner=h.start(env)
            with patch.object(flat_driver_candidate,'pack_chain_flat',side_effect=packing):
                result=owner_execute(owner,h.jobs)
            self.assertEqual(result[0],h.payload)
            count=sum(e[0]=='transfer' for e in h.events)
            with self.assertRaises(BatchStop):owner_execute(owner,h.jobs,first_job_id=65)
            self.assertEqual(sum(e[0]=='transfer' for e in h.events),count)
            owner.close()
            self.assertFalse(env.fd_live)


if __name__=='__main__':unittest.main(verbosity=2)
