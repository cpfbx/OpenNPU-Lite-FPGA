"""Pinned private runtime dependencies, not activation or physical authentication."""
import hashlib
import importlib
from pathlib import Path
import platform
import sys
import comparison_binding as base

ROOT=base.ROOT
SOURCES={
 'kws_device_recovery_candidate.py':(5982,'4ed5dd99edc58047a4fcae6c8e3f0bc16bacad14aea85c570e343792b5ea8347','python'),
 'opennpu_gemm_accelerator.bit':(4045769,'47ae0a3640ef6d31db467118fd1822c04d465cd31171275fc04824824a20451c','hardware'),
 'opennpu_gemm_accelerator.hwh':(288097,'d727688adc43d526b853e158648023f230fab081dd84e2c8e86437c60d747294','hardware')}


def check(anchors):
    if type(anchors) is not tuple or len(anchors)!=3:raise ValueError('three external identity anchors required')
    selected,bank=base.check(*anchors,enabled=True)
    raw=(ROOT/'fpga_sources.json').read_bytes();catalog=base.verifier.read_json(raw)
    if type(catalog) is not dict or set(catalog)!={'schema','files'} or catalog['schema']!='threeway-fpga-originals-v1':
        raise ValueError('FPGA source catalog schema')
    rows=catalog['files'];seen=set()
    if type(rows) is not list or len(rows)!=3:raise ValueError('three fixed FPGA originals required')
    for row in rows:
        if type(row) is not dict or set(row)!={'path','member','archive_sha256','bytes','sha256'}:
            raise ValueError('source catalog row')
        name=row['path'].removeprefix('runtime_fpga/') if type(row['path']) is str else None
        if name not in SOURCES or name in seen or row['path']!='runtime_fpga/'+name:raise ValueError('source set mismatch')
        seen.add(name);size,digest,group=SOURCES[name]
        if (type(row['bytes']) is not int or row['bytes']!=size or row['sha256']!=digest
                or row['archive_sha256']!='1564a21a016630561e5abd1063b1e304a450ad144aeb95d290afe339f397dab4'
                or row['member']!='candidate/core/frozen/baseline/'+group+'/'+name):
            raise ValueError('original source mapping drift')
        data=(ROOT/row['path']).read_bytes()
        if len(data)!=size or hashlib.sha256(data).hexdigest()!=digest:raise ValueError('FPGA dependency bytes drift')
    expected={n:ROOT/'src'/(n+'.py') for n in ('fpga_evidence','fpga_parent','fpga_worker','runtime_blocks',
        'failure_journal','round_runtime','panel_runtime_selection','materialized_call_candidate','panel_contiguous_candidate')}
    expected.update(outer_binding=ROOT/'outer_binding.py',kws_device_recovery_candidate=ROOT/'runtime_fpga/kws_device_recovery_candidate.py')
    for name,path in expected.items():
        if name in sys.modules and Path(getattr(sys.modules[name],'__file__','')).absolute()!=path:
            raise ValueError('runtime module path collision: '+name)
    if str(ROOT/'runtime_fpga') not in sys.path:sys.path.insert(0,str(ROOT/'runtime_fpga'))
    base.cold()
    return selected,bank


def require_arm():
    if (platform.system()!='Linux' or platform.machine()!='armv7l' or sys.byteorder!='little'
            or platform.release()!='6.6.10-xilinx-v2024.1-g3c0eca68c652'):
        raise RuntimeError('exact original ARM Linux runtime required; no PC fallback')


def request(value):
    keys={'schema','operator','board_serial_declared','image_declared','operator_confirmed',
          'scope','manifest_sha','plan_sha','bank_sha'}
    if type(value) is not dict or set(value)!=keys:raise ValueError('exact predeclared runtime request required')
    if (value['schema']!='panel-private-runtime-request-v1' or value['operator']!='bx'
            or type(value['board_serial_declared']) is not str or not 1<=len(value['board_serial_declared'])<=128
            or any(ord(c)<32 for c in value['board_serial_declared'])
            or value['image_declared']!='pynq-z2-v3.1.1' or value['operator_confirmed'] is not True
            or value['scope']!='48-formal-complete-request-latency-only'):
        raise ValueError('fixed operator/image/scope declaration required; not physical authentication')
    from comparison_bank import anchor
    return tuple(anchor(value[k]) for k in ('manifest_sha','plan_sha','bank_sha'))


def fpga(policy,anchors):
    check(anchors)
    selected=base.build_fpga(*anchors,policy,enabled=True)
    recovery=importlib.import_module('kws_device_recovery_candidate')
    helper=importlib.import_module('kws_threeway_entry_support_draft')
    base.cold()
    return selected,helper.existing_shared_lock_draft,recovery._Recovery,ROOT/'runtime_fpga/opennpu_gemm_accelerator.bit'
