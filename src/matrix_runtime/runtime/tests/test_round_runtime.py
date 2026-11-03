"""Offline error/quarantine-boundary tests. No retained infinite loop or board."""
from dataclasses import asdict
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import numpy as np
import outer_binding as binding
import failure_journal as journal
import fpga_worker
import fpga_parent
import round_runtime as runtime
import round_launcher as launcher
from comparison_policy import ComparisonPolicy
from comparison_bank import load_bank
from round_coordinator import RoundCoordinator
from cpu_frames import encode
from test_runtime import request

ROOT=Path(__file__).resolve().parent.parent
BANK='af893b4381e8c72a667b772b3d40aa7b2db03739232e9f60b21bbb1ef1c939a8'

class JournalTests(unittest.TestCase):
    def capture(self,root,payload=True):
        spec=ComparisonPolicy(0,True).request(0);error=ValueError('private exception text not exported')
        if payload:error.matrix_returned_payload=bytes(256**2*4)
        sink=journal.FailureJournal(root/'journal');sink.capture(spec,error)
        return sink,spec
    def test_ready_last_full_chain_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            sink,spec=self.capture(Path(tmp).resolve());actual,meta,raw=journal.read_ready(sink.folder,ComparisonPolicy(0,True),os.getpid())
            self.assertEqual(actual,spec);self.assertEqual(raw,bytes(262144))
            self.assertIs(meta['cleanup_observed'],False);self.assertNotIn('private',json.dumps(meta))
    def test_absent_payload_not_invented(self):
        with tempfile.TemporaryDirectory() as tmp:
            sink,_=self.capture(Path(tmp).resolve(),False)
            self.assertIsNone(journal.read_ready(sink.folder,ComparisonPolicy(0,True),os.getpid())[2])
    def test_no_ready_is_incomplete_not_success(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertIsNone(journal.read_ready(Path(tmp).resolve()/'missing',ComparisonPolicy(0,True),os.getpid()))
    def test_wrong_pid_or_policy_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            sink,_=self.capture(Path(tmp).resolve())
            for policy,pid in ((ComparisonPolicy(1,True),os.getpid()),(ComparisonPolicy(0,True),os.getpid()+1)):
                with self.assertRaises(ValueError):journal.read_ready(sink.folder,policy,pid)
    def test_tampered_full_output_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            sink,_=self.capture(Path(tmp).resolve());(sink.folder/'first_fault.bin').write_bytes(b'x'*262144)
            with self.assertRaises(ValueError):journal.read_ready(sink.folder,ComparisonPolicy(0,True),os.getpid())
    def test_capture_single_use_and_wrong_extent(self):
        with tempfile.TemporaryDirectory() as tmp:
            sink,spec=self.capture(Path(tmp).resolve())
            with self.assertRaises(RuntimeError):sink.capture(spec,ValueError())
            sink2=journal.FailureJournal(Path(tmp).resolve()/'other');error=ValueError();error.matrix_returned_payload=b'x'
            with self.assertRaises(ValueError):sink2.capture(spec,error)
            self.assertFalse((sink2.folder/'ready.json').exists())
    def test_bool_request_type_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            sink,_=self.capture(Path(tmp).resolve());path=sink.folder/'first_fault.json'
            meta=json.loads(path.read_bytes());meta['request']['block_index']=False
            raw=encode(meta);path.write_bytes(raw)
            (sink.folder/'ready.json').write_bytes(encode(dict(metadata_sha256=journal.sha(raw))))
            with self.assertRaises(ValueError):journal.read_ready(sink.folder,ComparisonPolicy(0,True),os.getpid())
    def test_internal_alias_refused_when_available(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();(root/'target').mkdir()
            try:(root/'alias').symlink_to(root/'target',target_is_directory=True)
            except OSError:
                # Mock metadata branch on Windows without administrator symlink rights.
                with patch.object(Path,'resolve',return_value=root/'target'),self.assertRaises(ValueError):
                    journal.canonical(root/'alias')
            else:
                with self.assertRaises(ValueError):journal.canonical(root/'alias')

class WorkerFaultOrder(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.bank=load_bank(ROOT,BANK)
    def exercise(self,held=False,io_fail=False,close_fail=False):
        policy=ComparisonPolicy(0,True);events=[]
        class Owner:
            def __init__(self):self.policy=policy;self._held=held;self._unsafe=held;self._closed=False
            def pre_submit(self):return {'ticket':'fixture'}
            def close(self):
                events.append('close')
                if close_fail:raise OSError('close failed')
                self._closed=True;self.cleanup_readback={}
        class Call:
            def __init__(self,*a,**kw):pass
            def __call__(self,a,b):
                error=ValueError('call failed');error.matrix_returned_payload=bytes(262144);raise error
        class Sink:
            def capture(self,spec,error):
                events.append('journal')
                self.assertion=error.matrix_returned_payload==bytes(262144)
                if io_fail:raise OSError('disk full')
        owner=Owner();sink=Sink()
        def supervisor(current,operation,publish,external,**kwargs):
            try:operation(lambda:False)
            except BaseException:
                events.append('supervisor-retains' if held else 'supervisor-exits');raise
        with patch.object(fpga_worker,'supervised',side_effect=supervisor):
            with self.assertRaisesRegex(ValueError,'call failed') as caught:
                fpga_worker.serve(policy,self.bank,owner,lambda o:None,
                    io.BytesIO(encode(dict(kind='go',index=0))),io.BytesIO(),lambda:False,
                    lambda row:None,enabled=True,call_type=Call,compute_kind='pc_fpga_fixture',failure_journal=sink)
        return events,caught.exception
    def test_capture_before_safe_cleanup(self):self.assertEqual(self.exercise()[0],['journal','close','supervisor-exits'])
    def test_capture_before_retained_supervisor_no_close(self):
        self.assertEqual(self.exercise(held=True)[0],['journal','supervisor-retains'])
    def test_journal_error_never_replaces_call_error(self):
        self.assertEqual(self.exercise(io_fail=True)[1].failure_journal_error_type,'OSError')
    def test_cleanup_error_never_replaces_call_error(self):
        self.assertEqual(self.exercise(close_fail=True)[1].owner_close_error_type,'OSError')

class ParentFaultJournalTests(unittest.TestCase):
    def test_actual_pc_call_fault_retained_before_wait_and_never_success(self):
        policy=ComparisonPolicy(0,True);guardian=fpga_parent.ProcessGuardian(policy,enabled=True)
        events=[];original=fpga_parent.observe_exit
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()/'observation'
            command=[sys.executable,'-I','-B',str(ROOT/'tests/pc_fpga_fixture.py'),
                '--enabled-pc-fixture','--block','0','--stop',str(folder/'stop.flag'),'--call-error']
            def fault(spec,metadata,payload):
                events.append('fault');self.assertEqual(len(payload),262144)
                self.assertFalse(metadata['cleanup_observed'])
            def wait(*args,**kwargs):
                # The journal may race with ABORTED; monitor_stop polls it inside
                # real wait as well. No kill or time-limited success in either path.
                result=original(*args,**kwargs);events.append('wait-return');return result
            with patch.object(fpga_parent,'observe_exit',side_effect=wait):
                with self.assertRaises(journal.JournalFault) as caught:
                    fpga_parent.run_fpga_block(command,folder,guardian,lambda:False,lambda spec:None,
                        lambda *a:None,enabled=True,fixture=True,group_query=lambda pid:True,
                        lock_snapshot=lambda:dict(device=2048,inode=11,path='/tmp/opennpu-kws-chain.lock'),
                        live_query=lambda *args:True,release_query=lambda i:dict(i,lock_released_same_inode=True),on_failure=fault)
            record=json.loads((folder/'actual_exit.json').read_bytes())
            self.assertEqual(events,['fault','wait-return'])
            self.assertEqual(len(caught.exception.matrix_returned_payload),262144)
            self.assertTrue(record['actual_wait_observed']);self.assertEqual(record['actual_exit_code'],73)
            self.assertTrue(record['cleanup_verified'],record);self.assertFalse(guardian._held)
            self.assertEqual(guardian._children,[])

def observations():
    values=[]
    for b in range(12):
        policy=ComparisonPolicy(b,True)
        row=dict(block_index=b,child_pid=1000+b,actual_exit_code=0,actual_wait_observed=True,
            process_group_absent=True,checked_calls=6,reader_clean=True,cleanup_verified=True,
            lock_released_same_inode=True,stop_requested=False,error_type=None,group_query_injected=False,
            release_readback=dict(device=2048,inode=11,path='/tmp/opennpu-kws-chain.lock',lock_released_same_inode=True))
        if policy.backend=='openblas_2t':row.update(native_compute=True,popen_factory_injected=False)
        else:row.update(fixture=False,evidence_injected=False)
        values.append(row)
    return values

class WholeRoundTests(unittest.TestCase):
    def test_predeclared_outer_inode_rechecked_before_any_round(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp).resolve();folder=root/'round';folder.mkdir();path=root/'launch_request.json'
            identity=dict(device=2048,inode=11,path='/tmp/opennpu-kws-chain.lock')
            value=dict(config_sha256='0'*64,request=request(),expected_lock=identity)
            path.write_bytes(encode(value));digest=journal.sha(path.read_bytes())
            self.assertTrue(launcher.read_launch_binding(path,digest,folder,request(),'0'*64,identity))
            with self.assertRaises(RuntimeError):launcher.read_launch_binding(path,digest,folder,request(),'0'*64,dict(identity,inode=12))
            with self.assertRaises(ValueError):launcher.read_launch_binding(path,'1'*64,folder,request(),'0'*64,identity)
    def test_missing_os_error_field_is_rejected_not_false_success(self):
        rows=observations();rows[0].pop('error_type')
        with self.assertRaises(ValueError):runtime.os_summary(rows)
    def test_os_summary_strict_blocks_and_same_inode(self):
        self.assertEqual(runtime.os_summary(observations())['actual_successful_calls'],72)
        rows=observations();rows[-1]['release_readback']['inode']=12
        with self.assertRaises(ValueError):runtime.os_summary(rows)
    def test_fixture_injection_and_bool_count_refused(self):
        for change in (dict(fixture=True),dict(actual_exit_code=False),dict(checked_calls=True),dict(process_group_absent=None)):
            rows=observations();rows[0].update(change)
            with self.subTest(change=change),self.assertRaises(ValueError):runtime.os_summary(rows)
    def test_incomplete_blocks_and_reused_pid_refused(self):
        with self.assertRaises(ValueError):runtime.os_summary(observations()[:11])
        rows=observations();rows[1]['child_pid']=rows[0]['child_pid']
        with self.assertRaises(ValueError):runtime.os_summary(rows)
    def test_signal_context_restores_after_exception(self):
        original=signal.getsignal(signal.SIGINT);context=runtime.StopContext(lambda:False)
        with self.assertRaises(ValueError):
            with context:context.handler(signal.SIGINT,None);raise ValueError()
        self.assertEqual(signal.getsignal(signal.SIGINT),original);self.assertTrue(context.stopped())
    def test_restore_error_attempts_all_not_swallow_primary(self):
        context=runtime.StopContext(lambda:False);context.previous={1:None,2:None}
        with patch.object(signal,'signal',side_effect=[OSError(),None]) as call:context.restore()
        self.assertEqual(call.call_count,2);self.assertEqual(len(context.restore_errors),1)
    def test_default_off_before_files(self):
        with self.assertRaises(ValueError):runtime.run_round('absent',{},None)
        with self.assertRaises(ValueError):launcher.launch('absent','0'*64,'absent')
    def test_actual_guardian_cannot_forget_unknown(self):
        guardian=launcher.RoundGuardian();child=object();guardian.retain(child);guardian._hold(ValueError())
        with self.assertRaises(RuntimeError):guardian.forget(child)
        self.assertTrue(guardian.supervision_status['runner_retained'])
    def test_launch_config_exact_sha_confirmations(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp).resolve()/'request.json'
            value=dict(schema='threeway-round-launch-config-v1',request=request(),utc_verified=True,
                board_idle_verified=True,single_supply_verified=True,separate_scope_approved=True)
            path.write_bytes(encode(value));digest=journal.sha(path.read_bytes())
            self.assertEqual(launcher.read_request(path,digest),value['request'])
            with self.assertRaises(ValueError):launcher.read_request(path,'0'*64)
            value['board_idle_verified']=1;path.write_bytes(encode(value))
            with self.assertRaises(ValueError):launcher.read_request(path,journal.sha(path.read_bytes()))
    def test_artifact_tamper_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve();(folder/'x').write_bytes(b'original')
            (folder/'evidence_manifest.json').write_bytes(encode(dict(schema='threeway-round-evidence-v1',files=runtime.file_inventory(folder))))
            self.assertEqual(launcher.verify_artifacts(folder)['files'],1)
            (folder/'x').write_bytes(b'changed')
            with self.assertRaises(ValueError):launcher.verify_artifacts(folder)
    def test_entry_default_off_and_enabled_pc_refused_no_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            target=Path(tmp)/'never_created'
            argv=[sys.executable,'-I','-B',str(ROOT/'launch_round_candidate.py'),
                '--config','absent','--config-sha','0'*64,'--evidence-dir',str(target)]
            for extra in ([],['--enable-unapproved-candidate']):
                child=subprocess.run(argv+extra,capture_output=True)
                self.assertEqual(child.returncode,2,child.stderr)
            self.assertFalse(target.exists())
    def test_round_numeric_fault_partial_and_final_both_persist_no_cleanup_claim(self):
        anchors=tuple(hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in ('review_manifest.json','plan.json','bank_manifest.json'))
        value=request();value.update(zip(('manifest_sha','plan_sha','bank_sha'),anchors))
        class BadBlock:
            def __call__(self,policy,before,accept):
                spec=policy.request(0);before(spec)
                output=np.zeros((256,256),dtype=np.int32)
                accept(spec,dict(begin_ns=1,end_ns=2,process_cpu_ns=0),'bad',output)
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()
            with self.assertRaises(ValueError):runtime.run_round(folder,value,lambda:False,enabled=True,
                fixture_factory=lambda folder:BadBlock())
            partial=folder/'partial_at_first_fault'
            self.assertEqual((partial/'outputs/first_failure.bin').stat().st_size,262144)
            self.assertEqual((folder/'outputs/first_failure.bin').stat().st_size,262144)
            self.assertFalse(json.loads((partial/'status.json').read_bytes())['cleanup_verified'])
            receipt=json.loads((folder/'round_receipt.json').read_bytes())
            self.assertFalse(receipt['operation_success']);self.assertIsNone(receipt['os_facts'])
            launcher.verify_artifacts(folder)
    def test_outer_start_receipt_failure_still_waits_and_preserves_primary(self):
        value=request();events=[];child=SimpleNamespace(pid=222)
        original=launcher.write_new
        def writer(path,row):
            if Path(path).name=='child_started.json':raise OSError('receipt disk fault')
            return original(path,row)
        def supervised(guardian,operation,publish,stopped,**kwargs):
            try:return dict(result=operation(lambda:False),signals={})
            finally:self.assertIsNone(guardian.child)
        def wait(*args,**kwargs):
            events.append('actual-wait-fixture')
            return dict(actual_wait_observed=True,actual_exit_code=0,process_group_absent=True)
        with tempfile.TemporaryDirectory() as tmp:
            target=Path(tmp).resolve()/'run'
            with patch.object(binding,'require_arm'),patch.object(binding,'check'),patch.object(launcher,'read_request',return_value=value),\
                patch.object(launcher.fpga_evidence,'snapshot',return_value={}),patch.object(launcher.fpga_evidence,'released',return_value={}),\
                patch.object(launcher.subprocess,'Popen',return_value=child),patch.object(launcher,'supervised',side_effect=supervised),\
                patch.object(launcher,'observe_exit',side_effect=wait),patch.object(launcher,'write_new',side_effect=writer),\
                patch.object(launcher,'validate_child',return_value=({},dict(operation_success=True),{},{})):
                with self.assertRaisesRegex(OSError,'receipt disk fault'):
                    launcher.launch('unused','0'*64,target,enabled=True,confirmed=True)
            self.assertEqual(events,['actual-wait-fixture'])
            receipt=json.loads((target/'outer_receipt.json').read_bytes())
            self.assertTrue(receipt['actual_wait_observed']);self.assertFalse(receipt['operation_success'])

if __name__=='__main__':unittest.main()
