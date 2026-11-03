"""Private fixed FPGA child. Default off; NOT a user-facing approved board RUN."""
from pathlib import Path
import os
import stat
import sys
sys.path.insert(0,str(Path(__file__).resolve().parent))
import outer_binding as binding


def read_config(path,sha):
    from comparison_bank import anchor
    path=Path(path).absolute()
    for item in [path,*path.parents]:binding.base.verifier.no_alias(item)
    st=path.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_size>30000:raise ValueError('bounded regular FPGA config required')
    with path.open('rb') as stream:raw=stream.read(30001)
    if len(raw)>30000 or binding.hashlib.sha256(raw).hexdigest()!=anchor(sha):raise ValueError('FPGA config SHA mismatch')
    value=binding.base.verifier.read_json(raw)
    if type(value) is not dict or set(value)!={'request','block_index','stop_flag','expected_lock'}:
        raise ValueError('fixed FPGA config fields')
    if path==binding.ROOT or binding.ROOT in path.parents:raise ValueError('external FPGA config required')
    binding.request(value['request'])
    stop=Path(value['stop_flag']).absolute()
    if (stop.resolve()!=stop or stop.name!='stop.flag' or stop.parent.parent!=path.parent
            or binding.ROOT in stop.parents or os.path.lexists(stop)):
        raise ValueError('fresh canonical external stop path required')
    return value,stop


def run_private(path,sha,*,enabled=False):
    if enabled is not True:raise ValueError('private FPGA worker default-off')
    binding.require_arm()  # Before any lease/Overlay/DMA/native acquisition.
    binding.base.configure();value,stop=read_config(path,sha)
    anchors=binding.request(value['request']);_,bank=binding.check(anchors)
    from comparison_policy import ComparisonPolicy
    from fpga_evidence import snapshot
    from fpga_worker import serve
    from panel_runtime_selection import call_type
    from cpu_frames import write_new
    from failure_journal import FailureJournal
    policy=ComparisonPolicy(value['block_index'],True)
    if os.name!='posix' or os.getsid(0)!=os.getpid() or os.getpgrp()!=os.getpid():
        raise RuntimeError('dedicated FPGA process/session required')
    if snapshot()!=value['expected_lock']:raise RuntimeError('predeclared canonical inode drift')
    selected,lease_factory,recovery,bit=binding.fpga(policy,anchors)
    owner=selected.owner_type(policy,lambda:False,enabled=True)
    def start(current):current.start(selected.runner_type,bit,lease_factory,recovery)
    def publish(record):write_new(Path(path).parent/'attention_retained.json',record)
    journal=FailureJournal(stop.parent/'failure_journal')
    return serve(policy,bank,owner,start,sys.stdin.buffer,sys.stdout.buffer,
                 lambda:os.path.lexists(stop),publish,enabled=True,call_type=call_type(policy),failure_journal=journal)


def main():
    import json
    try:
        p=binding.base.verifier.JsonParser()
        p.add_argument('--config',type=Path,required=True);p.add_argument('--config-sha',required=True)
        p.add_argument('--enabled-private-worker',action='store_true')
        args=p.parse_args();return run_private(args.config,args.config_sha,enabled=args.enabled_private_worker)
    except (OSError,ValueError,RuntimeError,KeyError,TypeError) as error:
        print(json.dumps(dict(error_type=type(error).__name__,error=str(error),promotion=False)),file=sys.stderr)
        return 2


if __name__=='__main__':sys.exit(main())
