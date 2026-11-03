"""Unapproved outer candidate: fixed child, actual wait, original retained supervisor.

Only bx can activate a separately reviewed/approved board package. This file is
provided for OFFLINE review, not an activation approval, remote API or retry tool.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import threading
import outer_binding as binding
from cpu_frames import write_new
from failure_journal import canonical,bounded_read,strict_json
from process_observer import observe_exit
from supervision_bridge import supervised
from round_runtime import file_inventory,strict_equal
import fpga_evidence

def read_request(path,digest):
    from comparison_bank import anchor
    path=canonical(path)
    if binding.ROOT in path.parents:raise ValueError('external predeclared config required')
    raw=bounded_read(path,30000)
    if hashlib.sha256(raw).hexdigest()!=anchor(digest):raise ValueError('whole-round config SHA drift')
    value=strict_json(raw)
    keys={'schema','request','utc_verified','board_idle_verified','single_supply_verified','separate_scope_approved'}
    if (type(value) is not dict or set(value)!=keys or value['schema']!='threeway-round-launch-config-v1'
            or any(value[k] is not True for k in keys-{'schema','request'})):
        raise ValueError('explicit fresh operator confirmations required')
    binding.request(value['request']);return value['request']

def read_launch_binding(path,digest,folder,request,config_sha,identity):
    from comparison_bank import anchor
    path=canonical(path)
    if path!=folder.parent/'launch_request.json':raise ValueError('fixed external launch binding path required')
    raw=bounded_read(path,30000)
    if hashlib.sha256(raw).hexdigest()!=anchor(digest):raise ValueError('launch binding SHA drift')
    value=strict_json(raw)
    if (type(value) is not dict or set(value)!={'config_sha256','request','expected_lock'}
            or value['config_sha256']!=config_sha or value['request']!=request):
        raise ValueError('launch/child request binding drift')
    if (type(value['expected_lock']) is not dict or value['expected_lock']!=identity
            or any(type(value['expected_lock'].get(k)) is not type(v) for k,v in identity.items())):
        raise RuntimeError('parent predeclared canonical inode changed before round entry')
    return True

class RoundGuardian:
    def __init__(self):
        self.pid=os.getpid();self.thread=threading.get_ident();self.child=None;self._held=False
    def _hold(self,error):self._held=True
    @property
    def supervision_status(self):
        return dict(pid=self.pid,held=self._held,safety_unresolved=self._held,
            lease_retained=False,runner_retained=self.child is not None,root_buffers_retained=0)
    def retain(self,child):
        if self.child is not None or self._held or (os.getpid(),threading.get_ident())!=(self.pid,self.thread):
            raise RuntimeError('exact serial round ownership required')
        self.child=child
    def forget(self,child):
        if self._held or self.child is not child:raise RuntimeError('unresolved whole-round child')
        self.child=None

def verify_artifacts(folder):
    raw=bounded_read(folder/'evidence_manifest.json',2*1024*1024)
    manifest=strict_json(raw)
    actual=file_inventory(folder);actual.pop('evidence_manifest.json',None)
    if (type(manifest) is not dict or set(manifest)!={'schema','files'}
            or manifest['schema']!='threeway-round-evidence-v1' or manifest['files']!=actual):
        raise ValueError('whole-round artifact identity mismatch')
    return dict(files=len(actual),manifest_sha256=hashlib.sha256(raw).hexdigest())

def validate_child(folder,pid,identity,request):
    terminal=strict_json(bounded_read(folder.parent/'round_child_terminal.json',8192))
    if not strict_equal(terminal,dict(schema='threeway-round-child-terminal-v1',pid=pid,promotion=False)):
        raise ValueError('exact round terminal identity required')
    released=fpga_evidence.released(identity)
    if terminal.get('release_readback')!=released:raise ValueError('independent whole-round release readback drift')
    artifacts=verify_artifacts(folder)
    receipt=strict_json(bounded_read(folder/'round_receipt.json',65536))
    from cpu_frames import encode
    if (not strict_equal(receipt,dict(schema='threeway-round-candidate-receipt-v1',fixture=False,
            run_ready=False,promotion=False,physical_identity_authenticated=False))
            or receipt.get('request_sha256')!=hashlib.sha256(encode(request)).hexdigest()):
        raise ValueError('bound child receipt identity required')
    if receipt.get('operation_success') is True:validate_success(folder,receipt,request)
    return terminal,receipt,artifacts,released

def validate_success(folder,receipt,request):
    """Parent re-reads frozen-plan counts, per-block facts and retained golden SHAs.
    This is consistency checking of the pinned child's artifacts, not independent
    authentication against an adversary who replaces all files and manifests.
    """
    from dataclasses import asdict
    from comparison_policy import ComparisonPolicy
    from round_runtime import os_summary
    from round_artifacts import descriptive_stats
    from comparison_bank import load_bank
    if strict_json(bounded_read(folder/'request.json',30000))!=request:raise ValueError('artifact request drift')
    observations=strict_json(bounded_read(folder/'os_blocks.json',4*1024*1024))
    if os_summary(observations)!=receipt.get('os_facts'):raise ValueError('outer OS summary differs from reread blocks')
    rows=strict_json(bounded_read(folder/'timing_rows.json',1024*1024))
    if descriptive_stats(rows)['complete_72_rows'] is not True:raise ValueError('72 complete timing rows required')
    for index,row in enumerate(rows):
        if row['request']!=asdict(ComparisonPolicy(index//6,True).request(index%6)):
            raise ValueError('exact fixed timing order required')
    signals=receipt.get('signals')
    if signals!={'stop_signals':[],'handler_restore_errors':[]} or receipt.get('secondary_error_types')!=[]:
        raise ValueError('clean whole-round handler lifecycle required')
    ledger=strict_json(bounded_read(folder/'coordinator_summary.json',1024*1024)).get('ledger')
    if not strict_equal(ledger,dict(plan_complete=True,formal_calls=48,warmup_calls=24,
            completed_blocks=12,stop_latched=False,fault_latched=False)):
        raise ValueError('complete fixed coordinator ledger required')
    bank=load_bank(binding.ROOT,request['bank_sha'])
    retained=strict_json(bounded_read(folder/'outputs/outputs.json',65536))
    outputs=retained.get('outputs')
    if type(outputs) is not list or len(outputs)!=12:raise ValueError('12 fixed retained outputs required')
    for index,row in enumerate(outputs):
        spec=ComparisonPolicy(index,True).request(2);name=f'success_block_{index:02d}.bin'
        expected=bank[spec.dimension,spec.input_id].expected
        if (type(row) is not dict or row.get('path')!=name or row.get('request')!=asdict(spec)
                or row.get('encoding')!='row-major-int32-le' or type(row.get('bytes')) is not int
                or row['bytes']!=len(expected) or row.get('sha256')!=hashlib.sha256(expected).hexdigest()
                or bounded_read(folder/'outputs'/name,1048576)!=expected):
            raise ValueError('fixed representative golden output mismatch')
    return True

def launch(config,config_sha,evidence,*,enabled=False,confirmed=False):
    if enabled is not True or confirmed is not True:raise ValueError('unapproved candidate default-off')
    binding.require_arm();binding.base.configure()
    request=read_request(config,config_sha);binding.check(binding.request(request))
    folder=canonical(evidence)
    if os.path.lexists(folder) or binding.ROOT in folder.parents:raise ValueError('fresh external whole-round evidence required')
    identity=fpga_evidence.snapshot()  # Existing original lock only. No bootstrap.
    fpga_evidence.released(identity)  # Read-only kernel check, not a reservation or idle proof.
    folder.mkdir();work=folder/'round';work.mkdir();stop=folder/'round.stop'
    guardian=RoundGuardian();record=dict(schema='threeway-outer-exit-candidate-v1',
        actual_exit_code=None,actual_wait_observed=False,process_group_absent=None,
        operation_success=False,automatic_kill=False,automatic_retry=False,promotion=False,run_ready=False)
    primary=None;secondary_errors=[]
    def remember(error,stage):
        nonlocal primary
        if primary is None:primary=error
        elif error is not primary:
            secondary_errors.append(dict(stage=stage,error_type=type(error).__name__))
        # Types/stages only: never serialize exception messages or tracebacks.
        primary.round_secondary_errors=list(secondary_errors)
        record.update(error_type=type(primary).__name__,secondary_errors=list(secondary_errors))
        return primary
    binding_file=folder/'launch_request.json'
    write_new(binding_file,dict(config_sha256=config_sha,request=request,expected_lock=identity))
    binding_sha=hashlib.sha256(bounded_read(binding_file,30000)).hexdigest()
    def cancel():
        try:
            with stop.open('xb') as stream:stream.write(b'STOP\n')
        except FileExistsError:pass
    def publish(row):
        value=dict(row,outer_primary_error_type=None if primary is None else type(primary).__name__,
                   outer_secondary_errors=list(secondary_errors))
        try:write_new(folder/'attention_retained.json',value)
        except BaseException as error:
            remember(error,'attention_retained');raise
    def operation(stopped):
        nonlocal primary
        child=None
        try:
            if stopped() is not False:
                from batch_policy import BatchStop
                raise BatchStop('stop before round child')
            command=[sys.executable,'-I','-B',str(binding.ROOT/'round_worker_entry.py'),
                '--config',str(Path(config).absolute()),'--config-sha',config_sha,
                '--evidence',str(work),'--stop',str(stop),'--launch-binding',str(binding_file),
                '--launch-binding-sha',binding_sha,'--enabled-private-round']
            with (folder/'round.stdout').open('xb') as out,(folder/'round.stderr').open('xb') as err:
                child=subprocess.Popen(command,stdout=out,stderr=err,stdin=subprocess.DEVNULL,
                    close_fds=True,shell=False,start_new_session=True)
                guardian.retain(child)
                try:write_new(folder/'child_started.json',dict(pid=child.pid,argv=command))
                except BaseException as error:
                    remember(error,'child_started')
                    try:cancel()
                    except BaseException as secondary:
                        primary.stop_write_error_type=type(secondary).__name__
                        remember(secondary,'stop_flag')
                # Even receipt-write failure never skips the real wait/group query.
                try:record.update(observe_exit(child,guardian,stopped,cancel))
                except BaseException as error:
                    partial=getattr(error,'comparison_exit_observation',None)
                    if partial is not None:record.update(partial)
                    remember(error,'observe_exit')
            try:write_new(folder/'observed_child_exit.json',record)
            except BaseException as error:
                remember(error,'observed_child_exit')
            if record['actual_wait_observed'] is not True or record['process_group_absent'] is not True:
                raise primary or RuntimeError('actual whole-round wait/group required')
            terminal,receipt,artifacts,release=validate_child(work,child.pid,identity,request)
            record.update(child_receipt=receipt,artifact_identity=artifacts,release_readback=release)
            guardian.forget(child)  # Only after actual wait/group and independent readback.
            if primary is not None:raise primary
            if (record['actual_exit_code']!=0 or terminal.get('operation_success') is not True
                    or receipt.get('operation_success') is not True or receipt.get('diagnostic_complete') is not True
                    or receipt.get('os_evidence_observed') is not True):
                raise RuntimeError('round unsuccessful; no retry or performance acceptance')
            record['operation_success']=True
            return record
        except BaseException as error:
            remember(error,'operation_exit')
            if child is not None and guardian.child is not None:
                guardian._hold(primary)
                # Supervisor retains the actual child handle; never release unknown state.
            raise primary
    try:
        result=supervised(guardian,operation,publish,lambda:False,enabled=True)
        record['signals']=result['signals']
    except BaseException as error:
        remember(error,'supervision')
        record.update(operation_success=False,error_type=type(primary).__name__,
            signals=getattr(error,'supervision_bridge_observation',None))
    # Unresolved original supervisor cannot reach this final receipt.
    try:write_new(folder/'outer_receipt.json',record)
    except BaseException as error:
        remember(error,'outer_receipt');record['operation_success']=False
    if primary is not None:raise primary
    return record
