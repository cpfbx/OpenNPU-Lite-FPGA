"""Exact new plan, bank and derived Python paths, always synthetic hardware/OS."""
import ast
import copy
from dataclasses import asdict,replace
import hashlib
import inspect
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import textwrap
import threading
from types import ModuleType,SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np
import batch_owner
from batch_policy import BatchPolicy,BatchStop
import owner_entry_candidate
from comparison_policy import (ComparisonPolicy,Geometry,describe_plan,validate_policy,
                               validate_fpga_policy)
from comparison_owner import ComparisonOwner
from comparison_call import ComparisonCall
import comparison_bank
from serial_plan import SerialPlan
import comparison_binding
import offline_fixture
from entry_fixture import FakeCanonicalEnvironment
import pynq_gemm as driver
from flat_driver_candidate import flat_runner_type
from matrix_panel_builder_candidate import build_panel_layout_cached_transactions
from tiled_gemm import TileConfig,Layout

ROOT=Path(__file__).resolve().parent.parent
BANK_SHA='af893b4381e8c72a667b772b3d40aa7b2db03739232e9f60b21bbb1ef1c939a8'


def bank():return comparison_bank.load_bank(ROOT,BANK_SHA)


def jobs_payload(pair):
    a,b=pair.arrays()
    jobs=list(build_panel_layout_cached_transactions(a,b,TileConfig(layout=Layout.K_MAJOR),enabled=True).transactions)
    expected=np.frombuffer(pair.expected,dtype='<i4').reshape(pair.dimension,pair.dimension)
    return a,b,jobs,offline_fixture.tiled_output(jobs,expected)


class Harness:
    def __init__(self,policy,stop=None,allocation_failure=None,clock=100.):
        self.policy=policy
        self.bank=bank()
        self.pair=self.bank[policy.dimension,42]
        _,_,self.jobs,payload=jobs_payload(self.pair)
        runner,_,_,self.events=offline_fixture.fixture(self.jobs,payload)
        self.engine=runner.mmio
        self.stop=False
        self.owner=ComparisonOwner(policy,stop or (lambda:self.stop),enabled=True)
        self.fake=ModuleType('pynq');self.fake.__version__='3.1.1'
        self.fake.Clocks=SimpleNamespace(fclk0_mhz=clock)
        overlay=SimpleNamespace(ip_dict={'axi_dma':{'type':'xilinx.com:ip:axi_dma:7.1'},
            'accel':{'phys_addr':0x40000000,'addr_range':4096}},axi_dma=runner.dma)
        self.fake.Overlay=lambda path,download:overlay
        self.fake.MMIO=lambda address,extent:self.engine
        self.buffers=[]
        def allocate(shape,dtype):
            if allocation_failure==len(self.buffers):raise RuntimeError('synthetic allocation failure')
            buf=offline_fixture.Buffer(shape[0],0x10000000+len(self.buffers)*0x10000000,
                self.events,'tx' if not self.buffers else 'rx')
            self.buffers.append(buf);return buf
        self.fake.allocate=allocate
        harness=self
        class Recovery:
            last_diagnostics={'source':'synthetic only, not hardware recovery'}
            def recover_and_confirm(self,r):
                harness.engine.values[0x12c]=1
                harness.engine.values[driver.REG_STATUS]=1
                return True
        self.recovery=lambda *args,**kwargs:Recovery()

    def start(self,env,runner_type=None):
        runner=runner_type or flat_runner_type(enabled=True)
        with patch.dict(sys.modules,{'pynq':self.fake}):
            self.owner.start(runner,Path('synthetic_not_a_device.bit'),env.factory,self.recovery)
        return self.owner

    def discard(self):
        if self.owner in batch_owner._RETAINED:batch_owner._RETAINED.remove(self.owner)


class PlanTests(unittest.TestCase):
    def test_exact_plan_count_and_order(self):
        plan=describe_plan()
        self.assertEqual((plan['formal_calls'],plan['warmup_calls'],plan['total_calls']),(48,24,72))
        for group in (plan['blocks'][:6],plan['blocks'][6:]):
            self.assertEqual([b['backend'] for b in group],['fpga_flat_baseline','fpga_flat_contiguous','openblas_2t','openblas_2t','fpga_flat_contiguous','fpga_flat_baseline'])

    def test_pinned_plan_json_equals_code(self):
        self.assertEqual(json.loads((ROOT/'plan.json').read_bytes()),describe_plan())

    def test_each_shape_each_backend_has_eight_formal(self):
        counts={}
        for block in describe_plan()['blocks']:
            for request in block['requests']:
                if request['phase']=='formal':
                    key=request['dimension'],request['backend'];counts[key]=counts.get(key,0)+1
        self.assertEqual(len(counts),6)
        self.assertEqual(set(counts.values()),{8})

    def test_indices_inputs_and_phase_fixed(self):
        indices=[]
        for b in range(12):
            p=ComparisonPolicy(b,True)
            for i in range(6):
                r=p.request(i);indices.append(r.global_index)
                self.assertEqual(r.input_id,42+i%2)
                self.assertEqual(r.phase,'warmup' if i<2 else 'formal')
                self.assertEqual(r.first_job_id,1+r.jobs*r.global_index)
        self.assertEqual(indices,list(range(72)))

    def test_policy_bad_block_type_or_range(self):
        for value in (-1,12,True,0.,'0',None):
            with self.subTest(value=value),self.assertRaises(ValueError):ComparisonPolicy(value,True)

    def test_default_off_and_truthy_not_true(self):
        for value in (False,1,'true',None):
            with self.subTest(value=value),self.assertRaises(ValueError):ComparisonPolicy(0,value)

    def test_bad_request_index(self):
        for value in (-1,6,True,0.,'0'):
            with self.subTest(value=value),self.assertRaises(ValueError):ComparisonPolicy(0,True).request(value)

    def test_old_policy_and_subclass_refused(self):
        class Fake(ComparisonPolicy):pass
        for p in (BatchPolicy('smoke8',True),Fake(0,True),None):
            with self.subTest(policy=p),self.assertRaises(ValueError):validate_policy(p)

    def test_cpu_blocks_cannot_construct_fpga_owner(self):
        for b in (2,3,8,9):
            with self.subTest(block=b),self.assertRaises(ValueError):ComparisonOwner(ComparisonPolicy(b,True),lambda:False,enabled=True)

    def test_geometry_exact_values(self):
        for d,wanted in ((256,(16,525312,262144,16777216)),(512,(64,4198400,1048576,134217728))):
            g=Geometry(d);self.assertEqual((g.jobs,g.input_bytes,g.output_bytes,g.macs),wanted)
        for d in (True,256.,128,0):
            with self.subTest(d=d),self.assertRaises(ValueError):Geometry(d)


class BankTests(unittest.TestCase):
    def test_bank_four_pairs_and_shapes(self):
        pairs=bank();self.assertEqual(set(pairs),{(d,i) for d in (256,512) for i in (42,43)})
        for pair in pairs.values():
            a,b=pair.arrays()
            for x in (a,b):
                self.assertEqual(x.shape,(pair.dimension,)*2)
                self.assertTrue(x.flags.owndata and x.flags.c_contiguous)
                self.assertFalse(x.flags.writeable)
            self.assertFalse(np.shares_memory(a,b))

    def test_all_four_goldens_match_independent_int64(self):
        for pair in bank().values():
            with self.subTest(d=pair.dimension,i=pair.input_id):
                a,b=pair.arrays();out=(a.astype(np.int64)@b.astype(np.int64)).astype(np.int32)
                self.assertEqual(comparison_bank.verify_output(pair,out),hashlib.sha256(pair.expected).hexdigest())

    def test_256_is_derived_inputs_not_sliced_512_golden(self):
        pairs=bank()
        for i in (42,43):
            big=pairs[512,i];small=pairs[256,i]
            for a,b in zip(big.arrays(),small.arrays()):np.testing.assert_array_equal(a[:256,:256],b)
            top=np.frombuffer(big.expected,dtype='<i4').reshape(512,512)[:256,:256]
            self.assertFalse(np.array_equal(top,np.frombuffer(small.expected,dtype='<i4').reshape(256,256)))

    def test_wrong_bank_anchor_refused(self):
        for anchor in ('0'*64,True,'x'):
            with self.subTest(anchor=anchor),self.assertRaises(ValueError):comparison_bank.load_bank(ROOT,anchor)

    def test_bool_size_and_duplicate_pair_refused(self):
        original=json.loads((ROOT/'bank_manifest.json').read_bytes())
        for mutate in (lambda v:v['rows'][0]['assets']['a'].update(bytes=True),
                       lambda v:v['rows'].__setitem__(0,v['rows'][1])):
            bad=copy.deepcopy(original);mutate(bad)
            with patch.object(comparison_bank.verifier,'read_json',return_value=bad):
                with self.assertRaises(ValueError):bank()

    def test_wrong_asset_mapping_refused(self):
        bad=json.loads((ROOT/'bank_manifest.json').read_bytes())
        bad['rows'][0]['assets']['a']['path']='../outside'
        with patch.object(comparison_bank.verifier,'read_json',return_value=bad):
            with self.assertRaisesRegex(ValueError,'mapping'):bank()

    def test_wrong_endian_metadata_refused(self):
        bad=json.loads((ROOT/'bank_manifest.json').read_bytes());bad['byte_order']='big'
        with patch.object(comparison_bank.verifier,'read_json',return_value=bad):
            with self.assertRaisesRegex(ValueError,'schema'):bank()

    def test_altered_asset_bytes_refused(self):
        original=comparison_bank.checked_path
        class Changed:
            def read_bytes(self):return b'\0'*65536
        def altered(root,name):
            return Changed() if name=='bank256/input_42_a.bin' else original(root,name)
        with patch.object(comparison_bank,'checked_path',side_effect=altered):
            with self.assertRaisesRegex(ValueError,'asset drift'):bank()

    def test_one_wrong_value_rejected(self):
        pair=bank()[256,42]
        out=np.frombuffer(pair.expected,dtype='<i4').reshape(256,256).copy();out[-1,-1]^=1
        with self.assertRaisesRegex(ValueError,'golden mismatch'):comparison_bank.verify_output(pair,out)

    def test_wrong_output_dtype_shape_or_array_subclass_refused(self):
        pair=bank()[256,42]
        for out in (np.zeros((256,256),np.int64),np.zeros((512,512),np.int32),
                    np.zeros((256,256),np.int32).view(np.matrix)):
            with self.subTest(kind=type(out)),self.assertRaises(ValueError):comparison_bank.verify_output(pair,out)


class DerivationTests(unittest.TestCase):
    def test_new_owner_only_three_overrides_rest_inherited(self):
        own={n for n,v in ComparisonOwner.__dict__.items() if callable(v)}
        self.assertEqual(own,{'__init__','start','execute_chain'})
        for name in ('_owned','_hold','_identity','_buffers_valid','pre_submit','close','supervision_status'):
            self.assertIs(getattr(ComparisonOwner,name),getattr(owner_entry_candidate.EntrySafeBatchOwner,name))

    def test_owner_init_and_execute_ast_exact_after_policy_normalization(self):
        for name in ('__init__','execute_chain'):
            old=textwrap.dedent(inspect.getsource(getattr(batch_owner.BatchOwner,name)))
            new=textwrap.dedent(inspect.getsource(getattr(ComparisonOwner,name)))
            new=new.replace('validate_fpga_policy(','validate_policy(')
            self.assertEqual(ast.dump(ast.parse(old)),ast.dump(ast.parse(new)))

    def test_owner_start_ast_exact_after_shape_extent_normalization(self):
        old=textwrap.dedent(inspect.getsource(owner_entry_candidate.EntrySafeBatchOwner.start))
        new=textwrap.dedent(inspect.getsource(ComparisonOwner.start))
        new=new.replace('(self.policy.geometry.input_bytes,self.policy.geometry.output_bytes)','(4198400,1048576)')
        self.assertEqual(ast.dump(ast.parse(old)),ast.dump(ast.parse(new)))

    def test_legacy_old_policy_still_fixed_and_unmodified(self):
        p=BatchPolicy('smoke8',True);self.assertEqual(p.request(0).shape,(512,)*3)
        import batch_policy
        with self.assertRaises(ValueError):batch_policy.validate_policy(ComparisonPolicy(0,True))

    def test_call_ast_exact_after_shape_and_metric_normalization(self):
        import batch_call
        old=textwrap.dedent(inspect.getsource(batch_call.BatchCall._call))
        new=textwrap.dedent(inspect.getsource(ComparisonCall._call))
        changes={
            'x.shape != (512, 512)':'x.shape != (spec.dimension, spec.dimension)',
            'chain_last=i == 63':'chain_last=i == spec.jobs-1',
            'mode=11, jobs=64, chain_jobs_completed=64, input_bytes=4198400':'mode=11, jobs=spec.jobs, chain_jobs_completed=spec.jobs, input_bytes=self.policy.geometry.input_bytes',
            'output_bytes=1048576, output_valid_bytes=1048576':'output_bytes=self.policy.geometry.output_bytes, output_valid_bytes=self.policy.geometry.output_bytes',
            'effective_macs=134217728':'effective_macs=self.policy.geometry.macs',
            'len(payload) != 1048576':'len(payload) != self.policy.geometry.output_bytes',
            'np.zeros((512, 512), dtype=np.int32)':'np.zeros((spec.dimension, spec.dimension), dtype=np.int32)',
            "batch_policy='explicit-service-batch-v1'":"batch_policy='explicit-panel-comparison-v1'"}
        for before,after in changes.items():
            self.assertEqual(new.count(after),1);new=new.replace(after,before)
        self.assertEqual(ast.dump(ast.parse(old)),ast.dump(ast.parse(new)))

    def test_call_init_only_adds_owner_policy_identity_guard(self):
        import batch_call
        old=ast.parse(textwrap.dedent(inspect.getsource(batch_call.BatchCall.__init__)))
        new=ast.parse(textwrap.dedent(inspect.getsource(ComparisonCall.__init__)))
        guards=[n for n in new.body[0].body if isinstance(n,ast.If) and 'owner.policy' in ast.unparse(n.test)]
        self.assertEqual(len(guards),1);new.body[0].body.remove(guards[0])
        fresh=[n for n in new.body[0].body if isinstance(n,ast.If) and "'_index'" in ast.unparse(n.test)]
        self.assertEqual(len(fresh),1);new.body[0].body.remove(fresh[0])
        self.assertEqual(ast.dump(old),ast.dump(new))


class OwnerCallTests(unittest.TestCase):
    def harness(self,block,**kwargs):
        h=Harness(ComparisonPolicy(block,True),**kwargs);self.addCleanup(h.discard);return h

    def test_both_fpga_paths_both_shapes_six_requests_cleanup(self):
        for block in (0,1,6,7):
            with self.subTest(block=block):
                h=self.harness(block);env=FakeCanonicalEnvironment()
                with env.install():
                    owner=h.start(env);call=ComparisonCall(owner,h.policy,enabled=True)
                    self.assertEqual(tuple(x.nbytes for x in owner._buffers),
                        (h.policy.geometry.input_bytes,h.policy.geometry.output_bytes))
                    for index in range(6):
                        spec=h.policy.request(index);pair=h.bank[spec.dimension,spec.input_id]
                        a,b,_,payload=jobs_payload(pair);h.engine.payload=payload
                        out,metrics=call(a,b)
                        comparison_bank.verify_output(pair,out)
                        self.assertEqual(metrics['jobs'],h.policy.geometry.jobs)
                        self.assertEqual(metrics['effective_macs'],h.policy.geometry.macs)
                        self.assertEqual(metrics['first_job_id'],spec.first_job_id)
                    transfers=sum(e[0]=='transfer' for e in h.events)
                    with self.assertRaises(ValueError):call(a,b)
                    self.assertEqual(sum(e[0]=='transfer' for e in h.events),transfers)
                    owner.close();owner.close()
                    self.assertEqual(env.close_calls,1);self.assertFalse(env.fd_live)
                    self.assertEqual([e for e in h.events if e[0]=='free'],[('free','rx'),('free','tx')])

    def test_mismatched_call_owner_policy_refused(self):
        h=self.harness(0)
        with self.assertRaisesRegex(ValueError,'policy object mismatch'):
            ComparisonCall(h.owner,ComparisonPolicy(0,True),enabled=True)

    def test_stop_before_acquisition_or_submission_no_dma(self):
        h=self.harness(0);h.stop=True;env=FakeCanonicalEnvironment()
        with env.install():
            with self.assertRaises(RuntimeError):h.start(env)
            self.assertEqual(env.factory_calls,0)
            self.assertFalse(any(e[0]=='transfer' for e in h.events))

    def test_stop_during_pack_finishes_current_request_no_next(self):
        h=self.harness(1);env=FakeCanonicalEnvironment()
        import flat_driver_candidate
        original=flat_driver_candidate.pack_chain_flat
        def during(*args,**kwargs):h.stop=True;return original(*args,**kwargs)
        with env.install():
            owner=h.start(env);call=ComparisonCall(owner,h.policy,enabled=True)
            a,b=h.pair.arrays()
            with patch.object(flat_driver_candidate,'pack_chain_flat',side_effect=during):out,_=call(a,b)
            comparison_bank.verify_output(h.pair,out)
            n=sum(e[0]=='transfer' for e in h.events)
            with self.assertRaises(BatchStop):call(a,b)
            self.assertEqual(sum(e[0]=='transfer' for e in h.events),n)
            owner.close();self.assertFalse(env.fd_live)

    def test_clock_and_partial_allocation_failures_quarantine(self):
        for kwargs in (dict(clock=99.),dict(allocation_failure=0),dict(allocation_failure=1)):
            with self.subTest(kwargs=kwargs):
                h=self.harness(0,**kwargs);env=FakeCanonicalEnvironment()
                with env.install():
                    with self.assertRaises(RuntimeError):h.start(env)
                    self.assertTrue(h.owner._held);self.assertIsNotNone(h.owner._lease)
                    with self.assertRaisesRegex(RuntimeError,'quarantined'):h.owner.close()
                    self.assertEqual(env.close_calls,0)

    def test_actual_helper_enter_and_close_double_failure_retains(self):
        h=self.harness(0);env=FakeCanonicalEnvironment(drift=True,close_error=True)
        with env.install():
            with self.assertRaises(ValueError):h.start(env)
            self.assertTrue(h.owner._held and h.owner._unsafe)
            self.assertIsNotNone(h.owner._lease)
            with self.assertRaises(RuntimeError):h.owner.close()
            self.assertTrue(env.fd_live);self.assertEqual(env.close_calls,1)

    def test_changed_counter_fails_and_does_not_retry(self):
        h=self.harness(1);env=FakeCanonicalEnvironment()
        with env.install():
            owner=h.start(env);call=ComparisonCall(owner,h.policy,enabled=True)
            h.engine.values[driver.REG_D7_OVERLAP_LO]+=1
            a,b=h.pair.arrays()
            with self.assertRaises(AssertionError):call(a,b)
            self.assertTrue(owner._held)
            transfers=sum(e[0]=='transfer' for e in h.events)
            with self.assertRaisesRegex(RuntimeError,'no retry'):call(a,b)
            self.assertEqual(sum(e[0]=='transfer' for e in h.events),transfers)
            with self.assertRaises(RuntimeError):owner.close()

    def test_wrong_shape_or_sequence_never_reaches_dma(self):
        h=self.harness(0);env=FakeCanonicalEnvironment()
        with env.install():
            owner=h.start(env);call=ComparisonCall(owner,h.policy,enabled=True)
            big=h.bank[512,42];a,b=big.arrays()
            with self.assertRaises(ValueError):call(a,b)
            self.assertFalse(any(e[0]=='transfer' for e in h.events))
            owner.close()

    def test_root_buffer_alias_rejected_before_dma(self):
        h=self.harness(0);env=FakeCanonicalEnvironment()
        with env.install():
            owner=h.start(env);owner._buffers[1].physical_address=owner._buffers[0].physical_address
            a,b=h.pair.arrays()
            with self.assertRaisesRegex(RuntimeError,'alias'):ComparisonCall(owner,h.policy,enabled=True)(a,b)
            self.assertFalse(any(e[0]=='transfer' for e in h.events))
            # pre_submit outside execute raises before hardware; restore only fake test data.
            owner._buffers[1].physical_address=0x20000000;owner.close()


class LedgerTests(unittest.TestCase):
    def finish(self,ledger):
        ledger.finish(dict(block_index=ledger.active.block_index,actual_exit_code=0,
            process_group_absent=True,cleanup_verified=True,lock_released=True))

    def test_all_72_calls_only_one_block_active(self):
        ledger=SerialPlan(enabled=True)
        for b in range(12):
            ledger.begin(ComparisonPolicy(b,True))
            for _ in range(6):r=ledger.claim();ledger.accept(r,exact=True)
            self.finish(ledger)
        self.assertTrue(ledger.summary()['plan_complete'])
        self.assertEqual((ledger.formal,ledger.warmup),(48,24))
        self.assertFalse(ledger.summary()['os_evidence_observed'])

    def test_next_block_not_started_before_terminal_receipt(self):
        ledger=SerialPlan(enabled=True);ledger.begin(ComparisonPolicy(0,True))
        with self.assertRaises(ValueError):ledger.begin(ComparisonPolicy(1,True))

    def test_duplicate_claim_rejected(self):
        l=SerialPlan(enabled=True);l.begin(ComparisonPolicy(0,True));l.claim()
        with self.assertRaises(ValueError):l.claim()

    def test_stop_during_pending_accepts_completion_no_next(self):
        l=SerialPlan(enabled=True);l.begin(ComparisonPolicy(0,True));r=l.claim();l.stop();l.accept(r,exact=True)
        with self.assertRaises(BatchStop):l.claim()
        self.assertEqual(l.warmup,1);self.assertFalse(l.summary()['plan_complete'])

    def test_wrong_result_latches_no_retry(self):
        l=SerialPlan(enabled=True);l.begin(ComparisonPolicy(0,True));r=l.claim()
        with self.assertRaises(ValueError):l.accept(r,exact=1)
        with self.assertRaises(RuntimeError):l.claim()

    def test_equal_but_different_request_object_rejected(self):
        l=SerialPlan(enabled=True);l.begin(ComparisonPolicy(0,True));r=l.claim()
        with self.assertRaises(ValueError):l.accept(replace(r),exact=True)

    def test_missing_cleanup_wrong_exit_bool_or_group_residual_refused(self):
        for change in (dict(actual_exit_code=1),dict(actual_exit_code=False),
                       dict(process_group_absent=False),dict(lock_released=False),dict(cleanup_verified=False)):
            with self.subTest(change=change):
                l=SerialPlan(enabled=True);l.begin(ComparisonPolicy(0,True))
                for _ in range(6):r=l.claim();l.accept(r,exact=True)
                receipt=dict(block_index=0,actual_exit_code=0,process_group_absent=True,cleanup_verified=True,lock_released=True)
                receipt.update(change)
                with self.assertRaises(ValueError):l.finish(receipt)
                with self.assertRaises(RuntimeError):l.begin(ComparisonPolicy(1,True))


class BindingTests(unittest.TestCase):
    def test_probe_cli_isolated_help_from_external_cwd(self):
        with tempfile.TemporaryDirectory() as folder:
            done=subprocess.run([sys.executable,'-I','-B',str(ROOT/'probe_comparison.py'),'--help'],
                                cwd=folder,capture_output=True,timeout=30)
        self.assertEqual(done.returncode,0,done.stderr.decode('utf-8',errors='replace'))
        self.assertIn(b'--manifest-sha',done.stdout)

    def test_default_off_and_cold_pynq_rejected(self):
        with self.assertRaisesRegex(ValueError,'default-off'):comparison_binding.check('x','x','x')
        for name in ('pynq','pynq.unknown'):
            with patch.dict(sys.modules,{name:ModuleType(name)}):
                with self.assertRaisesRegex(ValueError,'cold'):comparison_binding.cold()

    def test_new_module_collision_refused(self):
        for name in ('comparison_policy','comparison_owner','comparison_call','comparison_bank','serial_plan','verify_candidate','binding_flat'):
            with self.subTest(name=name),patch.dict(sys.modules,{name:SimpleNamespace(__file__='outside.py')}):
                with self.assertRaisesRegex(ValueError,'collision'):comparison_binding.configure()


if __name__=='__main__':unittest.main(verbosity=2)
