"""Sealed component-group composition probe, using fake OS/PYNQ only."""
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('flat_bound_probe',ROOT/'binding_flat.py')
binding=importlib.util.module_from_spec(spec)
spec.loader.exec_module(binding)


def main():
    parser=binding.verifier.JsonParser()
    parser.add_argument('--manifest-sha',required=True)
    args=parser.parse_args()
    components=binding.build_components(args.manifest_sha,enabled=True)
    import numpy as np
    from entry_fixture import FakeCanonicalEnvironment,PynqHarness
    from test_driver_integration import bank
    from batch_call import BatchCall
    from kws_device_supervision_candidate import _needs_retention
    env=FakeCanonicalEnvironment()
    harness=PynqHarness(components.owner_type)
    outputs=[]
    with env.install():
        owner=harness.start(env,runner_type=components.runner_type)
        assert type(owner) is components.owner_type
        assert type(owner._lease) is components.lease_type
        assert type(owner._runner) is components.runner_type
        call=BatchCall(owner,owner.policy,enabled=True)
        for index in (42,43):
            a,b,jobs,payload,expected=bank(index)
            harness.engine.payload=payload
            result,metrics=call(a,b)
            np.testing.assert_array_equal(result,expected)
            outputs.append({'input_id':index,'output_bytes':result.nbytes,
                'cpu_reconstruction_sha256':hashlib.sha256(result.astype('<i4').tobytes()).hexdigest(),
                'simulated_dma_source':'precomputed pinned golden bytes; NOT RTL compute',
                'effective_macs_field':metrics['effective_macs']})
        owner.close()
        assert not env.fd_live and env.close_calls==1
        assert not _needs_retention(owner.supervision_status)
    assert 'pynq' not in sys.modules
    print(json.dumps({'scope':'sealed runner+safe owner+safe lease over fake OS/PYNQ',
        'selected_types':{'owner':components.owner_type.__name__,'lease':components.lease_type.__name__,
                          'runner':components.runner_type.__name__},
        'outputs':outputs,'synthetic_fd_closed':not env.fd_live,'helper_close_calls':env.close_calls,
        'supervisor_retention_condition_after_cleanup':False,'real_supervisor_hold_loop_executed':False,
        'board_access':False,'promotion':False},ensure_ascii=False))
    return 0


if __name__=='__main__':sys.exit(main())
