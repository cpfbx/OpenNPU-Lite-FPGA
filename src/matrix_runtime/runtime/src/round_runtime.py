"""Whole-round candidate: fixed order, durable partials, distinct OS summary.

It does not promote generic coordinator callback receipts into OS proof. Only
RealBlocks supplies real observations; explicit PC fixtures remain non-board.
"""
from dataclasses import asdict
import hashlib
import os
from pathlib import Path
import signal
import threading
import outer_binding as binding
from batch_policy import BatchStop
from comparison_policy import ComparisonPolicy
from cpu_frames import write_new
from round_coordinator import RoundCoordinator
from round_artifacts import RetainedOutputs
from runtime_blocks import RealBlocks,external_folder
from failure_journal import canonical

class StopContext:
    def __init__(self,external):
        self.external=external;self.requested=[];self.restore_errors=[];self.previous={}
    def stopped(self):return bool(self.requested) or self.external() is not False
    def handler(self,number,frame):
        if number not in self.requested:self.requested.append(number)
    def __enter__(self):
        if threading.current_thread() is not threading.main_thread():raise RuntimeError('round main thread required')
        try:
            for name in ('SIGINT','SIGTERM','SIGHUP'):
                if hasattr(signal,name):
                    number=getattr(signal,name);self.previous[number]=signal.getsignal(number)
                    signal.signal(number,self.handler)
        except BaseException:
            self.restore();raise
        return self
    def restore(self):
        for number,handler in self.previous.items():
            try:signal.signal(number,handler)
            except BaseException as error:self.restore_errors.append(dict(signal=int(number),error_type=type(error).__name__))
    def __exit__(self,*ignored):self.restore()
    def report(self):return dict(stop_signals=[int(x) for x in self.requested],handler_restore_errors=self.restore_errors)

def strict_equal(actual,wanted):
    return type(actual) is dict and all(k in actual and type(actual[k]) is type(v) and actual[k]==v for k,v in wanted.items())

def os_summary(observations):
    """Deterministic checking of RealBlocks' trusted in-process observations, NOT
    authentication of user-supplied JSON or independently rerun hardware work.
    """
    if type(observations) is not list or len(observations)!=12:raise ValueError('12 actual OS blocks required')
    identity=None;children=set()
    for index,row in enumerate(observations):
        policy=ComparisonPolicy(index,True)
        wanted=dict(block_index=index,actual_exit_code=0,actual_wait_observed=True,
            process_group_absent=True,checked_calls=6,reader_clean=True,cleanup_verified=True,
            lock_released_same_inode=True,stop_requested=False,error_type=None,group_query_injected=False)
        if not strict_equal(row,wanted):raise ValueError('actual OS block gate mismatch')
        if type(row.get('child_pid')) is not int or row['child_pid']<=0 or row['child_pid'] in children:
            raise ValueError('distinct actual child PID required')
        children.add(row['child_pid'])
        if policy.backend=='openblas_2t':
            if not strict_equal(row,dict(native_compute=True,popen_factory_injected=False)):
                raise ValueError('real native CPU block required')
        elif not strict_equal(row,dict(fixture=False,evidence_injected=False)):
            raise ValueError('injected FPGA block refused')
        release=row.get('release_readback')
        if not strict_equal(release,dict(lock_released_same_inode=True)):
            raise ValueError('kernel release readback required')
        current={k:release.get(k) for k in ('device','inode','path')}
        if (type(current['device']) is not int or type(current['inode']) is not int
                or current['path']!='/tmp/opennpu-kws-chain.lock'):
            raise ValueError('canonical inode identity required')
        if identity is not None and current!=identity:raise ValueError('canonical inode changed across blocks')
        identity=current
    return dict(actual_waited_children=12,actual_successful_calls=72,formal_calls=48,warmup_calls=24,
                canonical_lock=identity,all_groups_absent=True,all_cleanup_verified=True)

def file_inventory(folder):
    files={}
    for path in sorted(folder.rglob('*')):
        canonical(path)
        if path.is_dir():continue
        st=path.lstat()
        import stat
        if not stat.S_ISREG(st.st_mode) or st.st_nlink!=1:raise ValueError('regular evidence members only')
        raw=path.read_bytes()
        files[path.relative_to(folder).as_posix()]=dict(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
    return files

def run_round(folder,request,external_stopped,*,enabled=False,fixture_factory=None):
    if enabled is not True:raise ValueError('round default-off')
    fixture=fixture_factory is not None
    if fixture:
        import platform
        if platform.machine().lower().startswith(('arm','aarch')):raise RuntimeError('PC fixture forbidden on ARM')
    else:binding.require_arm()
    anchors=binding.request(request);_,bank=binding.check(anchors)
    folder=external_folder(folder)
    core=None;blocks=None;primary=None;secondary=[];outputs=None;summary=None;os_facts=None
    partial_written=False
    context=StopContext(external_stopped)
    def partial(reason):
        nonlocal partial_written
        if partial_written:return
        partial_written=True  # I/O failure is retained, never overwritten/retried.
        target=folder/'partial_at_first_fault';target.mkdir()
        write_new(target/'status.json',dict(reason=reason,success=False,final=False,
            cleanup_verified=False,lock_release_verified=False,automatic_retry=False,
            snapshot_only=True,board_evidence=not fixture))
        write_new(target/'timing_rows.json',core.rows)
        # Shallow references to immutable bytes; do not mark core's final sink written.
        copy=RetainedOutputs(enabled=True);copy.successes=dict(core.outputs.successes)
        copy.first_failure=core.outputs.first_failure
        copy.persist(target/'outputs')
    def fault(spec,metadata,payload):
        if core.ledger.pending!=spec:raise ValueError('first fault not current coordinator request')
        if payload is not None:core.outputs.failure(spec,payload,metadata['encoding'])
        partial('first numerical/Call fault published before cleanup')
    try:
        with context:
            core=RoundCoordinator(bank,context.stopped,enabled=True)
            blocks=(fixture_factory(folder) if fixture else
                RealBlocks(folder,request,context.stopped,enabled=True,on_failure=fault))
            write_new(folder/'request.json',request)
            def execute(policy,before,accept):
                def guarded_accept(*args):
                    try:return accept(*args)
                    except BaseException as error:
                        try:partial(type(error).__name__)
                        except BaseException as other:error.partial_write_error_type=type(other).__name__
                        raise
                return blocks(policy,before,guarded_accept)
            summary=core.run(execute)
            if not fixture:os_facts=os_summary(blocks.observations)
            if context.stopped():raise BatchStop('round stopped after last block')
    except BaseException as error:primary=error
    # A retained original supervisor does not reach this post-cleanup area.
    if core is not None:
        for action in (
            lambda:write_new(folder/'timing_rows.json',core.rows),
            lambda:write_new(folder/'coordinator_summary.json',core.summary()),
            lambda:write_new(folder/'os_blocks.json',[] if blocks is None else getattr(blocks,'observations',[]))):
            try:action()
            except BaseException as error:secondary.append(type(error).__name__)
        try:outputs=core.outputs.persist(folder/'outputs')
        except BaseException as error:secondary.append(type(error).__name__)
    if context.restore_errors:secondary.append('SignalRestoreError')
    diagnostic_complete=(primary is None and not secondary and summary is not None
        and summary['ledger']['plan_complete'] is True and outputs is not None)
    result=dict(schema='threeway-round-candidate-receipt-v1',
        diagnostic_complete=diagnostic_complete,operation_success=diagnostic_complete and not fixture,
        fixture=fixture,os_evidence_observed=os_facts is not None and not fixture,
        os_facts=os_facts,error_type=None if primary is None else type(primary).__name__,
        secondary_error_types=secondary,signals=context.report(),
        request_sha256=hashlib.sha256(__import__('cpu_frames').encode(request)).hexdigest(),
        board_access=not fixture,physical_identity_authenticated=False,
        performance_accepted=False,energy_evaluated=False,promotion=False,run_ready=False,
        outer_process_exit_observed_by_this_receipt=False)
    try:
        write_new(folder/'round_receipt.json',result)
        write_new(folder/'evidence_manifest.json',dict(schema='threeway-round-evidence-v1',files=file_inventory(folder)))
    except BaseException as error:
        if primary is None:primary=error
    if primary is not None:
        primary.round_receipt=result;raise primary
    if secondary:raise RuntimeError('round persistence/handler lifecycle failed')
    return result
