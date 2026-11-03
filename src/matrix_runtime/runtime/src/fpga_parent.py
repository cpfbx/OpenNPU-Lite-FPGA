"""Parent IPC/wait/lock bridge. No arbitrary board launcher, retry or kill.

Trusted caller must install unchanged supervisor around ProcessGuardian before
starting a block; unresolved child/group/device cleanup retains the guardian.
"""
import hashlib
import os
from pathlib import Path
import queue
import subprocess
import threading
import numpy as np
from batch_policy import BatchStop
from comparison_policy import validate_fpga_policy
from cpu_frames import encode,exact_row,write_new
from cpu_parent import reader
from process_observer import observe_exit
from failure_journal import read_ready,JournalFault
import fpga_evidence


def metrics_for_request(policy,spec,value):
    from d007_mode11_contract import validate_summary
    if type(value) is not dict:raise ValueError('plain metrics required')
    wanted=dict(mode=11,jobs=spec.jobs,chain_jobs_completed=spec.jobs,
        input_bytes=policy.geometry.input_bytes,output_bytes=policy.geometry.output_bytes,
        output_valid_bytes=policy.geometry.output_bytes,effective_macs=policy.geometry.macs,
        first_job_id=spec.first_job_id,error_code=0,batch_pl_index=spec.local_index)
    if any(type(value.get(k)) is not type(v) or value[k]!=v for k,v in wanted.items()):
        raise ValueError('parent work/sequence counter mismatch')
    if (value.get('counter_contract')!='d007_global_work_v2' or value.get('layout')!='k_major'
            or type(value.get('status')) is not int or value['status'] & (2|4|8)!=4
            or type(value.get('seconds')) not in (int,float) or not value['seconds']>0
            or not all(validate_summary(value).values())):
        raise ValueError('parent MODE11 conservation mismatch')
    stages=value.get('attribution_adapter_ns')
    keys={'transaction_generation','owned_submission','record_reconstruction','output_unpack'}
    if type(stages) is not dict or set(stages)!=keys or any(type(v) is not int or v<0 for v in stages.values()):
        raise ValueError('explicit nonnegative host stage timings required')
    return value


def settle_fpga_reader(child,thread,messages,errors,*,successful,saw_done,aborted_seen=None):
    if thread is None:raise RuntimeError('FPGA reader not started')
    thread.join(timeout=1.)
    if thread.is_alive():raise RuntimeError('FPGA reader still alive')
    try:
        if errors:raise RuntimeError('FPGA reader protocol error')
        rest=[]
        while not messages.empty():rest.append(messages.get_nowait())
        if aborted_seen is not None:rest.insert(0,aborted_seen)
        if successful:
            if not saw_done or rest!=[None]:raise ValueError('FPGA trailing frame/EOF drift')
            return None
        # Preserve cleanup evidence on a cooperative STOP/numeric failure. More
        # than one terminal, missing EOF, or arbitrary frames cannot prove cleanup.
        if len(rest)!=2 or rest[-1] is not None:raise ValueError('failed FPGA cleanup frame/EOF required')
        terminal,payload=rest[0]
        if (type(terminal) is not dict or set(terminal)!={'kind','calls','pid','ticket','cleanup'}
                or terminal['kind']!='aborted' or type(terminal['calls']) is not int
                or not 0<=terminal['calls']<=6 or payload is not None):
            raise ValueError('exact aborted cleanup terminal required')
        return terminal
    finally:
        if child.stdout is not None:child.stdout.close()


class ProcessGuardian:
    def __init__(self,policy,*,enabled=False):
        if enabled is not True:raise ValueError('FPGA parent guardian default-off')
        validate_fpga_policy(policy)
        self.policy=policy;self.pid=os.getpid();self.thread=threading.get_ident()
        self._children=[];self._held=False;self._failures=[];self._used=False

    def _owned(self):
        if (os.getpid(),threading.get_ident())!=(self.pid,self.thread):raise RuntimeError('parent ownership drift')

    @property
    def supervision_status(self):
        return dict(pid=self.pid,held=self._held,safety_unresolved=self._held,
            lease_retained=False,runner_retained=bool(self._children),root_buffers_retained=0,
            failure_types=tuple(self._failures))

    def _hold(self,error):
        self._held=True;self._failures.append(type(error).__name__)

    def retain_child(self,child):
        self._owned()
        if self._used or self._children or self._held:raise RuntimeError('one FPGA child, no retry')
        self._used=True;self._children.append(child)

    def forget_child(self,child):
        self._owned()
        if self._held or self._children!=[child]:raise RuntimeError('quarantined/mismatched child')
        self._children.clear()


def run_fpga_block(command,directory,guardian,stopped,before,accept,*,enabled=False,
                   popen_factory=subprocess.Popen,group_query=None,
                   lock_snapshot=None,live_query=None,release_query=None,fixture=False,on_failure=None):
    if enabled is not True:raise ValueError('FPGA parent default-off')
    guardian._owned();policy=guardian.policy;validate_fpga_policy(policy)
    if guardian._used or guardian._held:raise RuntimeError('single-use FPGA block')
    if type(fixture) is not bool:raise ValueError('explicit fixture label required')
    injections=(popen_factory is not subprocess.Popen or group_query is not None
                or any(q is not None for q in (lock_snapshot,live_query,release_query)))
    if not fixture and (injections or os.name!='posix'):
        raise ValueError('real Linux bridge rejects injected process/group/lock evidence')
    if not all(callable(q) for q in (stopped,before,accept)):raise ValueError('trusted serial callbacks required')
    if type(command) is not list or not command or any(type(x) is not str or '\0' in x for x in command):
        raise ValueError('trusted fixed child argv required')
    folder=Path(directory).absolute()
    if folder.exists() or folder.resolve()!=folder:raise ValueError('fresh canonical external observation directory required')
    identity=(lock_snapshot or fpga_evidence.snapshot)()
    folder.mkdir();messages=queue.Queue(2);errors=[]
    child=thread=None;primary=None;observation=None;ticket=cleanup=None;checked=0;saw_done=False;aborted_seen=None
    record=dict(block_index=policy.block_index,actual_exit_code=None,actual_wait_observed=False,
        process_group_absent=None,checked_calls=0,reader_clean=False,cleanup_verified=False,
        lock_released_same_inode=False,evidence_injected=injections,fixture=fixture,
        automatic_kill=False,promotion=False,request_metrics=[])
    fault_seen=False
    def poll_fault():
        nonlocal fault_seen,primary
        if fault_seen or child is None:return
        value=read_ready(folder/'failure_journal',policy,child.pid)
        if value is None:return
        fault_seen=True;spec,metadata,payload=value
        if spec.local_index!=checked or ticket is None:
            raise ValueError('fault journal must match current entered request')
        error=JournalFault('child Call fault; cleanup not inferred from journal')
        if payload is not None:error.matrix_returned_payload=payload
        error.failure_request=spec;error.failure_metadata=metadata
        record['call_fault']=metadata
        if primary is None:primary=error
        if on_failure is not None:
            try:on_failure(spec,metadata,payload)
            except BaseException as secondary:
                primary.failure_snapshot_error_type=type(secondary).__name__
                record['failure_snapshot_error_type']=type(secondary).__name__
    def monitor_stop():
        # Poll even while real wait() blocks on the retained original supervisor.
        # Receiving bytes never forgets a child or proves lock release.
        poll_fault()
        return True if fault_seen else stopped()
    def cancel():
        try:
            with (folder/'stop.flag').open('xb') as stream:stream.write(b'STOP\n')
        except FileExistsError:pass
    def send(row):child.stdin.write(encode(row));child.stdin.flush()
    def receive():
        nonlocal aborted_seen
        while True:
            poll_fault()
            if fault_seen:raise primary
            if stopped() is not False:cancel()
            if errors:raise RuntimeError('FPGA protocol reader failed: '+errors[0])
            try:item=messages.get(timeout=.1)
            except queue.Empty:continue
            if item is None:raise RuntimeError('FPGA EOF before completion')
            if item[0].get('kind')=='aborted':
                aborted_seen=item
                poll_fault()
                if fault_seen:raise primary
                raise RuntimeError('FPGA aborted before completion')
            return item
    with (folder/'child.stderr').open('xb') as stderr:
        options=dict(stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,close_fds=True,shell=False)
        if os.name=='posix':options['start_new_session']=True
        else:options['creationflags']=subprocess.CREATE_NO_WINDOW
        try:
            if stopped() is not False:raise BatchStop('stop before FPGA process creation')
            child=popen_factory(command,**options);guardian.retain_child(child)
            record['child_pid']=child.pid
            write_new(folder/'child_started.json',dict(pid=child.pid,actual_exit_code=None))
            thread=threading.Thread(target=reader,args=(child.stdout,messages,errors,policy.geometry.output_bytes),daemon=True)
            thread.start()
            hello,payload=receive();ticket=hello.get('ticket')
            exact_row({k:v for k,v in hello.items() if k!='ticket'},dict(kind='hello',pid=child.pid,
                block_index=policy.block_index,dimension=policy.dimension,
                compute_kind='pc_fpga_fixture' if fixture else 'fpga_mode11'))
            if payload is not None:raise ValueError('HELLO payload forbidden')
            if (live_query or fpga_evidence.verify_live)(ticket,child.pid,identity) is not True:
                raise RuntimeError('child lock acquisition not independently observed')
            for index in range(6):
                spec=policy.request(index)
                ready,payload=receive();exact_row(ready,dict(kind='ready',index=index,input_id=spec.input_id,pid=child.pid))
                if payload is not None:raise ValueError('READY payload forbidden')
                if stopped() is not False:raise BatchStop('stop before next FPGA GO')
                if (live_query or fpga_evidence.verify_live)(ticket,child.pid,identity) is not True:
                    raise RuntimeError('fresh child canonical lease lost')
                before(spec)
                if stopped() is not False:raise BatchStop('stop after claim before GO')
                send(dict(kind='go',index=index));row,payload=receive()
                required={'kind','index','input_id','pid','payload_bytes','begin_ns','end_ns','process_cpu_ns','output_sha256','metrics'}
                if type(row) is not dict or set(row)!=required:raise ValueError('exact FPGA result fields')
                exact_row({k:row[k] for k in ('kind','index','input_id','pid','payload_bytes')},dict(kind='result',index=index,input_id=spec.input_id,pid=child.pid,payload_bytes=policy.geometry.output_bytes))
                if (any(type(row[k]) is not int for k in ('begin_ns','end_ns','process_cpu_ns'))
                        or not 0<row['begin_ns']<row['end_ns'] or row['process_cpu_ns']<0):
                    raise ValueError('valid complete-request timing required')
                digest=hashlib.sha256(payload).hexdigest()
                if row['output_sha256']!=digest:raise ValueError('transport output digest drift')
                output=np.frombuffer(payload,dtype='<i4').reshape(policy.dimension,policy.dimension).copy()
                # Parent retains one raw output; full numerical oracle executes INSIDE
                # RoundCoordinator.accept so first pure numeric failure is preserved.
                try:
                    metrics=metrics_for_request(policy,spec,row['metrics'])
                    accept(spec,row,digest,output)
                except BaseException as error:
                    error.comparison_returned_payload=payload
                    error.comparison_output_identity=dict(block_index=spec.block_index,
                        local_index=spec.local_index,input_id=spec.input_id,
                        dimension=spec.dimension,encoding='row-major-int32-le')
                    if on_failure is not None:
                        try:on_failure(spec,dict(encoding='row-major-int32-le',error_type=type(error).__name__),payload)
                        except BaseException as secondary:error.failure_snapshot_error_type=type(secondary).__name__
                    raise
                checked+=1
                record['request_metrics'].append(dict(local_index=index,input_id=spec.input_id,
                    output_sha256=digest,metrics=metrics))
                if stopped() is not False:raise BatchStop('stop after entered FPGA request')
                send(dict(kind='ack',index=index));del output,payload
            done,payload=receive()
            exact_row({k:v for k,v in done.items() if k not in ('ticket','cleanup')},dict(kind='done',calls=6,pid=child.pid))
            if payload is not None or done.get('ticket')!=ticket:raise ValueError('DONE identity drift')
            cleanup=done.get('cleanup');saw_done=True
        except BaseException as error:
            primary=error
            if child is not None:
                try:cancel();send(dict(kind='stop'))
                except BaseException:pass
        finally:
            if child is not None:
                try:
                    try:child.stdin.close()
                    except OSError as error:
                        if primary is None:primary=error
                    observation=observe_exit(child,guardian,monitor_stop,cancel,group_query=group_query)
                    poll_fault()  # Covers an immediately reaped child as well.
                    record.update(observation)
                    aborted=settle_fpga_reader(child,thread,messages,errors,successful=primary is None,saw_done=saw_done,aborted_seen=aborted_seen)
                    if aborted is not None:
                        if type(aborted['pid']) is not int or aborted['pid']!=child.pid or aborted['ticket']!=ticket:
                            raise ValueError('aborted cleanup identity drift')
                        cleanup=aborted['cleanup']
                    record['reader_clean']=True
                    # Even exit 0 is NOT a cleanup certificate without child terminal
                    # evidence and the parent's same-inode kernel release readback.
                    if cleanup is None:raise RuntimeError('FPGA cleanup terminal missing; quarantine')
                    fpga_evidence.validate_cleanup(cleanup,ticket,child.pid)
                    release=(release_query or fpga_evidence.released)(identity)
                    if type(release) is not dict or release.get('lock_released_same_inode') is not True:
                        raise RuntimeError('same-inode release proof missing')
                    record.update(cleanup_verified=True,lock_released_same_inode=True,
                        cleanup_readback=cleanup,release_readback=release)
                    guardian.forget_child(child)
                except BaseException as error:
                    guardian._hold(error)
                    partial=getattr(error,'comparison_exit_observation',None)
                    if partial is not None:
                        record.update(partial)
                        if (partial.get('actual_wait_observed') is True
                                and partial.get('process_group_absent') is True):
                            record['quarantined_reader_cleanup_attempted']=True
                            try:
                                settle_fpga_reader(child,thread,messages,errors,successful=False,saw_done=saw_done,aborted_seen=aborted_seen)
                                record['reader_clean']=True
                            except BaseException as cleanup_error:
                                record['reader_cleanup_error_type']=type(cleanup_error).__name__
                            # Dead-pipe cleanup is NOT permission to forget the child,
                            # release quarantine, or declare hardware cleanup verified.
                    if primary is None:primary=error
            try:final_stop=stopped() is not False
            except BaseException as error:
                final_stop=True;guardian._hold(error)
                if primary is None:primary=error
            record.update(checked_calls=checked,stop_requested=final_stop,error_type=None if primary is None else type(primary).__name__)
            try:write_new(folder/'actual_exit.json',record)
            except BaseException as error:
                if primary is None:primary=error
    if primary is not None:raise primary
    if record['stop_requested']:raise BatchStop('FPGA stop after cleanup; no success')
    if record['actual_exit_code']!=0 or checked!=6:raise RuntimeError('FPGA actual exit/count mismatch')
    return record


def receipt_for_plan(policy,observation,guardian):
    validate_fpga_policy(policy)
    wanted=dict(block_index=policy.block_index,actual_exit_code=0,actual_wait_observed=True,
        process_group_absent=True,checked_calls=6,reader_clean=True,cleanup_verified=True,
        lock_released_same_inode=True,evidence_injected=False,group_query_injected=False,
        fixture=False,stop_requested=False,error_type=None)
    if guardian.policy is not policy or guardian._held or guardian._children:
        raise RuntimeError('same resolved parent guardian required')
    if type(observation) is not dict or any(type(observation.get(k)) is not type(v) or observation[k]!=v for k,v in wanted.items()):
        raise ValueError('real non-injected successful FPGA OS observation required')
    return dict(block_index=policy.block_index,actual_exit_code=0,process_group_absent=True,cleanup_verified=True,lock_released=True)
