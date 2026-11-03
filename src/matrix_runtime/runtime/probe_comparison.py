"""72-plan-slot SYNTHETIC replay, with actual Python owners; no CPU-native/RTL compute."""
from pathlib import Path
import sys
import json
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parent))
import comparison_binding as binding


def replay(manifest_sha,plan_sha,bank_sha):
    binding.check(manifest_sha,plan_sha,bank_sha,enabled=True)
    root=Path(__file__).resolve().parent
    sys.path.insert(0,str(root/'tests'))
    from comparison_policy import ComparisonPolicy
    from comparison_bank import verify_output
    from comparison_call import ComparisonCall
    from serial_plan import SerialPlan
    from test_comparison import Harness,jobs_payload
    from entry_fixture import FakeCanonicalEnvironment
    ledger=SerialPlan(enabled=True)
    blocks=[]
    fpga_python_calls=0
    for b in range(12):
        policy=ComparisonPolicy(b,True);ledger.begin(policy)
        rows=[]
        if policy.backend!='openblas_2t':
            selected=binding.build_fpga(manifest_sha,plan_sha,bank_sha,policy,enabled=True)
            h=Harness(policy);env=FakeCanonicalEnvironment()
            assert type(h.owner) is selected.owner_type
            try:
                with env.install():
                    owner=h.start(env,selected.runner_type)
                    assert type(owner._runner) is selected.runner_type
                    call=ComparisonCall(owner,policy,enabled=True)
                    for _ in range(6):
                        request=ledger.claim();pair=selected.bank[request.dimension,request.input_id]
                        a,c,_,payload=jobs_payload(pair);h.engine.payload=payload
                        output,metrics=call(a,c)
                        digest=verify_output(pair,output)
                        ledger.accept(request,exact=True);fpga_python_calls+=1
                        rows.append(dict(local_index=request.local_index,phase=request.phase,
                            input_id=request.input_id,output_sha256=digest,jobs=metrics['jobs'],
                            effective_macs=metrics['effective_macs'],input_bytes=metrics['input_bytes'],
                            output_bytes=metrics['output_bytes'],first_job_id=metrics['first_job_id']))
                    owner.close()
                    assert env.close_calls==1 and not env.fd_live
            finally:h.discard()
            note='actual derived Python owner/call and pinned driver; OS/PYNQ/DMA synthetic, prefilled golden output'
        else:
            _,pairs=binding.check(manifest_sha,plan_sha,bank_sha,enabled=True)
            for _ in range(6):
                request=ledger.claim();pair=pairs[request.dimension,request.input_id]
                output=np.frombuffer(pair.expected,dtype='<i4').reshape(request.dimension,request.dimension).copy()
                digest=verify_output(pair,output);ledger.accept(request,exact=True)
                rows.append(dict(local_index=request.local_index,phase=request.phase,
                    input_id=request.input_id,output_sha256=digest,cpu_compute_not_run=True))
            note='CPU slots ONLY supplied golden bytes; no native compute, child process or timing'
        # This is the explicitly labelled model. NOT actual OS exit/wait evidence.
        ledger.finish(dict(block_index=b,actual_exit_code=0,process_group_absent=True,
                           cleanup_verified=True,lock_released=True))
        blocks.append(dict(block_index=b,dimension=policy.dimension,backend=policy.backend,
                           rows=rows,evidence=note,terminal_receipt_is_synthetic=True))
    summary=ledger.summary()
    assert summary['plan_complete'] and (summary['formal_calls'],summary['warmup_calls'])==(48,24)
    return dict(summary=summary,blocks=blocks,fpga_python_calls=fpga_python_calls,
        synthetic_only=True,real_os_exit_observed=False,real_fd_or_flock_tested=False,
        cpu_native_compute_executed=False,real_pynq_or_rtl_executed=False,
        timings_excluded=True,board_access=False,promotion=False)


def main():
    p=binding.verifier.JsonParser()
    p.add_argument('--manifest-sha',required=True);p.add_argument('--plan-sha',required=True)
    p.add_argument('--bank-sha',required=True)
    try:
        args=p.parse_args();print(json.dumps(replay(args.manifest_sha,args.plan_sha,args.bank_sha)));return 0
    except (ValueError,OSError,KeyError,TypeError,ImportError) as error:
        print(json.dumps(dict(error=str(error),board_access=False)),file=sys.stderr);return 2


if __name__=='__main__':sys.exit(main())
