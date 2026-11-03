"""Full 12-block PC integration only; actual PC CPU children, synthetic OS/FPGA.

Not imported by runtime core. Never an ARM fallback. No fixture timing is an
ARM/FPGA performance number and no supplied receipt is an actual outer proof.
"""
import hashlib
import json
import platform
from pathlib import Path
import sys
import time

from comparison_policy import ComparisonPolicy
from comparison_call import ComparisonCall
from panel_runtime_selection import call_type
from comparison_bank import verify_output
from cpu_guardian import CpuGuardian
from cpu_parent import run_cpu_block,receipt_for_plan
from supervision_bridge import supervised
from test_comparison import Harness,jobs_payload
from entry_fixture import FakeCanonicalEnvironment


class PcRoundFixture:
    def __init__(self,binding,anchors,directory):
        if platform.machine().lower().startswith(('arm','aarch')):
            raise RuntimeError('PC fixture cannot run on ARM board')
        self.binding,self.anchors,self.directory=binding,anchors,Path(directory)
        self.blocks=[];self.actual_cpu_children=[]

    def __call__(self,policy,before,accept):
        directory=self.directory/f'block_{policy.block_index:02d}';directory.mkdir()
        env=FakeCanonicalEnvironment()
        if policy.backend=='openblas_2t':
            holder={'stopped':lambda:False}
            factory=CpuGuardian(policy,lambda:holder['stopped'](),enabled=True)
            _,bank=self.binding.check(*self.anchors,enabled=True)
            obs=directory/'cpu_observation'
            command=[sys.executable,'-I','-B',str(self.binding.ROOT/'tests/pc_cpu_fixture.py'),
                '--block',str(policy.block_index),'--stop',str(obs/'stop.flag')]
            def operation(stopped):
                holder['stopped']=stopped
                try:
                    factory.start(env.factory)
                    return run_cpu_block(command,obs,factory,stopped,bank,accept,enabled=True,
                        native_required=False,group_query=lambda pid:True,before_go=before)
                finally:
                    if not factory._held and not factory._unsafe:factory.close()
            with env.install():
                observed=supervised(factory,operation,lambda row:None,lambda:False,enabled=True)
                actual=observed['result'];self.actual_cpu_children.append(actual)
                try:receipt_for_plan(policy,actual,factory)
                except ValueError:pass
                else:raise AssertionError('PC receipt must NOT enter real bridge')
                assert env.close_calls==1 and not env.fd_live
            note='real PC INT64 child/wait/pipe; canonical lock and group query injected'
        else:
            selected=self.binding.build_fpga(*self.anchors,policy,enabled=True)
            h=Harness(policy);factory=h.owner
            def operation(stopped):
                # Thread/process ownership unchanged; original supervisor already installed.
                factory.stop_requested=stopped
                try:
                    h.start(env,selected.runner_type)
                    call=call_type(policy)(factory,policy,enabled=True)
                    for index in range(6):
                        request=policy.request(index);pair=selected.bank[policy.dimension,request.input_id]
                        a,b,_,payload=jobs_payload(pair);h.engine.payload=payload
                        before(request)
                        cpu_start=time.process_time_ns();begin=time.perf_counter_ns()
                        output,metrics=call(a,b)
                        end=time.perf_counter_ns();cpu_ns=time.process_time_ns()-cpu_start
                        digest=verify_output(pair,output)
                        accept(request,dict(begin_ns=begin,end_ns=end,process_cpu_ns=cpu_ns),digest,output)
                finally:
                    if not factory._held and not factory._unsafe:factory.close()
            try:
                with env.install():
                    supervised(factory,operation,lambda row:None,lambda:False,enabled=True)
                    assert env.close_calls==1 and not env.fd_live
            finally:h.discard()
            note='real pinned Python owner/driver; prefilled golden output, MMIO/DMA/lock synthetic'
        self.blocks.append(dict(block_index=policy.block_index,backend=policy.backend,
            dimension=policy.dimension,evidence=note,terminal_receipt_supplied=True,
            original_supervisor_returned=True,fixture_helper_closed_once=env.close_calls==1))
        return dict(block_index=policy.block_index,actual_exit_code=0,process_group_absent=True,
            cleanup_verified=True,lock_released=True)  # Explicitly supplied model receipt.
