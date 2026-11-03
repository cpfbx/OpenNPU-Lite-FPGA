"""Narrow v3 regressions: publication interleavings and compound diagnostic faults.

Fake launcher supervision/children never claim real wait, lock, ARM or quarantine.
"""
import io
import json
import os
from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import outer_binding as binding
import failure_journal as journal
import round_launcher as launcher
from comparison_policy import ComparisonPolicy
from test_runtime import request


class PublicationRegressions(unittest.TestCase):
    def fault(self):
        error=ValueError('synthetic Call failure');error.matrix_returned_payload=bytes(262144)
        return error

    def test_open_ready_before_content_is_still_pending(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()/'journal';sink=journal.FailureJournal(folder)
            policy=ComparisonPolicy(0,True);observed=[];original=journal.exclusive
            def pause(path,raw):
                if path.name!='ready.json':return original(path,raw)
                with path.open('xb') as stream:
                    observed.append(journal.read_ready(folder,policy,os.getpid()))
                    stream.write(raw);stream.flush();os.fsync(stream.fileno())
            with patch.object(journal,'exclusive',side_effect=pause):sink.capture(policy.request(0),self.fault())
            self.assertEqual(observed,[None])
            self.assertEqual(journal.read_ready(folder,policy,os.getpid())[2],bytes(262144))

    def test_real_threads_partial_ready_is_pending_until_commit(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()/'journal';sink=journal.FailureJournal(folder)
            policy=ComparisonPolicy(0,True);partial=threading.Event();resume=threading.Event();errors=[]
            original=journal.exclusive
            def pause(path,raw):
                if path.name!='ready.json':return original(path,raw)
                with path.open('xb') as stream:
                    stream.write(raw[:5]);stream.flush();partial.set()
                    if not resume.wait(5):raise RuntimeError('offline test rendezvous failed')
                    stream.write(raw[5:]);stream.flush();os.fsync(stream.fileno())
            def publish():
                try:sink.capture(policy.request(0),self.fault())
                except BaseException as error:errors.append(error)
            with patch.object(journal,'exclusive',side_effect=pause):
                thread=threading.Thread(target=publish);thread.start()
                try:
                    self.assertTrue(partial.wait(5),'publisher did not reach staged write')
                    self.assertIsNone(journal.read_ready(folder,policy,os.getpid()))
                finally:resume.set();thread.join(timeout=6)
            self.assertFalse(thread.is_alive());self.assertEqual(errors,[])
            self.assertEqual(journal.read_ready(folder,policy,os.getpid())[2],bytes(262144))

    def test_empty_commit_is_valid_at_creation_before_close(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()/'journal';sink=journal.FailureJournal(folder)
            policy=ComparisonPolicy(0,True);observed=[];original=journal.exclusive
            def pause(path,raw):
                if path.name!='committed.flag':return original(path,raw)
                self.assertEqual(raw,b'')
                with path.open('xb') as stream:
                    # File creation itself is the publication point. No marker
                    # bytes remain to be filled in after the reader sees it.
                    observed.append(journal.read_ready(folder,policy,os.getpid())[2])
                    stream.flush();os.fsync(stream.fileno())
            with patch.object(journal,'exclusive',side_effect=pause):sink.capture(policy.request(0),self.fault())
            self.assertEqual(observed,[bytes(262144)])

    def test_nonempty_commit_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()/'journal';sink=journal.FailureJournal(folder);policy=ComparisonPolicy(0,True)
            sink.capture(policy.request(0),self.fault());(folder/'committed.flag').write_bytes(b'bad')
            with self.assertRaises(ValueError):journal.read_ready(folder,policy,os.getpid())

    def test_preexisting_commit_not_overwritten_or_retried(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()/'journal';sink=journal.FailureJournal(folder);policy=ComparisonPolicy(0,True)
            (folder/'committed.flag').write_bytes(b'sentinel')
            with self.assertRaises(FileExistsError):sink.capture(policy.request(0),self.fault())
            self.assertEqual((folder/'committed.flag').read_bytes(),b'sentinel')
            with self.assertRaises(RuntimeError):sink.capture(policy.request(0),self.fault())

    def test_committed_but_missing_metadata_is_not_pending_or_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder=Path(tmp).resolve()/'journal';folder.mkdir();(folder/'committed.flag').write_bytes(b'')
            with self.assertRaises(OSError):journal.read_ready(folder,ComparisonPolicy(0,True),os.getpid())


class CompoundFaultRegressions(unittest.TestCase):
    def exercise(self,*,start_error=True,validation_error=False,observed_error=False,final_error=False,publish_error=False):
        first=OSError('FIRST synthetic receipt failure, never export this text')
        validation=ValueError('SECOND synthetic terminal failure')
        observed=LookupError('SECOND synthetic observation write failure')
        final=RuntimeError('LAST synthetic outer write failure')
        publication=PermissionError('SECOND synthetic attention write failure')
        child=SimpleNamespace(pid=222);events=[];states=[];attempts=[];original=launcher.write_new
        def writer(path,row):
            name=Path(path).name;attempts.append((name,row))
            if name=='child_started.json' and start_error:raise first
            if name=='observed_child_exit.json' and observed_error:raise observed
            if name=='outer_receipt.json' and final_error:raise final
            if name=='attention_retained.json' and publish_error:raise publication
            return original(path,row)
        def supervisor(guardian,operation,publish,external,**kwargs):
            # Do NOT enter the real infinite hold. This fixture observes only
            # retention decision and metadata before the unchanged supervisor.
            try:return dict(result=operation(lambda:False),signals={})
            except BaseException as error:
                if guardian.child is not None or guardian._held:
                    try:publish(dict(outcome='offline-retention-fixture',primary_error_type=type(error).__name__))
                    except BaseException:pass
                raise
            finally:states.append(dict(held=guardian._held,child_retained=guardian.child is not None))
        def wait(*args,**kwargs):
            events.append('wait-fixture')
            return dict(actual_wait_observed=True,actual_exit_code=0,process_group_absent=True)
        def validate(*args):
            if validation_error:raise validation
            return (dict(operation_success=True),dict(operation_success=True,diagnostic_complete=True,os_evidence_observed=True),{},{})
        with tempfile.TemporaryDirectory() as tmp:
            target=Path(tmp).resolve()/'run';raised=None
            with patch.object(binding,'require_arm'),patch.object(binding,'check'),patch.object(launcher,'read_request',return_value=request()),\
                patch.object(launcher.fpga_evidence,'snapshot',return_value={}),patch.object(launcher.fpga_evidence,'released',return_value={}),\
                patch.object(launcher.subprocess,'Popen',return_value=child),patch.object(launcher,'supervised',side_effect=supervisor),\
                patch.object(launcher,'observe_exit',side_effect=wait),patch.object(launcher,'write_new',side_effect=writer),\
                patch.object(launcher,'validate_child',side_effect=validate):
                try:result=launcher.launch('unused','0'*64,target,enabled=True,confirmed=True)
                except BaseException as error:raised=error;result=None
            files={p.name:json.loads(p.read_bytes()) for p in target.glob('*.json')}
        self.assertEqual(events,['wait-fixture'])
        return SimpleNamespace(first=first,validation=validation,observed=observed,final=final,publication=publication,
            raised=raised,states=states,files=files,attempts=attempts,result=result)

    def test_start_then_terminal_error_preserves_first_object_and_holds_child(self):
        r=self.exercise(validation_error=True)
        self.assertIs(r.raised,r.first);self.assertEqual(r.states,[dict(held=True,child_retained=True)])
        self.assertEqual(r.files['outer_receipt.json']['error_type'],'OSError')
        self.assertEqual(r.first.round_secondary_errors[-1],dict(stage='operation_exit',error_type='ValueError'))

    def test_start_then_final_write_preserves_first_after_safe_cleanup(self):
        r=self.exercise(final_error=True)
        self.assertIs(r.raised,r.first);self.assertEqual(r.states,[dict(held=False,child_retained=False)])
        self.assertEqual(r.first.round_secondary_errors[-1],dict(stage='outer_receipt',error_type='RuntimeError'))

    def test_three_faults_all_secondary_types_recorded_without_private_messages(self):
        r=self.exercise(observed_error=True,validation_error=True,final_error=True)
        self.assertIs(r.raised,r.first)
        self.assertEqual(r.first.round_secondary_errors,[
            dict(stage='observed_child_exit',error_type='LookupError'),
            dict(stage='operation_exit',error_type='ValueError'),
            dict(stage='outer_receipt',error_type='RuntimeError')])
        self.assertNotIn('synthetic',json.dumps(r.first.round_secondary_errors))

    def test_retention_attention_preserves_original_and_secondary_facts(self):
        r=self.exercise(validation_error=True)
        attention=r.files['attention_retained.json']
        self.assertEqual(attention['outer_primary_error_type'],'OSError')
        self.assertEqual(attention['outer_secondary_errors'],[dict(stage='operation_exit',error_type='ValueError')])

    def test_failed_attention_write_never_replaces_primary_or_releases_child(self):
        r=self.exercise(validation_error=True,publish_error=True)
        self.assertIs(r.raised,r.first);self.assertTrue(r.states[0]['held']);self.assertTrue(r.states[0]['child_retained'])
        self.assertEqual(r.first.round_secondary_errors[-1],dict(stage='attention_retained',error_type='PermissionError'))

    def test_only_terminal_error_remains_primary(self):
        r=self.exercise(start_error=False,validation_error=True)
        self.assertIs(r.raised,r.validation);self.assertTrue(r.states[0]['child_retained'])

    def test_only_final_write_failure_rejects_prior_apparent_success(self):
        r=self.exercise(start_error=False,final_error=True)
        self.assertIs(r.raised,r.final);self.assertFalse(r.attempts[-1][1]['operation_success'])

    def test_healthy_fixture_unchanged(self):
        r=self.exercise(start_error=False)
        self.assertIsNone(r.raised);self.assertTrue(r.result['operation_success'])
        self.assertEqual(r.states,[dict(held=False,child_retained=False)])

if __name__=='__main__':unittest.main()
