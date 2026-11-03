"""12 real PC processes; ALL canonical lock/group and MMIO evidence is synthetic."""
from pathlib import Path
import sys
from fpga_parent import ProcessGuardian,run_fpga_block,receipt_for_plan
from round_fixture import PcRoundFixture


class PcRuntimeFixture:
    def __init__(self,binding,anchors,directory):
        self.root=Path(directory);self.binding=binding
        self.cpu=PcRoundFixture(binding,anchors,directory)
        self.fpga=[]

    def __call__(self,policy,before,accept):
        if policy.backend=='openblas_2t':return self.cpu(policy,before,accept)
        folder=self.root/f'block_{policy.block_index:02d}';folder.mkdir()
        observation=folder/'fpga_observation';guardian=ProcessGuardian(policy,enabled=True)
        command=[sys.executable,'-I','-B',str(self.binding.ROOT/'tests/pc_fpga_fixture.py'),
            '--enabled-pc-fixture','--block',str(policy.block_index),'--stop',str(observation/'stop.flag')]
        record=run_fpga_block(command,observation,guardian,lambda:False,before,accept,
            enabled=True,fixture=True,group_query=lambda pid:True,
            lock_snapshot=lambda:dict(device=2048,inode=11,path='/tmp/opennpu-kws-chain.lock'),
            live_query=lambda *args:True,release_query=lambda identity:dict(identity,lock_released_same_inode=True))
        try:receipt_for_plan(policy,record,guardian)
        except ValueError:pass
        else:raise AssertionError('PC FPGA observation incorrectly accepted as real board evidence')
        self.fpga.append(record)
        return dict(block_index=policy.block_index,actual_exit_code=0,process_group_absent=True,
                    cleanup_verified=True,lock_released=True)  # Supplied MODEL receipt only.
