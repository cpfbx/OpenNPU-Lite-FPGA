"""Offline checked component selection. NO board or CPU-process launch API."""
import importlib
import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace
import hashlib
import json

ROOT=Path(__file__).resolve().parent
LEGACY_MANIFEST_SHA='589cabf97e07c925e8b6e49c28f4e38f1eb9cb7b9b79bc310666f747de10fc9c'
spec=importlib.util.spec_from_file_location('comparison_checkpoint',ROOT/'legacy/verify_candidate.py')
verifier=importlib.util.module_from_spec(spec);spec.loader.exec_module(verifier)


def cold():
    if any(n=='pynq' or n.startswith('pynq.') for n in sys.modules):
        raise ValueError('fresh cold process required; PYNQ already imported')


def configure():
    # Refuse known module collisions instead of reusing cached foreign objects.
    expected={n:ROOT/'src'/(n+'.py') for n in
              ('comparison_policy','comparison_bank','comparison_owner','comparison_call','serial_plan',
               'cpu_guardian','cpu_frames','cpu_worker','cpu_native','cpu_parent','process_observer',
               'cpu_launch_config','round_artifacts','round_coordinator','supervision_bridge')}
    expected.update({n:ROOT/'legacy'/(n+'.py') for n in ('verify_candidate','binding_flat')})
    for name,path in expected.items():
        if name in sys.modules and Path(getattr(sys.modules[name],'__file__','')).absolute()!=path:
            raise ValueError('comparison module path collision: '+name)
    for entry in reversed([ROOT/'src',ROOT/'legacy',ROOT/'legacy/frozen_source']):
        if str(entry) not in sys.path:sys.path.insert(0,str(entry))


def verify_cpu_sources():
    expected={
        'blas_candidate.py':(5657,'42a5ac0fe3b2d0cf4ea8471df3593f2cb407528f7e8cb7c758dc6fbad1571a27'),
        'libmatrix_blas_arm.so':(86672,'a1ee68685946287785a55e07fb60089441252676fc78ee1756a28c3f5de29c3b'),
        'license':(1548,'190b5a9c8d9723fe958ad33916bd7346d96fab3c5ea90832bb02d854f620fcff')}
    catalog=verifier.read_json((ROOT/'cpu_sources.json').read_bytes())
    if type(catalog) is not dict:raise ValueError('CPU source catalog object required')
    rows=catalog.get('files')
    if catalog.get('schema')!='comparison-cpu-originals-v1' or type(rows) is not list or len(rows)!=3:
        raise ValueError('CPU source catalog shape')
    seen=set()
    for row in rows:
        if type(row) is not dict or set(row)!={'path','archive_sha256','member','bytes','sha256'}:
            raise ValueError('CPU source row shape')
        name=row['path'].removeprefix('runtime_cpu/') if type(row['path']) is str else None
        if name not in expected or name in seen or row['path']!='runtime_cpu/'+name:
            raise ValueError('CPU source member set')
        seen.add(name);size,digest=expected[name]
        if (row['archive_sha256']!='1564a21a016630561e5abd1063b1e304a450ad144aeb95d290afe339f397dab4'
                or row['member']!='candidate/core/frozen/cpu/'+('LICENSE' if name=='license' else name)
                or type(row['bytes']) is not int or row['bytes']!=size or row['sha256']!=digest):
            raise ValueError('CPU source original mapping drift')
        raw=(ROOT/row['path']).read_bytes()
        if len(raw)!=size or hashlib.sha256(raw).hexdigest()!=digest:raise ValueError('CPU source byte drift')
    return True


def check(manifest_sha,plan_sha,bank_sha,*,enabled=False):
    if enabled is not True:raise ValueError('comparison binding default-off')
    cold();verifier.verify(ROOT,manifest_sha)
    verifier.verify(ROOT/'legacy',LEGACY_MANIFEST_SHA)
    configure()
    legacy=importlib.import_module('binding_flat')
    if Path(legacy.__file__).absolute()!=ROOT/'legacy/binding_flat.py':
        raise ValueError('legacy binding path collision')
    components=legacy.build_components(LEGACY_MANIFEST_SHA,enabled=True)
    from comparison_policy import describe_plan
    from comparison_bank import load_bank,anchor
    raw=(ROOT/'plan.json').read_bytes()
    if hashlib.sha256(raw).hexdigest()!=anchor(plan_sha):raise ValueError('external plan identity drift')
    if verifier.read_json(raw)!=describe_plan():raise ValueError('fixed plan contents drift')
    bank=load_bank(ROOT,bank_sha)
    verify_cpu_sources()
    configure();cold()
    return components,bank


def build_fpga(manifest_sha,plan_sha,bank_sha,policy,*,enabled=False):
    components,bank=check(manifest_sha,plan_sha,bank_sha,enabled=enabled)
    from comparison_policy import validate_fpga_policy
    from comparison_owner import ComparisonOwner
    validate_fpga_policy(policy)
    runner=components.runner_type  # Both explicit FPGA backends use reviewed flat packing.
    configure();cold()
    return SimpleNamespace(runner_type=runner,owner_type=ComparisonOwner,
                           lease_type=components.lease_type,bank=bank,policy=policy)


def main():
    try:
        p=verifier.JsonParser()
        p.add_argument('--manifest-sha',required=True)
        p.add_argument('--plan-sha',required=True)
        p.add_argument('--bank-sha',required=True)
        args=p.parse_args()
        _,bank=check(args.manifest_sha,args.plan_sha,args.bank_sha,enabled=True)
        print(json.dumps(dict(check_pass=True,scope='offline plan/bank/legacy binding only',
            bank_pairs=len(bank),formal_calls=48,warmup_calls=24,total_calls=72,
            board_access=False,pynq_imported=False,cpu_worker_implemented=True,
            process_observer_implemented=True,native_arm_execution_tested=False,
            linux_group_query_tested=False,round_callback_core_implemented=True,
            output_retention_implemented=True,supervision_bridge_implemented=True,
            real_round_outer_implemented=False,run_ready=False,promotion=False)))
        return 0
    except (OSError,ValueError,TypeError,KeyError,ImportError) as error:
        print(json.dumps(dict(check_pass=False,error=str(error),board_access=False)),file=sys.stderr)
        return 2


if __name__=='__main__':sys.exit(main())
