"""PC INT64 child fixture ONLY. Never a board/ARM native fallback."""
from pathlib import Path
import os
import platform
import sys
ROOT=Path(__file__).resolve().parent.parent
for path in reversed([ROOT/'src',ROOT/'legacy',ROOT/'legacy/frozen_source']):sys.path.insert(0,str(path))
import argparse
import numpy as np
from comparison_policy import ComparisonPolicy
from comparison_bank import load_bank
from cpu_worker import loop


def main():
    if platform.machine().lower().startswith('arm'):raise RuntimeError('fixture is NOT allowed on ARM board')
    p=argparse.ArgumentParser();p.add_argument('--block',type=int,required=True)
    p.add_argument('--stop',type=Path,required=True);p.add_argument('--fail-compute',action='store_true')
    p.add_argument('--wrong-output',action='store_true');args=p.parse_args()
    policy=ComparisonPolicy(args.block,True)
    bank=load_bank(ROOT,'af893b4381e8c72a667b772b3d40aa7b2db03739232e9f60b21bbb1ef1c939a8')
    inputs={i:bank[policy.dimension,i].arrays() for i in (42,43)}
    def compute(a,b):
        if args.fail_compute:raise RuntimeError('synthetic child compute failure')
        out=(a.astype(np.int64)@b.astype(np.int64)).astype(np.int32)
        if args.wrong_output:out[-1,-1]^=1
        return out
    try:
        return loop(policy,inputs,compute,lambda:True,lambda:os.path.lexists(args.stop),
            sys.stdin.buffer,sys.stdout.buffer,compute_kind='pc_int64_fixture',library_sha=None)
    except Exception as error:
        print(type(error).__name__+': '+str(error),file=sys.stderr);return 73


if __name__=='__main__':sys.exit(main())
