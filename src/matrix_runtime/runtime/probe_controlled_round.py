"""Offline-only shared round controller, actual PC subprocess fixtures, not ARM."""
from pathlib import Path
import sys
import json
import platform
sys.path.insert(0,str(Path(__file__).resolve().parent))
import outer_binding as binding

def main():
    try:
        p=binding.base.verifier.JsonParser()
        for name in ('manifest-sha','plan-sha','bank-sha'):p.add_argument('--'+name,required=True)
        p.add_argument('--evidence-dir',type=Path,required=True);p.add_argument('--enabled-pc-fixture',action='store_true')
        args=p.parse_args()
        if not args.enabled_pc_fixture:raise ValueError('controlled PC probe default-off')
        if platform.machine().lower().startswith(('arm','aarch')):raise RuntimeError('PC fixture forbidden on ARM')
        anchors=(args.manifest_sha,args.plan_sha,args.bank_sha);binding.check(anchors)
        from failure_journal import canonical
        from round_runtime import run_round
        from cpu_frames import write_new
        folder=canonical(args.evidence_dir)
        if folder.exists() or binding.ROOT in folder.parents:raise ValueError('fresh external PC evidence required')
        folder.mkdir()
        sys.path.insert(0,str(binding.ROOT/'tests'));sys.path.insert(0,str(binding.ROOT/'legacy/frozen_tests'))
        from runtime_fixture import PcRuntimeFixture
        value=dict(schema='panel-private-runtime-request-v1',operator='bx',
            board_serial_declared='PC fixture NOT a board',image_declared='pynq-z2-v3.1.1',operator_confirmed=True,
            scope='48-formal-complete-request-latency-only',manifest_sha=anchors[0],plan_sha=anchors[1],bank_sha=anchors[2])
        created=[]
        def factory(target):
            fixture=PcRuntimeFixture(binding.base,anchors,target);created.append(fixture);return fixture
        result=run_round(folder,value,lambda:False,enabled=True,fixture_factory=factory)
        fixture=created[0]
        # Outside the sealed round evidence tree: additional PC harness evidence.
        record=dict(scope='PC injected MMIO/DMA/lock/group only',actual_pc_fpga_processes=len(fixture.fpga),
            actual_pc_cpu_processes=len(fixture.cpu.actual_cpu_children),
            fpga_python_calls=sum(x['checked_calls'] for x in fixture.fpga),
            pc_int64_calls=sum(x['checked_calls'] for x in fixture.cpu.actual_cpu_children),
            operation_success=result['operation_success'],diagnostic_complete=result['diagnostic_complete'],
            fixture=True,board_access=False,run_ready=False,promotion=False)
        write_new(folder.parent/(folder.name+'_pc_processes.json'),record)
        print(json.dumps(record));return 0 if result['diagnostic_complete'] and not result['operation_success'] else 2
    except (OSError,ValueError,RuntimeError,KeyError,TypeError,ImportError) as error:
        print(json.dumps(dict(error_type=type(error).__name__,error=str(error),board_access=False)),file=sys.stderr);return 2

if __name__=='__main__':sys.exit(main())
