"""Fixed private child argv/config preparation ONLY; never launches a process."""
from pathlib import Path
import hashlib
import sys
import comparison_binding as binding
from comparison_policy import validate_policy
from cpu_frames import encode


def prepare(directory,guardian,manifest_sha,plan_sha,bank_sha,*,enabled=False):
    if enabled is not True:raise ValueError('CPU command preparation default-off')
    policy=guardian.policy;validate_policy(policy)
    if policy.backend!='openblas_2t':raise ValueError('CPU command only')
    binding.check(manifest_sha,plan_sha,bank_sha,enabled=True)
    folder=Path(directory).absolute()
    if (not folder.is_dir() or folder.resolve()!=folder or folder==binding.ROOT
            or binding.ROOT in folder.parents):raise ValueError('canonical external block directory required')
    observation=folder/'cpu_observation'
    if observation.exists():raise ValueError('fresh observation directory required')
    ticket=guardian.pre_submit()
    config=dict(manifest_sha=manifest_sha,plan_sha=plan_sha,bank_sha=bank_sha,
        block_index=policy.block_index,ticket=ticket,stop_flag=str(observation/'stop.flag'))
    raw=encode(config);path=folder/'cpu_config.json'
    with path.open('xb') as stream:stream.write(raw);stream.flush()
    digest=hashlib.sha256(raw).hexdigest()
    command=[sys.executable,'-I','-B',str(binding.ROOT/'cpu_worker_entry.py'),
        '--enabled-private-worker','--config',str(path),'--config-sha',digest]
    return dict(command=command,observation_directory=observation,config_sha256=digest,
                config_path=path,process_launched=False)
