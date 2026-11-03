"""Seal-aware runner-type selection; check CLI never constructs PYNQ hardware."""
import hashlib
import importlib
import importlib.util
import json
from pathlib import Path
import re
import sys
from types import SimpleNamespace

ROOT=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('flat_candidate_identity',ROOT/'verify_candidate.py')
verifier=importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)
FROZEN_MODULES=('chain_protocol','tiled_gemm','pynq_gemm','pynq_dma_loopback',
    'd007_mode11_contract','matrix_panel_builder_candidate','batch_owner','batch_policy',
    'batch_call','os_evidence','kws_threeway_entry_support_draft','kws_device_supervision_candidate')


def expected_origins():
    """Canonical archive/member mapping, independently checked at packaging time.

    Runtime enforces this metadata contract and file hashes; it does NOT fetch
    or re-open original archives, nor turn an author's catalog into a signature.
    """
    board='1564a21a016630561e5abd1063b1e304a450ad144aeb95d290afe339f397dab4'
    review='8bd09cf215a28185af5065c029539aca1002628212089fef5eeef98d6a7a839a'
    result={}
    for name in ('chain_protocol','tiled_gemm','pynq_gemm','pynq_dma_loopback','d007_mode11_contract',
                 'kws_threeway_entry_support_draft','kws_device_supervision_candidate'):
        result['frozen_source/'+name+'.py']=(board,'candidate/core/frozen/baseline/python/'+name+'.py')
    result['frozen_source/matrix_panel_builder_candidate.py']=(board,'candidate/core/frozen/baseline/scripts/matrix_panel_builder_candidate.py')
    for name in ('batch_owner','batch_policy','batch_call'):
        result['frozen_source/'+name+'.py']=(board,'candidate/core/src/'+name+'.py')
    result['frozen_source/os_evidence.py']=(board,'candidate/core/frozen/adapter/os_evidence.py')
    for index in (42,43):
        for suffix in ('a','b','expected'):
            name=f'input_{index}_{suffix}.bin'
            result['bank/'+name]=(board,'candidate/core/frozen/bank/'+name)
    prefix='legacy/.offline-results/matrix-source-diagnostic-20261020_01/'
    for name in ('pack_chain_flat_candidate.py','test_flat_candidate.py'):
        result[name]=(review,prefix+name)
    for name in ('test_chain_protocol.py','test_k_major.py','test_d007_mode11_contract.py'):
        result['frozen_tests/'+name]=(review,prefix+'frozen_tests/'+name)
    return result


def require_cold_pynq():
    if any(name=='pynq' or name.startswith('pynq.') for name in sys.modules):
        raise ValueError('cold binding refuses pre-imported PYNQ; use a fresh checked process')


def source_identity():
    value=verifier.read_json((ROOT/'source_identity.json').read_bytes())
    rows=value['files']
    expected=expected_origins()
    if type(rows) is not list or len(rows)!=len(expected):
        raise ValueError('source identity entry count')
    seen=set()
    for item in rows:
        if type(item) is not dict or set(item)!={'path','archive_sha256','member','bytes','sha256'}:
            raise ValueError('source identity row shape')
        verifier.relative_name(item['path'])
        if item['path'] in seen or item['path'] not in expected:
            raise ValueError('source identity duplicate/unexpected member')
        seen.add(item['path'])
        if (item['archive_sha256'],item['member'])!=expected[item['path']]:
            raise ValueError('source archive/member mapping mismatch')
        if (type(item['bytes']) is not int or item['bytes']<0 or type(item['sha256']) is not str
                or re.fullmatch('[0-9a-f]{64}',item['sha256']) is None):
            raise ValueError('source size/hash types')
        raw=(ROOT/item['path']).read_bytes()
        if len(raw)!=item['bytes'] or hashlib.sha256(raw).hexdigest()!=item['sha256']:
            raise ValueError('source snapshot drift')
    return value


def loaded_paths():
    expected={name:ROOT/'frozen_source'/(name+'.py') for name in FROZEN_MODULES}
    expected.update({name:ROOT/(name+'.py') for name in ('flat_driver_candidate','pack_chain_flat_candidate',
                                                        'lease_entry_candidate','owner_entry_candidate')})
    for name,path in expected.items():
        module=sys.modules.get(name)
        if module is not None:
            file=getattr(module,'__file__',None)
            if file is None or Path(file).absolute()!=path:
                raise ValueError('loaded module path collision: '+name)


def build_runner_type(manifest_sha,*,enabled=False):
    if enabled is not True:
        raise ValueError('sealed flat runner binding default-off')
    require_cold_pynq()
    verifier.verify(ROOT,manifest_sha)
    source_identity()
    loaded_paths()
    for entry in reversed([ROOT/'frozen_source',ROOT]):
        if str(entry) not in sys.path:sys.path.insert(0,str(entry))
    flat=importlib.import_module('flat_driver_candidate')
    for name in FROZEN_MODULES:importlib.import_module(name)
    loaded_paths()
    require_cold_pynq()
    return flat.flat_runner_type(enabled=True)


def build_components(manifest_sha,*,enabled=False):
    """Select matching safety owner/observer and flat runner BEFORE acquisition."""
    runner=build_runner_type(manifest_sha,enabled=enabled)
    owner=importlib.import_module('owner_entry_candidate')
    lease=importlib.import_module('lease_entry_candidate')
    loaded_paths()
    require_cold_pynq()
    return SimpleNamespace(runner_type=runner,owner_type=owner.EntrySafeBatchOwner,
                           lease_type=lease.EntrySafeObservedLease)


def main():
    try:
        parser=verifier.JsonParser()
        parser.add_argument('operation',choices=['check'])
        parser.add_argument('--manifest-sha',required=True)
        args=parser.parse_args()
        components=build_components(args.manifest_sha,enabled=True)
        print(json.dumps({'check_pass':True,'scope':'file/import/runner-type only; no construction',
            'runner_class':components.runner_type.__name__,'owner_class':components.owner_type.__name__,
            'lease_class':components.lease_type.__name__,'source_files':len(source_identity()['files']),
            'board_access':False,'pynq_imported':'pynq' in sys.modules,'run_ready':False,'promotion':False}))
        return 0
    except (OSError,ValueError,TypeError,KeyError,ImportError) as error:
        print(json.dumps({'check_pass':False,'error':str(error),'board_access':False}),file=sys.stderr)
        return 2


if __name__=='__main__':sys.exit(main())
