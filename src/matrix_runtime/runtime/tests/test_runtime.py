"""Offline private bridges. All board lock/MMIO evidence explicitly synthetic."""
from dataclasses import asdict
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import queue
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import numpy as np

import outer_binding
import fpga_evidence as evidence
import fpga_parent as parent
import fpga_worker
import fpga_worker_entry
import runtime_blocks
from batch_policy import BatchStop
from comparison_policy import ComparisonPolicy
from comparison_bank import load_bank
from round_artifacts import RetainedOutputs
from round_coordinator import RoundCoordinator

ROOT=Path(__file__).resolve().parent.parent
BANK='af893b4381e8c72a667b772b3d40aa7b2db03739232e9f60b21bbb1ef1c939a8'


def request():
    return dict(schema='panel-private-runtime-request-v1',operator='bx',
        board_serial_declared='operator declaration only',image_declared='pynq-z2-v3.1.1',
        operator_confirmed=True,scope='48-formal-complete-request-latency-only',
        manifest_sha='0'*64,plan_sha='1'*64,bank_sha=BANK)


class IdentityTests(unittest.TestCase):
    def test_fixed_request_and_not_physical_authentication(self):
        self.assertEqual(outer_binding.request(request()),('0'*64,'1'*64,BANK))

    def test_bad_operator_scope_schema_and_boolean_refused(self):
        for changes in (dict(operator='agent'),dict(operator_confirmed=1),dict(scope='energy'),
                        dict(schema='old'),dict(board_serial_declared=''),dict(bank_sha='F'*64),
                        dict(image_declared='other')):
            value=request();value.update(changes)
            with self.subTest(changes=changes),self.assertRaises(ValueError):outer_binding.request(value)

    def test_extra_field_refused(self):
        value=request();value['run_ready']=True
        with self.assertRaises(ValueError):outer_binding.request(value)

    def test_pc_refused_before_runtime_acquisition(self):
        with patch.object(platform,'machine',return_value='x86_64'),self.assertRaisesRegex(RuntimeError,'ARM'):
            outer_binding.require_arm()

    def test_real_blocks_defaultoff(self):
        with self.assertRaisesRegex(ValueError,'default-off'):runtime_blocks.RealBlocks('absent',{},None)

    def test_private_worker_defaultoff_before_missing_config(self):
        with self.assertRaisesRegex(ValueError,'default-off'):fpga_worker_entry.run_private('absent','0'*64)

    def test_worker_help_and_pc_enabled_refusal_are_isolated(self):
        argv=[sys.executable,'-I','-B',str(ROOT/'fpga_worker_entry.py')]
        for extra,code in ((['--help'],0),(['--config','absent','--config-sha','0'*64],2),
            (['--config','absent','--config-sha','0'*64,'--enabled-private-worker'],2)):
            with self.subTest(extra=extra):
                result=subprocess.run(argv+extra,capture_output=True)
                self.assertEqual(result.returncode,code,result.stderr)

    def test_no_public_run_command(self):
        result=subprocess.run([sys.executable,'-I','-B',str(ROOT/'runtime_check.py'),'run'],capture_output=True)
        self.assertEqual(result.returncode,2)

    def test_fpga_service_defaultoff(self):
        with self.assertRaisesRegex(ValueError,'default-off'):fpga_worker.serve(None,None,None,None,None,None,None,None)

    def test_runtime_binding_checks_full_assets_without_pynq(self):
        anchors=tuple(hashlib.sha256((ROOT/n).read_bytes()).hexdigest() for n in ('review_manifest.json','plan.json','bank_manifest.json'))
        selected,bank=outer_binding.check(anchors)
        self.assertEqual(len(bank),4);self.assertFalse(any(n=='pynq' or n.startswith('pynq.') for n in sys.modules))
        self.assertTrue(callable(selected.runner_type))


class LockReadbackTests(unittest.TestCase):
    def identity(self):return dict(device=2048,inode=11,path=evidence.LOCK)

    def test_release_without_new_lock_acquisition(self):
        identity=self.identity()
        with patch.object(evidence,'snapshot',return_value=identity),patch.object(evidence,'read_text',return_value=''):
            self.assertTrue(evidence.released(identity)['lock_released_same_inode'])

    def test_unrelated_kernel_lock_allowed(self):
        identity=self.identity()
        with patch.object(evidence,'snapshot',return_value=identity),patch.object(evidence,'read_text',return_value='2: FLOCK ADVISORY WRITE 100 08:00:12 0 EOF\n'),patch.multiple(evidence.os,major=lambda d:8,minor=lambda d:0,create=True):
            self.assertTrue(evidence.released(identity)['lock_released_same_inode'])

    def test_same_inode_kernel_lock_rejected(self):
        identity=self.identity()
        row='2: FLOCK ADVISORY WRITE 100 08:00:11 0 EOF\n'
        with patch.object(evidence,'snapshot',return_value=identity),patch.object(evidence,'read_text',return_value=row),patch.multiple(evidence.os,major=lambda d:8,minor=lambda d:0,create=True),self.assertRaisesRegex(RuntimeError,'still'):
            evidence.released(identity)

    def test_changed_inode_rejected(self):
        with patch.object(evidence,'snapshot',return_value=dict(device=2048,inode=12,path=evidence.LOCK)),self.assertRaises(RuntimeError):
            evidence.released(self.identity())

    def test_malformed_or_unreadable_proc_not_absence(self):
        for answer in ('2: FLOCK invalid\n',OSError('denied')):
            context=patch.object(evidence,'read_text',side_effect=answer) if isinstance(answer,Exception) else patch.object(evidence,'read_text',return_value=answer)
            with self.subTest(answer=answer),patch.object(evidence,'snapshot',return_value=self.identity()),context,self.assertRaises((OSError,RuntimeError)):
                evidence.released(self.identity())

    def test_live_ticket_boolean_pid_refused_before_proc(self):
        with self.assertRaises(ValueError):evidence.verify_live({},True,self.identity())

    def test_cleanup_must_close_resources_and_confirm_recovery(self):
        ticket={'pid':123}
        cleanup=dict(owner_closed=True,readback=dict(last_lock_proof=ticket,
            resources=dict(pid=123,held=False,safety_unresolved=False,lease_retained=False,runner_retained=False,root_buffers_retained=0),
            terminal=dict(build_id=0x2026D075,phase=1,error=0,recovery=dict(confirmed=True))))
        self.assertTrue(evidence.validate_cleanup(cleanup,ticket,123))
        cleanup['readback']['resources']['root_buffers_retained']=False
        with self.assertRaises(ValueError):evidence.validate_cleanup(cleanup,ticket,123)


class RetentionBudgetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.bank=load_bank(ROOT,BANK)

    def test_failure_budget_checked_before_mutation(self):
        sink=RetainedOutputs(enabled=True);sink.MAX_PAYLOAD_BYTES=1
        with self.assertRaisesRegex(ValueError,'budget'):sink.failure(ComparisonPolicy(0,True).request(0),bytes(262144),'row-major-int32-le')
        self.assertIsNone(sink.first_failure)

    def test_success_budget_checked_before_mutation(self):
        spec=ComparisonPolicy(0,True).request(2);raw=self.bank[256,42].expected
        out=np.frombuffer(raw,dtype='<i4').reshape(256,256).copy()
        sink=RetainedOutputs(enabled=True);sink.MAX_PAYLOAD_BYTES=1
        with self.assertRaisesRegex(ValueError,'budget'):sink.success(spec,out,hashlib.sha256(raw).hexdigest())
        self.assertEqual(sink.successes,{})

    def test_generic_row_major_error_identity(self):
        spec=ComparisonPolicy(0,True).request(0);error=ValueError('count mismatch')
        error.comparison_returned_payload=bytes(262144)
        error.comparison_output_identity=dict(block_index=0,local_index=0,input_id=42,dimension=256,encoding='row-major-int32-le')
        sink=RetainedOutputs(enabled=True);self.assertTrue(sink.failure_from_exception(spec,error))
        error.comparison_output_identity['block_index']=False
        with self.assertRaises(ValueError):RetainedOutputs(enabled=True).failure_from_exception(spec,error)


class FpgaParentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):cls.bank=load_bank(ROOT,BANK)

    def exercise(self,block=0,*,extra=(),accept=None,stopped=None):
        policy=ComparisonPolicy(block,True);guardian=parent.ProcessGuardian(policy,enabled=True)
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()/'observation'
            command=[sys.executable,'-I','-B',str(ROOT/'tests/pc_fpga_fixture.py'),
                '--enabled-pc-fixture','--block',str(block),'--stop',str(folder/'stop.flag'),*extra]
            rows=[]
            def check(spec,result,digest,output):
                if accept:accept(spec,result,digest,output)
                else:
                    from comparison_bank import verify_output
                    self.assertEqual(verify_output(self.bank[policy.dimension,spec.input_id],output),digest)
                rows.append(spec)
            error=None;record=None
            try:
                record=parent.run_fpga_block(command,folder,guardian,stopped or (lambda:False),lambda spec:None,check,
                    enabled=True,fixture=True,group_query=lambda pid:True,
                    lock_snapshot=lambda:dict(device=2048,inode=11,path=evidence.LOCK),
                    live_query=lambda ticket,pid,identity:True,
                    release_query=lambda identity:dict(identity,lock_released_same_inode=True))
            except BaseException as caught:error=caught
            saved=json.loads((folder/'actual_exit.json').read_bytes()) if (folder/'actual_exit.json').exists() else None
            stderr=(folder/'child.stderr').read_text() if folder.exists() else ''
            return policy,guardian,record,error,saved,rows,stderr

    def test_parent_defaultoff(self):
        with self.assertRaisesRegex(ValueError,'default-off'):parent.run_fpga_block(None,None,None,None,None,None)

    def test_parent_rejects_injected_evidence_without_fixture_label(self):
        guardian=parent.ProcessGuardian(ComparisonPolicy(0,True),enabled=True)
        with self.assertRaises(ValueError):parent.run_fpga_block([],None,guardian,None,None,None,enabled=True,group_query=lambda pid:True)

    def test_guardian_defaultoff(self):
        with self.assertRaises(ValueError):parent.ProcessGuardian(None)

    def test_actual_pc_old_256(self):self.check_normal(0)
    def test_actual_pc_flat_256(self):self.check_normal(1)
    def test_actual_pc_old_512(self):self.check_normal(6)
    def test_actual_pc_flat_512(self):self.check_normal(7)

    def check_normal(self,block):
        policy,guardian,record,error,saved,rows,stderr=self.exercise(block)
        self.assertIsNone(error,stderr+' / '+repr(error));self.assertEqual(len(rows),6)
        self.assertEqual(record['actual_exit_code'],0);self.assertTrue(record['cleanup_verified'])
        self.assertTrue(record['reader_clean']);self.assertEqual(len(record['request_metrics']),6)
        self.assertEqual(guardian._children,[]);self.assertFalse(guardian._held)
        with self.assertRaises(ValueError):parent.receipt_for_plan(policy,record,guardian)

    def test_actual_child_nonzero_exit_not_success(self):
        policy,g,record,error,saved,rows,stderr=self.exercise(extra=['--nonzero-after-done'])
        self.assertIsInstance(error,RuntimeError,stderr);self.assertEqual(saved['actual_exit_code'],73)
        self.assertTrue(saved['cleanup_verified']);self.assertEqual(g._children,[])

    def test_pure_numeric_failure_retained_by_coordinator_before_next_request(self):
        core=RoundCoordinator(self.bank,lambda:False,enabled=True);policy=ComparisonPolicy(0,True)
        core.ledger.begin(policy)
        def accept(spec,result,digest,output):
            core.before(spec);core.accept(spec,result,digest,output)
        _,g,_,error,saved,rows,stderr=self.exercise(extra=['--wrong-output'],accept=accept)
        self.assertIsInstance(error,ValueError,stderr);self.assertIn('golden',str(error))
        self.assertIsNotNone(core.outputs.first_failure)
        self.assertEqual(len(core.outputs.first_failure['payload']),262144)
        self.assertEqual(core.outputs.first_failure['encoding'],'row-major-int32-le')
        self.assertEqual(saved['checked_calls'],0);self.assertTrue(saved['cleanup_verified'],saved)
        self.assertFalse(g._held,stderr)

    def test_complete_first_request_then_stop_no_second_go(self):
        stop={'value':False}
        def accept(spec,result,digest,output):stop['value']=True
        _,g,_,error,saved,rows,stderr=self.exercise(accept=accept,stopped=lambda:stop['value'])
        self.assertIsInstance(error,BatchStop,stderr);self.assertEqual(saved['checked_calls'],1)
        self.assertTrue(saved['cleanup_verified'],saved);self.assertEqual(g._children,[])

    def test_bad_counter_attachment_is_bounded_and_cleanup_preserved(self):
        _,g,_,error,saved,rows,stderr=self.exercise(extra=['--bad-metrics'])
        self.assertIsInstance(error,ValueError,stderr)
        self.assertEqual(len(error.comparison_returned_payload),262144)
        self.assertEqual(error.comparison_output_identity['encoding'],'row-major-int32-le')
        self.assertEqual(saved['checked_calls'],0);self.assertTrue(saved['cleanup_verified'],saved)
        self.assertFalse(g._held)

    def test_stopped_before_spawn_does_not_acquire_or_launch(self):
        policy=ComparisonPolicy(0,True);g=parent.ProcessGuardian(policy,enabled=True)
        with tempfile.TemporaryDirectory() as tmp,patch.object(parent.subprocess,'Popen') as spawn:
            with self.assertRaises(BatchStop):parent.run_fpga_block(['not-executed'],Path(tmp).resolve()/'run',g,
                lambda:True,lambda s:None,lambda *a:None,enabled=True,fixture=True,
                lock_snapshot=lambda:{},live_query=lambda *a:True,release_query=lambda i:{})
            spawn.assert_not_called();self.assertEqual(g._children,[])


class ReaderAndGuardTests(unittest.TestCase):
    def test_live_reader_not_closed(self):
        stream=io.BytesIO();child=SimpleNamespace(stdout=stream)
        thread=SimpleNamespace(join=lambda timeout:None,is_alive=lambda:True)
        with self.assertRaisesRegex(RuntimeError,'alive'):
            parent.settle_fpga_reader(child,thread,queue.Queue(),[],successful=False,saw_done=False)
        self.assertFalse(stream.closed)

    def test_missing_done_rejected_and_dead_pipe_closed(self):
        stream=io.BytesIO();child=SimpleNamespace(stdout=stream)
        thread=SimpleNamespace(join=lambda timeout:None,is_alive=lambda:False)
        messages=queue.Queue();messages.put(None)
        with self.assertRaises(ValueError):parent.settle_fpga_reader(child,thread,messages,[],successful=True,saw_done=False)
        self.assertTrue(stream.closed)

    def test_aborted_terminal_not_done(self):
        stream=io.BytesIO();child=SimpleNamespace(stdout=stream)
        thread=SimpleNamespace(join=lambda timeout:None,is_alive=lambda:False)
        messages=queue.Queue();terminal=dict(kind='aborted',pid=123,calls=1,ticket={},cleanup={})
        messages.put((terminal,None));messages.put(None)
        self.assertEqual(parent.settle_fpga_reader(child,thread,messages,[],successful=False,saw_done=False),terminal)

    def test_arbitrary_trailing_frame_not_cleanup(self):
        stream=io.BytesIO();child=SimpleNamespace(stdout=stream)
        thread=SimpleNamespace(join=lambda timeout:None,is_alive=lambda:False)
        messages=queue.Queue();messages.put((dict(kind='result'),None));messages.put(None)
        with self.assertRaises(ValueError):parent.settle_fpga_reader(child,thread,messages,[],successful=False,saw_done=False)

    def test_quarantined_guardian_cannot_forget_child(self):
        g=parent.ProcessGuardian(ComparisonPolicy(0,True),enabled=True);child=object()
        g.retain_child(child);g._hold(ValueError('unknown'))
        with self.assertRaises(RuntimeError):g.forget_child(child)
        self.assertEqual(g._children,[child])

    def test_guardian_rejects_second_child(self):
        g=parent.ProcessGuardian(ComparisonPolicy(0,True),enabled=True);g.retain_child(object())
        with self.assertRaises(RuntimeError):g.retain_child(object())

    def test_fault_terminal_write_does_not_replace_primary_error(self):
        bank=load_bank(ROOT,BANK);policy=ComparisonPolicy(0,True)
        first=OSError('first IPC write');second=RuntimeError('secondary cleanup IPC')
        class Sink:
            def __init__(self):self.n=0
            def write(self,raw):
                self.n+=1
                raise first if self.n==1 else second
            def flush(self):pass
        class Owner:
            def __init__(self):self.policy=policy;self._closed=self._held=self._unsafe=False;self.cleanup_readback={}
            @property
            def supervision_status(self):
                return dict(pid=os.getpid(),held=False,safety_unresolved=False,lease_retained=False,runner_retained=False,root_buffers_retained=0)
            def pre_submit(self):return {'pid':os.getpid()}
            def close(self):self._closed=True
        owner=Owner()
        with self.assertRaises(OSError) as captured:
            fpga_worker.serve(policy,bank,owner,lambda o:None,io.BytesIO(),Sink(),lambda:False,lambda r:None,
                enabled=True,call_type=lambda *a,**k:None)
        self.assertIs(captured.exception,first)
        self.assertEqual(first.cleanup_terminal_write_error_type,'RuntimeError')


if __name__=='__main__':unittest.main()
