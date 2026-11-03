"""Actual bounded-pipe parent/worker handshake; no native/device execution on import."""
import os
from pathlib import Path
import queue
import subprocess
import threading
import numpy as np
from batch_policy import BatchStop
from comparison_policy import validate_policy
from comparison_bank import verify_output
from cpu_frames import encode,line,exact_row,read_exact,write_new
from cpu_native import LIB_SHA
from process_observer import observe_exit


def reader(stream,messages,errors,payload_bytes):
    try:
        while True:
            row=line(stream)
            if row is None:messages.put_nowait(None);return
            payload=None
            if row.get('kind')=='result':
                if type(row.get('payload_bytes')) is not int or row['payload_bytes']!=payload_bytes:
                    raise ValueError('exact CPU output extent before allocation')
                payload=read_exact(stream,payload_bytes)
            messages.put_nowait((row,payload))
    except BaseException as error:
        errors.append(type(error).__name__)
        stream.close()  # Invalid producer must not remain blocked writing a pipe.


def settle_reader(child,thread,messages,errors,*,require_done=False,saw_done=False):
    """Only after actual wait AND group absence. Never close underneath a live reader."""
    if thread is not None:
        thread.join(timeout=1.)
        if thread.is_alive():raise RuntimeError('CPU reader thread unresolved')
    try:
        if thread is None:
            if require_done:raise RuntimeError('CPU reader never started')
        else:
            if errors:raise RuntimeError('CPU reader terminated with protocol error')
            rest=[]
            while not messages.empty():rest.append(messages.get_nowait())
            if require_done and (not saw_done or rest!=[None]):
                raise ValueError('CPU trailing frame or EOF drift')
    finally:
        if child.stdout is not None:child.stdout.close()


def run_cpu_block(command,directory,guardian,stopped,bank,accept,*,enabled=False,
                  native_required=True,popen_factory=subprocess.Popen,group_query=None,
                  before_go=None,on_failure=None):
    if enabled is not True:raise ValueError('CPU parent default-off')
    policy=guardian.policy;validate_policy(policy)
    if policy.backend!='openblas_2t':raise ValueError('CPU block required')
    if type(native_required) is not bool:raise ValueError('explicit native policy')
    if before_go is not None and not callable(before_go):raise ValueError('trusted before-GO callback required')
    if (type(command) is not list or not command
            or any(type(x) is not str or '\0' in x for x in command)):
        raise ValueError('trusted fixed argv required')
    if os.name!='posix' and group_query is None:
        raise ValueError('Windows cannot supply real POSIX group proof')
    if guardian._children:raise RuntimeError('previous CPU child still retained')
    guardian.pre_submit()
    directory=Path(directory).absolute()
    if directory.exists() or directory.resolve()!=directory:
        raise ValueError('fresh canonical external observation directory required')
    directory.mkdir()
    messages,errors=queue.Queue(maxsize=2),[]
    child=thread=None;observation=None;primary=None;checked=0;saw_done=False
    record=dict(block_index=policy.block_index,checked_calls=0,actual_exit_code=None,
        process_group_absent=None,actual_wait_observed=False,native_compute=False,
        group_query_injected=group_query is not None,reader_clean=False,
        popen_factory_injected=popen_factory is not subprocess.Popen,
        automatic_kill=False,promotion=False)

    def cancel():
        try:
            with (directory/'stop.flag').open('xb') as stream:stream.write(b'STOP\n')
        except FileExistsError:pass  # Never overwrite/delete a stop entry.

    def send(row):child.stdin.write(encode(row));child.stdin.flush()

    def receive():
        while True:
            if stopped() is not False:cancel()
            if errors:raise RuntimeError('CPU reader failed: '+errors[0])
            try:value=messages.get(timeout=.1)
            except queue.Empty:continue
            if value is None:raise RuntimeError('CPU EOF before protocol completion')
            return value

    with (directory/'child.stderr').open('xb') as stderr:
        options=dict(stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=stderr,close_fds=True,shell=False)
        if os.name=='nt':options['creationflags']=subprocess.CREATE_NO_WINDOW
        else:options['start_new_session']=True
        try:
            child=popen_factory(command,**options);guardian.retain_child(child)
            record['child_pid']=child.pid
            write_new(directory/'child_started.json',dict(pid=child.pid,actual_exit_code=None))
            thread=threading.Thread(target=reader,args=(child.stdout,messages,errors,policy.geometry.output_bytes),daemon=True)
            thread.start()
            hello,payload=receive()
            kind='arm_openblas_2t' if native_required else 'pc_int64_fixture'
            exact_row(hello,dict(kind='hello',pid=child.pid,block_index=policy.block_index,
                dimension=policy.dimension,compute_kind=kind,library_sha256=LIB_SHA if native_required else None))
            if payload is not None:raise ValueError('unexpected HELLO payload')
            record['native_compute']=native_required
            for index in range(6):
                spec=policy.request(index)
                ready,payload=receive()
                exact_row(ready,dict(kind='ready',index=index,input_id=spec.input_id,pid=child.pid))
                if payload is not None:raise ValueError('unexpected READY payload')
                guardian.pre_submit()  # Real binding audits canonical parent lease before EACH GO.
                if stopped() is not False:raise BatchStop('CPU stop before GO')
                if before_go is not None:before_go(spec)
                if stopped() is not False:raise BatchStop('CPU stop after claim before GO')
                send(dict(kind='go',index=index))
                result,payload=receive()
                keys={'kind','index','input_id','pid','payload_bytes','begin_ns','end_ns','process_cpu_ns'}
                if type(result) is not dict or set(result)!=keys:raise ValueError('CPU RESULT shape')
                exact_row({k:result[k] for k in ('kind','index','input_id','pid','payload_bytes')},
                    dict(kind='result',index=index,input_id=spec.input_id,pid=child.pid,
                         payload_bytes=policy.geometry.output_bytes))
                if (any(type(result[k]) is not int for k in ('begin_ns','end_ns','process_cpu_ns'))
                        or not 0<result['begin_ns']<result['end_ns'] or result['process_cpu_ns']<0):
                    raise ValueError('CPU request timing requires positive bounded integer interval')
                output=np.frombuffer(payload,dtype='<i4').reshape(policy.dimension,policy.dimension).copy()
                try:digest=verify_output(bank[policy.dimension,spec.input_id],output)
                except BaseException as error:
                    # One already bounded immutable payload, no traceback-frame scraping.
                    error.cpu_returned_payload=payload
                    error.cpu_output_identity=dict(block_index=spec.block_index,
                        local_index=spec.local_index,input_id=spec.input_id,
                        dimension=spec.dimension,encoding='row-major-int32-le')
                    if on_failure is not None:
                        try:on_failure(spec,dict(encoding='row-major-int32-le',error_type=type(error).__name__),payload)
                        except BaseException as secondary:error.failure_snapshot_error_type=type(secondary).__name__
                    raise
                accept(spec,result,digest,output)  # Outside child request timing; trusted caller retains bounded outputs.
                checked+=1
                if stopped() is not False:raise BatchStop('CPU stop after completed request')
                send(dict(kind='ack',index=index))
                del output,payload
            done,payload=receive();exact_row(done,dict(kind='done',calls=6,pid=child.pid))
            if payload is not None:raise ValueError('unexpected DONE payload')
            saw_done=True
        except BaseException as error:
            primary=error
            if child is not None:
                try:cancel();send(dict(kind='stop'))
                except BaseException:pass
        finally:
            if child is not None:
                # No protocol/write/receipt failure is permission to skip actual wait.
                try:
                    try:child.stdin.close()
                    except OSError as error:
                        if primary is None:primary=error
                    observation=observe_exit(child,guardian,stopped,cancel,group_query=group_query)
                    record.update(observation)
                    settle_reader(child,thread,messages,errors,
                                  require_done=primary is None,saw_done=saw_done)
                    record['reader_clean']=True
                    guardian.forget_child(child)
                except BaseException as error:
                    guardian._hold(error)
                    if observation is None:
                        partial=getattr(error,'comparison_exit_observation',None)
                        if partial is not None:
                            record.update(partial)
                            if (partial.get('actual_wait_observed') is True
                                    and partial.get('process_group_absent') is True):
                                record['quarantined_reader_cleanup_attempted']=True
                                try:
                                    settle_reader(child,thread,messages,errors)
                                    record['reader_clean']=True
                                except BaseException as cleanup_error:
                                    record['reader_cleanup_error_type']=type(cleanup_error).__name__
                                # Cleanup of dead pipes does NOT forget/release retained child/lease.
                    if primary is None:primary=error
            try:final_stop=stopped() is not False
            except BaseException as error:
                final_stop=True;guardian._hold(error)
                if primary is None:primary=error
            record.update(checked_calls=checked,stop_requested=final_stop,
                          error_type=None if primary is None else type(primary).__name__)
            try:write_new(directory/'actual_exit.json',record)
            except BaseException as error:
                if primary is None:primary=error
    if primary is not None:raise primary
    if record['stop_requested']:raise BatchStop('CPU stop after actual wait; not a successful block')
    if record['actual_exit_code']!=0 or checked!=6:raise RuntimeError('CPU actual exit/count failure')
    return record


def receipt_for_plan(policy,observation,guardian):
    """Never allow Windows mock group or PC-native fixture receipts into real plan acceptance."""
    validate_policy(policy)
    if policy.backend!='openblas_2t' or guardian.policy is not policy:
        raise ValueError('same exact CPU guardian policy required')
    required=dict(block_index=policy.block_index,actual_exit_code=0,process_group_absent=True,
        actual_wait_observed=True,group_query_injected=False,native_compute=True,
        popen_factory_injected=False,
        reader_clean=True,checked_calls=6,stop_requested=False,error_type=None)
    if (type(observation) is not dict or any(type(observation.get(k)) is not type(v)
            or observation.get(k)!=v for k,v in required.items())):
        raise ValueError('real native CPU/OS successful observation required')
    if guardian._closed is not True or guardian._held or guardian._unsafe or guardian._children or guardian._lease is not None:
        raise RuntimeError('guardian actual cleanup/release not confirmed')
    return dict(block_index=policy.block_index,actual_exit_code=0,process_group_absent=True,
                cleanup_verified=True,lock_released=True)
