"""Freshness/fail-closed tests and ACTUAL PC subprocesses; canonical lease is synthetic."""
import ast
import copy
import hashlib
import inspect
import io
import json
import os
import stat
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import numpy as np
import batch_call
from batch_policy import BatchStop
from comparison_policy import ComparisonPolicy
from comparison_call import ComparisonCall
from serial_plan import SerialPlan
from comparison_bank import load_bank
from cpu_guardian import CpuGuardian
import cpu_guardian
from cpu_frames import encode,line,exact_row,read_exact
from cpu_worker import loop
from cpu_parent import run_cpu_block,receipt_for_plan,reader
from process_observer import observe_exit
from cpu_native import native_compute
import comparison_binding
import cpu_worker_entry
import cpu_launch_config
from entry_fixture import FakeCanonicalEnvironment
from test_comparison import Harness,BANK_SHA

ROOT=Path(__file__).resolve().parent.parent


class HardeningTests(unittest.TestCase):
    def test_call_exact_callable_set_and_dunder_call_ast(self):
        self.assertEqual({n for n,v in ComparisonCall.__dict__.items() if callable(v)},
                         {'__init__','__call__','_call'})
        old=ast.parse(textwrap.dedent(inspect.getsource(batch_call.BatchCall.__call__)))
        new=ast.parse(textwrap.dedent(inspect.getsource(ComparisonCall.__call__)))
        self.assertEqual(ast.dump(old),ast.dump(new))

    def test_constructor_refuses_used_closed_or_unsafe_owner_before_dma(self):
        for changes in (dict(_index=1),dict(_index=False),dict(_closed=True),dict(_held=True),dict(_unsafe=True)):
            with self.subTest(changes=changes):
                h=Harness(ComparisonPolicy(0,True))
                try:
                    for k,v in changes.items():setattr(h.owner,k,v)
                    with self.assertRaisesRegex(ValueError,'fresh'):ComparisonCall(h.owner,h.policy,enabled=True)
                    self.assertFalse(any(e[0]=='transfer' for e in h.events))
                finally:h.discard()

    def test_all_serial_sequence_violations_latch_failure(self):
        cases=('bad_policy','wrong_block','double_begin','claim_without_block','double_claim','premature_finish','over_budget')
        for case in cases:
            with self.subTest(case=case):
                s=SerialPlan(enabled=True)
                with self.assertRaises(ValueError):
                    if case=='bad_policy':s.begin(None)
                    elif case=='wrong_block':s.begin(ComparisonPolicy(1,True))
                    elif case=='claim_without_block':s.claim()
                    else:
                        p=ComparisonPolicy(0,True);s.begin(p)
                        if case=='double_begin':s.begin(p)
                        elif case=='double_claim':s.claim();s.claim()
                        elif case=='premature_finish':s.finish({})
                        else:
                            for _ in range(6):r=s.claim();s.accept(r,exact=True)
                            s.claim()
                self.assertTrue(s.failed)
                with self.assertRaises(RuntimeError):s.claim()

    def test_cooperative_stop_does_not_latch_fault(self):
        s=SerialPlan(enabled=True);s.begin(ComparisonPolicy(0,True));r=s.claim();s.stop();s.accept(r,exact=True)
        with self.assertRaises(BatchStop):s.claim()
        self.assertFalse(s.failed)


class FrameTests(unittest.TestCase):
    def test_json_duplicate_nonfinite_or_nonobject_rejected(self):
        for raw in (b'{"x":1,"x":2}\n',b'{"x":NaN}\n',b'[]\n'):
            with self.subTest(raw=raw),self.assertRaises(ValueError):line(io.BytesIO(raw))

    def test_bool_cannot_impersonate_integer_frame(self):
        with self.assertRaises(ValueError):exact_row(dict(index=False),dict(index=0))

    def test_line_budget_and_missing_newline(self):
        for raw in (b'x'*8193,b'{}'):
            with self.subTest(size=len(raw)),self.assertRaises(ValueError):line(io.BytesIO(raw))

    def test_truncated_or_unbounded_payload_rejected(self):
        with self.assertRaises(ValueError):read_exact(io.BytesIO(b'x'),2)
        for size in (True,0,1048577):
            with self.subTest(size=size),self.assertRaises(ValueError):read_exact(io.BytesIO(),size)

    def test_reader_rejects_oversized_before_reading_payload(self):
        import queue
        q=queue.Queue(2);errors=[]
        reader(io.BytesIO(encode(dict(kind='result',payload_bytes=1048577))),q,errors,262144)
        self.assertEqual(errors,['ValueError']);self.assertTrue(q.empty())


class NativeConfigTests(unittest.TestCase):
    def test_private_worker_isolated_help_and_defaultoff(self):
        with tempfile.TemporaryDirectory() as temporary:
            base=[sys.executable,'-I','-B',str(ROOT/'cpu_worker_entry.py')]
            help_result=subprocess.run([*base,'--help'],cwd=temporary,capture_output=True,timeout=30)
            refused=subprocess.run([*base,'--config','absent','--config-sha','0'*64],
                                   cwd=temporary,capture_output=True,timeout=30)
        self.assertEqual(help_result.returncode,0,help_result.stderr)
        self.assertEqual(refused.returncode,2,refused.stderr)
        self.assertIn('default-off',json.loads(refused.stderr)['error'])

    def test_fixed_private_cpu_argv_config_preparation_only(self):
        g=CpuGuardian(ComparisonPolicy(2,True),lambda:False,enabled=True);env=FakeCanonicalEnvironment()
        with tempfile.TemporaryDirectory() as temporary,env.install():
            folder=Path(temporary).resolve();g.start(env.factory)
            with patch.object(comparison_binding,'check') as check:
                result=cpu_launch_config.prepare(folder,g,'0'*64,'1'*64,BANK_SHA,enabled=True)
                check.assert_called_once_with('0'*64,'1'*64,BANK_SHA,enabled=True)
            config,stop=cpu_worker_entry.read_config(result['config_path'],result['config_sha256'])
            self.assertEqual(config['block_index'],2);self.assertEqual(config['ticket']['pid'],os.getpid())
            self.assertEqual(stop,result['observation_directory']/'stop.flag')
            self.assertFalse(result['process_launched']);self.assertFalse(result['observation_directory'].exists())
            self.assertEqual(result['command'][:3],[sys.executable,'-I','-B'])
            self.assertEqual(Path(result['command'][3]),ROOT/'cpu_worker_entry.py')
            g.close()

    def test_cpu_command_preparation_default_off_no_files(self):
        with patch.object(comparison_binding,'check') as check:
            with self.assertRaisesRegex(ValueError,'default-off'):
                cpu_launch_config.prepare('absent',None,'0'*64,'0'*64,BANK_SHA)
            check.assert_not_called()

    def test_pinned_cpu_original_catalog_and_bool_size_refused(self):
        self.assertTrue(comparison_binding.verify_cpu_sources())
        original=json.loads((ROOT/'cpu_sources.json').read_bytes())
        bad=copy.deepcopy(original);bad['files'][0]['bytes']=True
        for value in ([],bad):
            with self.subTest(value=type(value)),patch.object(comparison_binding.verifier,'read_json',return_value=value):
                with self.assertRaises(ValueError):comparison_binding.verify_cpu_sources()

    def test_private_worker_default_off_before_any_verification(self):
        with patch.object(comparison_binding,'check') as check:
            with self.assertRaisesRegex(ValueError,'default-off'):cpu_worker_entry.run_private('absent','0'*64)
            check.assert_not_called()

    def test_external_config_hash_shape_and_existing_stop_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary).resolve();path=folder/'config.json'
            stop=folder/'observation/stop.flag'
            value=dict(manifest_sha='0'*64,plan_sha='0'*64,bank_sha=BANK_SHA,block_index=2,ticket={},stop_flag=str(stop))
            raw=encode(value)
            with path.open('xb') as stream:stream.write(raw)
            expected=hashlib.sha256(raw).hexdigest()
            got,got_stop=cpu_worker_entry.read_config(path,expected)
            self.assertEqual(got,value);self.assertEqual(got_stop,stop)
            with self.assertRaises(ValueError):cpu_worker_entry.read_config(path,'0'*64)
            stop.parent.mkdir()
            with stop.open('xb') as stream:stream.write(b'STOP')
            with self.assertRaises(ValueError):cpu_worker_entry.read_config(path,expected)

    def test_special_config_rejected_before_open(self):
        with patch.object(comparison_binding.verifier,'no_alias'),patch.object(Path,'lstat',
            return_value=SimpleNamespace(st_mode=stat.S_IFIFO,st_size=0)),patch.object(Path,'open') as opened:
            with self.assertRaisesRegex(ValueError,'regular'):cpu_worker_entry.read_config('/not_opened.pipe','0'*64)
            opened.assert_not_called()


class WorkerLoopTests(unittest.TestCase):
    def setUp(self):
        self.p=ComparisonPolicy(2,True);self.bank=load_bank(ROOT,BANK_SHA)
        self.inputs={i:self.bank[256,i].arrays() for i in (42,43)}

    def source(self):
        return io.BytesIO(b''.join(encode(dict(kind=k,index=i)) for i in range(6) for k in ('go','ack')))

    def test_six_real_pc_computes_and_double_guard_before_each(self):
        guarded=[];calls=[];sink=io.BytesIO()
        def compute(a,b):calls.append(1);return (a.astype(np.int64)@b.astype(np.int64)).astype(np.int32)
        self.assertEqual(loop(self.p,self.inputs,compute,lambda:(guarded.append(1) or True),lambda:False,
            self.source(),sink,compute_kind='pc_int64_fixture',library_sha=None),0)
        self.assertEqual(len(calls),6);self.assertEqual(len(guarded),14)
        data=io.BytesIO(sink.getvalue());self.assertEqual(line(data)['kind'],'hello')
        for i in range(6):
            self.assertEqual(line(data)['kind'],'ready');r=line(data)
            self.assertLess(r['begin_ns'],r['end_ns']);self.assertGreaterEqual(r['process_cpu_ns'],0)
            self.assertEqual(read_exact(data,r['payload_bytes']),self.bank[256,42+i%2].expected)
        self.assertEqual(line(data)['kind'],'done');self.assertIsNone(line(data))

    def test_guardian_failure_or_stop_never_computes(self):
        for stopped,guard in ((lambda:True,lambda:True),(lambda:False,lambda:False)):
            with self.subTest(stopped=stopped):
                calls=[]
                with self.assertRaises((BatchStop,RuntimeError)):
                    loop(self.p,self.inputs,lambda a,b:calls.append(1),guard,stopped,
                        self.source(),io.BytesIO(),compute_kind='pc_int64_fixture',library_sha=None)
                self.assertEqual(calls,[])

    def test_bad_go_bool_or_wrong_index_rejected_before_compute(self):
        for row in (dict(kind='go',index=False),dict(kind='go',index=1),dict(kind='ack',index=0)):
            calls=[]
            with self.subTest(row=row),self.assertRaises(ValueError):
                loop(self.p,self.inputs,lambda a,b:calls.append(1),lambda:True,lambda:False,
                    io.BytesIO(encode(row)),io.BytesIO(),compute_kind='pc_int64_fixture',library_sha=None)
            self.assertEqual(calls,[])

    def test_stop_arriving_inside_compute_completes_current_no_next(self):
        state={'stop':False};calls=[];sink=io.BytesIO()
        def compute(a,b):
            calls.append(1);state['stop']=True
            return (a.astype(np.int64)@b.astype(np.int64)).astype(np.int32)
        with self.assertRaises(BatchStop):
            loop(self.p,self.inputs,compute,lambda:True,lambda:state['stop'],self.source(),sink,
                 compute_kind='pc_int64_fixture',library_sha=None)
        self.assertEqual(calls,[1])
        data=io.BytesIO(sink.getvalue());line(data);line(data);row=line(data)
        self.assertEqual(row['kind'],'result');self.assertEqual(read_exact(data,row['payload_bytes']),self.bank[256,42].expected)

    def test_native_default_off_and_pc_no_fallback(self):
        with self.assertRaises(ValueError):native_compute(ROOT)
        # Explicit patched PC identity guarantees this never loads native code even on future ARM tests.
        with patch('cpu_native.platform.system',return_value='Windows'):
            with self.assertRaises(RuntimeError):native_compute(ROOT,enabled=True)


class GuardianTests(unittest.TestCase):
    def guardian(self,stopped=lambda:False):
        g=CpuGuardian(ComparisonPolicy(2,True),stopped,enabled=True)
        self.addCleanup(lambda:cpu_guardian._RETAINED.remove(g) if g in cpu_guardian._RETAINED else None)
        return g

    def test_cpu_only_default_off_and_wrong_backend(self):
        with self.assertRaises(ValueError):CpuGuardian(ComparisonPolicy(2,True),lambda:False)
        with self.assertRaises(ValueError):CpuGuardian(ComparisonPolicy(0,True),lambda:False,enabled=True)

    def test_actual_helper_normal_closes_once_no_pl(self):
        g=self.guardian();env=FakeCanonicalEnvironment()
        with env.install():
            g.start(env.factory);proof=g.pre_submit();self.assertTrue(proof['exclusive_flock'])
            g.close();g.close();self.assertEqual(env.close_calls,1);self.assertFalse(env.fd_live)
            self.assertFalse(g.supervision_status['runner_retained'])

    def test_pre_factory_failure_safe_close_without_factory(self):
        g=self.guardian();env=FakeCanonicalEnvironment(precheck=True)
        with env.install():
            with self.assertRaises(FileNotFoundError):g.start(env.factory)
            self.assertEqual(env.factory_calls,0);g.close();self.assertFalse(g._held)

    def test_uncertain_factory_and_close_double_failure_quarantine(self):
        for options in (dict(busy=True),dict(drift=True,close_error=True)):
            with self.subTest(options=options):
                g=self.guardian();env=FakeCanonicalEnvironment(**options)
                with env.install():
                    with self.assertRaises((BlockingIOError,ValueError)):g.start(env.factory)
                    self.assertTrue(g._held and g._unsafe)
                    with self.assertRaisesRegex(RuntimeError,'quarantined'):g.close()

    def test_active_child_prevents_release(self):
        g=self.guardian();env=FakeCanonicalEnvironment()
        with env.install():
            g.start(env.factory);g.retain_child(object())
            with self.assertRaises(RuntimeError):g.close()
            self.assertTrue(g._held);self.assertEqual(env.close_calls,0)

    def test_opaque_factory_batchstop_is_not_proven_safe_acquisition(self):
        g=self.guardian();env=FakeCanonicalEnvironment()
        def factory():raise BatchStop('synthetic opaque acquisition stop')
        with env.install():
            with self.assertRaises(BatchStop):g.start(factory)
            self.assertTrue(g._held and g._unsafe);self.assertIsNotNone(g._lease)
            with self.assertRaisesRegex(RuntimeError,'quarantined'):g.close()

    def test_stop_after_successful_acquisition_can_close(self):
        calls=[]
        def stopped():calls.append(1);return len(calls)>1
        g=self.guardian(stopped);env=FakeCanonicalEnvironment()
        with env.install():
            with self.assertRaises(BatchStop):g.start(env.factory)
            self.assertFalse(g._held);g.close();self.assertEqual(env.close_calls,1)


class ObserverTests(unittest.TestCase):
    def test_stop_notification_error_still_waits_and_records_known_exit(self):
        events=[];holds=[]
        g=SimpleNamespace(_hold=lambda error:holds.append(type(error).__name__))
        def wait(timeout):events.append('wait');return 0
        def request_stop():events.append('stop');raise OSError('synthetic stop write failure')
        with self.assertRaisesRegex(OSError,'stop write') as raised:
            observe_exit(SimpleNamespace(pid=9999,wait=wait),g,lambda:True,request_stop,
                         group_query=lambda pid:True)
        self.assertEqual(events,['stop','wait']);self.assertEqual(holds,['OSError'])
        self.assertTrue(raised.exception.comparison_exit_observation['actual_wait_observed'])
        self.assertEqual(raised.exception.comparison_exit_observation['actual_exit_code'],0)

    def test_stop_source_error_still_waits_before_quarantine(self):
        events=[];g=SimpleNamespace(_hold=lambda error:events.append('held'))
        def stopped():raise RuntimeError('synthetic stop source failure')
        def wait(timeout):events.append('wait');return 0
        with self.assertRaisesRegex(RuntimeError,'stop source') as raised:
            observe_exit(SimpleNamespace(pid=9999,wait=wait),g,stopped,lambda:events.append('stop'),
                         group_query=lambda pid:True)
        self.assertEqual(events,['stop','wait','held'])
        self.assertTrue(raised.exception.comparison_exit_observation['actual_wait_observed'])

    def test_timeouts_are_observation_not_kill(self):
        g=SimpleNamespace(_hold=lambda error:None);events=[]
        class Child:
            pid=9999
            def wait(self,timeout):
                events.append('wait')
                if len(events)==1:raise subprocess.TimeoutExpired('fixture',timeout)
                return 0
        r=observe_exit(Child(),g,lambda:False,lambda:None,group_query=lambda pid:True)
        self.assertTrue(r['actual_wait_observed']);self.assertTrue(r['group_query_injected'])
        self.assertFalse(r['automatic_kill']);self.assertEqual(r['wait_intervals'],1)

    def test_group_unknown_permission_or_nonbool_exit_holds(self):
        for code,query in ((False,lambda pid:True),(0,lambda pid:False),
                           (0,lambda pid:(_ for _ in ()).throw(PermissionError('fixture')))):
            holds=[];g=SimpleNamespace(_hold=lambda error:holds.append(type(error).__name__))
            child=SimpleNamespace(pid=9999,wait=lambda timeout:code)
            with self.subTest(code=code),self.assertRaises((ValueError,RuntimeError,PermissionError)):
                observe_exit(child,g,lambda:False,lambda:None,group_query=query)
            self.assertEqual(len(holds),1)


class RealPcProcessTests(unittest.TestCase):
    """Actual Popen/pipe/wait on this PC. OS group evidence explicitly injected."""
    def guardian(self,stopped):
        g=CpuGuardian(ComparisonPolicy(2,True),stopped,enabled=True)
        self.addCleanup(lambda:cpu_guardian._RETAINED.remove(g) if g in cpu_guardian._RETAINED else None)
        return g

    def command(self,folder,*extra):
        return [sys.executable,'-I','-B',str(ROOT/'tests/pc_cpu_fixture.py'),'--block','2',
                '--stop',str(Path(folder)/'observation/stop.flag'),*extra]

    def test_actual_child_wait_six_computes_and_cleanup(self):
        g=self.guardian(lambda:False);env=FakeCanonicalEnvironment();accepted=[]
        with tempfile.TemporaryDirectory() as folder,env.install():
            folder=str(Path(folder).resolve())  # Windows temp may arrive as an 8.3 alias.
            g.start(env.factory)
            result=run_cpu_block(self.command(folder),Path(folder)/'observation',g,lambda:False,
                load_bank(ROOT,BANK_SHA),lambda spec,row,digest,out:accepted.append((spec.local_index,digest)),
                enabled=True,native_required=False,group_query=lambda pid:True)
            self.assertEqual(result['actual_exit_code'],0);self.assertTrue(result['actual_wait_observed'])
            self.assertEqual(len(accepted),6);self.assertTrue(result['reader_clean'])
            self.assertFalse(result['native_compute']);self.assertTrue(result['group_query_injected'])
            self.assertEqual(g._children,[]);g.close();self.assertEqual(env.close_calls,1)
            receipt=json.loads((Path(folder)/'observation/actual_exit.json').read_bytes())
            self.assertEqual(receipt,result)
            with self.assertRaises(ValueError):receipt_for_plan(g.policy,result,g)

    def test_actual_child_nonzero_and_bad_golden_do_not_accept(self):
        for option in ('--fail-compute','--wrong-output'):
            with self.subTest(option=option):
                g=self.guardian(lambda:False);env=FakeCanonicalEnvironment();accepted=[]
                with tempfile.TemporaryDirectory() as folder,env.install():
                    folder=str(Path(folder).resolve())
                    g.start(env.factory)
                    with self.assertRaises((RuntimeError,ValueError)):
                        run_cpu_block(self.command(folder,option),Path(folder)/'observation',g,lambda:False,
                            load_bank(ROOT,BANK_SHA),lambda *args:accepted.append(1),enabled=True,
                            native_required=False,group_query=lambda pid:True)
                    record=json.loads((Path(folder)/'observation/actual_exit.json').read_bytes())
                    self.assertTrue(record['actual_wait_observed']);self.assertEqual(record['actual_exit_code'],73)
                    self.assertEqual(accepted,[])
                    if not g._held:g.close()

    def test_actual_stop_after_first_result_no_next_compute(self):
        state={'stop':False};g=self.guardian(lambda:state['stop']);env=FakeCanonicalEnvironment()
        with tempfile.TemporaryDirectory() as folder,env.install():
            folder=str(Path(folder).resolve())
            g.start(env.factory)
            def accept(*args):state['stop']=True
            with self.assertRaises(BatchStop):
                run_cpu_block(self.command(folder),Path(folder)/'observation',g,lambda:state['stop'],
                    load_bank(ROOT,BANK_SHA),accept,enabled=True,native_required=False,group_query=lambda pid:True)
            record=json.loads((Path(folder)/'observation/actual_exit.json').read_bytes())
            self.assertEqual(record['checked_calls'],1);self.assertTrue(record['actual_wait_observed'])
            self.assertTrue(record['stop_requested']);g.close()

    def test_native_required_rejects_pc_fixture_before_compute(self):
        g=self.guardian(lambda:False);env=FakeCanonicalEnvironment()
        with tempfile.TemporaryDirectory() as folder,env.install():
            folder=str(Path(folder).resolve());g.start(env.factory)
            with self.assertRaises(ValueError):
                run_cpu_block(self.command(folder),Path(folder)/'observation',g,lambda:False,
                    load_bank(ROOT,BANK_SHA),lambda *args:self.fail('no fake compute accepted'),
                    enabled=True,native_required=True,group_query=lambda pid:True)
            record=json.loads((Path(folder)/'observation/actual_exit.json').read_bytes())
            self.assertEqual(record['checked_calls'],0);self.assertFalse(record['native_compute'])
            self.assertTrue(record['actual_wait_observed']);g.close()

    def test_receipt_write_failure_still_obtains_actual_wait(self):
        import cpu_parent
        original=cpu_parent.write_new
        def fail_started(path,value):
            if Path(path).name=='child_started.json':raise OSError('synthetic evidence write failure')
            return original(path,value)
        g=self.guardian(lambda:False);env=FakeCanonicalEnvironment()
        with tempfile.TemporaryDirectory() as folder,env.install():
            folder=str(Path(folder).resolve());g.start(env.factory)
            with patch.object(cpu_parent,'write_new',side_effect=fail_started):
                with self.assertRaisesRegex(OSError,'evidence write'):
                    run_cpu_block(self.command(folder),Path(folder)/'observation',g,lambda:False,
                        load_bank(ROOT,BANK_SHA),lambda *args:None,enabled=True,native_required=False,
                        group_query=lambda pid:True)
            record=json.loads((Path(folder)/'observation/actual_exit.json').read_bytes())
            self.assertTrue(record['actual_wait_observed']);self.assertEqual(record['actual_exit_code'],73)
            self.assertEqual(g._children,[]);g.close()


if __name__=='__main__':unittest.main(verbosity=2)
