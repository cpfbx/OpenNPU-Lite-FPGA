"""Unapproved private whole-round child; no standalone public activation contract."""
from pathlib import Path
import os
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import outer_binding as binding

def run_private(config,config_sha,evidence,stop,launch_binding,launch_binding_sha,*,enabled=False):
    if enabled is not True:raise ValueError('round child default-off')
    binding.require_arm();binding.base.configure()
    from round_launcher import read_request,read_launch_binding
    from runtime_blocks import external_folder
    from failure_journal import canonical
    from fpga_evidence import snapshot,released
    from round_runtime import run_round
    from cpu_frames import write_new
    request=read_request(config,config_sha)
    folder=external_folder(evidence);stop=canonical(stop)
    if stop.parent!=folder.parent or stop.name!='round.stop':raise ValueError('bound outer stop path required')
    if os.getsid(0)!=os.getpid() or os.getpgrp()!=os.getpid():raise RuntimeError('dedicated round child group/session required')
    identity=snapshot()
    read_launch_binding(launch_binding,launch_binding_sha,folder,request,config_sha,identity)
    primary=None;result=None
    try:result=run_round(folder,request,lambda:os.path.lexists(stop),enabled=True)
    except BaseException as error:primary=error
    # Original nested supervisors cannot reach here with unresolved ownership.
    # This readback is not a substitute for their terminal cleanup checks.
    release=released(identity)
    write_new(folder.parent/'round_child_terminal.json',dict(
        schema='threeway-round-child-terminal-v1',pid=os.getpid(),
        release_readback=release,operation_success=primary is None and result['operation_success'] is True,
        error_type=None if primary is None else type(primary).__name__,promotion=False))
    if primary is not None:raise primary
    return 0

def main():
    import json
    try:
        p=binding.base.verifier.JsonParser()
        for name in ('config','evidence','stop','launch-binding'):p.add_argument('--'+name,type=Path,required=True)
        p.add_argument('--launch-binding-sha',required=True)
        p.add_argument('--config-sha',required=True);p.add_argument('--enabled-private-round',action='store_true')
        args=p.parse_args()
        return run_private(args.config,args.config_sha,args.evidence,args.stop,args.launch_binding,args.launch_binding_sha,enabled=args.enabled_private_round)
    except (OSError,ValueError,RuntimeError,KeyError,TypeError,ImportError) as error:
        print(json.dumps(dict(error_type=type(error).__name__,promotion=False)),file=sys.stderr);return 2

if __name__=='__main__':sys.exit(main())
