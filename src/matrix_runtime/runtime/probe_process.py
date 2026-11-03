"""Actual PC Popen/wait records; canonical lock and Windows group proof are synthetic."""
from pathlib import Path
import json
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import comparison_binding as binding


def replay(manifest_sha,plan_sha,bank_sha,evidence):
    _,bank=binding.check(manifest_sha,plan_sha,bank_sha,enabled=True)
    from comparison_policy import ComparisonPolicy
    from cpu_guardian import CpuGuardian,_RETAINED
    from cpu_parent import run_cpu_block,receipt_for_plan
    from cpu_frames import write_new
    from batch_policy import BatchStop
    from entry_fixture import FakeCanonicalEnvironment
    evidence=Path(evidence).absolute()
    if evidence.exists() or evidence.resolve()!=evidence or binding.ROOT in evidence.parents:
        raise ValueError('fresh canonical evidence OUTSIDE sealed candidate required')
    evidence.mkdir()
    records=[]
    for label,block,mode in (('normal256',2,'normal'),('normal512',8,'normal'),
                             ('wrong_output',2,'wrong'),('stop_after_first',2,'stop')):
        stop={'value':False};guardian=CpuGuardian(ComparisonPolicy(block,True),lambda:stop['value'],enabled=True)
        environment=FakeCanonicalEnvironment();accepted=[];folder=evidence/label
        command=[sys.executable,'-I','-B',str(binding.ROOT/'tests/pc_cpu_fixture.py'),
                 '--block',str(block),'--stop',str(folder/'stop.flag')]
        if mode=='wrong':command.append('--wrong-output')
        expected_error=None;receipt=None
        def accept(spec,row,digest,output):
            accepted.append(dict(local_index=spec.local_index,input_id=spec.input_id,sha256=digest,
                begin_ns=row['begin_ns'],end_ns=row['end_ns'],process_cpu_ns=row['process_cpu_ns']))
            if mode=='stop':stop['value']=True
        try:
            with environment.install():
                guardian.start(environment.factory)
                try:
                    receipt=run_cpu_block(command,folder,guardian,lambda:stop['value'],bank,accept,
                        enabled=True,native_required=False,group_query=lambda pid:True)
                    if mode!='normal':raise AssertionError('expected injected failure/stop')
                except ValueError as error:
                    if mode!='wrong':raise
                    expected_error=type(error).__name__
                except BatchStop as error:
                    if mode!='stop':raise
                    expected_error=type(error).__name__
                record=json.loads((folder/'actual_exit.json').read_bytes())
                assert record['actual_wait_observed'] is True
                assert record['group_query_injected'] is True and record['native_compute'] is False
                assert record['popen_factory_injected'] is False
                assert record['actual_exit_code']==(0 if mode=='normal' else 73)
                assert len(accepted)==(6 if mode=='normal' else 1 if mode=='stop' else 0)
                guardian.close();assert environment.close_calls==1 and not environment.fd_live
                if receipt is not None:
                    try:receipt_for_plan(guardian.policy,receipt,guardian)
                    except ValueError:pass
                    else:raise AssertionError('PC/mock group cannot promote into real plan receipt')
        finally:
            if guardian in _RETAINED:_RETAINED.remove(guardian)  # synthetic fixture registry only
        write_new(folder/'accepted.json',dict(accepted=accepted,source='PC INT64 fixture only, not ARM timings'))
        records.append(dict(case=label,block_index=block,expected_error=expected_error,observation=record,
                            accepted_calls=len(accepted),fake_helper_close_calls=environment.close_calls))
    result=dict(cases=records,successful_fixture_requests=12,real_pc_processes=4,
        actual_wait_observed=True,real_canonical_lock_tested=False,real_posix_group_query_tested=False,
        cpu_native_arm_executed=False,all_timings_are_pc_fixture_only=True,
        allowed_as_board_evidence=False,board_access=False,promotion=False)
    write_new(evidence/'summary.json',result)
    return result


def main():
    p=binding.verifier.JsonParser()
    p.add_argument('--manifest-sha',required=True);p.add_argument('--plan-sha',required=True)
    p.add_argument('--bank-sha',required=True);p.add_argument('--evidence-dir',required=True,type=Path)
    try:
        args=p.parse_args()
        print(json.dumps(replay(args.manifest_sha,args.plan_sha,args.bank_sha,args.evidence_dir)))
        return 0
    except (ValueError,OSError,KeyError,TypeError,ImportError,RuntimeError) as error:
        print(json.dumps(dict(error_type=type(error).__name__,error=str(error),board_access=False)),file=sys.stderr);return 2


if __name__=='__main__':sys.exit(main())
