"""Explicit PC-only fixture entry; never an authorized board launcher."""
from pathlib import Path
import sys
import json
sys.path.insert(0,str(Path(__file__).resolve().parent))
import comparison_binding as binding


def replay(manifest_sha,plan_sha,bank_sha,directory,*,enabled=False):
    if enabled is not True:raise ValueError('round PC fixture default-off')
    _,bank=binding.check(manifest_sha,plan_sha,bank_sha,enabled=True)
    folder=Path(directory).absolute()
    if folder.exists() or folder.resolve()!=folder:raise ValueError('fresh canonical external fixture directory required')
    if folder.is_relative_to(binding.ROOT):raise ValueError('evidence must be outside package')
    # PC fixture explicitly selected, never fallback for a native failure.
    sys.path.insert(0,str(binding.ROOT/'tests'))
    from round_fixture import PcRoundFixture
    from round_coordinator import RoundCoordinator
    from cpu_frames import write_new
    fixture=PcRoundFixture(binding,(manifest_sha,plan_sha,bank_sha),folder)
    folder.mkdir()
    core=RoundCoordinator(bank,lambda:False,enabled=True)
    summary=core.run(fixture)
    outputs=core.outputs.persist(folder/'retained_outputs')
    write_new(folder/'timing_rows.json',dict(rows=core.rows,performance_evidence=False))
    result=dict(summary=summary,blocks=fixture.blocks,actual_cpu_children=fixture.actual_cpu_children,
        outputs=outputs,pc_only=True,actual_pc_cpu_processes=len(fixture.actual_cpu_children),
        pc_int64_compute_calls=sum(c['checked_calls'] for c in fixture.actual_cpu_children),
        fpga_python_calls=48,synthetic_fpga_hardware=True,canonical_lock_tested=False,
        real_posix_group_query_tested=False,native_arm_executed=False,
        original_supervisor_exercised_normal_exit=True,quarantine_hold_exercised=False,
        timings_are_performance_evidence=False,run_ready=False,board_access=False,promotion=False)
    assert summary['ledger']['plan_complete'] and len(fixture.blocks)==12
    assert result['actual_pc_cpu_processes']==4 and result['pc_int64_compute_calls']==24
    write_new(folder/'round_summary.json',result)
    return result


def main():
    try:
        p=binding.verifier.JsonParser()
        p.add_argument('--manifest-sha',required=True);p.add_argument('--plan-sha',required=True)
        p.add_argument('--bank-sha',required=True);p.add_argument('--evidence-dir',required=True)
        p.add_argument('--enabled-pc-fixture',action='store_true')
        a=p.parse_args();result=replay(a.manifest_sha,a.plan_sha,a.bank_sha,a.evidence_dir,enabled=a.enabled_pc_fixture)
        print(json.dumps(result));return 0
    except (OSError,ValueError,TypeError,KeyError,ImportError,RuntimeError) as error:
        print(json.dumps(dict(error_type=type(error).__name__,error=str(error),board_access=False,promotion=False)),file=sys.stderr)
        return 2


if __name__=='__main__':sys.exit(main())
