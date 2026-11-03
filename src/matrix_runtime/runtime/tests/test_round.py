"""No board execution. Serial receipts injected; real PC child tests explicitly labelled."""
from dataclasses import replace
import hashlib
import io
import json
import os
from pathlib import Path
import queue
import signal
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np
from batch_policy import BatchStop
from comparison_policy import ComparisonPolicy
from comparison_bank import load_bank
from round_artifacts import RetainedOutputs,checked_request,timing_row,descriptive_stats
from round_coordinator import RoundCoordinator
import supervision_bridge as bridge
import cpu_parent
from cpu_parent import run_cpu_block,settle_reader
from cpu_guardian import CpuGuardian,_RETAINED
from entry_fixture import FakeCanonicalEnvironment

ROOT=Path(__file__).resolve().parent.parent
BANK_SHA='af893b4381e8c72a667b772b3d40aa7b2db03739232e9f60b21bbb1ef1c939a8'


def spec(block=0,index=2):return ComparisonPolicy(block,True).request(index)
def output(bank,request):
    return np.frombuffer(bank[request.dimension,request.input_id].expected,dtype='<i4').reshape(request.dimension,request.dimension).copy()
def receipt(policy):
    return dict(block_index=policy.block_index,actual_exit_code=0,process_group_absent=True,
        cleanup_verified=True,lock_released=True)
def result(index=0):return dict(begin_ns=1,end_ns=1001+index,process_cpu_ns=2000+index)


class RetentionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.bank=load_bank(ROOT,BANK_SHA)

    def test_default_off(self):
        with self.assertRaises(ValueError):RetainedOutputs()

    def test_fixed_representatives_and_maximum_byte_bound(self):
        sink=RetainedOutputs(enabled=True)
        for b in range(12):
            for i in range(6):
                r=spec(b,i);o=output(self.bank,r)
                sink.success(r,o,hashlib.sha256(self.bank[r.dimension,r.input_id].expected).hexdigest())
        sink.failure(spec(11,5),bytes(1048576),'row-major-int32-le')
        self.assertEqual(len(sink.successes),12)
        self.assertEqual(sink.payload_bytes,sink.MAX_PAYLOAD_BYTES)
        self.assertEqual(sink.MAX_PAYLOAD_BYTES,8912896)

    def test_success_is_immutable_copy(self):
        sink=RetainedOutputs(enabled=True);r=spec();o=output(self.bank,r)
        sink.success(r,o,hashlib.sha256(o.tobytes()).hexdigest());o[:]=0
        self.assertEqual(sink.successes[0]['payload'],self.bank[256,42].expected)

    def test_duplicate_representative_refused(self):
        sink=RetainedOutputs(enabled=True);r=spec();o=output(self.bank,r);digest=hashlib.sha256(o.tobytes()).hexdigest()
        sink.success(r,o,digest)
        with self.assertRaises(ValueError):sink.success(r,o,digest)

    def test_wrong_representative_sha_refused(self):
        sink=RetainedOutputs(enabled=True)
        with self.assertRaises(ValueError):sink.success(spec(),output(self.bank,spec()),'0'*64)
        self.assertEqual(sink.payload_bytes,0)

    def test_wrong_shape_dtype_and_subclass_refused(self):
        class Sub(np.ndarray):pass
        for o in (np.zeros((256,256),dtype=np.int64),np.zeros((1,256),dtype=np.int32),
                  np.zeros((256,256),dtype=np.int32).view(Sub)):
            with self.subTest(shape=o.shape),self.assertRaises(ValueError):
                RetainedOutputs(enabled=True).success(spec(),o,'0'*64)

    def test_first_failure_not_overwritten(self):
        sink=RetainedOutputs(enabled=True)
        self.assertTrue(sink.failure(spec(),b'a'*262144,'row-major-int32-le'))
        self.assertFalse(sink.failure(spec(),b'b'*262144,'row-major-int32-le'))
        self.assertEqual(sink.first_failure['payload'],b'a'*262144)

    def test_bad_failure_size_type_encoding_refused(self):
        for payload,encoding in ((b'x','row-major-int32-le'),(bytearray(262144),'row-major-int32-le'),(bytes(262144),'unknown')):
            with self.subTest(encoding=encoding),self.assertRaises(ValueError):
                RetainedOutputs(enabled=True).failure(spec(),payload,encoding)

    def test_cpu_attachment_identity_enforced(self):
        error=ValueError('test');error.cpu_returned_payload=bytes(262144)
        error.cpu_output_identity=dict(block_index=2,local_index=0,input_id=42,dimension=256,encoding='row-major-int32-le')
        sink=RetainedOutputs(enabled=True)
        self.assertTrue(sink.failure_from_exception(spec(2,0),error))
        error.cpu_output_identity['local_index']=False
        with self.assertRaises(ValueError):RetainedOutputs(enabled=True).failure_from_exception(spec(2,0),error)

    def test_fpga_transport_encoding_not_row_major(self):
        error=ValueError('test');error.matrix_returned_payload=bytes(262144)
        sink=RetainedOutputs(enabled=True);sink.failure_from_exception(spec(),error)
        self.assertEqual(sink.first_failure['encoding'],'chain-tiled-int32-le')

    def test_no_traceback_scraping(self):
        sink=RetainedOutputs(enabled=True)
        self.assertFalse(sink.failure_from_exception(spec(),ValueError('no raw output interface')))

    def test_persist_fresh_and_exclusive(self):
        sink=RetainedOutputs(enabled=True);sink.failure(spec(),bytes(262144),'row-major-int32-le')
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()/'outputs';r=sink.persist(folder)
            self.assertEqual((folder/'first_failure.bin').stat().st_size,262144)
            self.assertEqual(json.loads((folder/'outputs.json').read_bytes()),r)
            self.assertFalse(r['lifecycle_proven_by_this_sink'])
            with self.assertRaises(RuntimeError):sink.persist(folder.parent/'retry')
            with self.assertRaises(RuntimeError):sink.failure(spec(),bytes(262144),'row-major-int32-le')

    def test_existing_directory_not_modified(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()
            with self.assertRaises(ValueError):RetainedOutputs(enabled=True).persist(folder)
            self.assertEqual(list(folder.iterdir()),[])

    def test_write_failure_poison_no_retry(self):
        sink=RetainedOutputs(enabled=True)
        with tempfile.TemporaryDirectory() as tmp,patch('round_artifacts.write_new',side_effect=OSError('disk')):
            folder=Path(tmp).resolve()
            with self.assertRaises(OSError):sink.persist(folder/'failed')
            with self.assertRaises(RuntimeError):sink.persist(folder/'retry')

    def test_request_bool_alias_and_wrong_geometry_refused(self):
        for bad in (replace(spec(0,0),local_index=False),replace(spec(),dimension=512)):
            with self.subTest(bad=bad),self.assertRaises(ValueError):checked_request(bad)


class StatsTests(unittest.TestCase):
    def test_full_plan_descriptive_stats_no_tail_claim(self):
        rows=[timing_row(spec(b,i),1,1001+i,2*(1000+i)) for b in range(12) for i in range(6)]
        got=descriptive_stats(rows)
        self.assertTrue(got['complete_72_rows']);self.assertEqual(len(got['groups']),6)
        self.assertEqual({g['formal_n'] for g in got['groups']},{8})
        self.assertFalse(got['tail_latency_accepted']);self.assertFalse(got['energy_evaluated'])
        self.assertEqual(got['groups'][0]['wall_ns']['mean'],1003.5)

    def test_warmup_excluded_from_formal_summary(self):
        got=descriptive_stats([timing_row(spec(0,0),1,1000001,1000000),timing_row(spec(),1,11,9)])
        self.assertEqual(got['groups'][0]['formal_n'],1)
        self.assertEqual(got['groups'][0]['wall_ns']['mean'],10)

    def test_cpu_can_exceed_wall_two_threads(self):
        self.assertEqual(timing_row(spec(2,0),1,11,20)['process_cpu_ns'],20)

    def test_invalid_timings_refused(self):
        for values in ((True,2,0),(0,2,0),(2,2,0),(1,2,True),(1,2,-1),(1,float('inf'),0)):
            with self.subTest(values=values),self.assertRaises(ValueError):timing_row(spec(),*values)

    def test_duplicate_or_unbounded_rows_refused(self):
        row=timing_row(spec(),1,2,0)
        for rows in ([row,row],[row]*73):
            with self.assertRaises(ValueError):descriptive_stats(rows)

    def test_timing_scope_and_bool_wall_tamper_refused(self):
        for changes in (dict(scope='pure_pl'),dict(wall_ns=True),dict(oracle_ipc_setup_cleanup_included=0)):
            row=timing_row(spec(),1,2,0);row.update(changes)
            with self.assertRaises(ValueError):descriptive_stats([row])


class CoordinatorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.bank=load_bank(ROOT,BANK_SHA)

    def core(self,stopped=lambda:False):return RoundCoordinator(self.bank,stopped,enabled=True)

    def block(self,p,before,accept):
        for i in range(6):
            r=p.request(i);before(r);o=output(self.bank,r)
            accept(r,result(i),hashlib.sha256(o.tobytes()).hexdigest(),o)
        return receipt(p)

    def test_default_off(self):
        with self.assertRaises(ValueError):RoundCoordinator(self.bank,lambda:False)

    def test_12_blocks_72_calls_exact_fixed_counts(self):
        core=self.core();events=[]
        def block(p,before,accept):events.append(p.block_index);return self.block(p,before,accept)
        got=core.run(block)
        self.assertEqual(events,list(range(12)));self.assertTrue(got['ledger']['plan_complete'])
        self.assertEqual((got['ledger']['formal_calls'],got['ledger']['warmup_calls']),(48,24))
        self.assertFalse(got['run_ready']);self.assertFalse(got['os_evidence_observed'])
        self.assertEqual(len(core.outputs.successes),12)

    def test_single_use_no_retry(self):
        core=self.core();core.run(self.block)
        with self.assertRaises(RuntimeError):core.run(self.block)

    def test_stop_before_any_block(self):
        core=self.core(lambda:True);calls=[]
        with self.assertRaises(BatchStop):core.run(lambda *a:calls.append(a))
        self.assertEqual(calls,[])

    def test_stop_inside_entered_request_accepts_one_no_next(self):
        stop=[False];core=self.core(lambda:stop[0]);entered=[]
        def block(p,before,accept):
            r=p.request(0);before(r);entered.append(0);stop[0]=True
            o=output(self.bank,r);accept(r,result(),hashlib.sha256(o.tobytes()).hexdigest(),o)
            before(p.request(1))
        with self.assertRaises(BatchStop):core.run(block)
        self.assertEqual(entered,[0]);self.assertEqual(len(core.rows),1)
        self.assertFalse(core.ledger.failed);self.assertTrue(core.ledger.stopped)

    def test_bad_terminal_receipt_no_next_block(self):
        core=self.core();entered=[]
        def block(p,before,accept):
            entered.append(p.block_index);self.block(p,before,accept);r=receipt(p);r['actual_exit_code']=False;return r
        with self.assertRaises(ValueError):core.run(block)
        self.assertEqual(entered,[0]);self.assertTrue(core.ledger.failed)

    def test_wrong_output_retained_before_fault_no_next(self):
        core=self.core()
        def block(p,before,accept):
            r=p.request(0);before(r);o=output(self.bank,r);o[0,0]^=1
            accept(r,result(),'0'*64,o)
        with self.assertRaises(ValueError):core.run(block)
        self.assertIsNotNone(core.outputs.first_failure);self.assertEqual(core.rows,[])

    def test_bad_digest_latches_even_if_callback_swallowed(self):
        core=self.core()
        def block(p,before,accept):
            r=p.request(0);before(r)
            with self.assertRaises(ValueError):accept(r,result(),'0'*64,output(self.bank,r))
            before(p.request(1))
        with self.assertRaises(RuntimeError):core.run(block)
        self.assertTrue(core.ledger.failed)

    def test_sequence_mismatch_fails_before_accept(self):
        core=self.core()
        with self.assertRaises(ValueError):core.run(lambda p,b,a:b(p.request(1)))
        self.assertTrue(core.ledger.failed)

    def test_exception_attachment_saved_only_for_pending(self):
        core=self.core()
        def block(p,before,accept):
            r=p.request(0);before(r);error=ValueError('transport')
            error.matrix_returned_payload=bytes(262144);raise error
        with self.assertRaises(ValueError):core.run(block)
        self.assertEqual(core.outputs.first_failure['encoding'],'chain-tiled-int32-le')


class ReaderCleanupTests(unittest.TestCase):
    def thread(self,alive=False):return SimpleNamespace(join=lambda timeout:None,is_alive=lambda:alive)

    def test_live_reader_never_closed_underneath(self):
        child=SimpleNamespace(stdout=io.BytesIO())
        with self.assertRaises(RuntimeError):settle_reader(child,self.thread(True),queue.Queue(),[])
        self.assertFalse(child.stdout.closed)

    def test_dead_reader_pipe_closed_even_on_protocol_error(self):
        child=SimpleNamespace(stdout=io.BytesIO())
        with self.assertRaises(RuntimeError):settle_reader(child,self.thread(),queue.Queue(),['bad'])
        self.assertTrue(child.stdout.closed)

    def test_missing_done_not_clean(self):
        child=SimpleNamespace(stdout=io.BytesIO())
        with self.assertRaises(ValueError):settle_reader(child,self.thread(),queue.Queue(),[],require_done=True)
        self.assertTrue(child.stdout.closed)


class ParentIncrementTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.bank=load_bank(ROOT,BANK_SHA)

    def run_case(self,mode,check):
        g=CpuGuardian(ComparisonPolicy(2,True),lambda:False,enabled=True);env=FakeCanonicalEnvironment()
        self.addCleanup(lambda:_RETAINED.remove(g) if g in _RETAINED else None)
        with tempfile.TemporaryDirectory() as tmp,env.install():
            folder=Path(tmp).resolve();obs=folder/'observation';g.start(env.factory)
            cmd=[sys.executable,'-I','-B',str(ROOT/'tests/pc_cpu_fixture.py'),'--block','2','--stop',str(obs/'stop.flag')]
            if mode=='wrong':cmd+=['--wrong-output']
            check(g,env,cmd,obs)

    def test_actual_bad_output_has_one_full_immutable_attachment(self):
        def check(g,env,cmd,obs):
            with self.assertRaises(ValueError) as got:
                run_cpu_block(cmd,obs,g,lambda:False,self.bank,lambda *a:self.fail('no accept'),
                    enabled=True,native_required=False,group_query=lambda pid:True)
            error=got.exception;self.assertEqual(type(error.cpu_returned_payload),bytes)
            self.assertEqual(len(error.cpu_returned_payload),262144)
            sink=RetainedOutputs(enabled=True);sink.failure_from_exception(spec(2,0),error)
            expected=output(self.bank,spec(2,0));expected[-1,-1]^=1
            self.assertEqual(sink.first_failure['payload'],expected.tobytes())
            self.assertTrue(json.loads((obs/'actual_exit.json').read_bytes())['actual_wait_observed']);g.close()
        self.run_case('wrong',check)

    def test_actual_known_exit_callback_fault_closes_pipe_keeps_quarantine(self):
        real=cpu_parent.observe_exit
        def callback_fault(child,g,stopped,cancel,**kw):
            observed=real(child,g,lambda:False,cancel,**kw)
            error=OSError('synthetic post-wait callback failure');error.comparison_exit_observation=observed
            g._hold(error);raise error
        def check(g,env,cmd,obs):
            with patch.object(cpu_parent,'observe_exit',side_effect=callback_fault),self.assertRaisesRegex(OSError,'post-wait'):
                run_cpu_block(cmd,obs,g,lambda:False,self.bank,lambda *a:None,
                    enabled=True,native_required=False,group_query=lambda pid:True)
            record=json.loads((obs/'actual_exit.json').read_bytes())
            self.assertTrue(record['actual_wait_observed']);self.assertTrue(record['reader_clean'])
            self.assertTrue(record['quarantined_reader_cleanup_attempted'])
            self.assertTrue(g._held);self.assertEqual(len(g._children),1)
            self.assertTrue(g._children[0].stdout.closed);self.assertEqual(env.close_calls,0)
            with self.assertRaises(RuntimeError):g.close()
        self.run_case('normal',check)

    def test_before_go_occurs_before_each_real_compute_accept(self):
        def check(g,env,cmd,obs):
            events=[]
            run_cpu_block(cmd,obs,g,lambda:False,self.bank,
                lambda r,*a:events.append(('accept',r.local_index)),enabled=True,native_required=False,
                group_query=lambda pid:True,before_go=lambda r:events.append(('go',r.local_index)))
            self.assertEqual(events,[(kind,i) for i in range(6) for kind in ('go','accept')]);g.close()
        self.run_case('normal',check)

    def test_before_go_fault_prevents_compute_still_waits(self):
        def check(g,env,cmd,obs):
            def before(r):raise ValueError('synthetic claim failure')
            with self.assertRaisesRegex(ValueError,'claim failure'):
                run_cpu_block(cmd,obs,g,lambda:False,self.bank,lambda *a:self.fail('no compute accepted'),
                    enabled=True,native_required=False,group_query=lambda pid:True,before_go=before)
            record=json.loads((obs/'actual_exit.json').read_bytes())
            self.assertEqual(record['checked_calls'],0);self.assertTrue(record['actual_wait_observed'])
            self.assertEqual(record['actual_exit_code'],73);g.close()
        self.run_case('normal',check)

    def test_unknown_group_does_not_attempt_quarantined_pipe_cleanup(self):
        def check(g,env,cmd,obs):
            with self.assertRaises(RuntimeError):
                run_cpu_block(cmd,obs,g,lambda:False,self.bank,lambda *a:None,
                    enabled=True,native_required=False,group_query=lambda pid:False)
            record=json.loads((obs/'actual_exit.json').read_bytes())
            self.assertTrue(record['actual_wait_observed']);self.assertFalse(record['process_group_absent'])
            self.assertNotIn('quarantined_reader_cleanup_attempted',record)
            self.assertTrue(g._held);self.assertEqual(len(g._children),1)
            # TEST teardown of our already-waited PC child only; never guardian release.
            g._children[0].stdout.close()
        self.run_case('normal',check)


class SupervisionTests(unittest.TestCase):
    def factory(self):
        return SimpleNamespace(supervision_status=dict(pid=os.getpid(),held=False,safety_unresolved=False,
            lease_retained=False,runner_retained=False,root_buffers_retained=0))

    def test_default_off_before_operation(self):
        with self.assertRaises(ValueError):bridge.supervised(None,None,None,None)

    def test_original_supervisor_installed_before_resource_operation(self):
        old={n:signal.getsignal(n) for n in (signal.SIGINT,signal.SIGTERM)}
        def operation(stopped):
            self.assertFalse(stopped())
            self.assertTrue(callable(signal.getsignal(signal.SIGINT)));return 17
        got=bridge.supervised(self.factory(),operation,lambda row:None,lambda:False,enabled=True)
        self.assertEqual(got['result'],17)
        self.assertEqual({n:signal.getsignal(n) for n in old},old)

    def test_signal_latches_both_sources_no_async_unwind(self):
        events=[]
        def operation(stopped):
            handler=signal.getsignal(signal.SIGTERM);handler(signal.SIGTERM,None)
            events.append('completed_current');self.assertTrue(stopped());return 1
        with self.assertRaises(RuntimeError):bridge.supervised(self.factory(),operation,lambda row:None,lambda:False,enabled=True)
        self.assertEqual(events,['completed_current'])

    def test_external_stop_before_resource_operation(self):
        with self.assertRaises(BatchStop):
            bridge.supervised(self.factory(),lambda s:self.fail('not started'),lambda row:None,lambda:True,enabled=True)

    def test_restore_attempts_all_preserves_primary_error(self):
        handlers={n:object() for n in (signal.SIGINT,signal.SIGTERM)};calls=[]
        def getsignal(n):return handlers.setdefault(n,object())
        def sethandler(n,h):
            calls.append(n)
            if n==signal.SIGINT:raise OSError('synthetic restore error')
        def fail_supervisor(factory,op,pub,enabled):raise ValueError('original operation')
        with patch.object(bridge,'_supervise',side_effect=fail_supervisor),patch.object(signal,'getsignal',side_effect=getsignal),patch.object(signal,'signal',side_effect=sethandler):
            with self.assertRaisesRegex(ValueError,'original operation') as got:
                bridge.supervised(self.factory(),lambda s:None,lambda r:None,lambda:False,enabled=True)
        self.assertIn(signal.SIGTERM,calls)
        self.assertEqual(len(got.exception.supervision_bridge_observation['handler_restore_errors']),1)

    def test_restore_failure_rejects_apparent_success(self):
        with patch.object(bridge,'_supervise',return_value=17),patch.object(signal,'signal',side_effect=OSError('restore')):
            with self.assertRaisesRegex(RuntimeError,'lifecycle'):
                bridge.supervised(self.factory(),lambda s:None,lambda r:None,lambda:False,enabled=True)

    def test_external_stop_after_cleanup_is_not_success(self):
        state=[False]
        def operation(stopped):state[0]=True;return 'cleaned'
        with self.assertRaises(BatchStop):
            bridge.supervised(self.factory(),operation,lambda r:None,lambda:state[0],enabled=True)

    def test_original_supervisor_refuses_preexisting_resources(self):
        factory=self.factory();factory.supervision_status['lease_retained']=True
        with self.assertRaisesRegex(RuntimeError,'BEFORE'):
            bridge.supervised(factory,lambda s:self.fail('not started'),lambda r:None,lambda:False,enabled=True)


class EntryTests(unittest.TestCase):
    def test_pc_round_cli_help_and_defaultoff_outside_package(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp).resolve();args=[sys.executable,'-I','-B',str(ROOT/'probe_round.py')]
            help_result=subprocess.run([*args,'--help'],cwd=path,capture_output=True,timeout=30)
            refused=subprocess.run([*args,'--manifest-sha','0'*64,'--plan-sha','0'*64,
                '--bank-sha',BANK_SHA,'--evidence-dir',str(path/'absent')],cwd=path,capture_output=True,timeout=30)
            self.assertEqual(help_result.returncode,0,help_result.stderr)
            self.assertEqual(refused.returncode,2);self.assertIn('default-off',json.loads(refused.stderr)['error'])
            self.assertFalse((path/'absent').exists())

    def test_new_module_collision_refused(self):
        import comparison_binding
        for name in ('round_coordinator','round_artifacts','supervision_bridge'):
            with self.subTest(name=name),patch.dict(sys.modules,{name:SimpleNamespace(__file__='/foreign/'+name+'.py')}):
                with self.assertRaisesRegex(ValueError,'collision'):comparison_binding.configure()


if __name__=='__main__':unittest.main(verbosity=2)
