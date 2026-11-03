"""Fixed CPU/FPGA OS bridges; internal and unapproved for board activation.

No injection knobs in this runtime. Tests patch dependencies outside it and label
fixtures separately. It uses the original lease/recovery/supervisor, never RUN.sh.
"""
import hashlib
from pathlib import Path
import sys
import outer_binding as binding
from cpu_frames import encode,write_new
from comparison_policy import validate_policy
from supervision_bridge import supervised
import fpga_evidence
from fpga_parent import ProcessGuardian,run_fpga_block,receipt_for_plan as fpga_receipt
from cpu_guardian import CpuGuardian
from cpu_parent import run_cpu_block,receipt_for_plan as cpu_receipt
import cpu_launch_config


def external_folder(path):
    folder=Path(path).absolute()
    for node in [folder,*folder.parents]:binding.base.verifier.no_alias(node)
    if not folder.is_dir() or folder.resolve()!=folder or folder==binding.ROOT or binding.ROOT in folder.parents:
        raise ValueError('existing canonical external evidence directory required')
    return folder


def prepare_fpga(folder,policy,request):
    validate_policy(policy)
    if policy.backend=='openblas_2t':raise ValueError('FPGA fixed command required')
    anchors=binding.request(request);binding.check(anchors)
    folder=external_folder(folder);observation=folder/'fpga_observation'
    if observation.exists():raise ValueError('fresh FPGA observation path required')
    value=dict(request=request,block_index=policy.block_index,stop_flag=str(observation/'stop.flag'),
               expected_lock=fpga_evidence.snapshot())
    raw=encode(value);path=folder/'fpga_config.json'
    with path.open('xb') as stream:stream.write(raw);stream.flush()
    digest=hashlib.sha256(raw).hexdigest()
    command=[sys.executable,'-I','-B',str(binding.ROOT/'fpga_worker_entry.py'),
        '--enabled-private-worker','--config',str(path),'--config-sha',digest]
    return dict(command=command,observation_directory=observation,config_sha256=digest)


class RealBlocks:
    def __init__(self,folder,request,stopped,*,enabled=False,on_failure=None):
        if enabled is not True:raise ValueError('real block bridge default-off')
        binding.require_arm()
        if not callable(stopped):raise ValueError('stop callback required')
        self.anchors=binding.request(request);_,self.bank=binding.check(self.anchors)
        self.folder=external_folder(folder);self.request=dict(request);self.stopped=stopped
        self.on_failure=on_failure
        self.next_block=0;self.failed=False;self.observations=[]
        self.active_guardian=None

    def __call__(self,policy,before,accept):
        validate_policy(policy)
        if self.failed or policy.block_index!=self.next_block:raise RuntimeError('strict serial runtime; no retry')
        if self.stopped() is not False:
            from batch_policy import BatchStop
            raise BatchStop('stop before next real block')
        self.failed=True  # Cleared only after full OS and cleanup acceptance.
        binding.check(self.anchors)
        folder=self.folder/f'block_{policy.block_index:02d}';folder.mkdir()
        publish=lambda row:write_new(folder/'attention_retained.json',row)
        if policy.backend!='openblas_2t':
            guardian=ProcessGuardian(policy,enabled=True)
            self.active_guardian=guardian
            launch=prepare_fpga(folder,policy,self.request)
            def operation(stop):
                return run_fpga_block(launch['command'],launch['observation_directory'],guardian,
                                      stop,before,accept,enabled=True,on_failure=self.on_failure)
            observed=supervised(guardian,operation,publish,self.stopped,enabled=True)['result']
            receipt=fpga_receipt(policy,observed,guardian)
        else:
            # Parent holds the unchanged lock. CPU child must neither inherit nor acquire it.
            from kws_threeway_entry_support_draft import existing_shared_lock_draft
            identity=fpga_evidence.snapshot();holder={'stop':self.stopped}
            guardian=CpuGuardian(policy,lambda:holder['stop'](),enabled=True)
            self.active_guardian=guardian
            def operation(stop):
                holder['stop']=stop
                try:
                    guardian.start(existing_shared_lock_draft)
                    launch=cpu_launch_config.prepare(folder,guardian,*self.anchors,enabled=True)
                    return run_cpu_block(launch['command'],launch['observation_directory'],guardian,
                        stop,self.bank,accept,enabled=True,before_go=before,on_failure=self.on_failure)
                finally:
                    if not guardian._held and not guardian._unsafe:guardian.close()
            observed=supervised(guardian,operation,publish,self.stopped,enabled=True)['result']
            release=fpga_evidence.released(identity)
            observed['release_readback']=release
            receipt=cpu_receipt(policy,observed,guardian)
            observed.update(cleanup_verified=True,lock_released_same_inode=True,
                            cleanup_readback=guardian.cleanup_readback)
        write_new(folder/'accepted_os_observation.json',observed)
        self.observations.append(observed);self.next_block+=1;self.failed=False
        return receipt
