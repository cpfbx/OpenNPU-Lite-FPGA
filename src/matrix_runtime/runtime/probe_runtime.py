"""Explicit PC-only 12-process round. Not a user-facing board RUN."""
import json
from pathlib import Path
import platform
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import outer_binding


def main():
    try:
        p=outer_binding.base.verifier.JsonParser()
        for name in ('manifest-sha','plan-sha','bank-sha'):p.add_argument('--'+name,required=True)
        p.add_argument('--evidence-dir',type=Path,required=True);p.add_argument('--enabled-pc-fixture',action='store_true')
        args=p.parse_args()
        if not args.enabled_pc_fixture:raise ValueError('PC runtime fixture default-off')
        if platform.machine().lower().startswith(('arm','aarch')):raise RuntimeError('PC fixture forbidden on ARM')
        anchors=(args.manifest_sha,args.plan_sha,args.bank_sha)
        _,bank=outer_binding.check(anchors)
        from cpu_frames import write_new
        from round_coordinator import RoundCoordinator
        folder=args.evidence_dir.absolute()
        if folder.exists() or folder.resolve()!=folder or outer_binding.ROOT in folder.parents:
            raise ValueError('fresh canonical evidence directory outside package required')
        folder.mkdir()
        sys.path.insert(0,str(outer_binding.ROOT/'tests'))
        sys.path.insert(0,str(outer_binding.ROOT/'legacy/frozen_tests'))
        from runtime_fixture import PcRuntimeFixture
        core=RoundCoordinator(bank,lambda:False,enabled=True)
        fixture=PcRuntimeFixture(outer_binding.base,anchors,folder)
        summary=core.run(fixture);outputs=core.outputs.persist(folder/'outputs')
        write_new(folder/'timing_rows.json',core.rows)
        result=dict(summary=summary,outputs=outputs,
            actual_pc_fpga_processes=len(fixture.fpga),actual_pc_cpu_processes=len(fixture.cpu.actual_cpu_children),
            fpga_python_driver_calls=sum(r['checked_calls'] for r in fixture.fpga),
            pc_int64_compute_calls=sum(r['checked_calls'] for r in fixture.cpu.actual_cpu_children),
            scope='PC processes with injected canonical-lock/group queries and synthetic MMIO/DMA',
            native_arm_execution_tested=False,real_linux_lock_release_tested=False,
            board_access=False,performance_evaluated=False,run_ready=False,promotion=False)
        write_new(folder/'runtime_probe.json',result)
        print(json.dumps(result,allow_nan=False));return 0
    except (OSError,ValueError,RuntimeError,KeyError,TypeError,ImportError) as error:
        print(json.dumps(dict(error=str(error),board_access=False)),file=sys.stderr);return 2


if __name__=='__main__':sys.exit(main())
