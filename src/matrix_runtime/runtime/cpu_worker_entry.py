"""PRIVATE child entry; only fixed CPU policy and parent-verified original lock ticket."""
from pathlib import Path
import os
import signal
import stat
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import comparison_binding as binding


def read_config(config,expected_sha):
    from comparison_bank import anchor,sha
    path=Path(config).absolute()
    for ancestor in [path,*path.parents]:binding.verifier.no_alias(ancestor)
    info=path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_size>30000:
        raise ValueError('bounded regular CPU configuration required')
    with path.open('rb') as stream:raw=stream.read(30001)
    if len(raw)>30000 or sha(raw)!=anchor(expected_sha):raise ValueError('bounded external CPU config identity')
    value=binding.verifier.read_json(raw)
    if type(value) is not dict or set(value)!={'manifest_sha','plan_sha','bank_sha','block_index','ticket','stop_flag'}:
        raise ValueError('exact CPU private config fields')
    if path==binding.ROOT or binding.ROOT in path.parents:raise ValueError('CPU config must be outside sealed package')
    stop=Path(value['stop_flag']).absolute()
    if (stop.resolve()!=stop or stop.name!='stop.flag' or stop.parent.parent!=path.parent
            or stop==binding.ROOT or binding.ROOT in stop.parents or os.path.lexists(stop)):
        raise ValueError('fresh canonical external stop flag required')
    return value,stop


def run_private(config,config_sha,*,enabled=False):
    if enabled is not True:raise ValueError('private CPU worker default-off')
    binding.configure()
    value,stop=read_config(config,config_sha)
    _,bank=binding.check(value['manifest_sha'],value['plan_sha'],value['bank_sha'],enabled=True)
    from comparison_policy import ComparisonPolicy
    from cpu_native import native_compute,LIB_SHA
    from cpu_worker import loop
    from os_evidence import verify_guardian_ticket
    policy=ComparisonPolicy(value['block_index'],True)
    if policy.backend!='openblas_2t':raise ValueError('CPU worker cannot run FPGA block')
    if os.name!='posix' or os.getsid(0)!=os.getpid() or os.getpgrp()!=os.getpid():
        raise RuntimeError('dedicated Linux child session/process group required')
    verify_guardian_ticket(value['ticket'])  # Also rejects inherited canonical lock FD.
    native=native_compute(binding.ROOT,enabled=True)
    inputs={i:bank[policy.dimension,i].arrays() for i in (42,43)}
    requested=[];previous={};primary=None;result=None;restore_errors=[]
    try:
        for name in ('SIGINT','SIGTERM','SIGHUP'):
            number=getattr(signal,name)
            previous[number]=signal.signal(number,lambda n,f:requested.append(n))
        result=loop(policy,inputs,native,lambda:verify_guardian_ticket(value['ticket']),
            lambda:bool(requested) or os.path.lexists(stop),sys.stdin.buffer,sys.stdout.buffer,
            compute_kind='arm_openblas_2t',library_sha=LIB_SHA)
    except BaseException as error:primary=error
    finally:
        for number,handler in previous.items():
            try:signal.signal(number,handler)
            except BaseException as error:restore_errors.append(type(error).__name__)
    if primary is not None:raise primary
    if requested or restore_errors:raise RuntimeError('CPU stop or signal restoration failure; no success')
    return result


def main():
    import json
    try:
        p=binding.verifier.JsonParser()
        p.add_argument('--config',type=Path,required=True);p.add_argument('--config-sha',required=True)
        p.add_argument('--enabled-private-worker',action='store_true')
        args=p.parse_args();return run_private(args.config,args.config_sha,enabled=args.enabled_private_worker)
    except (ValueError,OSError,RuntimeError,KeyError,TypeError) as error:
        print(json.dumps(dict(error_type=type(error).__name__,error=str(error),promotion=False)),file=sys.stderr)
        return 2


if __name__=='__main__':sys.exit(main())
