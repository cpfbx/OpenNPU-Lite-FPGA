"""PC subprocess exercising pinned Python FPGA driver over synthetic MMIO/DMA.

NEVER real FPGA or ARM fallback. Canonical-lock OS calls are replaced only inside
the fixture; fd 99 is synthetic and is never opened/closed on the real OS.
"""
from pathlib import Path
import argparse
import os
import platform
import sys
ROOT=Path(__file__).resolve().parent.parent
for entry in reversed([ROOT/'tests',ROOT/'src',ROOT,ROOT/'legacy',ROOT/'legacy/frozen_source',ROOT/'legacy/frozen_tests']):
    sys.path.insert(0,str(entry))
from comparison_policy import ComparisonPolicy
from comparison_call import ComparisonCall
from panel_runtime_selection import call_type
from fpga_worker import serve
from entry_fixture import FakeCanonicalEnvironment
from test_comparison import Harness,jobs_payload


def main():
    if platform.machine().lower().startswith(('arm','aarch')):raise RuntimeError('PC FPGA fixture forbidden on ARM')
    parser=argparse.ArgumentParser()
    parser.add_argument('--block',type=int,required=True);parser.add_argument('--stop',type=Path,required=True)
    parser.add_argument('--enabled-pc-fixture',action='store_true')
    parser.add_argument('--wrong-output',action='store_true');parser.add_argument('--nonzero-after-done',action='store_true')
    parser.add_argument('--bad-metrics',action='store_true')
    parser.add_argument('--call-error',action='store_true')
    args=parser.parse_args()
    if not args.enabled_pc_fixture:raise ValueError('PC FPGA fixture default-off')
    policy=ComparisonPolicy(args.block,True);h=Harness(policy);env=FakeCanonicalEnvironment()
    class Call:
        def __init__(self,owner,selected,*,enabled=False):
            self.inner=call_type(selected)(owner,selected,enabled=enabled);self.index=0
        def __call__(self,a,b):
            spec=policy.request(self.index)
            h.engine.payload=jobs_payload(h.bank[policy.dimension,spec.input_id])[3]
            output,metrics=self.inner(a,b);self.index+=1
            if args.call_error:
                error=ValueError('injected Call post-return error')
                error.matrix_returned_payload=h.engine.payload
                raise error
            if args.wrong_output:output[-1,-1]^=1
            if args.bad_metrics:metrics['chain_jobs_completed']=False
            return output,metrics
    def start(owner):
        assert owner is h.owner
        h.start(env)
        h.owner._recovery.last_diagnostics['confirmed']=True  # Synthetic recovery only.
    try:
        from failure_journal import FailureJournal
        journal=FailureJournal(args.stop.parent/'failure_journal')
        with env.install():
            serve(policy,h.bank,h.owner,start,sys.stdin.buffer,sys.stdout.buffer,
                lambda:os.path.lexists(args.stop),lambda row:None,enabled=True,
                call_type=Call,compute_kind='pc_fpga_fixture',failure_journal=journal)
        return 73 if args.nonzero_after_done else 0
    except Exception as error:
        print(type(error).__name__+': '+str(error),file=sys.stderr);return 73
    finally:h.discard()


if __name__=='__main__':sys.exit(main())
