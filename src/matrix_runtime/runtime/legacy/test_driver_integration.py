"""Real Python/NumPy integration with synthetic device/lease fixtures only."""
import ast
import copy
import dataclasses
import hashlib
import inspect
import json
from pathlib import Path
import sys
import textwrap
import threading
import unittest
from unittest.mock import patch
from types import ModuleType, SimpleNamespace

ROOT=Path(__file__).resolve().parent
sys.path.insert(0,str(ROOT/'frozen_source'))
sys.path.insert(1,str(ROOT))
import numpy as np
import chain_protocol as chain
import tiled_gemm as tiled
import pynq_gemm as frozen
from batch_call import BatchCall
from batch_policy import BatchStop
from matrix_panel_builder_candidate import build_panel_layout_cached_transactions
from flat_driver_candidate import FlatPackPynqGemm, flat_runner_type
import flat_driver_candidate as candidate
import offline_fixture as fixture


def jobs_for(m=65,n=67,k=69,seed=42):
    rng=np.random.default_rng(seed)
    a=rng.integers(-128,128,(m,k),dtype=np.int8)
    b=rng.integers(-128,128,(k,n),dtype=np.int8)
    jobs=list(build_panel_layout_cached_transactions(a,b,tiled.TileConfig(layout=tiled.Layout.K_MAJOR),enabled=True).transactions)
    expected=a.astype(np.int64)@b.astype(np.int64)
    return jobs,fixture.tiled_output(jobs,expected),expected.astype(np.int32)


def bank(index=42):
    a,b=fixture.bank_arrays(index)
    jobs=list(build_panel_layout_cached_transactions(a,b,tiled.TileConfig(layout=tiled.Layout.K_MAJOR),enabled=True).transactions)
    expected=np.frombuffer((ROOT/'bank'/f'input_{index}_expected.bin').read_bytes(),dtype='<i4').reshape(512,512)
    return a,b,jobs,fixture.tiled_output(jobs,expected),expected


def execute(runner,tx,rx,jobs,**options):
    values=dict(first_job_id=1,timeout_s=.01,launch_order='dma-first',profile_host=True,mode_override=11)
    values.update(options)
    return runner.run_chain(jobs,tx,rx,**values)


def owner_execute(owner,jobs,**options):
    values=dict(first_job_id=1,timeout_s=.01,launch_order='dma-first',profile_host=True,mode_override=11)
    values.update(options)
    return owner.execute_chain(jobs,**values)


class BindingTests(unittest.TestCase):
    def test_sealed_binding_default_off_before_any_hardware(self):
        import binding_flat
        for enabled in (False,None,1,'true'):
            with self.subTest(enabled=enabled),self.assertRaises(ValueError):
                binding_flat.build_runner_type('not used',enabled=enabled)

    def test_import_collision_rejected(self):
        import binding_flat
        with patch.dict(sys.modules,{'pynq_gemm':SimpleNamespace(__file__=str(ROOT/'other_driver.py'))}):
            with self.assertRaisesRegex(ValueError,'collision'):binding_flat.loaded_paths()

    def test_snapshot_import_paths_accepted(self):
        import binding_flat
        binding_flat.loaded_paths()
        binding_flat.source_identity()

    def test_source_snapshot_bytes(self):
        for item in json.loads((ROOT/'source_identity.json').read_bytes())['files']:
            with self.subTest(path=item['path']):
                raw=(ROOT/item['path']).read_bytes()
                self.assertEqual((len(raw),hashlib.sha256(raw).hexdigest()),(item['bytes'],item['sha256']))

    def test_run_chain_ast_only_pack_and_enable_guard_changed(self):
        old=ast.parse(textwrap.dedent(inspect.getsource(frozen.PynqGemm.run_chain))).body[0]
        new=ast.parse(textwrap.dedent(inspect.getsource(FlatPackPynqGemm.run_chain))).body[0]
        old.body=old.body[1:]  # docstring
        new.body=new.body[2:]  # docstring + explicit instance enable guard
        class Normalize(ast.NodeTransformer):
            def visit_Attribute(self,node):
                self.generic_visit(node)
                if isinstance(node.value,ast.Name) and node.value.id=='frozen':
                    return ast.Name(id=node.attr,ctx=node.ctx)
                return node
            def visit_Call(self,node):
                self.generic_visit(node)
                if isinstance(node.func,ast.Name) and node.func.id=='pack_chain_flat':
                    node.func.id='pack_chain'
                    self_test=[x for x in node.keywords if x.arg=='enabled']
                    if len(self_test)!=1 or not isinstance(self_test[0].value,ast.Constant) or self_test[0].value.value is not True:
                        raise AssertionError('explicit flat enable binding')
                    node.keywords=[x for x in node.keywords if x.arg!='enabled']
                return node
        new=Normalize().visit(new)
        self.assertEqual(ast.dump(old,include_attributes=False),ast.dump(new,include_attributes=False))

    def test_dma_wait_counter_recovery_and_allocation_methods_inherited(self):
        for name in ['_submit_chain','_recover','allocate_buffers','_read_phase_counters',
                     '_read_mode11_counters','_read_d007_counters','run_prepared_chain','run_transaction']:
            with self.subTest(name=name):self.assertIs(getattr(FlatPackPynqGemm,name),getattr(frozen.PynqGemm,name))

    def test_constructor_default_off_before_pynq(self):
        for enabled in [False,None,1,'true']:
            with self.subTest(enabled=enabled),patch.object(frozen.PynqGemm,'__init__') as original:
                with self.assertRaises(ValueError):FlatPackPynqGemm(Path('not_loaded.bit'),enabled=enabled)
                original.assert_not_called()

    def test_constructor_explicit_opt_in_delegates_once(self):
        with patch.object(frozen.PynqGemm,'__init__',return_value=None) as original:
            obj=FlatPackPynqGemm(Path('synthetic.bit'),enabled=True)
            original.assert_called_once_with(Path('synthetic.bit'))
            self.assertIs(obj._flat_pack_enabled,True)

    def test_type_factory_default_off(self):
        for enabled in [False,None,1,'true']:
            with self.subTest(enabled=enabled),self.assertRaises(ValueError):flat_runner_type(enabled=enabled)

    def test_owner_type_factory_delegates_explicit_enable(self):
        cls=flat_runner_type(enabled=True)
        self.assertTrue(issubclass(cls,FlatPackPynqGemm))
        with patch.object(frozen.PynqGemm,'__init__',return_value=None) as original:
            obj=cls(Path('synthetic.bit'))
            original.assert_called_once()
            self.assertIs(obj._flat_pack_enabled,True)

    def test_no_default_pack_monkeypatch(self):
        self.assertIs(frozen.pack_chain,chain.pack_chain)
        self.assertIsNot(frozen.pack_chain,candidate.pack_chain_flat)

    def test_new_instance_without_enable_cannot_submit(self):
        jobs,payload,_=jobs_for(3,5,7)
        runner,tx,rx,events=fixture.fixture(jobs,payload)
        del runner._flat_pack_enabled
        with self.assertRaises(ValueError):execute(runner,tx,rx,jobs)
        self.assertEqual(events,[])


class DriverIntegration(unittest.TestCase):
    def successful_pair(self,jobs,payload,*,first=1):
        results=[]
        traces=[]
        for is_candidate in [False,True]:
            runner,tx,rx,events=fixture.fixture(jobs,payload,candidate=is_candidate)
            result=execute(runner,tx,rx,jobs,first_job_id=first)
            expected_wire,expected_records=chain.pack_chain(jobs,first)
            self.assertEqual(bytes(tx),expected_wire)
            self.assertEqual(result[0],payload)
            self.assertEqual(result[1],expected_records)
            self.assertEqual([e for e in events if e[0]=='transfer'],[('transfer','recv',len(rx)),('transfer','send',len(tx))])
            self.assertEqual([e for e in events if e[0]=='flush'],[('flush','tx'),('flush','rx')])
            self.assertEqual([e for e in events if e[0]=='invalidate'],[('invalidate','rx')])
            self.assertEqual([e for e in events if e[0]=='write' and e[1]==frozen.REG_CONTROL and e[2]==frozen.CONTROL_START],
                             [('write',frozen.REG_CONTROL,frozen.CONTROL_START)])
            self.assertTrue(np.all(np.frombuffer(result[0],dtype=np.uint8)==rx))
            for value in result[2]['host_profile'].values():self.assertGreaterEqual(value,0)
            self.assertGreater(result[2]['seconds'],0)
            results.append({k:v for k,v in result[2].items() if k not in ('seconds','host_profile')})
            traces.append(events)
        self.assertEqual(results[0],results[1])
        self.assertEqual(traces[0],traces[1])

    def test_tail_shape_actual_driver_trace_pair(self):
        jobs,payload,_=jobs_for()
        self.successful_pair(jobs,payload)

    def test_256_actual_driver_trace_pair(self):
        jobs,payload,_=jobs_for(256,256,256)
        self.successful_pair(jobs,payload)

    def test_both_frozen_512_inputs_actual_driver_trace_pair(self):
        for index in (42,43):
            with self.subTest(input_id=index):
                _,_,jobs,payload,_=bank(index)
                self.successful_pair(jobs,payload)

    def test_pinned_expected_banks_match_independent_int64_cpu(self):
        # Outside any request timing; no claim this is a hardware execution.
        for index in (42,43):
            with self.subTest(input_id=index):
                a,b=fixture.bank_arrays(index)
                expected=np.frombuffer((ROOT/'bank'/f'input_{index}_expected.bin').read_bytes(),dtype='<i4').reshape(512,512)
                np.testing.assert_array_equal(a.astype(np.int64)@b.astype(np.int64),expected)

    def test_tail_padding_corruption_still_rejected_by_original_splitter(self):
        jobs,payload,_=jobs_for()
        bad=payload[:-1]+bytes([payload[-1]^1])
        r,tx,rx,_=fixture.fixture(jobs,bad)
        returned,records,_=execute(r,tx,rx,jobs)
        with self.assertRaises(ValueError):list(chain.split_chain_output(returned,records))

    def test_job_id_wrap_in_driver(self):
        jobs,payload,_=jobs_for()
        self.successful_pair(jobs,payload,first=0xFFFFFFFE)

    def test_legacy_driver_does_not_call_flat(self):
        jobs,payload,_=jobs_for(3,5,7)
        r,tx,rx,_=fixture.fixture(jobs,payload,candidate=False)
        with patch.object(candidate,'pack_chain_flat',side_effect=AssertionError('not legacy')):
            execute(r,tx,rx,jobs)

    def test_candidate_does_not_materialize_record_bytes(self):
        jobs,payload,_=jobs_for()
        r,tx,rx,_=fixture.fixture(jobs,payload)
        with patch.object(chain.ChainRecord,'bytes',property(lambda self: (_ for _ in ()).throw(AssertionError('extra record bytes')))):
            execute(r,tx,rx,jobs)

    def reject_before_device(self,mutate,**options):
        jobs,payload,_=jobs_for()
        r,tx,rx,events=fixture.fixture(jobs,payload)
        jobs=mutate(r,tx,rx,jobs)
        with self.assertRaises((ValueError,RuntimeError)):execute(r,tx,rx,jobs,**options)
        self.assertEqual(events,[])

    def test_capability_rejected_before_dma(self):
        def change(r,tx,rx,jobs):r.capabilities=0;return jobs
        self.reject_before_device(change)

    def test_empty_chain_rejected_before_dma(self):self.reject_before_device(lambda r,t,o,j:[])
    def test_bad_mode_rejected_before_dma(self):self.reject_before_device(lambda r,t,o,j:j,mode_override=99)
    def test_nonboolean_fast_counter_rejected_before_dma(self):self.reject_before_device(lambda r,t,o,j:j,fast_counter_reads=1)
    def test_fast_counter_requires_mode11(self):self.reject_before_device(lambda r,t,o,j:j,mode_override=10,fast_counter_reads=True)

    def test_bad_payload_rejected_before_dma(self):
        def change(r,tx,rx,jobs):return [dataclasses.replace(jobs[0],payload=jobs[0].payload[:-8]),*jobs[1:]]
        self.reject_before_device(change)

    def test_small_buffers_rejected_before_dma(self):
        jobs,payload,_=jobs_for()
        r,tx,rx,events=fixture.fixture(jobs,payload)
        for a,b in [(tx[:-1],rx),(tx,rx[:-1])]:
            with self.subTest(input=len(a),output=len(b)),self.assertRaises(ValueError):execute(r,a,b,jobs)
        self.assertEqual(events,[])

    def test_pack_failure_no_fallback_no_dma(self):
        jobs,payload,_=jobs_for()
        r,tx,rx,events=fixture.fixture(jobs,payload)
        with patch.object(candidate,'pack_chain_flat',side_effect=ValueError('synthetic pack fail')) as pack:
            with self.assertRaisesRegex(ValueError,'pack fail'):execute(r,tx,rx,jobs)
            self.assertEqual(pack.call_count,1)
        self.assertEqual(events,[])

    def test_legacy_launch_order_preserved(self):
        jobs,payload,_=jobs_for(3,5,7)
        r,tx,rx,events=fixture.fixture(jobs,payload)
        execute(r,tx,rx,jobs,launch_order='pl-first')
        start=events.index(('write',frozen.REG_CONTROL,frozen.CONTROL_START))
        send=next(i for i,e in enumerate(events) if e[:2]==('transfer','send'))
        self.assertLess(start,send)

    def test_wrong_completed_job_count_still_rejected(self):
        jobs,payload,_=jobs_for()
        r,tx,rx,_=fixture.fixture(jobs,payload)
        r.mmio.values[frozen.REG_CHAIN_JOBS]-=1
        with self.assertRaisesRegex(AssertionError,'chain jobs'):execute(r,tx,rx,jobs)

    def test_wrong_effective_macs_still_rejected(self):
        jobs,payload,_=jobs_for()
        r,tx,rx,_=fixture.fixture(jobs,payload)
        r.mmio.values[frozen.REG_MACS_LO]-=1
        with self.assertRaisesRegex(AssertionError,'effective MAC'):execute(r,tx,rx,jobs)

    def test_wrong_mode11_conservation_still_rejected(self):
        jobs,payload,_=jobs_for()
        r,tx,rx,_=fixture.fixture(jobs,payload)
        r.mmio.values[frozen.REG_D7_OVERLAP_LO]+=1
        with self.assertRaisesRegex(AssertionError,'counter contract'):execute(r,tx,rx,jobs)

    def test_pl_error_original_recovery_no_retry(self):
        jobs,payload,_=jobs_for()
        r,tx,rx,events=fixture.fixture(jobs,payload)
        r.mmio.fault='pl_error'
        with self.assertRaisesRegex(RuntimeError,'sticky chain error'):execute(r,tx,rx,jobs)
        self.assertEqual(events.count(('synthetic_recover',)),1)
        self.assertEqual(len([e for e in events if e[0]=='transfer']),2)

    def test_wait_error_original_recovery_no_retry(self):
        jobs,payload,_=jobs_for()
        r,tx,rx,events=fixture.fixture(jobs,payload)
        with patch.object(frozen,'wait_until',side_effect=TimeoutError('synthetic timeout')):
            with self.assertRaises(TimeoutError):execute(r,tx,rx,jobs)
        self.assertEqual(events.count(('synthetic_recover',)),1)
        self.assertEqual(len([e for e in events if e[0]=='transfer']),2)


class OwnerAndCompleteCall(unittest.TestCase):
    def setUp(self):
        self.a,self.b,self.jobs,self.payload,self.expected=bank()
        self.runner,self.tx,self.rx,self.events=fixture.fixture(self.jobs,self.payload)
        self.stopped=False
        self.owner=fixture.owner_fixture(self.runner,self.tx,self.rx,self.events,lambda:self.stopped)

    def tearDown(self):
        import batch_owner
        # Synthetic-only quarantine is removed from this test process; never free a real lock/buffer.
        if self.owner in batch_owner._RETAINED:batch_owner._RETAINED.remove(self.owner)

    def test_actual_owner_call_reconstructs_entire_pinned_output(self):
        call=BatchCall(self.owner,self.owner.policy,enabled=True)
        output,metrics=call(self.a,self.b)
        np.testing.assert_array_equal(output,self.expected)
        self.assertEqual(output.nbytes,1048576)
        self.assertEqual(metrics['effective_macs'],134217728)
        self.assertEqual(set(metrics['attribution_adapter_ns']),{'transaction_generation','owned_submission','record_reconstruction','output_unpack'})
        self.assertEqual(self.owner._index,1)

    def test_stop_before_submit_blocks_all_dma(self):
        self.stopped=True
        with self.assertRaises(BatchStop):owner_execute(self.owner,self.jobs)
        self.assertFalse(any(e[0]=='transfer' for e in self.events))
        self.assertFalse(self.owner._held)

    def test_last_stop_check_before_entering_run_chain(self):
        original=self.owner.pre_submit
        def stop_after_precheck():
            proof=original()
            self.stopped=True
            return proof
        with patch.object(self.owner,'pre_submit',side_effect=stop_after_precheck):
            with self.assertRaises(BatchStop):owner_execute(self.owner,self.jobs)
        self.assertFalse(any(e[0]=='transfer' for e in self.events))

    def test_stop_arriving_during_pack_finishes_current_no_next(self):
        original=candidate.pack_chain_flat
        def during_pack(*args,**kwargs):
            self.stopped=True
            return original(*args,**kwargs)
        with patch.object(candidate,'pack_chain_flat',side_effect=during_pack):
            result=owner_execute(self.owner,self.jobs)
        self.assertEqual(result[0],self.payload)
        self.assertEqual(self.owner._index,1)
        transfers=len([e for e in self.events if e[0]=='transfer'])
        with self.assertRaises(BatchStop):owner_execute(self.owner,self.jobs,first_job_id=65)
        self.assertEqual(len([e for e in self.events if e[0]=='transfer']),transfers)

    def test_lease_failure_blocks_submission_and_quarantines(self):
        self.owner._lease.fault=True
        with self.assertRaisesRegex(RuntimeError,'lease lost'):owner_execute(self.owner,self.jobs)
        self.assertFalse(any(e[0]=='transfer' for e in self.events))
        self.assertTrue(self.owner._held)
        with self.assertRaises(RuntimeError):self.owner.close()
        self.assertFalse(any(e[0] in ('free','lease_close') for e in self.events))

    def test_hardware_identity_drift_blocks_dma(self):
        self.runner.mmio.values[frozen.REG_BUILD_ID]=0
        with self.assertRaises(RuntimeError):owner_execute(self.owner,self.jobs)
        self.assertTrue(self.owner._held)
        self.assertFalse(any(e[0]=='transfer' for e in self.events))

    def test_buffer_alias_blocks_dma(self):
        self.rx.physical_address=self.tx.physical_address
        with self.assertRaisesRegex(RuntimeError,'alias'):owner_execute(self.owner,self.jobs)
        self.assertFalse(any(e[0]=='transfer' for e in self.events))

    def test_owner_busy_no_nested_submit(self):
        self.owner._guard.acquire()
        try:
            with self.assertRaisesRegex(RuntimeError,'busy'):owner_execute(self.owner,self.jobs)
        finally:self.owner._guard.release()
        self.assertEqual(self.events,[])

    def test_owner_thread_drift_rejected(self):
        self.owner._thread=-1
        try:
            with self.assertRaisesRegex(RuntimeError,'ownership drift'):owner_execute(self.owner,self.jobs)
        finally:self.owner._thread=threading.get_ident()
        self.assertEqual(self.events,[])

    def test_schedule_drift_rejected(self):
        with self.assertRaisesRegex(ValueError,'schedule'):owner_execute(self.owner,self.jobs,first_job_id=65)
        self.assertFalse(any(e[0]=='transfer' for e in self.events))

    def test_wrong_counter_quarantines_and_preserves_resources(self):
        self.runner.mmio.values[frozen.REG_D7_OVERLAP_LO]+=1
        with self.assertRaises(AssertionError):owner_execute(self.owner,self.jobs)
        self.assertTrue(self.owner._held)
        with self.assertRaises(RuntimeError):self.owner.close()
        self.assertFalse(any(e[0]=='free' for e in self.events))

    def test_success_cleanup_recovery_free_and_lease_close_once(self):
        owner_execute(self.owner,self.jobs)
        self.owner.close()
        self.owner.close()
        self.assertEqual([e for e in self.events if e[0]=='free'],[('free','rx'),('free','tx')])
        self.assertEqual(self.events.count(('lease_close',)),1)
        self.assertIsNotNone(self.owner.cleanup_readback)
        self.assertFalse(self.owner.supervision_status['lease_retained'])
        self.assertFalse(self.owner.supervision_status['root_buffers_retained'])

    def test_no_post_close_reuse(self):
        self.owner.close()
        with self.assertRaises(RuntimeError):owner_execute(self.owner,self.jobs)
        self.assertFalse(any(e[0]=='transfer' for e in self.events))

    def test_owner_option_set_does_not_admit_fast_counter_switch(self):
        with self.assertRaises(ValueError):owner_execute(self.owner,self.jobs,fast_counter_reads=True)
        self.assertFalse(any(e[0]=='transfer' for e in self.events))

    def test_full_call_records_rebuilt_and_tamper_rejected(self):
        original=self.runner.run_chain
        def altered(*args,**kwargs):
            payload,records,metrics=original(*args,**kwargs)
            return payload,records[:-1],metrics
        call=BatchCall(self.owner,self.owner.policy,enabled=True)
        with patch.object(self.runner,'run_chain',side_effect=altered):
            with self.assertRaisesRegex(ValueError,'records differ') as raised:call(self.a,self.b)
        self.assertEqual(raised.exception.matrix_returned_payload,self.payload)
        count=len([e for e in self.events if e[0]=='transfer'])
        with self.assertRaisesRegex(RuntimeError,'no retry'):call(self.a,self.b)
        self.assertEqual(len([e for e in self.events if e[0]=='transfer']),count)


class OwnerInitializationBinding(unittest.TestCase):
    """Run the actual owner.start + original constructor against a fake PYNQ module."""
    def start(self,*,fail_overlay=False,fail_second_allocation=False,clock=100.):
        import batch_owner
        from batch_policy import BatchPolicy
        self.a,self.b,self.jobs,self.payload,self.expected=bank()
        r,_,_,self.events=fixture.fixture(self.jobs,self.payload)
        self.engine=r.mmio
        overlay=SimpleNamespace(ip_dict={'axi_dma':{'type':'xilinx.com:ip:axi_dma:7.1'},
            'accel':{'phys_addr':0x40000000,'addr_range':4096}},axi_dma=r.dma)
        fake=ModuleType('pynq')
        fake.__version__='3.1.1'
        fake.Clocks=SimpleNamespace(fclk0_mhz=clock)
        def load_overlay(path,download):
            self.events.append(('synthetic_overlay',path,download))
            if fail_overlay:raise RuntimeError('synthetic overlay init failure')
            return overlay
        fake.Overlay=load_overlay
        fake.MMIO=lambda address,extent:self.engine
        allocated=[]
        def allocate(shape,dtype):
            if fail_second_allocation and len(allocated)==1:
                raise RuntimeError('synthetic second allocation failure')
            result=fixture.Buffer(shape[0],0x10000000+len(allocated)*0x10000000,self.events,'tx' if not allocated else 'rx')
            allocated.append(result)
            return result
        fake.allocate=allocate
        self.owner=batch_owner.BatchOwner(BatchPolicy('smoke8',enabled=True),lambda:False,enabled=True)
        self.addCleanup(lambda:batch_owner._RETAINED.remove(self.owner) if self.owner in batch_owner._RETAINED else None)
        lease=fixture.Lease(self.events)
        class Recovery:
            last_diagnostics={'source':'synthetic PC recovery, NOT device evidence'}
            def recover_and_confirm(inner,runner):
                self.engine.values[0x12c]=1
                self.engine.values[frozen.REG_STATUS]=1
                self.events.append(('synthetic_recovery_factory',))
                return True
        with patch.dict(sys.modules,{'pynq':fake}),patch.object(batch_owner,'ObservedLease',return_value=lease):
            self.owner.start(flat_runner_type(enabled=True),Path('synthetic_only.bit'),lambda:None,
                             lambda *args,**kwargs:Recovery())
        return self.owner

    def test_factory_owner_start_complete_calls_both_inputs_cleanup(self):
        owner=self.start()
        call=BatchCall(owner,owner.policy,enabled=True)
        for offset,index in enumerate((42,43)):
            a,b,jobs,payload,expected=bank(index)
            self.engine.payload=payload
            result,metrics=call(a,b)
            np.testing.assert_array_equal(result,expected)
            self.assertEqual(bytes(owner._buffers[0]),chain.pack_chain(jobs,1+64*offset)[0])
            self.assertEqual(metrics['first_job_id'],1+64*offset)
        self.assertEqual(owner._index,2)
        self.assertIsInstance(owner._runner,FlatPackPynqGemm)
        owner.close()
        self.assertEqual(self.events.count(('synthetic_lease_enter',)),1)
        self.assertEqual(self.events.count(('lease_close',)),1)
        self.assertEqual([e for e in self.events if e[0]=='free'],[('free','rx'),('free','tx')])

    def test_partial_constructor_failure_retains_lease_and_runner(self):
        with self.assertRaisesRegex(RuntimeError,'overlay init'):self.start(fail_overlay=True)
        self.assertTrue(self.owner._held)
        self.assertTrue(self.owner._lease.entered)
        self.assertIsNotNone(self.owner._runner)
        with self.assertRaises(RuntimeError):self.owner.close()
        self.assertFalse(any(e[0] in ('free','lease_close') for e in self.events))

    def test_partial_root_allocation_failure_retains_first_buffer(self):
        with self.assertRaisesRegex(RuntimeError,'second allocation'):self.start(fail_second_allocation=True)
        self.assertTrue(self.owner._held)
        self.assertEqual(len(self.owner._buffers),1)
        with self.assertRaises(RuntimeError):self.owner.close()
        self.assertFalse(any(e[0] in ('free','lease_close') for e in self.events))

    def test_constructor_clock_identity_gate_kept(self):
        with self.assertRaisesRegex(RuntimeError,'100MHz'):self.start(clock=99.)
        self.assertTrue(self.owner._held)
        self.assertFalse(any(e[0]=='transfer' for e in self.events))


if __name__=='__main__':unittest.main(verbosity=2)
